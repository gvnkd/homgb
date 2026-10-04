{-# LANGUAGE OverloadedStrings #-}

module Homgb.Render
  ( Upkeep(..)
  , frameUpkeep
  , drawTraySurface
  , drawPopupSurface
  , drawMenusSurface
  , drawCenterSurface
  , drawTooltipSurface
  , anyMenuOpen
  , anyTooltipOpen
  ) where

import Control.Concurrent.STM.TVar
import Control.Concurrent.STM (atomically)
import Control.Monad (when, unless, forM, forM_)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.List ((\\))
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Linear (V2(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)

import System.IO (hPutStrLn, hFlush, stderr)
import System.Environment (lookupEnv)

import DearImGui hiding (image, begin, x, y, w)
import qualified DearImGui.Raw as Raw
  (sameLine, spacing, begin, pushStyleColor, setNextWindowPos
  , setNextWindowSize, showMetricsWindow, separator
  , pushStyleVar)

import Homgb.Backend (Backend, BarUpkeep(..), bkBarActions, bkBarUpkeep
  , bkHideSurface, bkMoveSurface, bkPollPointer, bkPressEdge
  , bkShowSurface, bkUpdateStrut)
import Homgb.Bar (BarSection(..), barActiveWindow)
import Homgb.Config (Config(..))
import Homgb.GL.Texture
import Homgb.Monitors (Monitor(..), monitorAt, clampMonitor)
import Homgb.Notifications.Daemon
  (NotifyState(..), closeAllNotifications, closeNotiById, expireNotiById)
import Homgb.Notifications.Data
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Surface
  (Surface(..), Surfaces(..), resizeSurfaceWindow, surfaceWindowSize)
import Homgb.Theme (Theme(..), themePopupBg, themePopupBorder, themePopupTitle)
import Homgb.Tray (TrayEnv(..), TooltipInfo(..))
import Homgb.Keyboard (kbUiPoll)
import Homgb.Tray.Menu.Render (MenuFrame(..), MenuState(..), renderMenus)
import Homgb.Tray.Render (renderTray)

-- | What frameUpkeep changed this iteration; the render loop redraws
-- only when an SDL/user event arrived or one of these is True
-- (render-on-wake instead of a free-running loop).
data Upkeep = Upkeep
  { upExpired :: Bool
    -- ^ at least one popup hit its timeout
  , upKbChanged :: Bool
    -- ^ the 1s XKB group poll saw a different group
  , upBarChanged :: Bool
    -- ^ the EWMH bar state re-read produced different state
  , upPointerMoved :: Bool
    -- ^ the follow-mouse pointer poll moved
  }

-- | Per-iteration state maintenance, all deadline/event-driven:
-- popup expiry (checked when the loop wakes), the XKB group poll on
-- its 1s deadline, the follow-mouse pointer poll (only when any
-- surface configures follow-mouse), and — gated by the X event
-- listener's dirty flag plus a 5s safety re-sync — the EWMH bar
-- re-read and the stacking re-assert. Texture uploads/pruning happen
-- in drawPopupSurface instead: GL contexts are per-surface and
-- unshared, so popup image textures must be created/deleted under
-- the popup context.
frameUpkeep :: AppState -> IO Upkeep
frameUpkeep app = do
  let tState = appNotify app
  state <- readTVarIO tState
  let config = notiConfig state
      notis = notiStList state
  now <- getCurrentTime
  let due = filter (isExpired config now) notis
  forM_ due $ \noti ->
    expireNotiById (appWake app) tState (notiId noti) Timeout
  let followAny = configNotiFollowMouse config
        || configNotiCenterFollowMouse config
        || configTrayFollowMouse config
  pointerMoved <-
    if followAny
      then do
        mP <- bkPollPointer (appBackend app)
        case mP of
          Just p -> do
            old <- readTVarIO (appPointer app)
            atomically $ writeTVar (appPointer app) p
            return (p /= old)
          Nothing -> return False
      else return False
  -- HOMGB_PTRDEBUG: 1Hz global pointer position, for driving the
  -- session with ydotool (follow-mouse off)
  debugPointer <- lookupEnv "HOMGB_PTRDEBUG"
  case debugPointer of
    Just _ -> do
      probeNow <- getPOSIXTime
      lastProbe <- readTVarIO (appPointerProbe app)
      when (probeNow - lastProbe > 1) $ do
        atomically $ writeTVar (appPointerProbe app) probeNow
        mP <- bkPollPointer (appBackend app)
        hPutStrLn stderr ("ptr: " ++ show mP)
    Nothing -> return ()
  kbChanged <- case appKeyboard app of
    Just kb -> kbUiPoll kb
    Nothing -> return False
  -- The bar state and the z-order re-assert are EVENT-DRIVEN:
  -- the backend's event listener (X11: root property/structure
  -- selection) sets appBarDirty, and wakes the loop. We re-read only
  -- then, plus a slow 5s safety re-sync. The platform upkeep itself
  -- (EWMH re-read + stacking fingerprint on X11) lives in the backend.
  nowTick <- getPOSIXTime
  dirty <- readTVarIO (appBarDirty app)
  lastBar <- readTVarIO (appBarTick app)
  (barChanged, kbFocusChanged) <-
    if dirty || nowTick - lastBar > 5
      then do
        atomically $ do
          writeTVar (appBarTick app) nowTick
          writeTVar (appBarDirty app) False
        bkBarUpkeep (appBackend app) BarUpkeep
          { buSurfaces = appSurfaces app
          , buBar = appBar app
          , buStrut = appStrut app
          , buKeyboard = appKeyboard app
          , buTray = appTray app
          }
      else return (False, False)
  return Upkeep
    { upExpired = not (null due)
    , upKbChanged = kbChanged || kbFocusChanged
    , upBarChanged = barChanged
    , upPointerMoved = pointerMoved
    }

-- | Pick the monitor a surface lives on: the configured index, or the
-- one containing the pointer when follow-mouse is set.
monitorFor :: AppState -> Config -> (Config -> Int) -> (Config -> Bool)
           -> IO Monitor
monitorFor app cfg idxOf followOf =
  let ms = appMonitors app
  in if followOf cfg
       then do
         p <- readTVarIO (appPointer app)
         return (monitorAt ms p)
       else return (clampMonitor ms (idxOf cfg))

-- | Draw the tray surface and shrink-wrap/position its SDL window at
-- the configured screen corner.
drawTraySurface :: AppState -> IO ()
drawTraySurface app = do
  let surf = surfacesTray (appSurfaces app)
  -- idempotent: the bar hides when covered (ToggleStruts/fullscreen)
  -- and must re-map when the strip is free again
  bkShowSurface (appBackend app) surf
  state <- readTVarIO (appNotify app)
  let config = notiConfig state
      theme = appTheme app
  V2 surfW surfH <- surfaceWindowSize surf
  winPos <- SDL3.windowPosition (sWindow surf)
  mon <- monitorFor app config configTrayMonitor configTrayFollowMouse
  (w, h) <- renderTray (appTray app) (trayTextures (appTray app)) config theme
    (appKeyboard app) (sMainFont surf)
    (if configBarWorkspaces config || configBarWindows config
       then Just (BarSection (appBar app) (bkBarActions (appBackend app)))
       else Nothing)
    (ImVec2 (fromIntegral surfW) (fromIntegral surfH))
    winPos (monW mon, monH mon)
  if configBarLayout config
    then do
      -- full-width bar hugging the monitor's top edge
      resizeSurfaceWindow surf (monW mon) (floor h + 2)
      bkMoveSurface (appBackend app) surf (monX mon) (monY mon)
      updateStrut app surf mon (floor h + 2 + configBarStrutGap config)
    else do
      let (mx, my) = (monX mon, monY mon)
          (mw, mh) = (monW mon, monH mon)
          (x, y) = case configTrayPosition config of
            "top-left" -> (mx + 10, my + 10)
            "bottom-left" -> (mx + 10, my + mh - 10 - floor h)
            "bottom-right" -> (mx + mw - 10 - floor w, my + mh - 10 - floor h)
            _ -> (mx + mw - 10 - floor w, my + 10)
      resizeSurfaceWindow surf (floor w + 2) (floor h + 2)
      bkMoveSurface (appBackend app) surf x y
  debug <- lookupEnv "HOMGB_DEBUG"
  case debug of
    Just _ -> hPutStrLn stderr
      $ "tray surface=(" ++ show (monX mon) ++ "," ++ show (monY mon) ++ ") "
        ++ show (floor w :: Int) ++ "x" ++ show (floor h :: Int)
    Nothing -> return ()
  metrics <- lookupEnv "HOMGB_METRICS"
  case metrics of
    Just _ -> Raw.showMetricsWindow
    Nothing -> return ()

-- | Reserve the bar's strip (struts on X11; the Wayland backend only
-- records the rect so popups place below the bar). Only writes when
-- the geometry changed (on X11 each write makes the WM re-run
-- avoidStruts).
updateStrut :: AppState -> Surface -> Monitor -> Int -> IO ()
updateStrut app surf mon depth = do
  state <- readTVarIO (appNotify app)
  bkUpdateStrut (appBackend app) (configBarStruts (notiConfig state))
    (appStrut app) surf mon depth

-- | Draw notification popups in their own surface window, placed at
-- the configured corner of the target monitor. The surface hides when
-- no popups are live. Modification rules can override a popup's
-- margin-top (restarts the stack at that root y) and margin-right
-- (shifts that popup; the surface hugs the union of all popups).
drawPopupSurface :: AppState -> IO ()
drawPopupSurface app = do
  let surf = surfacesPopups (appSurfaces app)
      tState = appNotify app
  state <- readTVarIO tState
  let config = notiConfig state
      notis = notiStList state
  if null notis
    then bkHideSurface (appBackend app) surf
    else do
      bkShowSurface (appBackend app) surf
      syncTextures app notis
      pruneCache app (map notiId notis)
      heights <- readTVarIO (appHeights app)
      let width = configWidthNoti config
      mon <- monitorFor app config configNotiMonitor configNotiFollowMouse
      let -- every popup's ideal root x (modification margin-right can
          -- shift individual popups); the surface spans their union
          idealX n = monX mon + monW mon
            - fromMaybe (configDistanceRight config) (notiRight n) - width - 2
          surfX = minimum (map idealX notis)
          surfW = maximum [ idealX n + width + 4 | n <- notis ] - surfX
      mStrut <- readTVarIO (appStrut app)
      let -- margin-top overrides are ROOT y positions; the surface
          -- top hugs the highest popup so overrides move the window,
          -- not just the content. The DEFAULT root is the configured
          -- margin-top, but never inside the bar's reserved strip:
          -- when the popup's monitor intersects the bar strut, the
          -- strut depth (surface height + strut-gap) wins if larger —
          -- popups must render right under the bar, not beneath it
          strutDepth = case mStrut of
            Just (depth, sx0, sx1)
              | monX mon <= sx1
                && monX mon + monW mon - 1 >= sx0 -> Just depth
            _ -> Nothing
          topDefault = case strutDepth of
            Just d -> max d (configDistanceTop config)
            Nothing -> configDistanceTop config
          rootTop n = fromMaybe topDefault (notiTop n)
          baseTop = minimum (topDefault : map rootTop notis)
      total <- go tState config surfX baseTop
                 (map idealX notis) (map rootTop notis) heights notis
      resizeSurfaceWindow surf surfW (floor total + 4)
      bkMoveSurface (appBackend app) surf surfX (monY mon + baseTop)
      debug <- lookupEnv "HOMGB_DEBUG"
      case debug of
        Just _ -> hPutStrLn stderr
          $ "popup surface=(" ++ show surfX ++ "," ++ show (monY mon + baseTop)
            ++ ") h=" ++ show (floor total :: Int)
        Nothing -> return ()
  where
    go _ _ _ _ _ _ _ [] = return 2
    go tState config surfX baseTop (ix:ixs) (rt:rts) heights (n:rest) = do
      let localTop = fromIntegral (rt - baseTop) + 2
          localX = fromIntegral (ix - surfX) + 2
      h <- renderPopup app tState config localX localTop
             (Map.findWithDefault (fallbackHeight config) (notiId n) heights) n
      below <- go tState config surfX baseTop ixs rts heights rest
      return (max below (localTop + h
        + fromIntegral (configDistanceBetween config)))
    go _ _ _ _ _ _ _ (_:_) = return 2

-- | deadd's timeout semantics (NotificationPopup.startTimeoutThread):
--   0 = never expires, >0 = that many milliseconds, <0 = configured default.
isExpired :: Config -> UTCTime -> Notification -> Bool
isExpired config now noti =
  let timeout = notiTimeout noti
      ms = if timeout > 0 then fromIntegral timeout
           else fromIntegral (configNotiDefaultTimeout config)
      age = realToFrac (diffUTCTime now (notiCreatedAt noti)) * 1000 :: Double
  in timeout /= 0 && age > ms

-- | Draw visible dbusmenus into the menu surface (EWMH POPUP_MENU):
-- the menu window sits at the surface's local origin and the surface
-- window is moved to the stored root position. The surface hides when
-- no menu is open.
-- | Any menu currently open? Drives whether the menu surface is
-- rendered at all (drawing it maps it - SDL_GL_SwapWindow maps hidden
-- windows - so an idle menu surface must be skipped entirely).
anyMenuOpen :: AppState -> IO Bool
anyMenuOpen app = do
  m <- readTVarIO (trayMenus (appTray app))
  return (any (\(_, _, st) -> msVisible st) (Map.elems m))

-- | Draw visible dbusmenus into the menu surface (EWMH POPUP_MENU):
-- the menu window sits at the surface's local origin and the surface
-- window is moved to the stored root position. The surface hides when
-- no menu is open.
drawMenusSurface :: AppState -> IO ()
drawMenusSurface app = do
  let surf = surfacesMenus (appSurfaces app)
      env = appTray app
  winPos <- SDL3.windowPosition (sWindow surf)
  mFrame <- renderMenus (trayClient env) (trayMenus env)
    (trayPrevButtons env) (bkPressEdge (appBackend app)) (appTheme app) winPos
    (trayWake env)
  case mFrame of
    Nothing -> bkHideSurface (appBackend app) surf
    Just f -> do
      -- keep the whole menu on its monitor: with the tray at the right
      -- edge the cursor-anchored position would push the surface off
      let (px, py) = mfRootPos f
          (mw, mh) = mfSize f
          mon = monitorAt (appMonitors app) (floor px, floor py)
          (bx, by) = (monX mon, monY mon)
          (bw, bh) = (monW mon, monH mon)
          x = if floor px + ceiling mw > bx + bw - 4
                then max bx (bx + bw - 4 - ceiling mw)
                else floor px
          y = if floor py + ceiling mh > by + bh - 4
                then max by (by + bh - 4 - ceiling mh)
                else floor py
      -- hug the menu content: the menu surface was created at a
      -- fixed 360x560, but AlwaysAutoResize windows overflow it for
      -- long labels (visually clipped at the viewport edge — menu
      -- items looked "shrunk"). Resize AFTER show: xmonad restores a
      -- re-mapped float's geometry from its float map, discarding
      -- resizes that happened while withdrawn (popup pattern).
      bkMoveSurface (appBackend app) surf x y
      bkShowSurface (appBackend app) surf
      resizeSurfaceWindow surf (ceiling mw + 4) (ceiling mh + 4)

-- | SNI tooltip surface (EWMH TOOLTIP): shows the pending hover
-- tooltip written by the tray render after the hover delay. Renders
-- like the menu surface — anchored at the pointer, clamped to the
-- monitor — because in-window ImGui tooltips clip against the bar's
-- 54px viewport.
drawTooltipSurface :: AppState -> IO ()
drawTooltipSurface app = do
  let surf = surfacesTooltip (appSurfaces app)
      env = appTray app
  mTip <- readTVarIO (trayTooltip env)
  now <- getPOSIXTime
  case mTip of
    Just tip | tooltipLive tip now -> do
      let theme = appTheme app
          mon = monitorAt (appMonitors app) (tiRootX tip, tiRootY tip)
          lines' = tiLines tip
      -- fully analytic sizing: auto-fit heights cannot be read
      -- mid-frame reliably, so compute the wrapped height ourselves
      lineWs <- mapM (\l -> do
        ImVec2 w _ <- calcTextSize l True 0
        return w) lines'
      ImVec2 _ lineH <- calcTextSize "A" True 0
      let maxLine = maximum (0 : lineWs)
          winW = min 420 (maxLine + 2 * thTrayPadX theme)
          availW = max 1 (winW - 2 * thTrayPadX theme)
          wraps :: Int
          wraps = sum [ max 1 (ceiling (w / availW) :: Int) | w <- lineWs ]
          contentH = fromIntegral wraps * lineH
            + fromIntegral (length lines' - 1) * (lineH / 2)
            + 2 * thTrayPadY theme
          x0 = max (monX mon) (min (tiRootX tip + 14) (monX mon + monW mon - floor winW - 4))
          y0 = max (monY mon) (min (tiRootY tip + 18) (monY mon + monH mon - floor contentH - 4))
      -- show FIRST, then resize/move: xmonad restores a re-mapped
      -- float's geometry from its float map, discarding resizes that
      -- happened while the window was withdrawn (popup pattern)
      bkShowSurface (appBackend app) surf
      resizeSurfaceWindow surf (floor winW + 2) (floor contentH + 2)
      bkMoveSurface (appBackend app) surf x0 y0
      withImVec4 (thMenuBg theme) $ \bgPtr ->
        withImVec4 (thMenuBorder theme) $ \borderPtr -> do
          Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
          Raw.pushStyleColor ImGuiCol_Border borderPtr
          withImVec2 (ImVec2 0 0) $ \posPtr ->
            Raw.setNextWindowPos posPtr ImGuiCond_Always Nothing
          withImVec2 (ImVec2 winW contentH) $ \sizePtr ->
            Raw.setNextWindowSize sizePtr ImGuiCond_Always
          beginVisible <- BS.useAsCString "homgb-tooltip"
            $ \label -> Raw.begin label Nothing (Just tooltipFlags)
          when beginVisible $
            forM_ (zip [0 :: Int ..] lines') $ \(i, l) -> do
              when (i > 0) $ Raw.spacing
              textWrapped l
          end
          popStyleColor 2
    _ -> bkHideSurface (appBackend app) surf
  where
    tooltipFlags = foldl1 combineFlags
      [ ImGuiWindowFlags_NoTitleBar
      , ImGuiWindowFlags_NoResize
      , ImGuiWindowFlags_NoMove
      , ImGuiWindowFlags_NoCollapse
      ]
    tooltipLive tip now =
      now - tiLastSeen tip < 0.15 && now - tiSince tip > 0.35

-- | Any live tooltip right now? Drives whether the surface renders.
anyTooltipOpen :: AppState -> IO Bool
anyTooltipOpen app = do
  mTip <- readTVarIO (trayTooltip (appTray app))
  now <- getPOSIXTime
  return (maybe False (\tip -> tooltipLive' tip now) mTip)
  where
    tooltipLive' tip now =
      now - tiLastSeen tip < 0.15 && now - tiSince tip > 0.35
-- | Notification center panel (EWMH DOCK): full-height window at the
-- right screen edge. Lists the daemon's persistent history (expired
-- popups included) with per-item dismiss and a clear-all button.
drawCenterSurface :: AppState -> IO ()
drawCenterSurface app = do
  let surf = surfacesCenter (appSurfaces app)
      tState = appNotify app
  bkShowSurface (appBackend app) surf
  state <- readTVarIO tState
  let config = notiConfig state
      width = configWidth config
      history =
        (if configNotiCenterNewFirst config then id else reverse)
          (notiHistory state)
  mon <- monitorFor app config configNotiCenterMonitor configNotiCenterFollowMouse
  let x = monX mon + monW mon - width - configRightMargin config
      y = monY mon + configBarHeight config
      h = monH mon - configBarHeight config - configBottomBarHeight config
  resizeSurfaceWindow surf width h
  bkMoveSurface (appBackend app) surf x y
  V2 surfW surfH <- surfaceWindowSize surf
  let winFlags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoCollapse
        ]
  withImVec2 (ImVec2 0 0) $ \posPtr ->
    Raw.setNextWindowPos posPtr ImGuiCond_Always Nothing
  withImVec2 (ImVec2 (fromIntegral surfW) (fromIntegral surfH)) $ \sizePtr ->
    Raw.setNextWindowSize sizePtr ImGuiCond_Always
  beginVisible <- BS.useAsCString "homgb-center"
    $ \label -> Raw.begin label Nothing (Just winFlags)
  when beginVisible $ do
    text ("Notifications (" <> T.pack (show (length history)) <> ")")
    -- action buttons on their own line, at the left edge: interactive
    -- rects on a sameLine row after a text are offset ~130px left of
    -- the rendered position (root cause unknown; left-edge widgets
    -- like the item rows below behave correctly)
    closeClicked <- smallButton "x##center-close"
    when closeClicked $
      atomically $ writeTVar (appCenterVisible app) False
    Raw.sameLine
    clearClicked <- smallButton "clear all"
    when clearClicked $ closeAllNotifications (appWake app) tState User
    Raw.separator
    -- list of persistent notifications
    forM_ (zip [0 :: Int ..] history) $ \(i, noti) -> do
      when (i > 0) Raw.separator
      dismiss <- smallButton ("x##noti-" <> T.pack (show (notiId noti)))
      Raw.sameLine
      text (notiSummary noti)
      unless (T.null (notiBody noti)) $ do
        Raw.spacing
        textWrapped (notiBody noti)
      when dismiss $ closeNotiById (appWake app) tState (notiId noti) User
    metrics <- lookupEnv "HOMGB_METRICS"
    case metrics of
      Just _ -> Raw.showMetricsWindow
      Nothing -> return ()
  end

-- | Draw one popup at local (x, top) inside the popup surface.
renderPopup :: AppState -> TVar NotifyState -> Config -> Float -> Float -> Float
            -> Notification -> IO Float
renderPopup app tState config popupX top heightGuess noti = do
  let theme = appTheme app
      width = fromIntegral (configWidthNoti config)
      popupFlags = foldl1 combineFlags
        [ ImGuiWindowFlags_NoTitleBar
        , ImGuiWindowFlags_NoResize
        , ImGuiWindowFlags_NoMove
        , ImGuiWindowFlags_NoScrollbar
        , ImGuiWindowFlags_NoCollapse
        , ImGuiWindowFlags_AlwaysAutoResize
        , ImGuiWindowFlags_NoFocusOnAppearing
        ]

  withImVec4 (themePopupBorder theme (notiUrgency noti)) $ \borderPtr ->
    withImVec4 (themePopupBg theme (notiUrgency noti)) $ \bgPtr ->
      withImVec2 (ImVec2 (thPopupPadX theme) (thPopupPadY theme)) $ \padPtr -> do
        Raw.pushStyleColor ImGuiCol_Border borderPtr
        Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
        Raw.pushStyleVar ImGuiStyleVar_WindowPadding padPtr

        withImVec2 (ImVec2 popupX top) $ \posPtr ->
          withImVec2 (ImVec2 0 0) $ \pivotPtr ->
            Raw.setNextWindowPos posPtr ImGuiCond_Always (Just pivotPtr)
        withImVec2 (ImVec2 width 0) $ \sizePtr ->
          Raw.setNextWindowSize sizePtr ImGuiCond_Always
        beginVisible <- BS.useAsCString (T.encodeUtf8 (windowLabel (notiId noti)))
          $ \label -> Raw.begin label Nothing (Just popupFlags)

        when beginVisible $ do
          withImVec4 (themePopupTitle theme (notiUrgency noti)) $ \titlePtr -> do
            Raw.pushStyleColor ImGuiCol_Text titlePtr
            text (notiSummary noti)
            popStyleColor 1
          Raw.sameLine
          closeClicked <- smallButton "x##close"
          when closeClicked $
            closeNotiById (appWake app) tState (notiId noti) User

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

          renderActions (appWake app) tState noti

        ImVec2 _ h <- getWindowSize
        end
        popStyleVar 1
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

renderActions :: IO () -> TVar NotifyState -> Notification -> IO ()
renderActions wake tState noti =
  forM_ (zip [0 :: Int ..] (actionPairs (notiActions noti))) $ \(i, (key, label)) -> do
    when (i > (0 :: Int)) Raw.sameLine
    clicked <- smallButton label
    when clicked $ do
      notiOnAction noti (notiActionCommands noti) (T.unpack key) Nothing
      closeNotiById wake tState (notiId noti) User

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
 