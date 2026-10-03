{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The status-bar section of the tray surface — the xmobar
-- replacement.
--
-- Phase 1: xmonad workspaces from the EWMH root properties
-- (_NET_DESKTOP_NAMES / _NET_CURRENT_DESKTOP), clickable buttons; a
-- left click sends the _NET_CURRENT_DESKTOP client message back.
--
-- Phase 2: taskbar — windows of the current workspace from
-- _NET_CLIENT_LIST_STACKING (+ _NET_WM_DESKTOP / _NET_WM_NAME /
-- _NET_WM_PID / _NET_WM_WINDOW_TYPE), focused one highlighted;
-- click sends _NET_ACTIVE_WINDOW. homgb's own surfaces (matched by
-- PID) and DOCK/DESKTOP windows (xmobar, trayer, desktop icons) are
-- filtered out. No xmonad.hs changes needed.
--
-- Also hosts the shared tray-layout helpers (sameLineS, framePad*):
-- both this module and Homgb.Tray.Render need them.
module Homgb.Bar
  ( BarState(..)
  , WinInfo(..)
  , newBarState
  , refreshBar
  , startBarEvents
  , renderBar
  , renderWorkspaces
  , renderWinButtons
  , measureWorkspaces
  , measureWinButtons
  , barActiveTitle
  , capTitleChars
  , renderClockWidget
  , renderDateWidget
  , fitTitleWidth
  , renderSep
  , sepWidth
  , centerCursorY
  , sameLineS
  , framePadX
  , framePadY
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (IOException, catch)
import Control.Monad (forM, forM_, void, when)
import Data.Bits ((.|.))
import Data.Char (chr)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime, zonedTimeToLocalTime)
import qualified Data.ByteString as BS
import Data.List (find)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.Types (CFloat(..), CLong(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)
import Graphics.X11.Types (Atom, Window, propertyChangeMask, substructureNotifyMask)
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Atom (internAtom)
import Graphics.X11.Xlib.Display (defaultRootWindow, openDisplay)
import Graphics.X11.Xlib.Event (allocaXEvent, nextEvent, selectInput)
import Graphics.X11.Xlib.Extras
  (getWindowProperty8, getWindowProperty32, getWindowAttributes
  , wa_map_state, waIsViewable)
import Graphics.X11.Xlib.Misc (getGeometry)
import System.Posix.Process (getProcessID)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import Homgb.WMProps (installErrorHandler)

import DearImGui hiding (begin, w)
import qualified DearImGui.Raw as Raw (pushStyleColor, textColored, setCursorPos)

import Homgb.Config (Config(..))
import Homgb.Theme (Theme(..))

-- | One taskbar entry.
data WinInfo = WinInfo
  { wiXid :: CLong
  , wiTitle :: T.Text
  } deriving (Show, Eq)

-- | Cached EWMH desktop/taskbar state (see 'refreshBar').
data BarState = BarState
  { barPid :: CLong
    -- ^ homgb's own pid: surfaces are excluded from the taskbar
  , barCurrent :: Int
  , barNames :: [T.Text]
  , barActiveWindow :: CLong
    -- ^ _NET_ACTIVE_WINDOW (0 when none)
  , barWindows :: [WinInfo]
    -- ^ current-workspace windows, bottom-to-top stacking order
  , barCovered :: Bool
    -- ^ a window overlaps the bar's strip (ToggleStruts, fullscreen
    --   layouts, floated windows): the bar surface hides
  } deriving (Show, Eq)

newBarState :: IO (TVar BarState)
newBarState = do
  pid <- fromIntegral <$> getProcessID
  newTVarIO (BarState pid (-1) [] 0 [] False)

-- | Blocking X event listener on its OWN display (Xlib displays are
-- not thread-safe; the render thread keeps trayDisplay). Selects
-- root property changes (workspace/focus/client-list) and child
-- map/unmap/configure on the root, and sets the dirty flag on every
-- event — the frame loop re-reads the EWMH state only then, plus a
-- slow 5s safety re-sync for what root selection cannot see (e.g.
-- _NET_WM_NAME changes on client windows, which need per-window
-- selection). This replaces the old unconditional 5Hz polling.
-- `wake` interrupts the render loop's timed SDL wait: a root restack
-- with unchanged root properties would otherwise sit unprocessed
-- until the next deadline.
startBarEvents :: TVar Bool -> IO () -> IO ()
startBarEvents dirty wake = do
  mDpy <- catch (Just <$> openDisplay "")
    (\(_ :: IOException) -> return Nothing)
  forM_ mDpy $ \dpy -> do
    installErrorHandler dpy
    selectInput dpy (defaultRootWindow dpy)
      (substructureNotifyMask .|. propertyChangeMask)
    void $ forkIO $ forever' $ allocaXEvent $ \ev -> do
      nextEvent dpy ev
      atomically $ writeTVar dirty True
      wake
  where
    forever' act = act >> forever' act

-- | Re-read the EWMH properties into the TVar. Cheap Xlib reads; call
-- at a few Hz from the frame loop. Windows appearing/vanishing mid
-- poll yield Nothing reads and are skipped. mStrut is the bar's own
-- reserved strip (depth, x0, x1): any current-workspace window
-- intersecting it sets barCovered.
refreshBar :: Display -> Maybe (Int, Int, Int) -> TVar BarState -> IO ()
refreshBar dpy mStrut st = do
  old <- readTVarIO st
  atoms <- mapM (\n -> internAtom dpy n False)
    [ "_NET_CURRENT_DESKTOP", "_NET_DESKTOP_NAMES", "_NET_ACTIVE_WINDOW"
    , "_NET_CLIENT_LIST_STACKING", "_NET_WM_DESKTOP", "_NET_WM_PID"
    , "_NET_WM_WINDOW_TYPE", "_NET_WM_NAME"
    , "_NET_WM_WINDOW_TYPE_DOCK", "_NET_WM_WINDOW_TYPE_DESKTOP" ]
  let root = defaultRootWindow dpy
  cur <- readOneDef dpy (atoms !! 0) root (-1)
  names <- readNames dpy (atoms !! 1) root
  active <- fromIntegral <$> readOneDef dpy (atoms !! 2) root (0 :: Int)
  stack <- readWinList dpy (atoms !! 3) root
  winPairs <- concat <$> forM stack (\wxid ->
    maybe [] (:[]) <$> readWindow dpy (atoms !! 4) (atoms !! 5) (atoms !! 6)
                     (atoms !! 7) (atoms !! 8) (atoms !! 9)
                     (barPid old) cur wxid)
  let wins = map fst winPairs
      covered = case mStrut of
        Just (depth, sx0, sx1) ->
          any (\(_, (wx, wy, ww, wh)) -> intersects (sx0, sx1, depth) (wx, wy, ww, wh)) winPairs
        Nothing -> False
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ | covered -> hPutStrLn stderr $ "bar covered by: "
      ++ show [ (wxid, (wx, wy, ww, wh))
              | (WinInfo wxid _, (wx, wy, ww, wh)) <- winPairs
              , maybe False (\(depth, sx0, sx1) ->
                  intersects (sx0, sx1, depth) (wx, wy, ww, wh)) mStrut ]
    _ -> return ()
  atomically $ writeTVar st old
    { barCurrent = cur
    , barNames = names
    , barActiveWindow = active
    , barWindows = wins
    , barCovered = covered
    }
  where
    intersects (sx0, sx1, depth) (wx, wy, ww, wh) =
      wx < sx1 + 1 && wx + fromIntegral ww > sx0
        && wy < depth && wy + fromIntegral wh > (0 :: Int)

readOneDef :: Display -> Atom -> Window -> Int -> IO Int
readOneDef dpy atom win def = do
  m <- getWindowProperty32 dpy atom win
  return $ case m of
    Just (v:_) -> fromIntegral v
    _ -> def

readWinList :: Display -> Atom -> Window -> IO [CLong]
readWinList dpy atom win = do
  m <- getWindowProperty32 dpy atom win
  return (maybe [] (map fromIntegral) m)

readNames :: Display -> Atom -> Window -> IO [T.Text]
readNames dpy atom win = do
  m <- getWindowProperty8 dpy atom win
  return $ case m of
    Nothing -> []
    Just bs -> filter (not . T.null)
      (T.split (== '\0') (T.pack (map (chr . fromIntegral) bs)))

-- | Fetch one window's taskbar entry and geometry; Nothing when it
-- should not appear (other workspace, homgb's own, dock/desktop type,
-- no title). Geometry failures (window vanished mid-poll) also yield
-- Nothing.
readWindow :: Display -> Atom -> Atom -> Atom -> Atom -> Atom -> Atom
           -> CLong -> Int -> CLong
           -> IO (Maybe (WinInfo, (Int, Int, Int, Int)))
readWindow dpy aDesktop aPid aType aName aDock aDesktopT pid cur xid = do
  let win = fromIntegral xid
  desktop <- readOneDef dpy aDesktop win (-1)
  if desktop /= cur
    then return Nothing
    else do
      wpid <- readOneDef dpy aPid win (-1)
      if fromIntegral wpid == pid
        then return Nothing
        else do
          mType <- getWindowProperty32 dpy aType win
          if maybe False (any (`elem` [aDock, aDesktopT]) . map fromIntegral) mType
            then return Nothing
            else do
              mName <- getWindowProperty8 dpy aName win
              let title = case mName of
                    Just bs -> either (const "") id
                      (TE.decodeUtf8' (BS.pack (map fromIntegral bs)))
                    Nothing -> ""
              if T.null title
                then return Nothing
                else do
                  mGeo <- fetchGeometry win
                  case mGeo of
                    Nothing -> return Nothing
                    Just geo -> do
                      mViewable <- isViewable win
                      if mViewable
                        then return (Just (WinInfo xid title, geo))
                        else return Nothing
  where
    isViewable w = do
      attrs <- getWindowAttributes dpy w
      return (wa_map_state attrs == waIsViewable)
    fetchGeometry w =
      (do (_, gx, gy, gw, gh, _, _) <- getGeometry dpy w
          return (Just (fromIntegral gx, fromIntegral gy
                      , fromIntegral gw, fromIntegral gh)))
        `catch` (\(_ :: IOException) -> return Nothing)

-- | Title of the focused window (for the bar's title widget).
barActiveTitle :: BarState -> Maybe T.Text
barActiveTitle s =
  wiTitle <$> find (\w -> wiXid w == barActiveWindow s) (barWindows s)

-- | Render the clock widget ("HH:MM") at the current cursor position,
-- in the theme's bar.clock color (the rightmost bar item). Returns the
-- content width.
renderClockWidget :: Theme -> Float -> IO Float
renderClockWidget theme gap = do
  sameLineS gap
  now <- zonedTimeToLocalTime <$> getZonedTime
  let label = T.pack (formatTime defaultTimeLocale "%H:%M" now)
  withImVec4 (thBarClock theme) $ \colPtr -> do
    Raw.pushStyleColor ImGuiCol_Text colPtr
    text label
    popStyleColor 1
  ImVec2 tw _ <- calcTextSize label True 0
  return tw

-- | Render the date widget ("dd.mm") at the current cursor position,
-- in the theme's muted bar.date color so it reads apart from the
-- clock. Returns the content width.
renderDateWidget :: Theme -> Float -> IO Float
renderDateWidget theme gap = do
  sameLineS gap
  now <- zonedTimeToLocalTime <$> getZonedTime
  let label = T.pack (formatTime defaultTimeLocale "%d.%m" now)
  withImVec4 (thBarDate theme) $ \colPtr -> do
    Raw.pushStyleColor ImGuiCol_Text colPtr
    text label
    popStyleColor 1
  ImVec2 tw _ <- calcTextSize label True 0
  return tw

-- | Truncate a title to fit a pixel budget (window-title-max).
fitTitleWidth :: Float -> T.Text -> IO T.Text
fitTitleWidth maxPx t = do
  ImVec2 w _ <- calcTextSize t True 0
  if w <= maxPx
    then return t
    else go (T.length t `div` 2)
  where
    go 0 = return "…"
    go n = do
      let cand = T.take n t <> "…"
      ImVec2 w _ <- calcTextSize cand True 0
      if w <= maxPx
        then grow n cand
        else go (n `div` 2)
    grow n cand = do
      let n' = n + 1
      if n' >= T.length t
        then return cand
        else do
          let cand' = T.take n' t <> "…"
          ImVec2 w _ <- calcTextSize cand' True 0
          if w <= maxPx then grow n' cand' else return cand

-- | Character cap for the title widget (bar.window-title-max): the
-- text keeps up to n-1 characters plus an ellipsis.
capTitleChars :: Int -> T.Text -> T.Text
capTitleChars n t
  | T.length t > n = T.take (n - 1) t <> "…"
  | otherwise = t

-- | Truncate a taskbar title (long browser/terminal titles make the
-- row unreadable).
truncateTitle :: T.Text -> T.Text
truncateTitle = capTitleChars maxLen
  where
    maxLen = 24

-- | EWMH client messages (xmonad's ewmh hook honors them).
foreign import ccall "homgb_set_current_desktop" c_set_current_desktop
  :: Display -> Window -> CLong -> IO ()
foreign import ccall "homgb_set_active_window" c_set_active_window
  :: Display -> Window -> CLong -> IO ()

switchTo :: Display -> Int -> IO ()
switchTo dpy idx =
  c_set_current_desktop dpy (defaultRootWindow dpy) (fromIntegral idx)

activate :: Display -> CLong -> IO ()
activate dpy xid =
  c_set_active_window dpy (defaultRootWindow dpy) xid

-- | Legacy shrink-wrap bar: workspaces + taskbar window buttons.
-- Returns the content width (0 when nothing is rendered).
renderBar :: Display -> TVar BarState -> Config -> Theme -> Float -> IO Float
renderBar dpy st config theme gap = do
  s <- readTVarIO st
  let showWs = configBarWorkspaces config && not (null (barNames s))
  wsW <- renderWorkspaces dpy st config theme gap
  winW <- renderWinButtons dpy st config theme gap showWs
  return (wsW + winW)

-- | Workspace items (left section): "1 | 2 | 3" — text labels with
-- full-row-height invisible click targets, separated by vertical
-- lines. `rowH` is the icon-row advance (btn + 2*framePadding) used
-- for vertical centering. Returns the content width.
renderWorkspaces :: Display -> TVar BarState -> Config -> Theme -> Float
                 -> IO Float
renderWorkspaces dpy st config theme rowH = do
  s <- readTVarIO st
  if configBarWorkspaces config && not (null (barNames s))
    then go s (zip [0 :: Int ..] (barNames s))
    else return 0
  where
    go _ [] = return 0
    go s ((i, name):rest) = do
      when (i > 0) $ do
        sameLineS 0
        renderSep theme rowH
        sameLineS 0
      (w, clicked) <- barItem theme rowH ("ws-" <> T.pack (show i)) name
        (i == barCurrent s && i < length (barNames s))
      when clicked $ switchTo dpy i
      (w +) <$> go s rest

-- | Taskbar window items (clickable, current workspace), same visual
-- style as the workspaces. withSep renders a leading separator when a
-- left section was already rendered. Returns the content width.
renderWinButtons :: Display -> TVar BarState -> Config -> Theme -> Float -> Bool
                 -> IO Float
renderWinButtons dpy st config theme rowH withSep = do
  s <- readTVarIO st
  if configBarWindows config && not (null (barWindows s))
    then do
      when withSep $ do
        sameLineS 0
        renderSep theme rowH
        sameLineS 0
      go s (zip [0 :: Int ..] (barWindows s))
    else return 0
  where
    go _ [] = return 0
    go s ((i, win):rest) = do
      when (i > 0) $ do
        sameLineS 0
        renderSep theme rowH
        sameLineS 0
      let label = truncateTitle (wiTitle win)
      (w, clicked) <- barItem theme rowH
        ("win-" <> T.pack (show (wiXid win)) <> "##" <> T.pack (show i)) label
        (wiXid win == barActiveWindow s)
      when clicked $ activate dpy (wiXid win)
      (w +) <$> go s rest

-- | One clickable bar item: an invisible button spanning the full row
-- height with the label vertically centered on it (mixed-height items
-- on a SameLine row would otherwise top-align). Active/hovered labels
-- draw in the theme's bright bar.ws-active color, others in the
-- default text color. Returns (width, clicked).
barItem :: Theme -> Float -> T.Text -> T.Text -> Bool -> IO (Float, Bool)
barItem theme rowH key label active = do
  ImVec2 tw th <- calcTextSize label True 0
  let w = tw + 2 * framePadX
  ImVec2 x0 y0 <- getCursorPos
  clicked <- invisibleButton key (ImVec2 w rowH) ImGuiButtonFlags_None
  hovered <- isItemHovered
  withImVec2 (ImVec2 (x0 + framePadX) (y0 + max 0 (rowH - th) / 2))
    $ \p -> Raw.setCursorPos p
  if active || hovered
    then withImVec4 (thBarWsActive theme) $ \colPtr ->
      BS.useAsCString (TE.encodeUtf8 label) $ \txtPtr ->
        Raw.textColored colPtr txtPtr
    else text label
  withImVec2 (ImVec2 (x0 + w) y0) $ \p -> Raw.setCursorPos p
  return (w, clicked)

-- | Width of one bar item (text + click-target padding).
barItemWidth :: T.Text -> IO Float
barItemWidth label = do
  ImVec2 tw _ <- calcTextSize label True 0
  return (tw + 2 * framePadX)

-- | The vertical separator label (spaces included, so items need no
-- extra SameLine spacing around it).
sepLabel :: T.Text
sepLabel = " | "

-- | Render a separator between left-section items: the sepLabel in
-- the theme's muted bar.separator color, vertically centered in a row
-- of the given height.
renderSep :: Theme -> Float -> IO ()
renderSep theme rowH = do
  ImVec2 _ th <- calcTextSize sepLabel True 0
  centerCursorY theme rowH th
  withImVec4 (thBarSeparator theme) $ \colPtr ->
    BS.useAsCString (TE.encodeUtf8 sepLabel) $ \txtPtr ->
      Raw.textColored colPtr txtPtr

sepWidth :: IO Float
sepWidth = do
  ImVec2 w _ <- calcTextSize sepLabel True 0
  return w

-- | Move the cursor so the next widget of height h is vertically
-- centered in a content row of height rowH.
centerCursorY :: Theme -> Float -> Float -> IO ()
centerCursorY theme rowH h = do
  ImVec2 x _ <- getCursorPos
  withImVec2 (ImVec2 x (thTrayPadY theme + max 0 (rowH - h) / 2))
    $ \p -> Raw.setCursorPos p

-- | Measure the workspace section's width WITHOUT rendering (the
-- spacer math runs before Begin; drawing there triggers ImGui usage
-- errors and the auto-opened Debug##Default window).
measureWorkspaces :: TVar BarState -> Config -> IO Float
measureWorkspaces st config = do
  s <- readTVarIO st
  if configBarWorkspaces config && not (null (barNames s))
    then do
      ws <- mapM barItemWidth (barNames s)
      sw <- sepWidth
      return (sum ws + fromIntegral (length ws - 1) * sw)
    else return 0

-- | Measure the taskbar window-items width without rendering.
measureWinButtons :: TVar BarState -> Config -> IO Float
measureWinButtons st config = do
  s <- readTVarIO st
  if configBarWindows config && not (null (barWindows s))
    then do
      ws <- mapM (barItemWidth . truncateTitle . wiTitle) (barWindows s)
      sw <- sepWidth
      return (sum ws + fromIntegral (length ws - 1) * sw)
    else return 0

-- | ImGui's default FramePadding (pixel-probed from the rendered
-- tray: item pitch = btn + 8 + ItemSpacing 8).
framePadX, framePadY :: Float
framePadX = 4
framePadY = 4

-- | dear-imgui's sameLine binds @SameLine()@ without the spacing
-- argument; go through the shim for theme-controlled gaps.
sameLineS :: Float -> IO ()
sameLineS sp = c_same_line (realToFrac sp)

foreign import ccall "homgb_same_line" c_same_line :: CFloat -> IO ()

withImVec4 :: ImVec4 -> (Ptr ImVec4 -> IO a) -> IO a
withImVec4 v f = alloca $ \p -> poke p v >> f p

withImVec2 :: ImVec2 -> (Ptr ImVec2 -> IO a) -> IO a
withImVec2 v f = alloca $ \p -> poke p v >> f p
