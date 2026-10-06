{-# LANGUAGE OverloadedStrings #-}

-- | DBus control interface. homgb does NOT grab keys globally; the
-- WM (or anything) binds shortcuts and sends commands, e.g.:
--
-- > busctl --user call org.homgb /org/homgb/Control org.homgb.Control NextLayout
--
-- Works under any WM and on Wayland (unlike XGrabKey). The interface
-- grows with new commands (notification center toggle, volume, etc).
module Homgb.Control (startControl) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar')
import DBus.Client
  (autoMethod, connectSession, export, requestName
  , defaultInterface, interfaceName, interfaceMethods
  , nameAllowReplacement, nameReplaceExisting)

import Homgb.Keyboard (KbUi(..))
import Homgb.Media (MediaEnv, mediaCommand)
import Homgb.Volume (VolumeEnv(..), volDelta, volToggleMute)

-- | Own org.homgb and export /org/homgb/Control. Best-effort: a
-- failed name request only disables remote control. centerVisible is
-- the notification center panel's show/hide switch. Volume
-- up/down/mute drive the PipeWire default sink and pop the OSD (via
-- the volume env's change callback). Media* route MPRIS commands to
-- the right player (Homgb.Media). `wake` re-renders after
-- command-handling mutations (dbus dispatcher thread).
startControl :: Maybe KbUi -> TVar Bool -> Maybe VolumeEnv -> MediaEnv -> IO () -> IO ()
startControl kbOpt centerVisible volOpt media wake = do
  client <- connectSession
  _ <- requestName client "org.homgb"
         [nameAllowReplacement, nameReplaceExisting]
  export client "/org/homgb/Control" defaultInterface
    { interfaceName = "org.homgb.Control"
    , interfaceMethods =
      [ autoMethod "NextLayout" (nextLayout wake kbOpt)
      , autoMethod "ToggleCenter"
          (atomically (modifyTVar' centerVisible not) >> wake)
      , autoMethod "VolumeUp" (volChange wake volOpt 1)
      , autoMethod "VolumeDown" (volChange wake volOpt (-1))
      , autoMethod "ToggleMute" (toggleMute wake volOpt)
      , autoMethod "MediaPlayPause" (mediaCommand media "PlayPause")
      , autoMethod "MediaNext" (mediaCommand media "Next")
      , autoMethod "MediaPrev" (mediaCommand media "Previous")
      ]
    }
  return ()

nextLayout :: IO () -> Maybe KbUi -> IO ()
nextLayout wake (Just kb) = kbUiRotate kb >> wake
nextLayout _ Nothing = return ()

-- | The PipeWire change callback re-renders (and pops the OSD), so an
-- extra wake is only needed when there is nothing to control. Steps
-- by the configured cubic-scale amount.
volChange :: IO () -> Maybe VolumeEnv -> Int -> IO ()
volChange _ (Just vol) dir = volDelta vol (fromIntegral dir * volStep vol)
volChange wake Nothing _ = wake

toggleMute :: IO () -> Maybe VolumeEnv -> IO ()
toggleMute _ (Just vol) = volToggleMute vol
toggleMute wake Nothing = wake
