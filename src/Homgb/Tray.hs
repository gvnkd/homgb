{-# LANGUAGE OverloadedStrings #-}

module Homgb.Tray
  ( TrayItem(..)
  , TrayState(..)
  , TrayEnv(..)
  , startTray
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, modifyTVar')
import Control.Concurrent.STM.TVar
import qualified Data.Map.Strict as Map
import Graphics.GL (GLuint)
import System.IO (hPutStrLn, stderr)

import DBus.Client (Client, connectSession)
import qualified StatusNotifier.Host.Service as SHost
import StatusNotifier.Host.Service (UpdateType(..), ItemInfo, itemServiceName)

-- | One tray entry. tiVersion bumps whenever the host reports an
-- icon-affecting change so the renderer re-uploads the GL texture.
data TrayItem = TrayItem
  { tiInfo :: ItemInfo
  , tiVersion :: Int
  }

data TrayState = TrayState
  { trayItems :: [TrayItem]
  , trayVersion :: Int
    -- ^ Global counter, bumped on any icon-affecting update
  }

data TrayEnv = TrayEnv
  { trayState :: TVar TrayState
  , trayClient :: Client
  , trayTextures :: TVar (Map.Map String (Int, Maybe GLuint))
    -- ^ icon textures: item bus name -> (version, texture)
  }

startTray :: IO TrayEnv
startTray = do
  tState <- newTVarIO $ TrayState [] 0
  textures <- newTVarIO Map.empty
  client <- connectSession
  _ <- forkIO $ runHost tState client
  return $ TrayEnv tState client textures

runHost :: TVar TrayState -> Client -> IO ()
runHost tState client = do
  mHost <- SHost.build SHost.defaultParams
    { SHost.dbusClient = Just client
    , SHost.uniqueIdentifier = "homgb"
    , SHost.startWatcher = True
    }
  case mHost of
    Nothing -> hPutStrLn stderr "tray: failed to start SNI host"
    Just host -> do
      _ <- SHost.addUpdateHandler host (updateHandler tState)
      return ()
  -- the dbus client keeps its own dispatcher thread alive; signal
  -- callbacks (our updateHandler) run there, so this thread may exit

-- | Apply a host update to the tray TVar.
updateHandler :: TVar TrayState -> SHost.UpdateHandler
updateHandler tState updateType info =
  atomically $ modifyTVar' tState $ \s ->
    let name = itemServiceName info
        items = trayItems s
        bump item = item { tiVersion = trayVersion s + 1 }
    in case updateType of
      ItemAdded ->
        s { trayItems = items ++ [TrayItem info (trayVersion s + 1)]
          , trayVersion = trayVersion s + 1 }
      ItemRemoved ->
        s { trayItems = filter (\i -> itemServiceName (tiInfo i) /= name) items }
      IconUpdated -> updateMatching s items name bump
      OverlayIconUpdated -> updateMatching s items name bump
      _ -> s
  where
    updateMatching s items name f =
      s { trayItems = map (\i -> if itemServiceName (tiInfo i) == name
                                   then f i else i) items
        , trayVersion = trayVersion s + 1 }
