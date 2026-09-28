{-# LANGUAGE OverloadedStrings #-}

module Homgb.Tray.Render (renderTray) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically, modifyTVar')
import Control.Monad (when, forM_)
import Data.Bits ((.|.))
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Coerce (coerce)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (poke)
import Graphics.GL (GLuint)
import SDL hiding (Normal)

import DBus.Client (Client)
import DBus.Internal.Types (BusName(..))
import qualified StatusNotifier.Item.Client as I
import StatusNotifier.Host.Service (ItemInfo(..))

import DearImGui hiding (image, begin)
import qualified DearImGui.Raw as Raw
  (imageButton, sameLine, begin, setNextWindowPos)

import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Tray (TrayEnv(..), TrayItem(..), TrayState(..), trayTextures)
import Homgb.Tray.Icons (iconRgba)

-- | Tray icon texture cache: bus name -> (version, texture).
type TrayTextures = TVar (Map.Map String (Int, Maybe GLuint))

renderTray :: TrayEnv -> TrayTextures -> Config -> Float -> Float -> IO ()
renderTray env textures config winW winH = do
  state <- readTVarIO (trayState env)
  let items = [ ti | ti <- trayItems state
               , tiStatus ti /= Just "Passive" ]
      size = fromIntegral (configTrayIconSize config)
      spacing = fromIntegral (configTraySpacing config)
      btn = size + 6
      pos = trayPos (configTrayPosition config) winW winH
      pivot = trayPivot (configTrayPosition config)
      flags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoScrollbar
        , ImGuiWindowFlags_NoCollapse
        , ImGuiWindowFlags_AlwaysAutoResize
        , ImGuiWindowFlags_NoFocusOnAppearing
        ]

  withImVec2 pos $ \posPtr ->
    withImVec2 pivot $ \pivotPtr ->
      Raw.setNextWindowPos posPtr ImGuiCond_Always (Just pivotPtr)
  beginVisible <- BS.useAsCString "homgb-tray"
    $ \label -> Raw.begin label Nothing (Just flags)
  when beginVisible $
    forM_ (zip [0 :: Int ..] items) $ \(idx, item) -> do
      when (idx > 0) Raw.sameLine
      renderItem env textures config size btn spacing idx item
  end

renderItem :: TrayEnv -> TrayTextures -> Config -> Float -> Float -> Float
           -> Int -> TrayItem -> IO ()
renderItem env textures config size btn spacing idx item = do
  let info = tiInfo item
      name = itemServiceName info
      path = itemServicePath info
      label = T.encodeUtf8 (T.pack (show (coerce name :: String)))
      clickX = floor (btn / 2)
      clickY = floor (btn / 2)

  mTex <- trayTexture textures (configTrayIconSize config) item
  clicked <- case mTex of
    Just tex ->
      BS.useAsCString label $ \labelPtr ->
        alloca $ \refPtr ->
          alloca $ \sizePtr ->
            alloca $ \uv0Ptr ->
              alloca $ \uv1Ptr ->
                alloca $ \tintPtr ->
                  alloca $ \bgPtr -> do
                    poke refPtr (ImTextureRef nullPtr (fromIntegral tex))
                    poke sizePtr (ImVec2 btn btn)
                    poke uv0Ptr (ImVec2 0 0)
                    poke uv1Ptr (ImVec2 1 1)
                    poke tintPtr (ImVec4 1 1 1 1)
                    poke bgPtr (ImVec4 0 0 0 0)
                    Raw.imageButton labelPtr refPtr sizePtr uv0Ptr uv1Ptr
                                    tintPtr bgPtr
    Nothing ->
      smallButton (T.pack (take 1 (safeTitle (iconTitle info))))

  -- SNI Activate wants the click position in the item's window space;
  -- tray geometry is approximate (single overlay window), so we send the
  -- button center within the overlay.
  when clicked $
    void' $ I.activate (trayClient env) name path clickX clickY

  setItemTooltip (T.pack (tooltipText info))
  where
    _unused = (config, spacing, idx)
    void' action = do
      _ <- action
      return ()

tooltipText :: ItemInfo -> String
tooltipText info =
  case itemToolTip info of
    Just (_, _, tipTitle, tipBody)
      | not (null tipTitle) -> if null tipBody then tipTitle
                               else tipTitle ++ "\n" ++ tipBody
    _ -> iconTitle info

safeTitle :: String -> String
safeTitle [] = "?"
safeTitle s = s

tiStatus :: TrayItem -> Maybe String
tiStatus = itemStatus . tiInfo

-- | Upload (or fetch cached) tray icon texture for an item.
trayTexture :: TrayTextures -> Int -> TrayItem -> IO (Maybe GLuint)
trayTexture textures size item = do
  cache <- readTVarIO textures
  let key = show (coerce (itemServiceName (tiInfo item)) :: String)
  case Map.lookup key cache of
    Just (v, tex) | v == tiVersion item -> return tex
    _ -> do
      mRgba <- iconRgba size (tiInfo item)
      mTex <- traverse uploadRgba mRgba
      -- drop the stale texture after the new one is up
      case Map.lookup key cache of
        Just (_, Just old) | Just old /= mTex -> deleteTextures [old]
        _ -> return ()
      atomically $ modifyTVar' textures $ Map.insert key (tiVersion item, mTex)
      return mTex

trayPos :: String -> Float -> Float -> ImVec2
trayPos pos winW winH = case pos of
  "top-left"     -> ImVec2 10 10
  "bottom-left"  -> ImVec2 10 (winH - 10)
  "bottom-right" -> ImVec2 (winW - 10) (winH - 10)
  _              -> ImVec2 (winW - 10) 10

trayPivot :: String -> ImVec2
trayPivot pos = case pos of
  "top-left"     -> ImVec2 0 0
  "bottom-left"  -> ImVec2 0 1
  "bottom-right" -> ImVec2 1 1
  _              -> ImVec2 1 0

withImVec2 :: ImVec2 -> (Ptr ImVec2 -> IO a) -> IO a
withImVec2 v f = alloca $ \p -> poke p v >> f p

combineFlags :: ImGuiWindowFlags -> ImGuiWindowFlags -> ImGuiWindowFlags
combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
  ImGuiWindowFlags (a .|. b)
