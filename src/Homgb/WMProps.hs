-- | EWMH window properties: tell window managers how to treat the
-- homgb overlay. One SDL window hosts the tray, notification popups and
-- menus, so it gets the closest single type — DOCK (a permanent panel
-- surface; ManageDocks skips borders/struts handling) — plus
-- skip-taskbar/pager and stickiness. Per-surface types
-- (NOTIFICATION/POPUP_MENU) would need separate X windows per surface.
module Homgb.WMProps (setWindowProperties, setWindowPropsById) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, void, when)
import Data.Word (Word64)
import Foreign.C.Types (CLong(..))
import Graphics.X11.Types (Window)
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Display (defaultRootWindow, openDisplay)
import System.Posix.Process (getProcessID)

foreign import ccall "homgb_find_window_by_pid" c_find_window_by_pid
  :: Display -> Window -> CLong -> IO Window
foreign import ccall "homgb_set_dock_props" c_set_dock_props
  :: Display -> Window -> IO ()
foreign import ccall "homgb_ensure_sticky" c_ensure_sticky
  :: Display -> Window -> IO ()

-- | Tag a specific X window (preferred: the SDL window's X11 id from
-- SDL_PROP_WINDOW_X11_WINDOWID). A background thread re-asserts
-- stickiness every couple of seconds because WMs overwrite
-- _NET_WM_DESKTOP when they adopt the window (map-time race with the
-- initial set); it uses its own display to stay thread-safe with the
-- render thread's pointer polls.
setWindowPropsById :: Display -> Word64 -> IO ()
setWindowPropsById dpy wid = applyProps dpy (fromIntegral wid)

-- | Fallback: find this process's top-level X window under root by
-- _NET_WM_PID and tag it. No-op when no matching window exists.
setWindowProperties :: Display -> IO ()
setWindowProperties dpy = do
  pid <- fromIntegral <$> getProcessID
  win <- c_find_window_by_pid dpy (defaultRootWindow dpy) pid
  when (win /= 0) $ applyProps dpy win

applyProps :: Display -> Window -> IO ()
applyProps dpy win = do
  c_set_dock_props dpy win
  mDpy <- catch (Just <$> openDisplay "") (constNoDisplay)
  forM_ mDpy $ \dpy2 ->
    void $ forkIO $ forever $ do
      c_ensure_sticky dpy2 win
      threadDelay 2000000

forever :: IO () -> IO ()
forever act = act >> forever act

constNoDisplay :: SomeException -> IO (Maybe Display)
constNoDisplay _ = return Nothing
