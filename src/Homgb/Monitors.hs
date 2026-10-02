{-# LANGUAGE OverloadedStrings #-}

-- | Xinerama monitor enumeration and selection. Single-screen X
-- sessions (and XWayland without RandR panning) report one monitor
-- covering the whole screen, which degenerates to today's behavior.
module Homgb.Monitors
  ( Monitor(..)
  , getMonitors
  , monitorAt
  , clampMonitor
  , fallbackMonitor
  ) where

import Graphics.X11.Xinerama
  ( XineramaScreenInfo(..), xineramaIsActive, xineramaQueryScreens )
import Graphics.X11.Xlib (Display)

-- | A monitor's geometry in root coordinates.
data Monitor = Monitor
  { monX :: Int
  , monY :: Int
  , monW :: Int
  , monH :: Int
  } deriving (Show, Eq)

-- | Enumerate monitors via Xinerama; fall back to a single monitor
-- covering the given screen size when Xinerama is inactive or the
-- query fails.
getMonitors :: Display -> (Int, Int) -> IO [Monitor]
getMonitors dpy (sw, sh) = do
  active <- xineramaIsActive dpy
  mInfos <- if active then xineramaQueryScreens dpy else return Nothing
  return $ case mInfos of
    Just infos | not (null infos) -> map toMonitor infos
    _ -> [Monitor 0 0 sw sh]
  where
    toMonitor info = Monitor
      { monX = fromIntegral (xsi_x_org info)
      , monY = fromIntegral (xsi_y_org info)
      , monW = fromIntegral (xsi_width info)
      , monH = fromIntegral (xsi_height info)
      }

-- | The monitor containing the root-coordinate point; the closest
-- one when the point is in a gap (or the first monitor as last
-- resort).
monitorAt :: [Monitor] -> (Int, Int) -> Monitor
monitorAt [] _ = Monitor 0 0 1920 1080
monitorAt (m0:rest) (px, py) = go m0 rest
  where
    go def [] = def
    go def (m:ms)
      | contains m = m
      | otherwise = go def ms
    contains m = px >= monX m && px < monX m + monW m
      && py >= monY m && py < monY m + monH m

-- | Monitor at the given index, clamped into range.
clampMonitor :: [Monitor] -> Int -> Monitor
clampMonitor [] _ = Monitor 0 0 1920 1080
clampMonitor ms i = ms !! max 0 (min i (length ms - 1))

-- | The fallback monitor covering the given screen size.
fallbackMonitor :: (Int, Int) -> [Monitor]
fallbackMonitor (sw, sh) = [Monitor 0 0 sw sh]
