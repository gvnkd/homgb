{-# LANGUAGE OverloadedStrings #-}

-- | Backend seam (design_docs/wayland.md step 1).
--
-- A Backend bundles every platform touchpoint: surface show/hide/tag,
-- monitor enumeration, pointer polling, the bar's event listener and
-- dirty-gated upkeep, the strut write, the tray embed host and the
-- keyboard layout manager. The X11 instance (Homgb.Backend.X11) is the
-- existing code with the display captured; the Wayland instance
-- (step 2) implements the same record over dbus-to-xmonad and SDL3.
--
-- Nothing in this module may import X11, xcb or Wayland types.
module Homgb.Backend
  ( Backend(..)
  , BarUpkeep(..)
  ) where

import Control.Concurrent.STM.TVar (TVar)

import Homgb.Bar (BarState)
import Homgb.Config (Config)
import Homgb.Keyboard (KeyboardEnv)
import Homgb.Monitors (Monitor)
import Homgb.Surface (Surface, Surfaces)
import Homgb.Tray (TrayEnv)
import Homgb.WMProps (WmClass)

-- | Arguments of the dirty-gated bar upkeep block (frameUpkeep calls
-- it only when the bar event listener flagged a change or the 5s
-- safety re-sync fired).
data BarUpkeep = BarUpkeep
  { buSurfaces :: Surfaces
  , buBar :: TVar BarState
  , buStrut :: TVar (Maybe (Int, Int, Int))
  , buKeyboard :: Maybe KeyboardEnv
  , buTray :: TrayEnv
  }

data Backend = Backend
  { bkName :: String
  , bkScreenSize :: IO (Int, Int)
    -- ^ primary screen size, fallback monitor geometry
  , bkMonitors :: IO [Monitor]
    -- ^ monitor list (single entry on single-screen setups)
  -- surfaces
  , bkTagSurface :: Surface -> WmClass -> IO ()
    -- ^ pre-map window tagging (EWMH on X11; app_id/layer elsewhere)
  , bkShowSurface :: Surface -> IO ()
  , bkHideSurface :: Surface -> IO ()
  , bkStartEmbedHost :: Config -> TrayEnv -> Surface -> IO ()
    -- ^ legacy tray host startup (XEmbed on X11; absent on Wayland)
  -- bar
  , bkStartBarEvents :: TVar Bool -> IO () -> IO ()
    -- ^ event listener thread setting the dirty flag
  , bkBarUpkeep :: BarUpkeep -> IO (Bool, Bool)
    -- ^ bar state re-read + platform upkeep; returns (barChanged,
    -- kbFocusChanged) — kbFocusChanged is the per-app layout restore
  , bkUpdateStrut :: Bool -> TVar (Maybe (Int, Int, Int)) -> Surface
                  -> Monitor -> Int -> IO ()
    -- ^ reserve the bar's strip (struts on X11; a no-op or a pure
    -- TVar write elsewhere). Bool = config enabled flag
  -- pointer
  , bkPollPointer :: IO (Maybe (Int, Int))
    -- ^ pointer position in screen coordinates; Nothing when the
    -- platform cannot see the pointer outside its own surfaces
  -- keyboard
  , bkStartKeyboard :: Config -> IO () -> IO (Maybe KeyboardEnv)
  }
