{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | MPRIS media-key routing. Every player (chromium with a media tab,
-- kodi, mpv, ...) owns an org.mpris.MediaPlayer2.* bus name, and MPRIS
-- commands go to the BUS, not to a window — an unfocused or
-- backgrounded player receives them fine. The only question is WHICH
-- player a media key targets, resolved in this order:
--
--   1. the focused window's app_id, when that app is a player (you are
--      in kodi: the key controls kodi);
--   2. the player that most recently reported PlaybackStatus=Playing,
--      tracked live from PropertiesChanged — the "music playing in the
--      background" case: focused terminal, YouTube in an inactive
--      chromium;
--   3. a live PlaybackStatus query across current players, covering
--      playback that began before homgb started (the monitor has no
--      record of it);
--   4. the sole player, when exactly one exists.
--
-- Nothing matches: the key is a no-op. homgb does not grab keys; the WM
-- binds XF86Audio* and calls the org.homgb.Control Media* methods.
module Homgb.Media
  ( MediaEnv(..)
  , startMedia
  , mediaCommand
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad (filterM, forM_, void)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import System.IO (hPutStrLn, stderr)

import DBus
  ( Signal, Variant, busName_, formatBusName, formatMemberName, fromVariant
  , memberName_, methodCall, methodCallBody, methodCallDestination
  , methodReturnBody, signalBody, signalMember, signalSender, toVariant)
import DBus.Client (Client, addMatch, call, callNoReply, connectSession
  , matchAny, matchInterface)

mprisPrefix :: T.Text
mprisPrefix = "org.mpris.MediaPlayer2."

data MediaEnv = MediaEnv
  { meClient :: Client
  , meFocusedAppId :: IO T.Text
    -- ^ app_id of the focused window ("" when unknown); only the
    -- Wayland backend plumbs this today
  , meLastPlaying :: TVar (Map T.Text UTCTime)
    -- ^ player bus name -> when it last reported PlaybackStatus=Playing
  }

-- | Connect and subscribe to PropertiesChanged. The player set itself
-- is not cached: every resolution lists current bus names, so players
-- that exit mid-playback simply disappear.
startMedia :: IO T.Text -> IO MediaEnv
startMedia focusedAppId = do
  client <- connectSession
  lastPlaying <- newTVarIO Map.empty
  let env = MediaEnv client focusedAppId lastPlaying
  _ <- addMatch client matchAny
    { matchInterface = Just "org.freedesktop.DBus.Properties" }
    (recordPlayback env)
  return env

recordPlayback :: MediaEnv -> Signal -> IO ()
recordPlayback env sig
  | formatMemberName (signalMember sig) /= "PropertiesChanged" = return ()
  | otherwise = case signalSender sig of
      Just sender
        | (T.unpack mprisPrefix) `isPrefixOf` formatBusName sender ->
            case signalBody sig of
              (_iface : changedV : _) ->
                case (fromVariant changedV :: Maybe (Map T.Text Variant)) of
                  Just changed | Just v <- Map.lookup "PlaybackStatus" changed ->
                    case fromVariant v of
                      Just ("Playing" :: T.Text) -> do
                        now <- getCurrentTime
                        atomically $ modifyTVar' (meLastPlaying env)
                          (Map.insert (T.pack (formatBusName sender)) now)
                      _ -> return ()
                  _ -> return ()
              _ -> return ()
      _ -> return ()

-- | org.homgb.Control method handler. Runs on the dbus dispatcher
-- thread, so the resolving calls happen on a forked thread — blocking
-- them here would stall every homgb dbus subscription.
mediaCommand :: MediaEnv -> T.Text -> IO ()
mediaCommand env member = void $ forkIO $ do
  target <- resolveTarget env
  forM_ target $ \name ->
    callNoReply (meClient env)
      (methodCall "/org/mpris/MediaPlayer2" "org.mpris.MediaPlayer2.Player"
        (memberName_ (T.unpack member)))
        { methodCallDestination = Just (busName_ (T.unpack name)) }

resolveTarget :: MediaEnv -> IO (Maybe T.Text)
resolveTarget env = do
  players <- playersOf (meClient env)
  case players of
    [] -> return Nothing
    _ -> do
      foc <- meFocusedAppId env
      case focusedMatch foc players of
        Just p -> return (Just p)
        Nothing -> do
          recent <- lastPlayingAmong env players
          case recent of
            Just p -> return (Just p)
            Nothing -> do
              playing <- filterM
                (\p -> (== Just "Playing") <$> playbackStatusOf (meClient env) p)
                players
              case playing of
                (p:_) -> return (Just p)
                [] -> case players of
                  [p] -> return (Just p)
                  _ -> return Nothing

-- | Focused-app rule: the player whose bus base name matches the
-- focused app_id — "chromium" against
-- org.mpris.MediaPlayer2.chromium.instance352362 (app_id is a prefix of
-- the base), "kodi" against org.mpris.MediaPlayer2.kodi (equal).
-- Prefix matching both ways covers ".instanceN" suffixes and
-- reverse-domain app_ids alike.
focusedMatch :: T.Text -> [T.Text] -> Maybe T.Text
focusedMatch foc players
  | T.null foc = Nothing
  | otherwise = listToMaybe
      [ p | p <- players
          , let base = baseName p
          , foc == base || foc `T.isPrefixOf` base || base `T.isPrefixOf` foc ]

baseName :: T.Text -> T.Text
baseName = fromMaybe "" . T.stripPrefix mprisPrefix

lastPlayingAmong :: MediaEnv -> [T.Text] -> IO (Maybe T.Text)
lastPlayingAmong env players = do
  seen <- readTVarIO (meLastPlaying env)
  let alive = Map.filterWithKey (\k _ -> k `elem` players) seen
  return $ case Map.toDescList alive of
    [] -> Nothing
    _ -> Just (fst (Map.foldlWithKey newest (Map.findMin alive) alive))
  where
    newest acc@(aName, aT) bName bT = if bT > aT then (bName, bT) else acc

-- | Current org.mpris.MediaPlayer2.* bus names.
playersOf :: Client -> IO [T.Text]
playersOf client = do
  res <- call client
    (methodCall "/org/freedesktop/DBus" "org.freedesktop.DBus" "ListNames")
      { methodCallDestination = Just (busName_ "org.freedesktop.DBus") }
  case res of
    Left err -> do
      hPutStrLn stderr ("homgb: media: ListNames failed: " ++ show err)
      return []
    Right r -> return
      [ n | v <- methodReturnBody r
          , Just names <- [(fromVariant v :: Maybe [T.Text])]
          , n <- names
          , mprisPrefix `T.isPrefixOf` n ]

-- | org.mpris.MediaPlayer2.Player.PlaybackStatus of one player.
playbackStatusOf :: Client -> T.Text -> IO (Maybe T.Text)
playbackStatusOf client name = do
  res <- call client
    (methodCall "/org/mpris/MediaPlayer2" "org.freedesktop.DBus.Properties" "Get")
      { methodCallDestination = Just (busName_ (T.unpack name))
      , methodCallBody =
          [ toVariant ("org.mpris.MediaPlayer2.Player" :: T.Text)
          , toVariant ("PlaybackStatus" :: T.Text) ] }
  case res of
    -- Get returns the value wrapped in a VARIANT: unwrap twice.
    Right r | (v:_) <- methodReturnBody r ->
      return (fromVariant v >>= fromVariant)
    _ -> return Nothing
