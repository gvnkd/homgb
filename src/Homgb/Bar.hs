{-# LANGUAGE OverloadedStrings #-}

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
  , renderBar
  , renderWorkspaces
  , renderWinButtons
  , barActiveTitle
  , renderClockWidget
  , renderDateWidget
  , fitTitleWidth
  , sameLineS
  , framePadX
  , framePadY
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM, when)
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
import Graphics.X11.Types (Atom, Window)
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Atom (internAtom)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Extras (getWindowProperty8, getWindowProperty32)
import System.Posix.Process (getProcessID)

import DearImGui hiding (begin)
import qualified DearImGui.Raw as Raw (pushStyleColor)

import Homgb.Config (Config(..))
import Homgb.Theme (Theme(..))

-- | One taskbar entry.
data WinInfo = WinInfo
  { wiXid :: CLong
  , wiTitle :: T.Text
  } deriving (Show)

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
  } deriving (Show)

newBarState :: IO (TVar BarState)
newBarState = do
  pid <- fromIntegral <$> getProcessID
  newTVarIO (BarState pid (-1) [] 0 [])

-- | Re-read the EWMH properties into the TVar. Cheap Xlib reads; call
-- at a few Hz from the frame loop. Windows appearing/vanishing mid
-- poll yield Nothing reads and are skipped.
refreshBar :: Display -> TVar BarState -> IO ()
refreshBar dpy st = do
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
  wins <- concat <$> forM stack (\wxid ->
    maybe [] (:[]) <$> readWindow dpy (atoms !! 4) (atoms !! 5) (atoms !! 6)
                     (atoms !! 7) (atoms !! 8) (atoms !! 9)
                     (barPid old) cur wxid)
  atomically $ writeTVar st old
    { barCurrent = cur
    , barNames = names
    , barActiveWindow = active
    , barWindows = wins
    }

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

-- | Fetch one window's taskbar entry; Nothing when it should not
-- appear (other workspace, homgb's own, dock/desktop type, no title).
readWindow :: Display -> Atom -> Atom -> Atom -> Atom -> Atom -> Atom
           -> CLong -> Int -> CLong -> IO (Maybe WinInfo)
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
                else return (Just (WinInfo xid title))

-- | Title of the focused window (for the bar's title widget).
barActiveTitle :: BarState -> Maybe T.Text
barActiveTitle s =
  wiTitle <$> find (\w -> wiXid w == barActiveWindow s) (barWindows s)

-- | Render the clock widget ("HH:MM") at the current cursor position.
-- Returns the content width.
renderClockWidget :: Float -> IO Float
renderClockWidget gap = do
  sameLineS gap
  now <- zonedTimeToLocalTime <$> getZonedTime
  let label = T.pack (formatTime defaultTimeLocale "%H:%M" now)
  text label
  ImVec2 tw _ <- calcTextSize label True 0
  return tw

-- | Render the date widget ("dd.mm") at the current cursor position.
-- Returns the content width.
renderDateWidget :: Float -> IO Float
renderDateWidget gap = do
  sameLineS gap
  now <- zonedTimeToLocalTime <$> getZonedTime
  let label = T.pack (formatTime defaultTimeLocale "%d.%m" now)
  text label
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

-- | Truncate a taskbar title (long browser/terminal titles make the
-- row unreadable).
truncateTitle :: T.Text -> T.Text
truncateTitle t
  | T.length t > maxLen = T.take (maxLen - 1) t <> "…"
  | otherwise = t
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

-- | Workspace buttons (left section). Returns the content width.
renderWorkspaces :: Display -> TVar BarState -> Config -> Theme -> Float
                 -> IO Float
renderWorkspaces dpy st config theme gap = do
  s <- readTVarIO st
  if configBarWorkspaces config && not (null (barNames s))
    then do
      widths <- mapM (renderWs s) (zip [0 :: Int ..] (barNames s))
      return (sum widths + fromIntegral (length widths - 1) * gap)
    else return 0
  where
    renderWs s (i, name) = do
      when (i > 0) $ sameLineS gap
      clicked <- buttonHilite theme (i == barCurrent s && i < length (barNames s)) name
      when clicked $ switchTo dpy i
      buttonWidth name

-- | Taskbar window buttons (clickable, current workspace).
-- follow=True chains the first button onto the previous section's
-- line. Returns the content width.
renderWinButtons :: Display -> TVar BarState -> Config -> Theme -> Float -> Bool
                 -> IO Float
renderWinButtons dpy st config theme gap follow = do
  s <- readTVarIO st
  if configBarWindows config && not (null (barWindows s))
    then do
      widths <- mapM (renderWin s) (zip [0 :: Int ..] (barWindows s))
      return (sum widths + fromIntegral (length widths - 1) * gap)
    else return 0
  where
    renderWin s (i, win) = do
      when (follow || i > 0) $ sameLineS gap
      let label = truncateTitle (wiTitle win)
      clicked <- buttonHilite theme (wiXid win == barActiveWindow s) label
      when clicked $ activate dpy (wiXid win)
      buttonWidth label

buttonHilite :: Theme -> Bool -> T.Text -> IO Bool
buttonHilite theme active label =
  if active
    then withImVec4 (thMenuBg theme) $ \ptr -> do
      Raw.pushStyleColor ImGuiCol_Button ptr
      c <- smallButton label
      popStyleColor 1
      return c
    else smallButton label

buttonWidth :: T.Text -> IO Float
buttonWidth label = do
  ImVec2 tw _ <- calcTextSize label True 0
  return (tw + 2 * framePadX)

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
