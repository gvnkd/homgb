{-# LANGUAGE OverloadedStrings #-}

-- | Volume state + OSD bookkeeping, backed by the native PipeWire
-- client ("Homgb.PipeWire"). Rendering lives in "Homgb.Render"
-- (drawVolumeOsd), mirroring the battery/env split.
--
-- WirePlumber's volume scale is cubic: the raw channel gains on the
-- wire are linear, wpctl-style tools display the cube root. We keep
-- 'volLevel' on the cubic scale so the OSD percent and the configured
-- step match what every other mixer UI shows.
module Homgb.Volume
  ( VolumeEnv(..)
  , VolumeState(..)
  , startVolume
  , volOsdVisible
  , volDeadline
  , volDelta
  , volToggleMute
  , linearToCubic
  , cubicToLinear
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (unless, void, when)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Foreign (Ptr, nullPtr)
import System.IO (hPutStrLn, stderr)

import Homgb.Config (Config(..))
import Homgb.PipeWire (PwHandle, pwConnect, pwSetCallback, pwSetMute, pwSetVolume)

data VolumeState = VolumeState
  { volAvailable :: Bool
  , volLevel :: Float
    -- ^ cubic-scale 0..1 (0.55 = what wpctl displays as 55%)
  , volMuted :: Bool
  } deriving (Show, Eq)

data VolumeEnv = VolumeEnv
  { volHandle :: Ptr PwHandle
  , volState :: TVar VolumeState
    -- ^ set by the PipeWire thread on every change
  , volDirty :: TVar Bool
    -- ^ set with volState; frameUpkeep swaps it out as upVolChanged
    --   (render-on-wake: the dbus/pw thread only writes TVars)
  , volOsdAt :: TVar (Maybe POSIXTime)
    -- ^ last OSD show time; Nothing = hidden. Set on every volume
    --   state change (commands AND external apps) so the indicator
    --   appears whenever the level changed
  , volPrimed :: TVar Bool
    -- ^ the first callback delivery (cached state replay + initial
    --   param enum) must not pop the OSD at startup
  , volTimeoutSec :: Float
  , volPosition :: String
    -- ^ top-center | center | bottom-center
  , volMargin :: Int
    -- ^ px from the top/bottom screen edge (top-center/bottom-center)
  , volStep :: Float
    -- ^ cubic-scale fraction per VolumeUp/VolumeDown
  }

-- | Connect to PipeWire and start tracking the default audio sink.
-- Nothing when disabled or no server (no widget, no deadline — the
-- battery-env pattern).
startVolume :: Config -> IO () -> IO (Maybe VolumeEnv)
startVolume config wake
  | not (configVolumeEnable config) = return Nothing
  | otherwise = do
      h <- pwConnect
      if h == nullPtr
        then do
          hPutStrLn stderr "homgb: volume: no PipeWire server, OSD disabled"
          return Nothing
        else do
          st <- newTVarIO (VolumeState False 0 False)
          dirty <- newTVarIO True
          osdAt <- newTVarIO Nothing
          primed <- newTVarIO False
          let env = VolumeEnv
                { volHandle = h
                , volState = st
                , volDirty = dirty
                , volOsdAt = osdAt
                , volPrimed = primed
                , volTimeoutSec = fromIntegral (configVolumeTimeout config) / 1000
                , volPosition = configVolumePosition config
                , volMargin = configVolumeMargin config
                , volStep = fromIntegral (configVolumeStep config) / 100
                }
          pwSetCallback h $ \lin mut avail -> do
            now <- getPOSIXTime
            let cubic = linearToCubic (realToFrac lin)
                newSt = VolumeState (avail /= 0) cubic (mut /= 0)
            popOsd <- atomically $ do
              oldSt <- readTVar st
              writeTVar st newSt
              writeTVar dirty True
              ready <- readTVar primed
              writeTVar primed True
              -- pop the OSD only on a CHANGE after the initial state
              -- delivery, and only while a sink is available
              let changed = ready && avail /= 0 && oldSt /= newSt
              when changed $ writeTVar osdAt (Just now)
              return changed
            when popOsd wake
          return (Just env)

-- | Is the OSD within its visibility window?
volOsdVisible :: VolumeEnv -> IO Bool
volOsdVisible env = do
  now <- getPOSIXTime
  m <- readTVarIO (volOsdAt env)
  return (maybe False (\t -> now - t < realToFrac (volTimeoutSec env)) m)

-- | Wake time at which the OSD must hide (Nothing = not visible).
volDeadline :: VolumeEnv -> IO (Maybe POSIXTime)
volDeadline env = do
  vis <- volOsdVisible env
  if vis
    then fmap (+ realToFrac (volTimeoutSec env)) <$> readTVarIO (volOsdAt env)
    else return Nothing

-- | VolumeUp/VolumeDown: step on the cubic scale. The C side echoes
-- the new state through the callback (which pops the OSD and wakes
-- the render loop), so no extra wake here.
volDelta :: VolumeEnv -> Float -> IO ()
volDelta env delta = do
  st <- readTVarIO (volState env)
  when (volAvailable st) $
    void $ pwSetVolume (volHandle env)
      (cubicToLinear (clamp01 (volLevel st + delta)))

-- | Mute toggle (0=unmute / 1=mute / 2=toggle exist on the C side; the
-- OSD path always wants toggle).
volToggleMute :: VolumeEnv -> IO ()
volToggleMute env = void $ pwSetMute (volHandle env) 2

linearToCubic :: Float -> Float
linearToCubic l
  | l <= 0 = 0
  | otherwise = l ** (1 / 3)

cubicToLinear :: Float -> Float
cubicToLinear c = c * c * c

clamp01 :: Float -> Float
clamp01 v
  | v < 0 = 0
  | v > 1 = 1
  | otherwise = v
