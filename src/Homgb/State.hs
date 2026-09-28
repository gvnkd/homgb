{-# LANGUAGE OverloadedStrings #-}

module Homgb.State where

import qualified Data.Map.Strict as Map
import Graphics.GL (GLuint)
import Control.Concurrent.STM.TVar (TVar, newTVarIO)

import Homgb.Notifications.Daemon (NotifyState)
import Homgb.Tray (TrayEnv)

data AppState = AppState
  { appNotify :: TVar NotifyState
  , appTextures :: TVar (Map.Map Int GLuint)
    -- ^ GL textures for notification images, keyed by notiId
  , appHeights :: TVar (Map.Map Int Float)
    -- ^ Last measured popup heights, keyed by notiId (stacking layout)
  , appTray :: TrayEnv
  }

initialAppState :: TVar NotifyState -> TrayEnv -> IO AppState
initialAppState tState tray = do
  textures <- newTVarIO Map.empty
  heights <- newTVarIO Map.empty
  return AppState
    { appNotify = tState
    , appTextures = textures
    , appHeights = heights
    , appTray = tray
    }
