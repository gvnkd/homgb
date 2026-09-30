{-# LANGUAGE OverloadedStrings #-}

module Homgb.Render
  ( frameUpkeep
  , drawTraySurface
  , drawPopupSurface
  ) where

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
import Linear (V2(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)

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
import Homgb.SDL3 (Window)
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Surface
  (Surface(..), Surfaces(..), hideSurface, moveSurfaceWindow
  , resizeSurfaceWindow, showSurface, surfaceWindowSize)
import Homgb.Tray (trayTextures)
import Homgb.Tray.Render (renderTray)

-- | Per-frame state maintenance: popup expiry (checked in the frame
-- loop, no timeout threads), image texture uploads, cache pruning.
frameUpkeep :: AppState -> IO ()
frameUpkeep app = do
  let tState = appNotify app
  state <- readTVarIO tState
  let config = notiConfig state
      notis = notiStList state
  now <- getCurrentTime
  forM_ (filter (isExpired config now) notis) $ \noti ->
    closeNotiById tState (notiId noti) Timeout
  let liveIds = map notiId notis
  syncTextures app notis
  pruneCache app liveIds

-- | Draw the tray surface and shrink-wrap/position its SDL window at
-- the configured screen corner.
drawTraySurface :: AppState -> IO ()
drawTraySurface app = do
  let surf = surfacesTray (appSurfaces app)
  state <- readTVarIO (appNotify app)
  let config = notiConfig state
  V2 surfW surfH <- surfaceWindowSize surf
  winPos <- SDL3.windowPosition (sWindow surf)
  (w, h) <- renderTray (appTray app) (trayTextures (appTray app)) config
    (appKeyboard app) (ImVec2 (fromIntegral surfW) (fromIntegral surfH)) winPos
  let (sw, sh) = appScreenSize app
      (x, y) = case configTrayPosition config of
        "top-left" -> (10, 10)
        "bottom-left" -> (10, sh - 10 - floor h)
        "bottom-right" -> (sw - 10 - floor w, sh - 10 - floor h)
        _ -> (sw - 10 - floor w, 10)
  resizeSurfaceWindow surf (floor w + 2) (floor h + 2)
  moveSurfaceWindow surf x y
  debug <- lookupEnv "HOMGB_DEBUG"
  case debug of
    Just _ -> hPutStrLn stderr
      $ "tray surface=(" ++ show x ++ "," ++ show y ++ ") "
        ++ show (floor w :: Int) ++ "x" ++ show (floor h :: Int)
    Nothing -> return ()
  metrics <- lookupEnv "HOMGB_METRICS"
  case metrics of
    Just _ -> Raw.showMetricsWindow
    Nothing -> return ()

-- | Draw notification popups in their own surface window, placed at
-- the configured top corner of the screen. The surface hides when no
-- popups are live.
drawPopupSurface :: AppState -> IO ()
drawPopupSurface app = do
  let surf = surfacesPopups (appSurfaces app)
      tState = appNotify app
  state <- readTVarIO tState
  let config = notiConfig state
      notis = notiStList state
  if null notis
    then hideSurface surf
    else do
      showSurface surf
      heights <- readTVarIO (appHeights app)
      let width = configWidthNoti config
          startY = 2
      total <- go tState config width startY heights notis
      let (sw, _) = appScreenSize app
          x = sw - configDistanceRight config - width - 2
          y = configDistanceTop config
      resizeSurfaceWindow surf (width + 4) (floor total + 4)
      moveSurfaceWindow surf x y
      debug <- lookupEnv "HOMGB_DEBUG"
      case debug of
        Just _ -> hPutStrLn stderr
          $ "popup surface=(" ++ show x ++ "," ++ show y ++ ") h="
            ++ show (floor total :: Int)
        Nothing -> return ()
  where
    go _ _ _ py _ [] = return py
    go tState config width py heights (n:rest) = do
      h <- renderPopup app tState config py
             (Map.findWithDefault (fallbackHeight config) (notiId n) heights) n
      go tState config width (py + h + fromIntegral (configDistanceBetween config)) heights rest

-- | deadd's timeout semantics (NotificationPopup.startTimeoutThread):
--   0 = never expires, >0 = that many milliseconds, <0 = configured default.
isExpired :: Config -> UTCTime -> Notification -> Bool
isExpired config now noti =
  let timeout = notiTimeout noti
      ms = if timeout > 0 then fromIntegral timeout
           else fromIntegral (configNotiDefaultTimeout config)
      age = realToFrac (diffUTCTime now (notiCreatedAt noti)) * 1000 :: Double
  in timeout /= 0 && age > ms

-- | Draw one popup at local x=2 (the surface window hugs the popup
-- stack, so no window-width math is needed here).
renderPopup :: AppState -> TVar NotifyState -> Config -> Float -> Float
            -> Notification -> IO Float
renderPopup app tState config top heightGuess noti = do
  let width = fromIntegral (configWidthNoti config)
      popupX = 2
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
            ++ ") h=" ++ show h
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
 