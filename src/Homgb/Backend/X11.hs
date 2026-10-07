{-# LANGUAGE OverloadedStrings #-}

-- | The X11 backend: the pre-seam code with the tray display captured.
-- One display drives surface show/hide/tag, pointer polls, the bar
-- upkeep and the strut write (all formerly threaded as `trayDisplay`
-- Maybe-values through the render modules); the bar event listener and
-- the keyboard manager open their own connections, as before.
module Homgb.Backend.X11
  ( x11Backend
  , preferredBackend
  , selectBackend
  ) where

-- selection lives here because it needs both instances; the Wayland
-- backend imports no X11, so the dependency is one-way

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import Foreign.C.Types (CLong(..))
import Graphics.X11.Types (Window)
import Graphics.X11.Xlib.Atom (internAtom)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Extras (getWindowProperty32)
import Graphics.X11.Xlib.Misc (queryPointer)
import Graphics.X11.Xlib.Types (Display(..))
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Homgb.Backend
import Homgb.Backend.Wayland (waylandBackend)
import Homgb.Bar (barActiveWindow, refreshBar
  , startBarEvents, x11BarActions)
import Homgb.Config (Config(..))
import qualified Homgb.Keyboard as Keyboard
import Homgb.Keyboard (KbUi(..), kbToUi)
import qualified Homgb.Keyboard.Xcb as Xcb
import Homgb.Monitors (Monitor(..), getMonitors)
import Homgb.Surface
  ( Surface(..), Surfaces(..), reassertStacking, rootChildren
  , showSurface, hideSurface, surfaceX11Id, tagSurface
  , moveSurfaceWindow)
import Homgb.Tray (TrayEnv(..), reapZombieItems)
import Homgb.Tray.Embed (acquireTraySelection)
import Homgb.Tray.Menu.Render (samplePressEdge)
import Homgb.WMProps (setStrutPartial)
import Homgb.Wayland.WmClient (startWmClient)

-- | Build the X11 backend over an existing display connection (the
-- tray's). hoverRevert holds the window to return focus to when the
-- pointer leaves a hover-focus surface (set at enter time).
x11Backend :: Display -> TVar (Maybe Word64) -> Backend
x11Backend dpy hoverRevert = Backend
  { bkName = "x11"
  , bkScreenSize = fromMaybe (1920, 1080) <$> Xcb.screenSize
  , bkMonitors = do
      screen <- fromMaybe (1920, 1080) <$> Xcb.screenSize
      getMonitors dpy screen
  , bkTagSurface = tagSurface dpy
  , bkShowSurface = showSurface dpy
  , bkHideSurface = hideSurface dpy
  , bkStartEmbedHost = startEmbedHost dpy
  , bkStartBarEvents = startBarEvents
  , bkBarUpkeep = barUpkeep dpy
  , bkBarActions = x11BarActions dpy
  , bkUpdateStrut = updateStrut dpy
  , bkMoveSurface = moveSurfaceWindow
  , bkPollPointer = pollPointer dpy
  , bkPressEdge = samplePressEdge (Just dpy)
  , bkSurfaceHover = surfaceHover dpy hoverRevert
  , bkStartKeyboard = \cfg wake ->
      fmap (kbToUi dpy) <$> Keyboard.startKeyboard cfg wake
  , bkFocusedAppId = return ""
    -- the WM_CLASS of the active window is not plumbed here; media
    -- keys fall back to the last-Playing/sole-player rules
  }

-- | Which backend WOULD be selected — the pure env part, splittable
-- from construction because SDL's video driver must be forced to
-- Wayland BEFORE SDL_Init when this says "wayland" (both DISPLAY and
-- WAYLAND_DISPLAY exist on a river session, and SDL prefers X11).
preferredBackend :: IO (Maybe String)
preferredBackend = do
  forced <- lookupEnv "HOMGB_BACKEND"
  case forced of
    Just b -> return (Just b)
    Nothing -> do
      session <- lookupEnv "XDG_SESSION_TYPE"
      case session of
        Just s -> return (if s == "wayland" then Just "wayland" else Nothing)
        -- stale-shell fallback: a shell that predates the session
        -- export has no XDG_SESSION_TYPE; trust WAYLAND_DISPLAY only
        -- when its socket actually exists in XDG_RUNTIME_DIR (a bare
        -- X11 session never sets WAYLAND_DISPLAY)
        Nothing -> do
          mSock <- lookupEnv "WAYLAND_DISPLAY"
          case mSock of
            Just sock | not (null sock) -> do
              runtime <- fromMaybe "/run/user/1000" <$> lookupEnv "XDG_RUNTIME_DIR"
              exists <- doesFileExist (runtime </> sock)
              return (if exists then Just "wayland" else Nothing)
            _ -> return Nothing

-- | Backend selection. HOMGB_BACKEND=x11|wayland forces; otherwise a
-- Wayland session (XDG_SESSION_TYPE) picks the Wayland backend and
-- anything with an X display falls back to X11. The Wayland backend
-- needs the bar-dirty TVar (its WM client writes it from signal
-- handlers), the wake action, and the per-app keyboard flag
-- (config keyboard.per-app) at construction time.
selectBackend :: Maybe Display -> TVar Bool -> IO () -> Bool -> IO Backend
selectBackend mDpy barDirty wake kbPerApp = do
  pref <- preferredBackend
  case pref of
    Just "x11" -> requireX11 mDpy
    Just "wayland" -> wayland
    Just other -> die ("homgb: unknown HOMGB_BACKEND " ++ other)
    Nothing -> case mDpy of
      Just dpy -> do
        hoverRevert <- newTVarIO Nothing
        return (x11Backend dpy hoverRevert)
      Nothing -> die
        "homgb: no X display (DISPLAY not set); set HOMGB_BACKEND=wayland"
  where
    wayland = waylandBackend <$> startWmClient barDirty wake kbPerApp

requireX11 :: Maybe Display -> IO Backend
requireX11 (Just dpy) = do
  hoverRevert <- newTVarIO Nothing
  return (x11Backend dpy hoverRevert)
requireX11 Nothing = die "homgb: HOMGB_BACKEND=x11 but DISPLAY is not set"

-- | XEmbed tray host: become the _NET_SYSTEM_TRAY_S0 owner so running
-- XEmbed apps dock without a restart (config tray.xembed).
startEmbedHost :: Display -> Config -> TrayEnv -> Surface -> IO ()
startEmbedHost dpy config tray surf =
  case (configTrayXEmbed config) of
    True -> do
      mId <- surfaceX11Id surf
      case mId of
        Just wid -> do
          mEmbed <- acquireTraySelection dpy (fromIntegral wid)
          atomically $ writeTVar (trayXEmbedHost tray) mEmbed
        Nothing ->
          hPutStrLn stderr "tray: xembed: no X11 window id on tray surface"
    False -> return ()

-- | The dirty-gated bar block: stacking re-assert (fingerprinted),
-- EWMH re-read, per-app layout restore, zombie reap. Returns
-- (barChanged, kbFocusChanged).
barUpkeep :: Display -> BarUpkeep -> IO (Bool, Bool)
barUpkeep dpy bu = do
  children <- rootChildren dpy
  let surfs = buSurfaces bu
  reassertStacking dpy children (surfacesTray surfs)
  reassertStacking dpy children (surfacesMenus surfs)
  reassertStacking dpy children (surfacesTooltip surfs)
  mStrut <- readTVarIO (buStrut bu)
  oldBar <- readTVarIO (buBar bu)
  refreshBar dpy mStrut (buBar bu)
  newBar <- readTVarIO (buBar bu)
  -- per-app layouts: the active-window read just refreshed; restore
  -- the layout remembered for the focused class
  kbFocus <- case buKeyboard bu of
    Just ui -> kbUiSyncFocus ui (barActiveWindow newBar)
    Nothing -> return False
  -- reap SNI items whose unique bus name died without unregistering
  -- (zombies spam the property poller and leave stuck empty menus);
  -- close their menus too
  removed <- reapZombieItems (trayClient (buTray bu)) (trayState (buTray bu))
  unless (null removed) $ atomically $
    modifyTVar' (trayMenus (buTray bu))
      (Map.filterWithKey (\k _ -> k `notElem` removed))
  return (oldBar /= newBar, kbFocus)

-- | Set _NET_WM_STRUT_PARTIAL on the bar surface so avoidStruts
-- reserves its strip. Only writes when the geometry changed (each
-- write makes the WM re-run avoidStruts).
updateStrut :: Display -> Bool -> TVar (Maybe (Int, Int, Int)) -> Surface
            -> Monitor -> Int -> IO ()
updateStrut _ False _ _ _ _ = return ()
updateStrut dpy True appStrut surf mon depth = do
  mId <- surfaceX11Id surf
  forM_mId mId $ \wid -> do
    lastStrut <- readTVarIO appStrut
    let rect = (depth, monX mon, monX mon + monW mon - 1)
    when (lastStrut /= Just rect) $ do
      atomically $ writeTVar appStrut (Just rect)
      setStrutPartial dpy (fromIntegral wid) rect

pollPointer :: Display -> IO (Maybe (Int, Int))
pollPointer dpy = do
  (_, _, _, rx, ry, _, _, _) <- queryPointer dpy (defaultRootWindow dpy)
  return (Just (fromIntegral rx, fromIntegral ry))

-- | EWMH _NET_ACTIVE_WINDOW client message (xmonad's ewmh hook honors
-- it); the same cbits entry Bar.activate uses.
foreign import ccall "homgb_set_active_window" c_set_active_window
  :: Display -> Window -> CLong -> IO ()

-- | Current _NET_ACTIVE_WINDOW xid (Nothing when none/unset).
activeXid :: Display -> IO (Maybe Word64)
activeXid dpy = do
  a <- internAtom dpy "_NET_ACTIVE_WINDOW" False
  m <- getWindowProperty32 dpy a (defaultRootWindow dpy)
  return $ case m of
    Just (v:_) | v /= 0 -> Just (fromIntegral v)
    _ -> Nothing

-- | Hover focus for the notification popups. Enter activates the
-- surface and remembers who held focus; leave returns focus to that
-- window — but only when the popup still holds it (the user may have
-- switched windows mid-hover; yanking focus back would fight them).
surfaceHover :: Display -> TVar (Maybe Word64) -> Surface -> Bool -> IO ()
surfaceHover dpy revert surf entered = do
  mId <- surfaceX11Id surf
  forM_mId mId $ \wid -> do
    let root = defaultRootWindow dpy
    if entered
      then do
        cur <- activeXid dpy
        atomically $ writeTVar revert
          (if cur == Just wid then Nothing else cur)
        c_set_active_window dpy root (fromIntegral wid)
      else do
        target <- readTVarIO revert
        atomically $ writeTVar revert Nothing
        cur <- activeXid dpy
        forM_mId target $ \t ->
          when (cur == Just wid) $
            c_set_active_window dpy root (fromIntegral t)

-- tiny local helper to keep the import list minimal
forM_mId :: Maybe a -> (a -> IO ()) -> IO ()
forM_mId (Just x) f = f x
forM_mId Nothing _ = return ()
