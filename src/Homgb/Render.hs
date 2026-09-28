{-# LANGUAGE OverloadedStrings #-}

module Homgb.Render (renderFrame) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically)
import Control.Monad (when, unless, forM_)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.List ((\\))
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)
import SDL hiding (Normal)

import System.IO (hPutStrLn, hFlush, stderr)
import System.Environment (lookupEnv)

import DearImGui hiding (image, begin)
import qualified DearImGui.Raw as Raw
  (sameLine, spacing, begin, pushStyleColor, setNextWindowPos
  , setNextWindowSize, showMetricsWindow)

import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Notifications.Daemon (NotifyState(..), closeNotiById)
import Homgb.Notifications.Data
import Homgb.State
import Homgb.Tray (trayTextures)
import Homgb.Tray.Render (renderTray)

renderFrame :: AppState -> Window -> IO ()
renderFrame app window = do
  V2 winW winH <- get (windowSize window)
  let tState = appNotify app
  state <- readTVarIO tState
  let config = notiConfig state
      notis = notiStList state

  now <- getCurrentTime
  -- Expiry is checked in the frame loop (design decision 2): no timeout
  -- threads, no races.
  forM_ (filter (isExpired config now) notis) $ \noti ->
    closeNotiById tState (notiId noti) Timeout

  let liveIds = map notiId notis
  syncTextures app notis
  pruneCache app liveIds

  heights <- readTVarIO (appHeights app)
  let startY = fromIntegral (configDistanceTop config)
  renderPopups app tState config (fromIntegral winW) startY heights notis
  renderTray (appTray app) (trayTextures (appTray app)) config
    (fromIntegral winW) (fromIntegral winH)
  debug <- lookupEnv "HOMGB_DEBUG"
  case debug of
    Just _ -> hPutStrLn stderr
      $ "win size=(" ++ show winW ++ "," ++ show winH ++ ")"
    Nothing -> return ()
  metrics <- lookupEnv "HOMGB_METRICS"
  case metrics of
    Just _ -> Raw.showMetricsWindow
    Nothing -> return ()

-- | deadd's timeout semantics (NotificationPopup.startTimeoutThread):
--   0 = never expires, >0 = that many milliseconds, <0 = configured default.
isExpired :: Config -> UTCTime -> Notification -> Bool
isExpired config now noti =
  let timeout = notiTimeout noti
      ms = if timeout > 0 then fromIntegral timeout
           else fromIntegral (configNotiDefaultTimeout config)
      age = realToFrac (diffUTCTime now (notiCreatedAt noti)) * 1000 :: Double
  in timeout /= 0 && age > ms

renderPopups :: AppState -> TVar NotifyState -> Config -> Float -> Float
             -> Map.Map Int Float -> [Notification] -> IO ()
renderPopups app tState config winW startY heights notis = go startY notis
  where
    -- newest first, stacked from the top down
    go _ [] = return ()
    go py (n:rest) = do
      h <- renderPopup app tState config winW py
                       (Map.findWithDefault (fallbackHeight config) (notiId n) heights) n
      go (py + h + fromIntegral (configDistanceBetween config)) rest

renderPopup :: AppState -> TVar NotifyState -> Config -> Float -> Float -> Float
            -> Notification -> IO Float
renderPopup app tState config winW top heightGuess noti = do
  let width = fromIntegral (configWidthNoti config)
      right = fromIntegral $ maybe (configDistanceRight config) id (notiRight noti)
      popupX = winW - right - width
      popupFlags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoScrollbar
        , ImGuiWindowFlags_NoCollapse
        , ImGuiWindowFlags_AlwaysAutoResize
        , ImGuiWindowFlags_NoFocusOnAppearing
        ]

  withImVec4 (urgencyBorder (notiUrgency noti)) $ \borderPtr ->
    withImVec4 (urgencyBg (notiUrgency noti)) $ \bgPtr -> do
      Raw.pushStyleColor ImGuiCol_Border borderPtr
      Raw.pushStyleColor ImGuiCol_WindowBg bgPtr

      withImVec2 (ImVec2 popupX top) $ \posPtr ->
        withImVec2 (ImVec2 0 0) $ \pivotPtr ->
          Raw.setNextWindowPos posPtr ImGuiCond_Always (Just pivotPtr)
      withImVec2 (ImVec2 width 0) $ \sizePtr ->
        Raw.setNextWindowSize sizePtr ImGuiCond_Always
      beginVisible <- BS.useAsCString (T.encodeUtf8 (windowLabel (notiId noti)))
        $ \label -> Raw.begin label Nothing (Just popupFlags)

      when beginVisible $ do
        withImVec4 (urgencyTitle (notiUrgency noti)) $ \titlePtr -> do
          Raw.pushStyleColor ImGuiCol_Text titlePtr
          text (notiSummary noti)
          popStyleColor 1
        Raw.sameLine
        closeClicked <- smallButton "x##close"
        when closeClicked $
          closeNotiById tState (notiId noti) User

        forM_ (notiPercentage noti) $ \p ->
          progressBar (realToFrac p / 100) Nothing

        -- Body is plain text in M1 (no body-markup capability). A
        -- rich-text renderer would slot in here (design decision 5).
        unless (T.null (notiBody noti) && configPopupHideBodyIfEmpty config) $ do
          Raw.spacing
          textWrapped (notiBody noti)

        mTex <- case notiImg noti of
          RawImg argb | isRgba8 argb -> do
            cache <- readTVarIO (appTextures app)
            case Map.lookup (notiId noti) cache of
              Just tex -> return (Just tex)
              Nothing -> do
                tex <- uploadRgba (rawImgRgba argb)
                atomically $ modifyTVar' (appTextures app)
                  $ Map.insert (notiId noti) tex
                return (Just tex)
          _ -> return Nothing
        forM_ mTex $ \tex -> do
          Raw.spacing
          let imgPx = fromIntegral (notiImgSize noti)
          drawImage tex imgPx imgPx

        renderActions tState noti

      ImVec2 _ h <- getWindowSize
      end
      popStyleColor 2

      -- Remember measured height for next frame's stacking; fall back to
      -- an estimate until the first frame for this popup has been drawn.
      let h' = max h heightGuess
      atomically $ modifyTVar' (appHeights app) $ Map.insert (notiId noti) h'
      debug <- lookupEnv "HOMGB_DEBUG"
      case debug of
        Just _ -> hPutStrLn stderr
          $ "popup " ++ show (notiId noti) ++ " pos=(" ++ show popupX ++ "," ++ show top
            ++ ") h=" ++ show h ++ " winW=" ++ show winW
        Nothing -> return ()
      hFlush stderr
      return h'

renderActions :: TVar NotifyState -> Notification -> IO ()
renderActions tState noti =
  forM_ (zip [0 :: Int ..] (actionPairs (notiActions noti))) $ \(i, (key, label)) -> do
    when (i > (0 :: Int)) Raw.sameLine
    clicked <- smallButton label
    when clicked $ do
      notiOnAction noti (notiActionCommands noti) (T.unpack key) Nothing
      closeNotiById tState (notiId noti) User

actionPairs :: [T.Text] -> [(T.Text, T.Text)]
actionPairs (k:v:rest) = (k, v) : actionPairs rest
actionPairs _ = []

-- | Upload ARGB (DBus network order) images to GL textures, cached by
-- notification id. ImagePath/NamedIcon need freedesktop icon lookup —
-- deferred to M2 (tray will share it).
syncTextures :: AppState -> [Notification] -> IO ()
syncTextures app notis =
  forM_ notis $ \noti ->
    case notiImg noti of
      RawImg argb | isRgba8 argb -> do
        cache <- readTVarIO (appTextures app)
        case Map.lookup (notiId noti) cache of
          Just _ -> return ()
          Nothing -> do
            tex <- uploadRgba (rawImgRgba argb)
            atomically $ modifyTVar' (appTextures app)
              $ Map.insert (notiId noti) tex
      _ -> return ()

-- | Delete textures and measured heights for notifications that are gone.
pruneCache :: AppState -> [Int] -> IO ()
pruneCache app liveIds = do
  cache <- readTVarIO (appTextures app)
  let deadIds = Map.keys cache \\ liveIds
      dead = map (cache Map.!) deadIds
  unless (null dead) $ do
    deleteTextures dead
    atomically $ modifyTVar' (appTextures app)
      $ \m -> foldl' (flip Map.delete) m deadIds
  atomically $ modifyTVar' (appHeights app)
    $ \m -> Map.filterWithKey (\k _ -> k `elem` liveIds) m

isRgba8 :: (Int32, Int32, Int32, Bool, Int32, Int32, BS.ByteString) -> Bool
isRgba8 (imgW, imgH, rowstride, _, bits, channels, dat) =
  imgW > 0 && imgH > 0 && bits == 8 && channels == 4
    && fromIntegral rowstride >= imgW * 4
    && BS.length dat >= fromIntegral (rowstride * (imgH - 1) + imgW * 4)

-- | Convert a DBus raw image hint (ARGB32, network byte order) to RGBA.
rawImgRgba :: (Int32, Int32, Int32, Bool, Int32, Int32, BS.ByteString) -> SizedRgba
rawImgRgba (imgW, imgH, _, _, _, _, dat) =
  SizedRgba (fromIntegral imgW) (fromIntegral imgH) (argbToRgba dat)

urgencyBg :: Urgency -> ImVec4
urgencyBg Normal = ImVec4 0.13 0.14 0.15 1.0
urgencyBg Low    = ImVec4 0.10 0.10 0.11 1.0
urgencyBg High   = ImVec4 0.16 0.11 0.11 1.0

urgencyBorder :: Urgency -> ImVec4
urgencyBorder Normal = ImVec4 0.25 0.26 0.28 1.0
urgencyBorder Low    = ImVec4 0.20 0.20 0.22 1.0
urgencyBorder High   = ImVec4 0.80 0.20 0.20 1.0

urgencyTitle :: Urgency -> ImVec4
urgencyTitle Normal = ImVec4 0.90 0.90 0.90 1.0
urgencyTitle Low    = ImVec4 0.75 0.75 0.75 1.0
urgencyTitle High   = ImVec4 0.95 0.40 0.40 1.0

windowLabel :: Int -> T.Text
windowLabel id' = "noti-" <> T.pack (show id')

combineFlags :: ImGuiWindowFlags -> ImGuiWindowFlags -> ImGuiWindowFlags
combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
  ImGuiWindowFlags (a .|. b)

withImVec2 :: ImVec2 -> (Ptr ImVec2 -> IO a) -> IO a
withImVec2 v f = alloca $ \p -> poke p v >> f p

withImVec4 :: ImVec4 -> (Ptr ImVec4 -> IO a) -> IO a
withImVec4 v f = alloca $ \p -> poke p v >> f p

fallbackHeight :: Config -> Float
fallbackHeight config =
  fromIntegral (configImgSize config)
    + fromIntegral (configImgMarginTop config + configImgMarginBottom config)
 