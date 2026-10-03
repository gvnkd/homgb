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
  , pushStyleVar, popStyleVar, getMousePos, dummy, setCursorPos)
import DearImGui.Raw.Font (Font(..))
import Homgb.Bar
  ( BarState, barActiveTitle, fitTitleWidth, capTitleChars, renderClockWidget
  , renderDateWidget, renderWinButtons, renderWorkspaces
  , measureWorkspaces, measureWinButtons, renderSep, sepWidth
  , centerCursorY
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
                renderWorkspaces dpy barT config theme (btn + 2 * framePadY)
              winW <- withDpy $ \dpy ->
                renderWinButtons dpy barT config theme (btn + 2 * framePadY)
                  (wsW > 0)
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
          kbW0 <- renderIndicator env kbEnv (configKbIndicator config) theme
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
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr $ "bar sections: left="
      ++ show (map snd (slLeft sects)) ++ " right="
      ++ show (map snd (slRight sects)) ++ " rightX=" ++ show (slRightX sects)
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
            embeds iconSize btn traySpacing sects surfSize winPos screenSize
        end
        Raw.popStyleVar 2
        popStyleColor 2
  -- move XEmbed icon slots to their right-group positions. The SNI
  -- icons are drawn at the same anchor ('slRightX'), computed once in
  -- measureSections — a single source of truth for the group's left
  -- edge (widths + inter-section gaps), so ImGui-drawn widgets and
  -- foreign X windows can never drift apart.
  let rightX0 = slRightX sects
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
        Just barT -> measureWorkspaces barT config
        Nothing -> return 0
      winW <- case mBar of
        Just barT -> measureWinButtons barT config
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
      sw <- sepWidth
      let hasWs = wsW > 0
          hasTitle = titleNatural > 0
          hasWin = winW > 0
          rightFlags = [iconsW > 0, kbW > 0, clockW > 0, dateW > 0]
          rightN = length (filter id rightFlags)
          rightGaps = fromIntegral (max 0 (rightN - 1))
          -- separators between the left sections themselves
          crossSeps = (if hasWs && hasTitle then 1 else 0)
            + (if (hasWs || hasTitle) && hasWin then 1 else 0) :: Int
          crossSepW = fromIntegral crossSeps * sw
          fixedLeft = wsW + winW + crossSepW
          rightTotal = iconsW + kbW + clockW + dateW + rightGaps * gap
          -- the right group's left edge, anchored to the right pad;
          -- the ONLY placement authority — renderRow draws the group
          -- at exactly this x and the XEmbed slots use it too
          rightX = fromIntegral monW - thTrayPadX theme - rightTotal
          titleAvail = rightX - thTrayPadX theme - fixedLeft
          titleW = min titleNatural (max 0 titleAvail)
          left = filter fst [ (wsW > 0, wsW), (hasTitle, titleW)
                            , (winW > 0, winW) ]
          right = filter fst [ (iconsW > 0, iconsW), (kbW > 0, kbW)
                             , (dateW > 0, dateW), (clockW > 0, clockW) ]
      return (SectionLayout left right titleW rightX)
    measureIndicator = case kbEnv of
      Just kb | configKbIndicator config -> do
        s <- readTVarIO (kbState kb)
        let code = T.toUpper (T.take 2 (currentLayout s))
        if T.null code then return 0 else do
          ImVec2 tw _ <- calcTextSize code True 0
          return (tw + 2 * framePadX)
      _ -> return 0

-- Pre-measured section widths for one bar row. `slRightX` is the
-- single placement authority for the right group (icons, indicator,
-- date, clock): renderRow draws the group at exactly that x and the
-- XEmbed slot math reads it too — the ImGui widgets and the foreign
-- X windows therefore cannot drift apart.
data SectionLayout = SectionLayout
  { slLeft :: [(Bool, Float)]
    -- ^ on/off flags + widths of the left sections (ws, title,
    --   windows) — title width is the clamped budget, not the
    --   rendered advance
  , slRight :: [(Bool, Float)]
  , slTitleW :: Float
  , slRightX :: Float
    -- ^ absolute window-local x of the right group's left edge
  }

-- | Render one bar row: left sections flow from the left edge, then
-- the right group is JUMPED to its measured anchor ('slRightX') — no
-- spacer. A spacer's width is derived from the measured sections, but
-- the cursor it consumes follows the sections' ACTUAL advances (which
-- drift: the ellipsis-fitted title renders narrower than its budget,
-- text metrics vary), so anything right of the spacer shifted with
-- the title while the analytically-placed XEmbed icons stood still.
renderRow :: TrayEnv -> TrayTextures -> Config -> Theme
          -> Maybe KeyboardEnv -> Ptr () -> Maybe (TVar BarState)
          -> [TrayItem] -> [XEmbedIcon] -> Float -> Float -> Float
          -> SectionLayout
          -> ImVec2 -> (Int, Int) -> (Int, Int) -> IO ()
renderRow env textures config theme kbEnv mainFont mBar items embeds iconSize btn
          traySpacing sects surfSize winPos screenSize = do
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
            when wsRendered $ do
              sameLineS 0
              renderSep theme rowH
              sameLineS 0
            ImVec2 _ th <- calcTextSize fitted True 0
            centerCursorY theme rowH th
            text fitted
            return True
      Nothing -> return False
    else return False
  winRendered <-
    if winOn then case mBar of
      Just barT -> do
        _ <- withDpy $ \dpy ->
          renderWinButtons dpy barT config theme rowH
            (wsRendered || titleRendered)
        return True
      Nothing -> return False
    else return False
  -- the right group is JUMPED to its measured anchor (see the
  -- 'SectionLayout' haddock): absolute positioning, independent of
  -- how wide the left sections actually rendered
  withImVec2 (ImVec2 (slRightX sects) (thTrayPadY theme)) $ \p ->
    Raw.setCursorPos p
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
  _ <- renderIndicator env kbEnv (configKbIndicator config) theme traySpacing
         mainFont btn (n > 0 || wsRendered || titleRendered || winRendered)
         winPos
  _ <- renderDateWidget theme traySpacing
  void $ renderClockWidget theme traySpacing
  where
    rowH = btn + 2 * framePadY
    withDpy f = case trayDisplay env of
      Just dpy -> f dpy
      Nothing -> fail "homgb: no X display (trayDisplay)"

-- | Current-layout label at the tray edge (config @keyboard.indicator@).
-- Clicking rotates layouts, same as the hotkey. The label is drawn at
-- a size fitted so its button height matches the icon row (btn), i.e.
-- visually the same height as the tray icons. Returns the rendered
-- width (0 when nothing is drawn).
renderIndicator :: TrayEnv -> Maybe KeyboardEnv -> Bool -> Theme -> Float
                -> Ptr () -> Float -> Bool -> (Int, Int) -> IO Float
renderIndicator env kbEnv indicatorOn theme gap mainFont btn follow winPos =
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
        -- same widget style as the rest of the bar: transparent
        -- button, subtle hover tint (the default Button color is the
        -- light-blue ImGui style)
        withImVec4 (ImVec4 0 0 0 0) $ \btnPtr ->
          withImVec4 (thBarButtonHovered theme) $ \hovPtr -> do
            Raw.pushStyleColor ImGuiCol_Button btnPtr
            Raw.pushStyleColor ImGuiCol_ButtonHovered hovPtr
            Raw.pushStyleColor ImGuiCol_ButtonActive hovPtr
            clicked <- smallButton (code <> "##kbdlayout")
            popStyleColor 3
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
 