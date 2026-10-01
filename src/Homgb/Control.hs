{-# LANGUAGE OverloadedStrings #-}

-- | DBus control interface. homgb does NOT grab keys globally; the
-- WM (or anything) binds shortcuts and sends commands, e.g.:
--
-- > busctl --user call org.homgb /org/homgb/Control org.homgb.Control NextLayout
--
-- Works under any WM and on Wayland (unlike XGrabKey). The interface
-- grows with new commands (notification center toggle, etc).
module Homgb.Control (startControl) where

import DBus.Client
  (autoMethod, connectSession, export, requestName
  , defaultInterface, interfaceName, interfaceMethods
  , nameAllowReplacement, nameReplaceExisting)

import Homgb.Keyboard (KeyboardEnv, rotateLayout)

-- | Own org.homgb and export /org/homgb/Control. Best-effort: a
-- failed name request only disables remote control.
startControl :: Maybe KeyboardEnv -> IO ()
startControl Nothing = return ()
startControl (Just kb) = do
  client <- connectSession
  _ <- requestName client "org.homgb"
         [nameAllowReplacement, nameReplaceExisting]
  export client "/org/homgb/Control" defaultInterface
    { interfaceName = "org.homgb.Control"
    , interfaceMethods =
      [ autoMethod "NextLayout" (rotateLayout kb >> return ())
      ]
    }
  return ()
