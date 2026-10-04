{-# LANGUAGE OverloadedStrings #-}

-- | The X11 backend: the pre-seam code with the tray display captured.
-- One display drives surface show/hide/tag, pointer polls, the bar
-- upkeep and the strut write (all formerly threaded as `trayDisplay`
-- Maybe-values through the render modules); the bar event listener and
-- the keyboard manager open their own connections, as before.
module Homgb.Backend.X11
  ( x11Backend
  , selectBackend
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', readTVarIO, writeTVar)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Misc (queryPointer)
import Graphics.X11.Xlib.Types (Display(..))
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

import Homgb.Backend
import Homgb.Bar (BarState, barActiveWindow, refreshBar, startBarEvents)
import Homgb.Config (Config(..))
import qualified Homgb.Keyboard as Keyboard
import Homgb.Keyboard (KeyboardEnv, syncFocus)
import qualified Homgb.Keyboard.Xcb as Xcb
import Homgb.Monitors (Monitor(..), getMonitors)
import Homgb.Surface
  ( Surface(..), Surfaces(..), reassertStacking, rootChildren
  , showSurface, hideSurface, surfaceX11Id, tagSurface)
import Homgb.Tray (TrayEnv(..), reapZombieItems)
import Homgb.Tray.Embed (acquireTraySelection)
import Homgb.WMProps (setStrutPartial)

-- | Build the X11 backend over an existing display connection (the
-- tray's).
x11Backend :: Display -> Backend
x11Backend dpy = Backend
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
  , bkUpdateStrut = updateStrut dpy
  , bkPollPointer = pollPointer dpy
  , bkStartKeyboard = Keyboard.startKeyboard
  }

-- | Backend selection: HOMGB_BACKEND=x11|wayland, else auto-detect from
-- the tray's display. Wayland is step 2 of design_docs/wayland.md.
selectBackend :: Maybe Display -> IO Backend
selectBackend mDpy = do
  forced <- lookupEnv "HOMGB_BACKEND"
  case forced of
    Just "x11" -> requireX11 mDpy
    Just "wayland" -> die
      "homgb: HOMGB_BACKEND=wayland is not implemented yet \
      \(design_docs/wayland.md step 2)"
    _ -> case mDpy of
      Just dpy -> return (x11Backend dpy)
      Nothing -> die
        "homgb: no X display (DISPLAY not set) and no Wayland backend \
        \yet (design_docs/wayland.md step 2)"

requireX11 :: Maybe Display -> IO Backend
requireX11 (Just dpy) = return (x11Backend dpy)
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
    Just kb -> syncFocus kb dpy (barActiveWindow newBar)
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

-- tiny local helper to keep the import list minimal
forM_mId :: Maybe a -> (a -> IO ()) -> IO ()
forM_mId (Just x) f = f x
forM_mId Nothing _ = return ()
