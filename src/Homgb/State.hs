{-# LANGUAGE OverloadedStrings #-}

module Homgb.State where

import qualified Data.Map.Strict as Map
import Graphics.GL (GLuint)
import Control.Concurrent.STM.TVar (TVar, newTVarIO)

import Homgb.Keyboard (KeyboardEnv)
import Homgb.Notifications.Daemon (NotifyState)
import Homgb.Surface (Surfaces)
import Homgb.Tray (TrayEnv)

data AppState = AppState
  { appNotify :: TVar NotifyState
  , appTextures :: TVar (Map.Map Int GLuint)
    -- ^ GL textures for notification images, keyed by notiId
  , appHeights :: TVar (Map.Map Int Float)
    -- ^ Last measured popup heights, keyed by notiId (stacking layout)
  , appTray :: TrayEnv
  , appKeyboard :: Maybe KeyboardEnv
  , appSurfaces :: Surfaces
  , appScreenSize :: (Int, Int)
    -- ^ primary X screen size, for surface positioning
  , appCenterVisible :: TVar Bool
    -- ^ notification center panel visibility (DBus ToggleCenter)
  }

initialAppState :: TVar NotifyState -> TrayEnv -> Maybe KeyboardEnv
                -> Surfaces -> (Int, Int) -> TVar Bool -> IO AppState
initialAppState tState tray kb surfaces screenSize centerVisible = do
  textures <- newTVarIO Map.empty
  heights <- newTVarIO Map.empty
  return AppState
    { appNotify = tState
    , appTextures = textures
    , appHeights = heights
    , appTray = tray
    , appKeyboard = kb
    , appSurfaces = surfaces
    , appScreenSize = screenSize
    , appCenterVisible = centerVisible
    }
