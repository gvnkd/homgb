{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray
  ( TrayItem(..)
  , TrayState(..)
  , TrayEnv(..)
  , TooltipInfo(..)
  , startTray
  , reapZombieItems
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Exception (catch, IOException)
import Control.Monad (filterM, forM_, unless, void, when)
import Data.List (isPrefixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Time.Clock.POSIX (POSIXTime)
import qualified Data.Text as T
import Graphics.GL (GLuint)
import Graphics.X11.Xlib (Display)
import Graphics.X11.Xlib.Display (openDisplay)
import System.IO (hPutStrLn, stderr)

import DBus
import DBus.Client (Client, call, connectSession)
import DBus.Internal.Types (BusName(..))
import qualified StatusNotifier.Host.Service as SHost
import StatusNotifier.Host.Service (UpdateType(..), ItemInfo, itemServiceName)
import qualified StatusNotifier.Watcher.Client as Watcher

import Homgb.Tray.Embed (EmbedState, XEmbedIcon)
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
  , tiHoverAt :: POSIXTime
    -- ^ same as tiSince, but set even when the hovered widget has no
    -- tooltip lines: drives the render loop's hover-delay deadline
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
  , trayXEmbed :: TVar [XEmbedIcon]
    -- ^ XEmbed-docked icon windows (legacy tray protocol)
  , trayXEmbedHost :: TVar (Maybe EmbedState)
    -- ^ set after the selection is acquired (tray.xembed)
  , trayWake :: IO ()
    -- ^ push a user event on the SDL queue (render-on-wake): DBus
    -- host callbacks and menu fetches run on dispatcher threads and
    -- must wake the blocked render loop when tray state changes
  }

startTray :: IO () -> IO TrayEnv
startTray wake = do
  tState <- newTVarIO $ TrayState [] 0
  textures <- newTVarIO Map.empty
  menus <- newMenus
  prevButtons <- newTVarIO (False, False)
  tooltip <- newTVarIO Nothing
  hoverKey <- newTVarIO Nothing
  xembed <- newTVarIO []
  xembedHost <- newTVarIO Nothing
  mDisplay <- catch (Just <$> openDisplay "") ignoreIO
  forM_ mDisplay installErrorHandler
  client <- connectSession
  _ <- forkIO $ runHost wake tState client
  return $ TrayEnv tState client textures menus prevButtons mDisplay
    tooltip hoverKey xembed xembedHost wake

ignoreIO :: IOException -> IO (Maybe Display)
ignoreIO _ = return Nothing

-- | Drop tray items whose SNI service lived on a UNIQUE bus name
-- that no longer has an owner (the client died/crashed without
-- unregistering). Real items use unique names, so a dead name is a
-- dead item; well-known names are never reaped. Returns the removed
-- names so the caller can also close their menus.
reapZombieItems :: Client -> TVar TrayState -> IO [String]
reapZombieItems client tState = do
  s <- readTVarIO tState
  let zombies = [ n | i <- trayItems s
                , let n = itemServiceName (tiInfo i)
                , isUnique n ]
  dead <- filterM (fmap not . nameAlive) zombies
  unless (null dead) $ do
    atomically $ modifyTVar' tState $ \st ->
      st { trayItems = [ i | i <- trayItems st
                           , itemServiceName (tiInfo i) `notElem` dead ] }
    hPutStrLn stderr $ "tray: reaped " ++ show (length dead)
      ++ " zombie item(s)"
  return (map busNameString dead)
  where
    isUnique (BusName n) = ":" `isPrefixOf` n
    busNameString (BusName n) = n
    nameAlive name = do
      r <- call client (methodCall "/org/freedesktop/DBus" (interfaceName_ "org.freedesktop.DBus") "NameHasOwner")        { methodCallDestination = Just "org.freedesktop.DBus"
        , methodCallBody = [toVariant name]
        }
      case r of
        Right rep -> case methodReturnBody rep of
          (b:_) -> return (fromVariant b == Just True)
          _ -> return False
        Left _ -> return False

runHost :: IO () -> TVar TrayState -> Client -> IO ()
runHost wake tState client = go (10 :: Int)
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
          _ <- SHost.addUpdateHandler host (updateHandler wake tState)
          hPutStrLn stderr "tray: SNI host started"
          -- The host can silently miss items that re-registered in
          -- the window between the watcher name appearing and the
          -- host's initial item-map fetch (worst right after homgb
          -- restarts, when clients re-register within milliseconds —
          -- exposed when font resolution made startup fast). The
          -- map fills without firing ItemAdded to update handlers,
          -- so the tray stays empty. Watchdog: if the watcher's
          -- registered-name SET differs from our tray's a few
          -- seconds in, replay each registered name through the
          -- host's forceUpdate (a fresh item fetch; already-tracked
          -- names are ignored by the library). Never rebuild here:
          -- a second SHost.build would request the host name we
          -- already own → NameAlreadyOwner spam and no new host.
          -- Counts are deliberately not compared: a reaped zombie
          -- stays in the watcher's list forever, so count drift is
          -- not proof of a missed item.
          when (n > 1) $ void $ forkIO $ do
            threadDelay 3000000
            mRegistered <- (Just <$> Watcher.getRegisteredStatusNotifierItems client)
              `catch` (\(_ :: IOException) -> return Nothing)
            s <- readTVarIO tState
            -- the watcher lists items as "busName" or
            -- "uniqueName/object/path" (clients may register by object
            -- path); compare and replay the parsed bus name
            let registeredNames = sort
                  [ takeWhile (/= '/') nm
                  | Just (Right ns) <- [mRegistered], nm <- ns ]
                trayNames = sort
                  [ nm | i <- trayItems s
                      , let BusName nm = itemServiceName (tiInfo i) ]
            case mRegistered of
              Just (Right registered)
                | registeredNames /= trayNames -> do
                    hPutStrLn stderr
                      "tray: SNI host out of sync with watcher, replaying item map"
                    mapM_ (SHost.forceUpdate host . BusName) registered
              _ -> return ()
  -- the dbus client keeps its own dispatcher thread alive; signal
  -- callbacks (our updateHandler) run there, so this thread may exit
-- | Apply a host update to the tray TVar and wake the render loop
-- (the handler runs on the dbus dispatcher thread). The wake is
-- gated on an actual state change: busy items (steam puts download
-- progress in its TOOLTIP) emit a steady stream of Tooltip/Title
-- updates that homgb does not render — waking per update was another
-- constant-CPU-at-idle source.
updateHandler :: IO () -> TVar TrayState -> SHost.UpdateHandler
updateHandler wake tState updateType info = do
  changed <- atomically $ do
    s <- readTVar tState
    let (s', changed') = applyUpdate updateType info s
    writeTVar tState s'
    return changed'
  when changed wake

applyUpdate :: UpdateType -> ItemInfo -> TrayState -> (TrayState, Bool)
applyUpdate updateType info s =
  let name = itemServiceName info
      items = trayItems s
      bump item = item { tiVersion = trayVersion s + 1 }
  in case updateType of
    ItemAdded ->
      ( s { trayItems = items ++ [TrayItem info (trayVersion s + 1)]
          , trayVersion = trayVersion s + 1 }
      , True )
    ItemRemoved ->
      let remaining = filter (\i -> itemServiceName (tiInfo i) /= name) items
      in (s { trayItems = remaining }, length remaining /= length items)
    IconUpdated -> updateMatching s items name bump
    OverlayIconUpdated -> updateMatching s items name bump
    _ -> (s, False)
  where
    updateMatching s' items' name' f =
      let (matched, out) = foldr
            (\i (m, acc) -> if itemServiceName (tiInfo i) == name'
                              then (True, f i : acc)
                              else (m, i : acc))
            (False, []) items'
      in ( s' { trayItems = out, trayVersion = trayVersion s' + 1 }
         , matched )
 