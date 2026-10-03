{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray.Render (renderTray) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO)
import Control.Exception (try, SomeException)
import Control.Monad (when, forM_, void)
import Data.Bits ((.|.))
import Data.Int (Int32)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Coerce (coerce)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Foreign.C.Types (CFloat(..), CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr, castPtr)
import Foreign.Storable (poke)
import Graphics.GL (GLuint)

import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import DBus.Internal.Types (BusName(..))
import qualified StatusNotifier.Item.Client as I
import StatusNotifier.Host.Service (ItemInfo(..))

import DearImGui hiding (image, begin, w)
import qualified DearImGui.Raw as Raw
  (imageButton, begin, setNextWindowPos, setNextWindowSize, pushStyleColor
  , pushStyleVar, popStyleVar, getMousePos, dummy)
import DearImGui.Raw.Font (Font(..))
import Homgb.Bar
  ( BarState, barActiveTitle, fitTitleWidth, capTitleChars, renderClockWidget
  , renderDateWidget, renderWinButtons, renderWorkspaces
  , measureWorkspaces, measureWinButtons
  , sameLineS, framePadX, framePadY )
import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Keyboard (KeyboardEnv(..), currentLayout, rotateLayout)
import Homgb.Theme (Theme(..))
import Homgb.Tray (TrayEnv(..), TrayItem(..), TrayState(..), TooltipInfo(..))
import Homgb.Tray.Embed (XEmbedIcon, pumpEmbedEvents, layoutEmbedIcons)
import Homgb.Tray.Icons (iconRgbaSrc)
import Homgb.Tray.Menu.Render (openItemMenu)

-- | Tray icon texture cache: bus name -> (version, texture).
type TrayTextures = TVar (Map.Map String (Int, Maybe GLuint))

-- | An item renders unless it is Passive and the user opted to hide
-- passive items (tray.show-passive; default shows them — many apps,
-- Telegram and Electron clients among them, misuse Passive and
-- Plasma shows them too).
keepItem :: Config -> TrayItem -> Bool
keepItem config item =
  configTrayShowPassive config || tiStatus item /= Just "Passive"

-- | HOMGB_DEBUG: list registered items and which are hidden, so
-- "where did my app go" is answerable from the log.
dbgPassive :: TrayState -> [TrayItem] -> IO ()
dbgPassive state visible = do
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr $ "tray items: "
      ++ show [ (t, coerce (itemServiceName (tiInfo i)) :: String, tiStatus i)
              | i <- trayItems state
              , let t = iconTitle (tiInfo i) ]
      ++ " shown=" ++ show (length visible)
    Nothing -> return ()

-- | Drain XEmbed dock/undock events and move docked icon slots to
-- their row positions. No-op unless tray.xembed is on and the
-- selection was acquired.
pumpEmbeds :: TrayEnv -> Config -> Theme -> (Int -> (Int, Int, Int)) -> IO ()
pumpEmbeds env config theme slotPos =
  when (configTrayXEmbed config) $ do
    mHost <- readTVarIO (trayXEmbedHost env)
    forM_ mHost $ \host ->
      pumpEmbedEvents host (trayXEmbed env) slotPos (barBgRgb theme)

-- | Bar background as 0-255 RGB for the XEmbed slot background
-- (slots are 24-bit X windows — no alpha — so unpainted regions get
-- the bar's color instead of black).
barBgRgb :: Theme -> (Int, Int, Int)
barBgRgb theme =
  let ImVec4 r g b _ = thBarBg theme
  in (round (r * 255), round (g * 255), round (b * 255))

placeEmbeds :: TrayEnv -> Config -> (Int -> (Int, Int, Int)) -> IO ()
placeEmbeds env config slotPos =
  when (configTrayXEmbed config) $ do
    mHost <- readTVarIO (trayXEmbedHost env)
    forM_ mHost $ \host -> layoutEmbedIcons host (trayXEmbed env) slotPos

-- | Hover tooltip handoff: while the LAST item/widget is hovered,
-- refresh the pending-tooltip state (the tooltip SURFACE picks it up
-- after the hover delay; staleness via tiLastSeen).
offerTooltip :: TrayEnv -> String -> [T.Text] -> (Int, Int) -> IO ()
offerTooltip env key tipLines (wx, wy) = do
  hovered <- isItemHovered
  now <- getPOSIXTime
  when hovered $ do
    hk <- readTVarIO (trayHoverKey env)
    since <- case hk of
      Just (k, s) | k == key -> return s
      _ -> do
        atomically $ writeTVar (trayHoverKey env) (Just (key, now))
        -- wake the render loop at the hover-delay deadline: nothing
        -- else would re-render while the pointer sits still
        trayWake env
        return now
    when (not (null tipLines)) $ do
      ImVec2 mx my <- Raw.getMousePos
      dbg <- lookupEnv "HOMGB_DEBUG"
      case dbg of
        Just _ -> hPutStrLn stderr $ "tooltip " ++ key ++ ": "
          ++ show tipLines
        Nothing -> return ()
      atomically $ writeTVar (trayTooltip env) (Just TooltipInfo
        { tiLines = tipLines
        , tiRootX = floor mx + wx
        , tiRootY = floor my + wy
        , tiSince = since
        , tiLastSeen = now
        , tiHoverAt = since
        })

-- | Draw the tray into the current (tray surface) ImGui context. The
-- tray window sits at the surface's local origin; returns the measured
-- content size so the caller can shrink-wrap the SDL window. In bar
-- layout mode the surface spans the full monitor width instead.
renderTray :: TrayEnv -> TrayTextures -> Config -> Theme
           -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
           -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO (Float, Float)
renderTray env textures config theme kbEnv mainFont mBar surfSize winPos screenSize
  | configBarLayout config =
      renderTrayBar env textures config theme kbEnv mainFont mBar surfSize
        winPos screenSize
  | otherwise =
      renderTrayLegacy env textures config theme kbEnv mainFont mBar surfSize
        winPos screenSize

-- | Legacy shrink-wrapped corner tray.
renderTrayLegacy :: TrayEnv -> TrayTextures -> Config -> Theme
                 -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
                 -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO (Float, Float)
renderTrayLegacy env textures config theme kbEnv mainFont mBar surfSize
                 winPos screenSize = do
  state <- readTVarIO (trayState env)
  dbg0 <- lookupEnv "HOMGB_DEBUG"
  case dbg0 of
    Just _ -> hPutStrLn stderr $ "tray items: "
      ++ show [ (t, coerce (itemServiceName (tiInfo i)) :: String)
              | i <- trayItems state
              , let t = iconTitle (tiInfo i) ]
    Nothing -> return ()
  let items = filter (keepItem config) (trayItems state)
  dbgPassive state items
  embeds <- if configTrayXEmbed config
    then readTVarIO (trayXEmbed env)
    else return []
  let iconSize = fromIntegral (thTrayIconSize theme)
      traySpacing = fromIntegral (thTraySpacing theme)
      btn = iconSize + 6
      nAll = length items + length embeds
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
      c_push_style_var_float (coerce ImGuiStyleVar_WindowBorderSize)
        (realToFrac (thBarBorderSize theme))
      beginVisible <- BS.useAsCString "homgb-tray"
        $ \label -> Raw.begin label Nothing (Just trayFlags)
      (kbWidth, barWidth) <- if beginVisible
        then do
          barW0 <- case mBar of
            Just barT -> do
              wsW <- withDpy $ \dpy ->
                renderWorkspaces dpy barT config theme traySpacing
              winW <- withDpy $ \dpy ->
                renderWinButtons dpy barT config theme traySpacing (wsW > 0)
              return (wsW + winW)
            Nothing -> return 0
          when (barW0 > 0 && not (null items)) $
            sameLineS barItemGap
          forM_ (zip [0 :: Int ..] items) $ \(idx, item) -> do
            when (idx > 0) $ sameLineS traySpacing
            renderItem env textures theme iconSize btn traySpacing idx item surfSize
              winPos screenSize
          -- reserve layout space for docked XEmbed icons; the
          -- foreign windows themselves draw on top
          let itemW' = btn + 2 * framePadX
          forM_ (zip [0 :: Int ..] embeds) $ \(idx, _) -> do
            if idx == (0 :: Int) && null items && barW0 > 0
              then sameLineS barItemGap
              else sameLineS traySpacing
            withImVec2 (ImVec2 itemW' btn) $ \szPtr -> Raw.dummy szPtr
          kbW0 <- renderIndicator env kbEnv (configKbIndicator config)
            traySpacing mainFont btn (nAll > 0) winPos
          return (kbW0, barW0)
        else return (0, 0)
      end
      Raw.popStyleVar 2
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
  let n = length items + length embeds
      gaps = fromIntegral (max 0 (n - 1)) * traySpacing
      gapKb = if n > 0 && kbW > 0 then traySpacing else 0
      gapBar = if n > 0 && barW > 0 then barItemGap else 0
      itemW = btn + 2 * framePadX
      trayW = 2 * thTrayPadX theme + barW + gapBar
        + fromIntegral n * itemW + gaps + gapKb + kbW
      h = btn + 2 * framePadY + 2 * thTrayPadY theme
  -- XEmbed icon slots: the foreign windows are children of the tray
  -- surface; position them where the dummy reservations landed
  let slotPos :: Int -> (Int, Int, Int)
      slotPos i =
        ( floor (thTrayPadX theme)
            + (if barW > 0 then floor barW + floor barItemGap else 0)
            + (length items + i) * (floor itemW + floor traySpacing)
            + floor framePadX
        , floor (thTrayPadY theme) + floor framePadY
        , floor btn )
  pumpEmbeds env config theme slotPos
  placeEmbeds env config slotPos
  return (trayW, h)
  where
    barItemGap = 12
    withDpy f = case trayDisplay env of
      Just dpy -> f dpy
      Nothing -> return 0

-- | Full-width bar layout (the xmobar replacement), left to right:
-- workspaces, active window title (capped at bar.window-title-max
-- px), taskbar window buttons (bar.windows), an h-spacer, then the
-- right group: tray icons, keyboard indicator, date "dd.mm", clock
-- "HH:MM" (rightmost). Returns (monitor width, height) — the caller sizes the
-- surface to the full monitor width.
renderTrayBar :: TrayEnv -> TrayTextures -> Config -> Theme
              -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
              -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO (Float, Float)
renderTrayBar env textures config theme kbEnv mainFont mBar surfSize
              winPos screenSize@(monW, _) = do
  state <- readTVarIO (trayState env)
  embeds <- if configTrayXEmbed config
    then readTVarIO (trayXEmbed env)
    else return []
  let items = filter (keepItem config) (trayItems state)
  dbgPassive state items
  let iconSize = fromIntegral (thTrayIconSize theme)
      traySpacing = fromIntegral (thTraySpacing theme)
      btn = iconSize + 6
      contentH = btn + 2 * framePadY + 2 * thTrayPadY theme
      -- no AlwaysAutoResize here: the window must span the whole
      -- surface or the spacer-pushed right widgets clip at the
      -- viewport edge (auto-resize only measures direct content)
      trayFlags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoScrollbar
        , ImGuiWindowFlags_NoCollapse
        , ImGuiWindowFlags_NoBringToFrontOnFocus
        ]
  -- pre-measure every section so the spacer can be computed exactly.
  -- Measure-only (no drawing): this runs before Begin. The title is
  -- flexible: it takes its natural (char-capped) width, shrunk into
  -- whatever space remains after the fixed sections — a long title
  -- eats the spacer region before truncating.
  sects <- measureSections items (length embeds) btn traySpacing
  let leftW = sectionSum (slLeft sects)
      rightW = sectionSum (slRight sects)
      spacerW = max 0 (fromIntegral monW - 2 * thTrayPadX theme
                       - leftW - rightW - slGaps sects)
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr $ "bar sections: left="
      ++ show (map snd (slLeft sects)) ++ " right="
      ++ show (map snd (slRight sects)) ++ " spacer=" ++ show spacerW
    Nothing -> return ()
  let ImVec2 _surfW surfH = surfSize
  _ <- withImVec4 (thBarBg theme) $ \bgPtr ->
    withImVec4 (thBarBorder theme) $ \borderPtr ->
      withImVec2 (ImVec2 (thTrayPadX theme) (thTrayPadY theme)) $ \padPtr -> do
        Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
        Raw.pushStyleColor ImGuiCol_Border borderPtr
        Raw.pushStyleVar ImGuiStyleVar_WindowPadding padPtr
        c_push_style_var_float (coerce ImGuiStyleVar_WindowBorderSize)
          (realToFrac (thBarBorderSize theme))
        withImVec2 (ImVec2 0 0) $ \posPtr ->
          Raw.setNextWindowPos posPtr ImGuiCond_Always Nothing
        -- span the whole surface height (surfH = content + the hug
        -- fudge): a content-height window leaves a transparent strip
        -- between the bar paint and the strut edge, which reads as a
        -- gap above the tiled windows
        withImVec2 (ImVec2 (fromIntegral monW) surfH) $ \sizePtr ->
          Raw.setNextWindowSize sizePtr ImGuiCond_Always
        beginVisible <- BS.useAsCString "homgb-tray"
          $ \label -> Raw.begin label Nothing (Just trayFlags)
        when beginVisible $
          renderRow env textures config theme kbEnv mainFont mBar items
            embeds iconSize btn traySpacing sects spacerW surfSize winPos screenSize
        end
        Raw.popStyleVar 2
        popStyleColor 2
  -- move XEmbed icon slots to their right-group positions. The
  -- sections render with `gap` between them, so the group's left edge
  -- is monW - pad - (widths + gaps); forgetting the gaps shifted the
  -- embeds right, leaving a hole after the SNI icons and colliding
  -- the last one with the keyboard indicator.
  let rightX0 = fromIntegral monW - thTrayPadX theme
        - sectionSum (slRight sects) - slRightGaps sects
      itemW = btn + 2 * framePadX
      slotPos :: Int -> (Int, Int, Int)
      slotPos i =
        ( floor rightX0 + (length items + i) * (floor itemW + floor traySpacing)
            + floor framePadX
        , floor (thTrayPadY theme) + floor framePadY
        , floor btn )
  pumpEmbeds env config theme slotPos
  placeEmbeds env config slotPos
  return (fromIntegral monW, btn + 2 * framePadY + 2 * thTrayPadY theme)
  where
    gap = fromIntegral (thTraySpacing theme)
    -- Section widths; the flags say whether each renders at all.
    -- Measure-only (no drawing): this runs before Begin. The title
    -- width is computed LAST: natural char-capped width clamped into
    -- the space left by the fixed sections.
    measureSections items nEmbed btn traySpacing = do
      wsW <- case mBar of
        Just barT -> measureWorkspaces barT config traySpacing
        Nothing -> return 0
      winW <- case mBar of
        Just barT -> measureWinButtons barT config traySpacing
        Nothing -> return 0
      kbW <- measureIndicator
      titleNatural <- case mBar of
        Just barT -> do
          s <- readTVarIO barT
          case barActiveTitle s of
            Nothing -> return 0
            Just t -> do
              let capped = capTitleChars (configBarTitleMax config) t
              ImVec2 tw _ <- calcTextSize capped True 0
              return tw
        Nothing -> return 0
      let n = length items + nEmbed
          iconsW = if n == 0 then 0
            else fromIntegral n * (btn + 2 * framePadX)
                   + fromIntegral (n - 1) * traySpacing
      clockW <- do
        ImVec2 w _ <- calcTextSize "00:00" True 0
        return w
      dateW <- do
        ImVec2 w _ <- calcTextSize "00.00" True 0
        return w
      let hasTitle = titleNatural > 0
          leftFlags = [wsW > 0, hasTitle, winW > 0]
          rightFlags = [iconsW > 0, kbW > 0, clockW > 0, dateW > 0]
          leftN = length (filter id leftFlags)
          rightN = length (filter id rightFlags)
          leftGaps = fromIntegral (max 0 (leftN - 1))
          rightGaps = fromIntegral (max 0 (rightN - 1))
          spacerGaps = if leftN > 0 && rightN > 0 then 2
                       else if leftN + rightN > 0 then 1 else 0
          fixedLeft = wsW + winW
          rightTotal = iconsW + kbW + clockW + dateW + rightGaps * gap
          titleAvail = fromIntegral monW - 2 * thTrayPadX theme
            - fixedLeft - rightTotal - (leftGaps + spacerGaps) * gap
          titleW = min titleNatural (max 0 titleAvail)
          left = filter fst [ (wsW > 0, wsW), (hasTitle, titleW)
                            , (winW > 0, winW) ]
          right = filter fst [ (iconsW > 0, iconsW), (kbW > 0, kbW)
                             , (dateW > 0, dateW), (clockW > 0, clockW) ]
          gaps = gap * (leftGaps + rightGaps + spacerGaps)
      -- the embed anchor: the right group's left edge sits spacerGaps
      -- * gap left of monW - pad - right widths (the spacer reserves
      -- that breathing room), so the slots must account for it
      return (SectionLayout left right gaps titleW
               (gap * (rightGaps + spacerGaps)))
    sectionSum ps = sum (map snd ps)
    measureIndicator = case kbEnv of
      Just kb | configKbIndicator config -> do
        s <- readTVarIO (kbState kb)
        let code = T.toUpper (T.take 2 (currentLayout s))
        if T.null code then return 0 else do
          ImVec2 tw _ <- calcTextSize code True 0
          return (tw + 2 * framePadX)
      _ -> return 0

-- Pre-measured section widths for one bar row.
data SectionLayout = SectionLayout
  { slLeft :: [(Bool, Float)]
  , slRight :: [(Bool, Float)]
  , slGaps :: Float
  , slTitleW :: Float
  , slRightGaps :: Float
    -- ^ total spacing between the right-group sections (for embed
    --   slot positioning)
  }

-- | Render one bar row: left sections, h-spacer, right group. The
-- section list mirrors 'measureSections' (ws, title, windows | icons,
-- indicator, date, clock).
renderRow :: TrayEnv -> TrayTextures -> Config -> Theme
          -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
          -> [TrayItem] -> [XEmbedIcon] -> Float -> Float -> Float
          -> SectionLayout -> Float
          -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO ()
renderRow env textures config theme kbEnv mainFont mBar items embeds iconSize btn
          traySpacing sects spacerW surfSize winPos screenSize = do
  let secFlag i = maybe False fst (atSec i)
      atSec i =
        let ps = slLeft sects
        in if i < length ps then Just (ps !! i) else Nothing
      wsOn = secFlag 0
      titleOn = secFlag 1
      winOn = secFlag 2
  wsRendered <-
    if wsOn then case mBar of
      Just barT -> do
        _ <- withDpy $ \dpy -> renderWorkspaces dpy barT config theme traySpacing
        return True
      Nothing -> return False
    else return False
  titleRendered <-
    if titleOn then case mBar of
      Just barT -> do
        s <- readTVarIO barT
        case barActiveTitle s of
          Nothing -> return False
          Just t -> do
            let capped = capTitleChars (configBarTitleMax config) t
            fitted <- fitTitleWidth (slTitleW sects) capped
            sameLineS traySpacing
            text fitted
            return True
      Nothing -> return False
    else return False
  winRendered <-
    if winOn then case mBar of
      Just barT -> do
        _ <- withDpy $ \dpy ->
          renderWinButtons dpy barT config theme traySpacing
            (wsRendered || titleRendered)
        return True
      Nothing -> return False
    else return False
  -- the h-spacer: pushes the right group to the right edge
  when (wsRendered || titleRendered || winRendered) $
    sameLineS spacerW
  let n = length items + length embeds
  forM_ (zip [0 :: Int ..] items) $ \(idx, item) -> do
    when (idx > 0) $ sameLineS traySpacing
    renderItem env textures theme iconSize btn traySpacing idx item surfSize
      winPos screenSize
  -- reserve layout space for docked XEmbed icons (the foreign
  -- windows draw on top of the reservations)
  let itemW = btn + 2 * framePadX
  forM_ (zip [0 :: Int ..] embeds) $ \(idx, _) -> do
    when (idx > 0 || not (null items)) $ sameLineS traySpacing
    withImVec2 (ImVec2 itemW btn) $ \szPtr -> Raw.dummy szPtr
  _ <- renderIndicator env kbEnv (configKbIndicator config) traySpacing
         mainFont btn (n > 0 || wsRendered || titleRendered || winRendered)
         winPos
  _ <- renderDateWidget theme traySpacing
  void $ renderClockWidget theme traySpacing
  where
    withDpy f = case trayDisplay env of
      Just dpy -> f dpy
      Nothing -> fail "homgb: no X display (trayDisplay)"

-- | Current-layout label at the tray edge (config @keyboard.indicator@).
-- Clicking rotates layouts, same as the hotkey. The label is drawn at
-- a size fitted so its button height matches the icon row (btn), i.e.
-- visually the same height as the tray icons. Returns the rendered
-- width (0 when nothing is drawn).
renderIndicator :: TrayEnv -> Maybe KeyboardEnv -> Bool -> Float -> Ptr ()
                -> Float -> Bool -> (Int, Int) -> IO Float
renderIndicator env kbEnv indicatorOn gap mainFont btn follow winPos =
  case kbEnv of
    Just kb | indicatorOn -> do
      -- the group itself is polled on a 1s deadline in frameUpkeep
      -- (render-on-wake: no per-frame polling here)
      s <- readTVarIO (kbState kb)
      let code = T.toUpper (T.take 2 (currentLayout s))
      if T.null code then return 0 else do
        when follow $ sameLineS gap
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
        offerTooltip env "kbdlayout" [currentLayout s] winPos
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
  -- ImageButton draws its frame with ImGuiCol_Button (default style:
  -- a light blue at 0.40 alpha) regardless of the transparent
  -- bg_col — neutralize the button palette so only the icon art
  -- shows.
  let transparent = ImVec4 0 0 0 0
  clicked <- case mTex of
    Just tex ->
      BS.useAsCString label $ \labelPtr ->
        alloca $ \refPtr ->
          alloca $ \sizePtr ->
            alloca $ \uv0Ptr ->
              alloca $ \uv1Ptr ->
                alloca $ \bgPtr ->
                  alloca $ \tintPtr ->
                    withImVec4 transparent $ \btnColPtr ->
                      withImVec4 transparent $ \hovColPtr ->
                        withImVec4 transparent $ \actColPtr -> do
                          poke refPtr (ImTextureRef nullPtr (fromIntegral tex))
                          poke sizePtr (ImVec2 btn btn)
                          poke uv0Ptr (ImVec2 0 0)
                          poke uv1Ptr (ImVec2 1 1)
                          -- ImageButton order is (str_id, tex_ref, size,
                          -- uv0, uv1, bg_col, tint_col) — do NOT swap
                          -- these: tint alpha 0 + white bg renders the
                          -- icon as a solid white square.
                          poke bgPtr (ImVec4 0 0 0 0)
                          poke tintPtr (ImVec4 1 1 1 1)
                          Raw.pushStyleColor ImGuiCol_Button btnColPtr
                          Raw.pushStyleColor ImGuiCol_ButtonHovered hovColPtr
                          Raw.pushStyleColor ImGuiCol_ButtonActive actColPtr
                          c <- Raw.imageButton labelPtr refPtr sizePtr
                                   uv0Ptr uv1Ptr bgPtr tintPtr
                          popStyleColor 3
                          return c
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
      (floor surfH) screenSize (trayWake env)

  offerTooltip env ("icon:" ++ show (coerce name :: String))
    (filter (not . T.null) (T.lines (T.pack (tooltipText info)))) winPos

tooltipText :: ItemInfo -> String
tooltipText info =
  case itemToolTip info of
    Just (_, _, tipTitle, tipBody)
      | not (null tipTitle) && not (null tipBody) -> tipTitle ++ "\n" ++ tipBody
      | not (null tipTitle) -> tipTitle
      | not (null tipBody) -> tipBody
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

-- dear-imgui 2.5 has no float PushStyleVar binding (see the cpp shim).
foreign import ccall "homgb_push_style_var_float" c_push_style_var_float
  :: CInt -> CFloat -> IO ()
 