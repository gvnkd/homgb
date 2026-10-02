{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray.Render (renderTray) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO)
import Control.Exception (try, SomeException)
import Control.Monad (when, forM_)
import Data.Bits ((.|.))
import Data.Int (Int32)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Coerce (coerce)
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr, castPtr)
import Foreign.Storable (poke)
import Graphics.GL (GLuint)

import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import DBus.Internal.Types (BusName(..))
import qualified StatusNotifier.Item.Client as I
import StatusNotifier.Host.Service (ItemInfo(..))

import DearImGui hiding (image, begin)
import qualified DearImGui.Raw as Raw
  (imageButton, begin, setNextWindowPos, pushStyleColor
  , pushStyleVar, popStyleVar, getMousePos)
import DearImGui.Raw.Font (Font(..))
import Homgb.Bar (BarState, renderBar, sameLineS, framePadX, framePadY)
import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Keyboard (KeyboardEnv(..), currentLayout, pollGroup, rotateLayout)
import Homgb.Theme (Theme(..))
import Homgb.Tray (TrayEnv(..), TrayItem(..), TrayState(..))
import Homgb.Tray.Icons (iconRgbaSrc)
import Homgb.Tray.Menu.Render (openItemMenu)

-- | Tray icon texture cache: bus name -> (version, texture).
type TrayTextures = TVar (Map.Map String (Int, Maybe GLuint))

-- | Draw the tray into the current (tray surface) ImGui context. The
-- tray window sits at the surface's local origin; returns the measured
-- content size so the caller can shrink-wrap the SDL window.
renderTray :: TrayEnv -> TrayTextures -> Config -> Theme
           -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
           -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO (Float, Float)
renderTray env textures config theme kbEnv mainFont mBar surfSize winPos screenSize = do
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
      iconSize = fromIntegral (thTrayIconSize theme)
      traySpacing = fromIntegral (thTraySpacing theme)
      btn = iconSize + 6
      pos = ImVec2 0 0
      pivot = ImVec2 0 0
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
  (kbW, barW) <- withImVec4 (ImVec4 0 0 0 0) $ \bgPtr ->
    withImVec2 (ImVec2 (thTrayPadX theme) (thTrayPadY theme)) $ \padPtr -> do
      Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
      Raw.pushStyleVar ImGuiStyleVar_WindowPadding padPtr
      beginVisible <- BS.useAsCString "homgb-tray"
        $ \label -> Raw.begin label Nothing (Just trayFlags)
      (kbWidth, barWidth) <- if beginVisible
        then do
          barW0 <- case mBar of
            Just barT -> renderBar' barT
            Nothing -> return 0
          when (barW0 > 0 && not (null items)) $
            sameLineS barItemGap
          forM_ (zip [0 :: Int ..] items) $ \(idx, item) -> do
            when (idx > 0) $ sameLineS traySpacing
            renderItem env textures theme iconSize btn traySpacing idx item surfSize
              winPos screenSize
          kbW0 <- renderIndicator kbEnv (configKbIndicator config) traySpacing
            mainFont btn (length items)
          return (kbW0, barW0)
        else return (0, 0)
      end
      Raw.popStyleVar 1
      popStyleColor 1
      return (kbWidth, barWidth)
  -- Analytic size: ImGui windows are clipped to the host viewport
  -- (the SDL window), so measuring the window size inside feeds back
  -- and collapses it. The layout is fully determined instead: an
  -- imageButton advances btn + 2*framePadding, items are separated by
  -- the explicit sameLine spacing, the indicator is a smallButton
  -- (text width + 2*framePadding). FramePadding (4,4) is the default
  -- style; pixel-probed via the 44px item pitch (28 btn + 8 padding +
  -- 8 old ItemSpacing).
  let n = length items
      gaps = fromIntegral (max 0 (n - 1)) * traySpacing
      gapKb = if n > 0 && kbW > 0 then traySpacing else 0
      gapBar = if n > 0 && barW > 0 then barItemGap else 0
      itemW = btn + 2 * framePadX
      trayW = 2 * thTrayPadX theme + barW + gapBar
        + fromIntegral n * itemW + gaps + gapKb + kbW
      h = btn + 2 * framePadY + 2 * thTrayPadY theme
  return (trayW, h)
  where
    barItemGap = 12
    renderBar' barT = case trayDisplay env of
      Just dpy -> renderBar dpy barT theme (fromIntegral (thTraySpacing theme))
      Nothing -> return 0

-- | Current-layout label at the tray edge (config @keyboard.indicator@).
-- Clicking rotates layouts, same as the hotkey. The label is drawn at
-- a size fitted so its button height matches the icon row (btn), i.e.
-- visually the same height as the tray icons. Returns the rendered
-- width (0 when nothing is drawn).
renderIndicator :: Maybe KeyboardEnv -> Bool -> Float -> Ptr () -> Float
                -> Int -> IO Float
renderIndicator kbEnv indicatorOn gap mainFont btn itemCount =
  case kbEnv of
    Just kb | indicatorOn -> do
      pollGroup kb
      s <- readTVarIO (kbState kb)
      let code = T.toUpper (T.take 2 (currentLayout s))
      if T.null code then return 0 else do
        when (itemCount > 0) $ sameLineS gap
        -- two-pass fit: measure at a trial size, rescale so the text
        -- height equals the icon row height minus the button's frame
        -- padding
        let target = btn - 2 * framePadY
            haveFont = mainFont /= nullPtr
        indSize <-
          if not haveFont
            then return target
            else do
              pushFontWithSize (Font (castPtr mainFont)) (CFloat target)
              ImVec2 _ th0 <- calcTextSize code True 0
              popFont
              return (if th0 > 0 then target * target / th0 else target)
        when haveFont $ pushFontWithSize (Font (castPtr mainFont)) (CFloat indSize)
        ImVec2 tw _ <- calcTextSize code True 0
        clicked <- smallButton (code <> "##kbdlayout")
        setItemTooltip (currentLayout s)
        when haveFont popFont
        when clicked $ rotateLayout kb
        return (tw + 2 * framePadX)
    _ -> return 0

renderItem :: TrayEnv -> TrayTextures -> Theme -> Float -> Float -> Float
           -> Int -> TrayItem -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO ()
renderItem env textures theme _iconSize btn _traySpacing _idx item surfSize
           winPos screenSize = do
  let ImVec2 _surfW surfH = surfSize
  let info = tiInfo item
      name = itemServiceName info
      path = itemServicePath info
      label = T.encodeUtf8 (T.pack (show (coerce name :: String)))

  mTex <- trayTexture textures (thTrayIconSize theme) item
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

  -- SNI Activate wants the click position; send the real pointer
  -- position in ROOT coordinates (winPos + surface-local mouse pos).
  -- The call itself runs on its own thread: some items (flameshot)
  -- never reply, and a synchronous Activate on the render thread
  -- freezes the whole UI for the ~25s DBus call timeout.
  when clicked $ do
    ImVec2 mx my <- Raw.getMousePos
    let (wx, wy) = winPos
        rootX = floor mx + fromIntegral wx :: Int32
        rootY = floor my + fromIntegral wy :: Int32
    _ <- forkIO $ do
      res <- try (I.activate (trayClient env) name path rootX rootY)
      case res of
        Left (e :: SomeException) ->
          hPutStrLn stderr $ "tray activate " ++ show (coerce name :: String)
            ++ ": " ++ show e
        Right _ -> return ()
    return ()

  -- Right-click toggles the item's dbusmenu window (when it has one).
  rightClicked <- isItemClicked ImGuiMouseButton_Right
  when rightClicked $ do
    debug <- lookupEnv "HOMGB_DEBUG"
    case debug of
      Just _ -> hPutStrLn stderr $ "tray right-click: " ++ show (coerce name :: String)
        ++ " menu=" ++ show (menuPath info)
      Nothing -> return ()
    openItemMenu (trayClient env) (trayMenus env) info winPos
      (floor surfH) screenSize

  setItemTooltip (T.pack (tooltipText info))

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

withImVec2 :: ImVec2 -> (Ptr ImVec2 -> IO a) -> IO a
withImVec2 v f = alloca $ \p -> poke p v >> f p

withImVec4 :: ImVec4 -> (Ptr ImVec4 -> IO a) -> IO a
withImVec4 v f = alloca $ \p -> poke p v >> f p

combineFlags :: ImGuiWindowFlags -> ImGuiWindowFlags -> ImGuiWindowFlags
combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
  ImGuiWindowFlags (a .|. b)
 