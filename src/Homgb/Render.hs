{-# LANGUAGE OverloadedStrings #-}

module Homgb.Render (renderFrame) where

import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Control.Monad (when)
import qualified Data.Text as T
import DearImGui

import Homgb.State

renderFrame :: TVar AppState -> IO ()
renderFrame state = withWindowOpen "homgb" $ do
  text "homgb"
  clicked <- button "click"
  when clicked $
    atomically $
      modifyTVar' state (\s -> s { stateClicks = stateClicks s + 1 })
  clicks <- readTVarIO state
  text (T.pack ("clicks: " ++ show (stateClicks clicks)))
