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
  , sameLineS
  , framePadX
  , framePadY
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM, when)
import Data.Char (chr)
import qualified Data.ByteString as BS
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
                else return (Just (WinInfo xid (truncateTitle title)))

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

-- | Draw the bar (workspaces, then taskbar) at the current cursor
-- position (the tray window's left edge). Active workspace and
-- focused window are highlighted with the theme menu background.
-- Returns the content width (0 when nothing is rendered).
renderBar :: Display -> TVar BarState -> Config -> Theme -> Float -> IO Float
renderBar dpy st config theme gap = do
  s <- readTVarIO st
  let showWs = configBarWorkspaces config && not (null (barNames s))
      showWins = configBarWindows config && not (null (barWindows s))
  wsW <-
    if showWs
      then do
        widths <- mapM (renderWs s) (zip [0 :: Int ..] (barNames s))
        return (sum widths + fromIntegral (length widths - 1) * gap)
      else return 0
  winW <-
    if showWins
      then do
        widths <- mapM (renderWin showWs s) (zip [0 :: Int ..] (barWindows s))
        return (sum widths + fromIntegral (length widths - 1) * gap)
      else return 0
  return (wsW + winW)
  where
    renderWs s (i, name) = do
      when (i > 0) $ sameLineS gap
      clicked <- buttonHilite (i == barCurrent s && i < length (barNames s)) name
      when clicked $ switchTo dpy i
      buttonWidth name
    renderWin followWs s (i, win) = do
      when (followWs || i > 0) $ sameLineS gap
      clicked <- buttonHilite (wiXid win == barActiveWindow s) (wiTitle win)
      when clicked $ activate dpy (wiXid win)
      buttonWidth (wiTitle win)
    buttonHilite active label =
      if active
        then withImVec4 (thMenuBg theme) $ \ptr -> do
          Raw.pushStyleColor ImGuiCol_Button ptr
          c <- smallButton label
          popStyleColor 1
          return c
        else smallButton label
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
