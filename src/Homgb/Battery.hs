{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Battery widget data source: reads /sys/class/power_supply/BAT*
-- directly. No UPower, no udev: capacity moves in 1% steps, so a
-- deadline-driven poll every bar.battery-interval seconds (default
-- 10) loses nothing, and the render loop already wakes ~1Hz for the
-- XKB group poll — the battery deadline adds zero extra wakeups and
-- each poll is a handful of tiny sysfs reads.
module Homgb.Battery
  ( BatteryEnv(..)
  , BatteryState(..)
  , startBattery
  , pollBattery
  , batteryLabel
  , batteryTooltip
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (try, SomeException)
import Control.Monad (when)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))

import Homgb.Config (Config(..))

-- | Sysfs snapshot of one battery. Display fields are the capacity,
-- the current draw and the status; energy figures only feed the
-- hover tooltip.
data BatteryState = BatteryState
  { batPresent :: Bool
  , batCapacity :: Int
    -- ^ percent, 0-100
  , batPowerW :: Maybe Double
    -- ^ power_now, or current_now*voltage_now when power_now is
    -- absent; watts
  , batStatus :: T.Text
    -- ^ Charging / Discharging / Not charging / Full
  , batEnergyNowWh :: Maybe Double
  , batEnergyFullWh :: Maybe Double
  , batQueriedAt :: POSIXTime
    -- ^ freshness for nextDeadline's battery deadline. MUST be
    -- refreshed on EVERY poll, changed or not, failed or not — a
    -- stale value is a deadline in the past, and a past deadline
    -- clamps the main loop's wait to 1ms (the lsQueriedAt spin).
  }

data BatteryEnv = BatteryEnv
  { batDir :: FilePath
    -- ^ e.g. /sys/class/power_supply/BAT0
  , batInterval :: Int
    -- ^ seconds between polls (bar.battery-interval)
  , batState :: TVar BatteryState
  }

sysfsRoot :: FilePath
sysfsRoot = "/sys/class/power_supply"

-- | Nothing when disabled (bar.battery: false) or the node has no
-- battery: no widget, no deadline, no polling at all.
startBattery :: Config -> IO (Maybe BatteryEnv)
startBattery config
  | not (configBarBattery config) = return Nothing
  | otherwise = do
      let dev = configBarBatteryDevice config
      mDir <- if not (null dev)
        then do
          let d = sysfsRoot </> dev
          ok <- doesFileExist (d </> "capacity")
          return (if ok then Just d else Nothing)
        else detectBattery
      case mDir of
        Nothing -> return Nothing
        Just dir -> do
          now <- getPOSIXTime
          -- queriedAt far in the past so the first pollBattery in
          -- frameUpkeep reads immediately
          st <- newTVarIO BatteryState
            { batPresent = False
            , batCapacity = 0
            , batPowerW = Nothing
            , batStatus = ""
            , batEnergyNowWh = Nothing
            , batEnergyFullWh = Nothing
            , batQueriedAt = now - 1000000
            }
          return (Just (BatteryEnv dir (max 1 (configBarBatteryInterval config)) st))

-- | First power_supply entry of type Battery.
detectBattery :: IO (Maybe FilePath)
detectBattery = do
  entsE <- try @SomeException (listDirectory sysfsRoot)
  case entsE of
    Left _ -> return Nothing
    Right ents -> go ents
  where
    go [] = return Nothing
    go (e:es) = do
      ty <- readSys (sysfsRoot </> e </> "type")
      if ty == Just "Battery"
        then return (Just (sysfsRoot </> e))
        else go es

-- | Re-read the sysfs attributes when the cached snapshot is older
-- than the configured interval; returns True when a displayed field
-- changed (tray redraw). Called from frameUpkeep; the loop wakes for
-- it via nextDeadline (batQueriedAt + interval).
pollBattery :: BatteryEnv -> IO Bool
pollBattery be = do
  now <- getPOSIXTime
  s <- readTVarIO (batState be)
  if now - batQueriedAt s < fromIntegral (batInterval be)
    then return False
    else do
      -- refresh the timestamp FIRST: even a failed read must keep the
      -- deadline in the future
      atomically $ writeTVar (batState be) s { batQueriedAt = now }
      mNew <- readBattery (batDir be)
      case mNew of
        Nothing -> return False
        Just new0 -> do
          let new = new0 { batQueriedAt = now }
              changed = batPresent new /= batPresent s
                || batCapacity new /= batCapacity s
                || batPowerW new /= batPowerW s
                || batStatus new /= batStatus s
          when changed $ atomically $ writeTVar (batState be) new
          return changed

readBattery :: FilePath -> IO (Maybe BatteryState)
readBattery dir = do
  mCap <- readSys (dir </> "capacity")
  case mCap >>= readMaybe of
    Nothing -> return Nothing
    Just cap -> do
      now <- getPOSIXTime
      status <- fromMaybe "" <$> readSys (dir </> "status")
      present <- (== Just "1") <$> readSys (dir </> "present")
      power <- readWatts dir
      eNow <- readWh dir "energy_now"
      eFull <- readWh dir "energy_full"
      return (Just BatteryState
        { batPresent = present
        , batCapacity = cap
        , batPowerW = power
        , batStatus = T.pack status
        , batEnergyNowWh = eNow
        , batEnergyFullWh = eFull
        , batQueriedAt = now
        })

-- | Watts: power_now is microwatts; when missing, fall back to
-- current_now (uA) * voltage_now (uV).
readWatts :: FilePath -> IO (Maybe Double)
readWatts dir = do
  mP <- readSys (dir </> "power_now")
  case mP >>= readMaybe of
    Just uW -> return (Just (uW / 1e6))
    Nothing -> do
      mI <- readSys (dir </> "current_now")
      mV <- readSys (dir </> "voltage_now")
      return $ case (mI >>= readMaybe, mV >>= readMaybe) of
        (Just uA, Just uV) -> Just (uA * uV / 1e12)
        _ -> Nothing

readWh :: FilePath -> FilePath -> IO (Maybe Double)
readWh dir name = do
  m <- readSys (dir </> name)
  return (fmap (/ 1e6) (m >>= readMaybe))

readSys :: FilePath -> IO (Maybe String)
readSys path = do
  r <- try @SomeException (readFile path)
  return (either (const Nothing) (Just . trim) r)
  where
    trim = reverse . dropWhile (== '\n') . reverse

readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
  [(x, "")] -> Just x
  _ -> Nothing

-- | One-decimal render (show Double would print exponents for tiny
-- values and long tails for ugly ones).
fmt1 :: Double -> String
fmt1 x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)

-- | Bar label: "90% -12.3W" discharging, "85% +15.0W" charging,
-- "100%" when full (a full battery reports ~0W, which reads as
-- noise). Shared by the render and the measure pass — the bar's
-- right-anchor math depends on them agreeing.
batteryLabel :: BatteryState -> T.Text
batteryLabel s = T.pack (show (batCapacity s) ++ "%") <> watts
  where
    watts = case batPowerW s of
      Just w | batStatus s /= "Full" && w > 0.05 ->
        T.pack (" " ++ sign ++ fmt1 w ++ "W")
      _ -> ""
    sign = case batStatus s of
      "Charging" -> "+"
      "Discharging" -> "-"
      _ -> ""

batteryTooltip :: BatteryState -> [T.Text]
batteryTooltip s =
  [ "Battery: " <> batStatus s ]
  ++ case (batEnergyNowWh s, batEnergyFullWh s) of
       (Just n, Just f) ->
         [ T.pack ("Energy: " ++ fmt1 n ++ " / " ++ fmt1 f ++ " Wh") ]
       _ -> []
