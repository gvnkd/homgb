module Homgb.State where

data AppState = AppState
  { stateClicks :: Int
  }

initialState :: AppState
initialState = AppState
  { stateClicks = 0
  }
