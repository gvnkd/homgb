{-# LANGUAGE OverloadedStrings #-}

module Homgb.Tray.Render (renderTray) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically)
import Control.Monad (when, unless, forM_)
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

import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import DBus.Internal.Types (BusName(..))
import qualified StatusNotifier.Item.Client as I
import StatusNotifier.Host.Service (ItemInfo(..))

import DearImGui hiding (image, begin)
import qualified DearImGui.Raw as Raw
  (imageButton, sameLine, begin, setNextWindowPos, pushStyleColor)

import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Keyboard (KeyboardEnv(..), currentLayout, pollGroup, rotateLayout)
import Homgb.Tray (TrayEnv(..), TrayItem(..), TrayState(..))
import Homgb.Tray.Icons (iconRgbaSrc)
import Homgb.Tray.Menu.Render (openItemMenu, renderMenus)

-- | Tray icon texture cache: bus name -> (version, texture).
type TrayTextures = TVar (Map.Map String (Int, Maybe GLuint))

renderTray :: TrayEnv -> TrayTextures -> Config -> Maybe KeyboardEnv
           -> Float -> Float -> IO ()
renderTray env textures config kbEnv winW winH = do
  state <- readTVarIO (trayState env)
  dbg0 <- lookupEnv "HOMGB_DEBUG"
  case dbg0 of
    Just _ -> hPutStrLn stderr $ "tray items: "
      ++ show [ (t, coerce (itemServiceName (tiInfo i)) :: String)
              | i <- trayItems state
              , let t = iconTitle (tiInfo i) ]
    Nothing -> return ()
  let items = [ ti | ti <- trayItems state
               , tiStatus ti /= Just "Passive" ]
      iconSize = fromIntegral (configTrayIconSize config)
      traySpacing = fromIntegral (configTraySpacing config)
      btn = iconSize + 6
      pos = trayPos (configTrayPosition config) winW winH
      pivot = trayPivot (configTrayPosition config)
      trayFlags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoScrollbar
        , ImGuiWindowFlags_NoCollapse
        , ImGuiWindowFlags_AlwaysAutoResize
        , ImGuiWindowFlags_NoFocusOnAppearing
        , ImGuiWindowFlags_NoBringToFrontOnFocus
        ]

  withImVec2 pos $ \posPtr ->
    withImVec2 pivot $ \pivotPtr ->
      Raw.setNextWindowPos posPtr ImGuiCond_Always (Just pivotPtr)
  -- transparent window bg: only the icons/label should be visible
  withImVec4 (ImVec4 0 0 0 0) $ \bgPtr ->
    Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
  beginVisible <- BS.useAsCString "homgb-tray"
    $ \label -> Raw.begin label Nothing (Just trayFlags)
  when beginVisible $ do
    forM_ (zip [0 :: Int ..] items) $ \(idx, item) -> do
      when (idx > 0) Raw.sameLine
      renderItem env textures config iconSize btn traySpacing idx item winW winH
    renderIndicator kbEnv config (length items)
  end
  popStyleColor 1
  -- menus submit after the tray window so they draw on top of it
  renderMenus (trayClient env) (trayMenus env) (trayPrevButtons env)
    (trayDisplay env)

-- | Current-layout label at the tray edge (config @keyboard.indicator@).
-- Clicking rotates layouts, same as the hotkey.
renderIndicator :: Maybe KeyboardEnv -> Config -> Int -> IO ()
renderIndicator kbEnv config itemCount =
  forM_ kbEnv $ \kb -> when (configKbIndicator config) $ do
    pollGroup kb
    s <- readTVarIO (kbState kb)
    let code = T.toUpper (T.take 2 (currentLayout s))
    unless (T.null code) $ do
      when (itemCount > 0) Raw.sameLine
      clicked <- smallButton (code <> "##kbdlayout")
      setItemTooltip (currentLayout s)
      when clicked $ rotateLayout kb

renderItem :: TrayEnv -> TrayTextures -> Config -> Float -> Float -> Float
           -> Int -> TrayItem -> Float -> Float -> IO ()
renderItem env textures config _iconSize btn _traySpacing _idx item winW winH = do
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
                alloca $ \bgPtr ->
                  alloca $ \tintPtr -> do
                    poke refPtr (ImTextureRef nullPtr (fromIntegral tex))
                    poke sizePtr (ImVec2 btn btn)
                    poke uv0Ptr (ImVec2 0 0)
                    poke uv1Ptr (ImVec2 1 1)
                    -- ImageButton order is (str_id, tex_ref, size, uv0,
                    -- uv1, bg_col, tint_col) — do NOT swap these:
                    -- tint alpha 0 + white bg renders the icon as a
                    -- solid white square.
                    poke bgPtr (ImVec4 0 0 0 0)
                    poke tintPtr (ImVec4 1 1 1 1)
                    Raw.imageButton labelPtr refPtr sizePtr uv0Ptr uv1Ptr
                                    bgPtr tintPtr
    Nothing ->
      smallButton (T.pack (take 1 (safeTitle (iconTitle info))))

  -- SNI Activate wants the click position in the item's window space;
  -- tray geometry is approximate (single overlay window), so we send the
  -- button center within the overlay.
  when clicked $
    void' $ I.activate (trayClient env) name path clickX clickY

  -- Right-click toggles the item's dbusmenu window (when it has one).
  rightClicked <- isItemClicked ImGuiMouseButton_Right
  when rightClicked $ do
    debug <- lookupEnv "HOMGB_DEBUG"
    case debug of
      Just _ -> hPutStrLn stderr $ "tray right-click: " ++ show (coerce name :: String)
        ++ " menu=" ++ show (menuPath info)
      Nothing -> return ()
    openItemMenu (trayClient env) (trayMenus env) info (ImVec2 winW winH)

  setItemTooltip (T.pack (tooltipText info))
  where
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
trayTexture textures iconSz item = do
  cache <- readTVarIO textures
  let key = show (coerce (itemServiceName (tiInfo item)) :: String)
  case Map.lookup key cache of
    Just (v, tex) | v == tiVersion item -> return tex
    _ -> do
      mRgba <- iconRgbaSrc iconSz (tiInfo item)
      mTex <- traverse uploadRgba (fmap snd mRgba)
      -- drop the stale texture after the new one is up
      case Map.lookup key cache of
        Just (_, Just old) | Just old /= mTex -> deleteTextures [old]
        _ -> return ()
      atomically $ modifyTVar' textures $ Map.insert key (tiVersion item, mTex)
      debug <- lookupEnv "HOMGB_DEBUG"
      case debug of
        Just _ -> do
          let info = tiInfo item
              pixDims = [ (w, h) | (w, h, _) <- iconPixmaps info ]
          hPutStrLn stderr $ "tray icon " ++ key
            ++ " name=" ++ show (iconName info)
            ++ " themePath=" ++ show (iconThemePath info)
            ++ " pixmaps=" ++ show pixDims
            ++ " -> " ++ maybe "FAIL" (\(src, SizedRgba w h _) ->
                 src ++ " " ++ show w ++ "x" ++ show h) mRgba
        Nothing -> return ()
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

withImVec4 :: ImVec4 -> (Ptr ImVec4 -> IO a) -> IO a
withImVec4 v f = alloca $ \p -> poke p v >> f p

combineFlags :: ImGuiWindowFlags -> ImGuiWindowFlags -> ImGuiWindowFlags
combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
  ImGuiWindowFlags (a .|. b)
 