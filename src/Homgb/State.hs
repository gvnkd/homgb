{-# LANGUAGE OverloadedStrings #-}

module Homgb.State where

import qualified Data.Map.Strict as Map
import Graphics.GL (GLuint)
import Control.Concurrent.STM.TVar (TVar, newTVarIO)
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word32)

import Homgb.Backend (Backend)
import Homgb.Bar (BarState, newBarState)
import Homgb.Keyboard (KeyboardEnv)
import Homgb.Monitors (Monitor)
import Homgb.Notifications.Daemon (NotifyState)
import Homgb.Surface (Surfaces)
import Homgb.Theme (Theme)
import Homgb.Tray (TrayEnv)

data AppState = AppState
  { appBackend :: Backend
    -- ^ platform seam (design_docs/wayland.md): every X/Wayland
    -- touchpoint reaches the render loop through this record
  , appNotify :: TVar NotifyState
  , appTextures :: TVar (Map.Map Int GLuint)
    -- ^ GL textures for notification images, keyed by notiId
  , appHeights :: TVar (Map.Map Int Float)
    -- ^ Last measured popup heights, keyed by notiId (stacking layout)
  , appTray :: TrayEnv
  , appKeyboard :: Maybe KeyboardEnv
  , appSurfaces :: Surfaces
  , appScreenSize :: (Int, Int)
    -- ^ primary X screen size, fallback monitor geometry
  , appMonitors :: [Monitor]
    -- ^ Xinerama monitor list (single entry on single-screen setups)
  , appPointer :: TVar (Int, Int)
    -- ^ last polled pointer root coordinates (for follow-mouse)
  , appBar :: TVar BarState
    -- ^ cached EWMH desktop/workspace state (bar section)
  , appBarDirty :: TVar Bool
    -- ^ set by the X event listener (startBarEvents): EWMH state
    -- changed; the frame loop re-reads it and clears the flag
  , appBarTick :: TVar POSIXTime
    -- ^ last EWMH re-read (fallback re-sync every 5s)
  , appStrut :: TVar (Maybe (Int, Int, Int))
    -- ^ last _NET_WM_STRUT_PARTIAL written for the bar (depth, x0,
    -- x1); writes are suppressed while unchanged because each write
    -- re-runs the WM's avoidStruts
  , appTheme :: Theme
  , appCenterVisible :: TVar Bool
    -- ^ notification center panel visibility (DBus ToggleCenter)
  , appUserEvent :: Word32
    -- ^ registered SDL_EVENT_USER type: DBus/X threads push it to
    -- wake the render loop out of its timed wait (render-on-wake)
  , appWake :: IO ()
    -- ^ push a user event on the SDL queue (see appUserEvent)
  }

initialAppState :: Backend -> TVar NotifyState -> TrayEnv -> Maybe KeyboardEnv
                -> Surfaces -> (Int, Int) -> [Monitor] -> Theme -> TVar Bool
                -> Word32 -> IO () -> IO AppState
initialAppState backend tState tray kb surfaces screenSize monitors theme centerVisible userEv wake = do
  textures <- newTVarIO Map.empty
  heights <- newTVarIO Map.empty
  pointer <- newTVarIO (0, 0)
  bar <- newBarState
  barDirty <- newTVarIO True
  barTick <- newTVarIO 0
  strut <- newTVarIO Nothing
  return AppState
    { appBackend = backend
    , appNotify = tState
    , appTextures = textures
    , appHeights = heights
    , appTray = tray
    , appKeyboard = kb
    , appSurfaces = surfaces
    , appScreenSize = screenSize
    , appMonitors = monitors
    , appPointer = pointer
    , appBar = bar
    , appBarDirty = barDirty
    , appBarTick = barTick
    , appStrut = strut
    , appTheme = theme
    , appCenterVisible = centerVisible
    , appUserEvent = userEv
    , appWake = wake
    }
