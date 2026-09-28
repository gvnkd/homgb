{-# LANGUAGE OverloadedStrings #-}

module Homgb.Notifications.Daemon
  ( startNotificationDaemon
  , NotifyState(..)
  , closeNotiById
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
  (readTVarIO, stateTVar, modifyTVar', atomically, newTVarIO, TVar)

import DBus (Variant, fromVariant, signal, toVariant)
import DBus.Internal.Message (Signal(..))
import DBus.Client
       ( connectSession, autoMethod, requestName, export
       , defaultInterface, interfaceName, interfaceMethods
       , nameAllowReplacement, nameReplaceExisting, emit
       , RequestNameReply(..))
import Data.Text (unpack, pack, Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.ByteString.Lazy (toStrict)
import Data.Word ( Word8, Word32 )
import Data.Int ( Int32 )
import Data.Time
import Data.Maybe (fromMaybe, isJust)
import Data.List (find)
import qualified Data.Text as Text
import qualified Data.Map as Map
import qualified Data.Yaml as Yaml
import qualified Data.Aeson as Aeson

import Control.Exception (finally)
import System.Process (readCreateProcess, shell, spawnCommand, interruptProcessGroupOf, waitForProcess)

import System.IO (hFlush, stdout)

import Homgb.Helpers (removeAllTags, parseHtmlEntities, getImgTagAttrs)
import Homgb.Config (Config(..), ModificationRule(..))
import Homgb.Notifications.Data
  (Urgency(..), CloseType(..), Notification(..), Image(..), parseImageString)

data NotifyState = NotifyState
  { notiStList :: [ Notification ]
    -- ^ Live notifications, newest first. For M1 every live notification
    --   is rendered as a popup (the center panel is M3+).
  , notiStNextId :: Int
    -- ^ Id for the next noti
  , notiConfig :: Config
    -- ^ Configuration
  }

getServerInformation :: IO (Text, Text, Text, Text)
getServerInformation =
  return ("homgb",
          "gvnkd",
          "0.1.0",
          "1.2")

getCapabilities :: IO [Text]
-- body-markup intentionally not advertised: M1 renders plain text only
-- (see design_docs/milestone_1.md, decision 5). Add "body-markup" and
-- "body-hyperlinks" here once a rich-text renderer exists.
getCapabilities = return [ "body"
                         , "hints"
                         , "actions"
                         , "persistence"
                         , "icon-static"
                         , "action-icons" ]

emitNotificationClosed :: Bool -> (Signal -> IO ()) -> Int -> CloseType -> IO ()
emitNotificationClosed doSend onClose notiId' ctype =
  if doSend then
    onClose $ (signal "/org/freedesktop/Notifications"
               "org.freedesktop.Notifications"
               "NotificationClosed")
    { signalBody = [ toVariant (fromIntegral notiId' :: Word32)
                   , toVariant (case ctype of
                                   Timeout -> 1
                                   User -> 2
                                   CloseByCall -> 3
                                   _ -> 4 :: Word32)] }
  else return ()

emitAction :: (Signal -> IO ()) -> Int -> [(String, String)] -> String -> Maybe String -> IO ()
emitAction onAction notiId' actionCommands key mParam = do
  let mCommand = lookup key actionCommands
  if isJust mCommand then do
    ph <- spawnCommand $ fromMaybe "" mCommand
    _ <- waitForProcess ph `finally` interruptProcessGroupOf ph
    return ()
    else
    onAction $ (signal "/org/freedesktop/Notifications"
                "org.freedesktop.Notifications"
                "ActionInvoked")
    { signalBody = [ toVariant (fromIntegral notiId' :: Word32)
                   , toVariant key]
                   ++ if mParam == Nothing then
                        []
                      else
                        [toVariant $ fromMaybe "" mParam]
        }

parseActionIcons :: Map.Map Text Variant -> Bool
parseActionIcons hints =
  fromMaybe False $ (fromVariant =<< Map.lookup "action-icons" hints :: Maybe Bool)

parseUrgency :: Map.Map Text Variant -> Urgency
parseUrgency hints =
  let urgency = fromVariant =<< Map.lookup "urgency" hints :: Maybe Word8
  in case urgency of
       (Just 0) -> Low
       Nothing  -> Normal
       (Just 1) -> Normal
       _        -> High

parseTransient :: Map.Map Text Variant -> Bool
parseTransient hints =
  let transient = Map.lookup "transient" hints
  in case transient of
    Nothing -> False
    (Just _) -> True

getAppIcon :: String -> IO Image
-- Freedesktop icon lookup (GI.Gio desktop-file walk) is deferred to M2,
-- where the tray will share it. Until then: no guessed icons.
getAppIcon _ = return NoImage

parseIcon :: Config -> Map.Map Text Variant -> Text -> Text -> IO Image
parseIcon config hints icon appName =
  if (Text.length icon) > 0 then do
    return $ parseImageString icon
    else do
      let mFileName = fromVariant =<< Map.lookup "desktop-entry" hints
        in case mFileName of
         (Just fileName) -> do
           getAppIcon fileName

         Nothing -> if configGuessIconFromAppname config then
                      getAppIcon $ unpack appName
                    else
                      return NoImage

parseImg :: Map.Map Text Variant -> Text -> Image
parseImg hints text =
  fromMaybe NoImage
  $ fromBody <|> fromImageData <|> fromImagePath <|> fromIcon
  where
    fromBody = ImagePath <$> unpack <$> lookup (pack "src") (getImgTagAttrs text)
    fromIcon = RawImg <$> (fromVariant =<< Map.lookup "icon_data" hints)
    fromImageData = RawImg <$> (fromVariant =<< Map.lookup "image-data" hints)
    fromImagePath = parseImageString <$> (fromVariant =<< Map.lookup "image-path" hints)

getTime :: IO Text
getTime = do
  now <- zonedTimeToLocalTime <$> getZonedTime
  return $ pack $ formatTime defaultTimeLocale "%H:%M" now

htmlEntitiesStrip :: Config -> Text -> Text
htmlEntitiesStrip config text =
  if configNotiParseHtmlEntities config
  then Text.pack $ parseHtmlEntities $ unpack text
  else text

xmlStrip :: Config -> Text -> Text
xmlStrip config text = do
  if configNotiMarkup config then
    text
    else removeAllTags text

notify :: Config
       -> TVar NotifyState
       -> (Signal -> IO ())
       -> Text -- ^ Application name
       -> Word32 -- ^ Replaces id
       -> Text -- ^ App icon
       -> Text -- ^ Summary
       -> Text -- ^ Body
       -> [Text] -- ^ Actions
       -> Map.Map Text Variant -- ^ Hints
       -> Int32 -- ^ Expires timeout (milliseconds)
       -> IO Word32
notify config tState emit'
  appName replaceId icon summary body actions hints timeout = do
  createdAt <- getCurrentTime
  time <- getTime
  icon' <- parseIcon config hints icon appName
  let newNotiWithoutId = Notification
        { notiAppName = appName
        , notiRepId = replaceId
        , notiId = 0
        , notiIcon = icon'
        , notiImg = parseImg hints body
        , notiImgSize = configImgSize config
        , notiSummary = htmlEntitiesStrip config summary
        , notiBody = htmlEntitiesStrip config $ xmlStrip config body
        , notiActions = actions
        , notiActionIcons = parseActionIcons hints
        , notiActionCommands = []
        , notiHints = hints
        , notiUrgency = parseUrgency hints
        , notiTimeout = timeout
        , notiTime = time
        , notiCreatedAt = createdAt
        , notiTransient = parseTransient hints
        , notiSendClosedMsg = (configSendNotiClosedDbusMessage config)
        , notiOnClosed = \_ -> return ()
        , notiOnAction = \_ _ _ -> return ()
        , notiTop = Nothing
        , notiRight = Nothing
        , notiPercentage = fromIntegral
          <$> ( fromVariant =<< Map.lookup "value" hints :: Maybe Int32 )
        }

  newNotiWoIdModified <- modifyNoti config newNotiWithoutId

  newId <- atomically $ stateTVar tState
           $ \state ->
             ( notiStNextId state, state
               { notiStNextId = notiStNextId state + 1 } )

  let newNoti = newNotiWoIdModified
        { notiId = newId
        , notiOnClosed = emitNotificationClosed (notiSendClosedMsg newNotiWoIdModified)
                         emit' newId
        , notiOnAction = emitAction emit' newId }

  atomically $ modifyTVar' tState $ \state ->
    state { notiStList =
              updatedNotiList (notiStList state) newNoti
              (fromIntegral (notiRepId newNoti)) }

  return $ fromIntegral $ notiId newNoti
    where
      updatedNotiList :: [Notification] -> Notification
                      -> Int -> [Notification]
      updatedNotiList oldNotis newNoti repId =
        let notis' = map (\n -> if notiId n == repId then newNoti
                                else n) oldNotis
        in if (find ((==) newNoti) notis') /= Nothing then notis'
           else (newNoti:notis')

modifyNoti :: Config -> Notification -> IO Notification
modifyNoti config noti =
  let modificationRules = configMatchingRules config
  in foldr (\rule ioNoti -> modifies rule =<< ioNoti) (return noti)
     $ filter (\rule -> rule `matches` noti) modificationRules
  where matches rule n =
          Map.foldrWithKey (\k v acc -> acc && ((v == lookupFun k n)))
          True (mMatch rule)
        lookupFun name n = Text.unpack $ fromMaybe (Text.pack "")
          (let notiUrgencyStr = (\x -> case (notiUrgency x) of
                                         Low -> "low"
                                         Normal -> "normal"
                                         High -> "critical")
           in ((lookup name
                [ ("title", notiSummary)
                , ("body", notiBody)
                , ("app-name", notiAppName)
                , ("urgency", pack . notiUrgencyStr)
                , ("time", notiTime)
                ]) <*> (Just n)))
        replace ('\\':cs) = "\\\\" ++ replace cs
        replace (c:cs) = c : replace cs
        replace ([]) = []
        modifies (Script _m s) noti' = do
          returnText <- readCreateProcess (shell s)
            $ replace (unpack $ decodeUtf8 $ toStrict $ Aeson.encode noti') ++ "\n"
          newModifier <- Yaml.decodeThrow $ encodeUtf8 $ pack returnText
          modifies newModifier noti'
        modifies modify noti' = do
          let newnoti = noti'
                { notiSummary = fromMaybe (notiSummary noti')
                  $ pack <$> modifyTitle modify
                , notiBody = fromMaybe (notiBody noti')
                  $ pack <$> modifyBody modify
                , notiAppName = fromMaybe (notiAppName noti')
                  $ pack <$> modifyAppname modify
                , notiIcon = fromMaybe (notiIcon noti')
                  $ parseImageString <$> pack <$> modifyAppicon modify
                , notiTimeout = fromMaybe (notiTimeout noti')
                  $ modifyTimeout modify
                , notiRight = fromMaybe (notiRight noti')
                  $ Just <$> modifyRight modify
                , notiTop = fromMaybe (notiTop noti')
                  $ Just <$> modifyTop modify
                , notiImg = fromMaybe (notiImg noti')
                  $ parseImageString <$> pack <$> modifyImage modify
                , notiImgSize = fromMaybe (notiImgSize noti')
                  $ modifyImageSize modify
                , notiTransient = fromMaybe (notiTransient noti')
                  $ modifyTransient modify
                , notiSendClosedMsg = fromMaybe (notiSendClosedMsg noti')
                  $ modifyNoClosedMsg modify
                , notiActions = (pack <$> (fromMaybe [] $  modifyActions modify))
                                ++ (maybe (notiActions noti')
                                    (\_ -> []) $ modifyRemoveActions modify)
                , notiActionIcons = fromMaybe (notiActionIcons noti')
                  $ modifyActionIcons modify
                , notiActionCommands = fromMaybe (notiActionCommands noti')
                $ Map.assocs <$> modifyActionCommands modify }
          return newnoti

-- | Remove a notification from state, invoke its onClosed with the given
-- close type (emitting NotificationClosed when configured).
closeNotiById :: TVar NotifyState -> Int -> CloseType -> IO ()
closeNotiById tState notiId' ctype = do
  state <- readTVarIO tState
  let mNoti = find (\n -> notiId n == notiId') (notiStList state)
  case mNoti of
    Nothing -> return ()
    Just noti -> do
      atomically $ modifyTVar' tState $ \s ->
        s { notiStList = filter (\n -> notiId n /= notiId') (notiStList s) }
      notiOnClosed noti ctype

closeNotification :: TVar NotifyState -> Word32 -> IO ()
closeNotification tState wid = closeNotiById tState (fromIntegral wid) CloseByCall

notificationDaemon :: Config -> TVar NotifyState -> IO ()
notificationDaemon config tState = do
  putStrLn "notificationDaemon started"
  hFlush stdout
  client <- connectSession
  reply <- requestName client "org.freedesktop.Notifications"
       [nameAllowReplacement, nameReplaceExisting]
  case reply of
    NamePrimaryOwner -> return ()
    _ -> putStrLn $ "requestName: could not own org.freedesktop.Notifications (" ++ show reply ++ ")"
  hFlush stdout
  export client "/org/freedesktop/Notifications" defaultInterface
    { interfaceName = "org.freedesktop.Notifications"
    , interfaceMethods =
      [ autoMethod "GetServerInformation" getServerInformation
      , autoMethod "GetCapabilities" getCapabilities
      , autoMethod "CloseNotification" (closeNotification tState)
      , autoMethod "Notify" (notify config tState (emit client))
      ]
    }

startNotificationDaemon :: Config -> IO (TVar NotifyState)
startNotificationDaemon config = do
  istate <- newTVarIO $ NotifyState [] 1 config
  _ <- forkIO (notificationDaemon config istate)
  return istate
