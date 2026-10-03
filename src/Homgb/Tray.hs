{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray
  ( TrayItem(..)
  , TrayState(..)
  , TrayEnv(..)
  , TooltipInfo(..)
  , startTray
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Exception (catch, IOException)
import Control.Monad (forM_, void, when)
import qualified Data.Map.Strict as Map
import Data.Time.Clock.POSIX (POSIXTime)
import qualified Data.Text as T
import Graphics.GL (GLuint)
import Graphics.X11.Xlib (Display)
import Graphics.X11.Xlib.Display (openDisplay)
import System.IO (hPutStrLn, stderr)

import DBus.Client (Client, connectSession)
import qualified StatusNotifier.Host.Service as SHost
import StatusNotifier.Host.Service (UpdateType(..), ItemInfo, itemServiceName)
import qualified StatusNotifier.Watcher.Client as Watcher

import Homgb.Tray.Menu.Render (Menus, newMenus)
import Homgb.WMProps (installErrorHandler)

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

-- | Pending SNI tooltip: rendered on its own surface (EWMH TOOLTIP)
-- anchored at the pointer — the in-window ImGui tooltip clipped
-- against the 54px-tall bar viewport, so multi-line SNI tooltips
-- (blueman) never fit.
data TooltipInfo = TooltipInfo
  { tiLines :: [T.Text]
  , tiRootX :: Int
  , tiRootY :: Int
  , tiSince :: POSIXTime
    -- ^ when the current hover started (delay before showing)
  , tiLastSeen :: POSIXTime
    -- ^ last frame the hovered item was hovered (staleness check)
  }

data TrayEnv = TrayEnv
  { trayState :: TVar TrayState
  , trayClient :: Client
  , trayTextures :: TVar (Map.Map String (Int, Maybe GLuint))
    -- ^ icon textures: item bus name -> (version, texture)
  , trayMenus :: Menus
  , trayPrevButtons :: TVar (Bool, Bool)
    -- ^ (left, right) mouse button state last frame, for press edges
  , trayDisplay :: Maybe Display
    -- ^ own X connection for global pointer/button polls (SDL only
    -- tracks events delivered to its own window)
  , trayTooltip :: TVar (Maybe TooltipInfo)
  , trayHoverKey :: TVar (Maybe (String, POSIXTime))
    -- ^ which item is hovered and since when (tooltip show delay)
  }

startTray :: IO TrayEnv
startTray = do
  tState <- newTVarIO $ TrayState [] 0
  textures <- newTVarIO Map.empty
  menus <- newMenus
  prevButtons <- newTVarIO (False, False)
  tooltip <- newTVarIO Nothing
  hoverKey <- newTVarIO Nothing
  mDisplay <- catch (Just <$> openDisplay "") ignoreIO
  forM_ mDisplay installErrorHandler
  client <- connectSession
  _ <- forkIO $ runHost tState client
  return $ TrayEnv tState client textures menus prevButtons mDisplay
    tooltip hoverKey

ignoreIO :: IOException -> IO (Maybe Display)
ignoreIO _ = return Nothing

runHost :: TVar TrayState -> Client -> IO ()
runHost tState client = go (10 :: Int)
  where
    go 0 = hPutStrLn stderr "tray: failed to start SNI host"
    go n = do
      mHost <- SHost.build SHost.defaultParams
        { SHost.dbusClient = Just client
        , SHost.uniqueIdentifier = "homgb"
        , SHost.startWatcher = True
        }
      case mHost of
        Nothing -> do
          -- the watcher name may still be held by a previous homgb
          -- instance that is releasing it, or our request is queued
          -- behind it; retry instead of giving up
          threadDelay 1000000
          go (n - 1)
        Just host -> do
          _ <- SHost.addUpdateHandler host (updateHandler tState)
          hPutStrLn stderr "tray: SNI host started"
          -- The host can silently miss items that re-registered in
          -- the window between the watcher name appearing and the
          -- host's initial item-map fetch (worst right after homgb
          -- restarts, when clients re-register within milliseconds —
          -- exposed when font resolution made startup fast). The
          -- map fills without firing ItemAdded to update handlers,
          -- so the tray stays empty. Watchdog: if the watcher knows
          -- more items than our tray a few seconds in, rebuild once
          -- (a fresh build replays the full item map).
          when (n > 1) $ void $ forkIO $ do
            threadDelay 3000000
            mRegistered <- (Just <$> Watcher.getRegisteredStatusNotifierItems client)
              `catch` (\(_ :: IOException) -> return Nothing)
            s <- readTVarIO tState
            case mRegistered of
              Just (Right registered)
                | length registered > length (trayItems s) -> do
                    hPutStrLn stderr
                      "tray: SNI host missed registered items, rebuilding"
                    go (n - 1)
              _ -> return ()
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
 