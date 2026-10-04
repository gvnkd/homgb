{-# LANGUAGE OverloadedStrings #-}

module Homgb (run) where

import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO)
import Control.Exception (bracket_)
import Control.Monad (forM, unless, void, when)
import Control.Monad.IO.Class
import Control.Monad.Managed
import Data.Word (Word32)
import qualified Data.Text.IO as T
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime, utcTimeToPOSIXSeconds)
import DearImGui hiding (w)
import DearImGui.OpenGL3
import qualified DearImGui.Raw as Raw (Context, setCurrentContext)
import Graphics.GL
import Linear (V2(..))

import System.Directory (doesFileExist, getXdgDirectory, XdgDirectory(..))
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Homgb.Config (Config(..), getConfig, defaultConfigText)
import Homgb.Control (startControl)
import Homgb.Bar (barCovered)
import Homgb.Backend (bkHideSurface, bkMonitors, bkName, bkScreenSize
  , bkShowSurface, bkStartBarEvents, bkStartEmbedHost, bkStartKeyboard
  , bkTagSurface)
import Homgb.Backend.X11 (preferredBackend, selectBackend)
import qualified Homgb.ImGui.SDL3 as ImGuiSdl3 (newFrame)
import Homgb.Keyboard (KbUi(..), LayoutState(..))
import Homgb.Notifications.Daemon (NotifyState(..), startNotificationDaemon)
import Homgb.Notifications.Data (Notification(..))
import Homgb.Render
import Homgb.Tray.Menu.Render (MenuState(..))
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Surface
import Homgb.Theme (applyFont, mkTheme)
import Homgb.Tray (TrayEnv(..), TooltipInfo(..), startTray)
import Homgb.WMProps (WmClass(..))

run :: IO ()
run = do
  -- SDL prefers X11 when DISPLAY exists (XWayland on river sessions);
  -- a Wayland backend decision must land BEFORE SDL_Init
  pref <- preferredBackend
  vdrv <- lookupEnv "SDL_VIDEODRIVER"
  when (pref == Just "wayland" && vdrv == Nothing) $
    setEnv "SDL_VIDEODRIVER" "wayland"
  SDL3.initializeVideo
  config <- loadConfig
  theme <- mkTheme config
  -- one registered SDL user event type for cross-thread wakeups of
  -- the (blocked) render loop; every producer that mutates rendered
  -- state pushes it (see pushWakeEvent)
  userEv <- SDL3.registerUserEvent
  let wake = SDL3.pushWakeEvent userEv
  tState <- startNotificationDaemon config wake
  tray <- startTray wake
  barDirty <- newTVarIO True
  backend <- selectBackend (trayDisplay tray) barDirty wake
  hPutStrLn stderr $ "homgb: backend: " ++ bkName backend
  kb <- bkStartKeyboard backend config wake
  screen <- bkScreenSize backend
  monitors <- bkMonitors backend
  centerVisible <- newTVarIO False
  startControl kb centerVisible wake
  surfs0 <- mapM (\(name, V2 w h, raise) -> createSurface name (V2 w h) raise)
    -- menu and tooltip are created LAST: xmonad stacks floats by
    -- window-id order, so they get the topmost slots among homgb
    -- floats ("menu/tooltip always on top", even over the center
    -- panel). The tray maps lowered when tray.behind-windows is set
    -- (it stays behind all windows, unclickable where overlapped).
    [ ("homgb-tray", V2 500 80, not (configTrayBehindWindows config))
    , ("homgb-popups", V2 340 200, True)
    , ("homgb-center", V2 (configWidth config) 800, True)
    , ("homgb-menu", V2 360 560, True)
    , ("homgb-tooltip", V2 360 120, True)
    ]
  -- each surface context gets its own font atlas: add the theme font
  -- to every context before the renderer builds the atlas, and keep
  -- the ImFont* for explicit per-widget sizing
  surfs <- forM surfs0 $ \s -> do
    Raw.setCurrentContext (sContext s)
    f <- applyFont theme
    return s { sMainFont = f }
  (traySurf, popSurf, centerSurf, menuSurf, tooltipSurf) <- case surfs of
    [t, p, c, m, tt] -> return (t, p, c, m, tt)
    _ -> error "homgb: internal: expected 5 surfaces"
  -- EWMH tags must be set BEFORE the windows map
  mapM_ (\(s, c) -> bkTagSurface backend s c)
    [ (traySurf, WmDock)
    , (popSurf, WmNotification)
    , (centerSurf, WmDock)
    , (menuSurf, WmPopupMenu)
    , (tooltipSurf, WmTooltip)
    ]
  mapM_ initSurfaceBackend [traySurf, popSurf, centerSurf, menuSurf, tooltipSurf]
  -- become the XEmbed tray host (trayer must not be running):
  -- the ICCCM MANAGER broadcast wakes already-running XEmbed apps
  -- (Telegram-desktop) so they dock without a restart.
  bkStartEmbedHost backend config tray traySurf
  -- making a GL context current maps a hidden SDL window; the
  -- popup/menu/center/tooltip surfaces start hidden (skip-draw while
  -- idle)
  SDL3.hideWindow (sWindow popSurf)
  SDL3.hideWindow (sWindow menuSurf)
  SDL3.hideWindow (sWindow centerSurf)
  SDL3.hideWindow (sWindow tooltipSurf)
  app <- initialAppState backend tState tray kb
    (Surfaces traySurf popSurf menuSurf centerSurf tooltipSurf) screen
    monitors theme centerVisible barDirty userEv wake
  bkStartBarEvents backend (appBarDirty app) wake
  runManaged $ do
    -- the OpenGL3 renderer keeps per-ImGui-context backend data
    -- (io.BackendRendererUserData): init/shutdown it once per surface
    managed_ $ bracket_
      (mapM_ (withSurfaceContext (void openGL3Init))
        [traySurf, popSurf, centerSurf, menuSurf, tooltipSurf])
      (mapM_ (withSurfaceContext openGL3Shutdown)
        [tooltipSurf, menuSurf, centerSurf, popSurf, traySurf])
    liftIO $ do
      SDL3.hideWindow (sWindow popSurf)
      SDL3.hideWindow (sWindow menuSurf)
      SDL3.hideWindow (sWindow centerSurf)
      SDL3.hideWindow (sWindow tooltipSurf)
      bkShowSurface backend traySurf
      mainLoop app
  SDL3.quitVideo

debugEnv :: String -> [String] -> IO ()
debugEnv fmt args = do
  d <- lookupEnv "HOMGB_DEBUG"
  case d of
    Just _ -> hPutStrLn stderr (printf fmt args)
    Nothing -> return ()
  where
    printf [] _ = []
    printf ('%':'s':rest) (a:as) = a ++ printf rest as
    printf (c:rest) as = c : printf rest as
    printf _ _ = ""

withSurfaceContext :: IO () -> Surface -> IO ()
withSurfaceContext action surf = do
  SDL3.makeCurrent (sWindow surf) (sGLContext surf)
  Raw.setCurrentContext (sContext surf)
  action

loadConfig :: IO Config
loadConfig = do
  path <- (</> "config.yml") <$> getXdgDirectory XdgConfig "homgb"
  exists <- doesFileExist path
  if exists
    then getConfig =<< T.readFile path
    else getConfig defaultConfigText

-- | Render-on-wake main loop. Blocks in SDL_WaitEventTimeout until
-- the nearest deadline (popup expiry, clock minute rollover, XKB
-- poll, bar re-sync, tooltip staleness/hover-delay) or until an SDL
-- input event or a user wake event (pushed by DBus threads, the X
-- event listener and render-side hover tracking) arrives. Renders
-- only then — an idle homgb draws nothing and its CPU stays blocked
-- in the wait.
mainLoop :: AppState -> IO ()
mainLoop app = do
  deadline <- nextDeadline app
  now0 <- getPOSIXTime
  let waitMs = max 1 (ceiling ((deadline - now0) * 1000))
  (shouldQuit, sawEvents) <- SDL3.pumpEventsTimeout (appUserEvent app)
    (eventRoutes app) waitMs
  debugEnv "mainloop: wake sawEvents=%s shouldQuit=%s"
    [show sawEvents, show shouldQuit]
  unless shouldQuit $ do
    up <- frameUpkeep app
    debugEnv "mainloop: upkeep expired=%s kb=%s bar=%s ptr=%s"
      [show (upExpired up), show (upKbChanged up), show (upBarChanged up)
      , show (upPointerMoved up)]
    state <- readTVarIO (appNotify app)
    let config = notiConfig state
        notis = notiStList state
        popCount = length notis
    heights <- readTVarIO (appHeights app)
    -- a popup shown for the first time has only an estimated height:
    -- draw once more so the stack layout uses the measured height
    let popUnmeasured = popCount > 0
          && any (\n -> notiId n `Map.notMember` heights) notis
        changed = sawEvents
          || upExpired up || upKbChanged up || upBarChanged up
          || upPointerMoved up || popUnmeasured
    -- an open menu runs its own ~20Hz poll loop (outside-click close
    -- detection via XQueryPointer edges in renderMenus): it must
    -- render on the menu DEADLINE (nextDeadline adds 50ms), not only
    -- on state changes — and crucially NOT via renderMenus' old
    -- per-frame wake, which made the loop frame-locked at GL speed
    -- (~13-15% CPU while open)
    menuOpen <- anyMenuOpen app
    when (changed || menuOpen) $ do
      -- The menu poll ticks (~20Hz, menuOpen via the menu deadline)
      -- redraw ONLY the menu surface: a full re-render per tick costs
      -- ~10% CPU. Everything else renders on real changes only.
      when changed $ do
        -- bar auto-hide: when a window covers the bar's strip
        -- (ToggleStruts, fullscreen layouts, floated windows), hide
        -- the surface entirely
        bar <- readTVarIO (appBar app)
        let covered = configBarLayout config && barCovered bar
        if covered
          then bkHideSurface (appBackend app) (surfacesTray (appSurfaces app))
          else drawOn (surfacesTray (appSurfaces app)) (drawTraySurface app)
        -- SNI hover tooltips: own TOOLTIP surface (in-window tooltips
        -- clip against the bar viewport)
        ttOpen <- anyTooltipOpen app
        if ttOpen
          then drawOn (surfacesTooltip (appSurfaces app)) (drawTooltipSurface app)
          else bkHideSurface (appBackend app) (surfacesTooltip (appSurfaces app))
        -- swapWindow on a hidden SDL window maps it, so the popup
        -- surface must be skipped entirely (not just drawn-and-hidden)
        -- while no popups are live
        if popCount == 0
          then bkHideSurface (appBackend app) (surfacesPopups (appSurfaces app))
          else drawOn (surfacesPopups (appSurfaces app)) (drawPopupSurface app)
        centerOpen <- readTVarIO (appCenterVisible app)
        if centerOpen
          then drawOn (surfacesCenter (appSurfaces app)) (drawCenterSurface app)
          else bkHideSurface (appBackend app) (surfacesCenter (appSurfaces app))
        when popUnmeasured $
          drawOn (surfacesPopups (appSurfaces app)) (drawPopupSurface app)
      -- the menu surface is drawn only while a menu is open: swapping
      -- a hidden SDL window maps it (stale black frame over other
      -- surfaces). menuOpen also drives the menu poll ticks above.
      if menuOpen
        then drawOn (surfacesMenus (appSurfaces app)) (drawMenusSurface app)
        else bkHideSurface (appBackend app) (surfacesMenus (appSurfaces app))
    -- Menu hiding runs OUTSIDE the render gate: on the close
    -- transition neither `changed` nor menuOpen is true (closeMenu
    -- sets msVisible=False without waking), so a gated hide would
    -- leave the surface mapped forever. hideSurface is idempotent
    -- (sShown), so calling it on idle iterations is free.
    unless menuOpen $
      bkHideSurface (appBackend app) (surfacesMenus (appSurfaces app))
    mainLoop app

-- | Earliest time the loop must wake even with no events: the bar
-- clock's next minute rollover, the next popup expiry, the XKB
-- group poll, the bar's 5s safety re-sync, tooltip staleness (hide
-- after the pointer left without an event) and the hover-delay show
-- deadline. Also a small absolute cap so anything not covered by an
-- explicit wake event or deadline stays bounded (0.1s while a
-- follow-mouse surface must track the pointer, 0.25s otherwise).
nextDeadline :: AppState -> IO POSIXTime
nextDeadline app = do
  state <- readTVarIO (appNotify app)
  now <- getPOSIXTime
  lastBar <- readTVarIO (appBarTick app)
  kbD <- case appKeyboard app of
    Just kb -> do
      s <- readTVarIO (kbUiState kb)
      return (realToFrac (utcTimeToPOSIXSeconds (lsQueriedAt s)) + 1)
    Nothing -> return far
  tipD <- do
    mTip <- readTVarIO (trayTooltip (appTray app))
    case mTip of
      -- STALE entries must not become deadlines: offerTooltip only
      -- writes while hovered, so after the pointer leaves the TVar
      -- keeps the last TooltipInfo with tiLastSeen/tiHoverAt in the
      -- PAST — a past deadline clamps waitMs to 1ms and the main
      -- loop spun at ~870Hz (~2.5-8% CPU) until restart. Mirror the
      -- freshness gate from 'anyTooltipOpen' (Render.hs): a stale
      -- tooltip only matters through the 5s bar re-sync, not here.
      Just tip | now - tiLastSeen tip < 0.15
               , now - tiSince tip > 0.35 ->
        return (min (tiHoverAt tip + 0.36) (tiLastSeen tip + 0.2))
      _ -> return far
  embedD <- do
    mHost <- readTVarIO (trayXEmbedHost (appTray app))
    return (if isJust mHost then now + 0.2 else far)
  -- while a menu is open the loop must re-render at ~10Hz: the
  -- outside-click close in renderMenus polls XQueryPointer edges and
  -- only runs inside a render. Timeout wakes arrive with
  -- sawEvents=False, so mainLoop ORs menuOpen into the render gate.
  -- Each tick costs ~7-9ms (GL swap on this stack), so 20Hz would be
  -- ~14% CPU; 10Hz halves that with imperceptible close latency.
  menuD <- do
    menus <- readTVarIO (trayMenus (appTray app))
    return (if any (\(_, _, st) -> msVisible st) (Map.elems menus)
              then now + 0.1 else far)
  let config = notiConfig state
      followAny = configNotiFollowMouse config
        || configNotiCenterFollowMouse config
        || configTrayFollowMouse config
      cap = now + (if followAny then 0.1 else 0.25)
      clock = fromInteger ((floor (now / 60) + 1) * 60) :: POSIXTime
      expiries = [ expiryAt config n | n <- notiStList state ]
  return (foldl' min cap (clock : lastBar + 5 : kbD : tipD : embedD
    : menuD : expiries))
  where
    far = 1e12 :: POSIXTime

-- | When a popup with a finite timeout will expire (POSIX seconds;
-- infinity for timeout=0, "never").
expiryAt :: Config -> Notification -> POSIXTime
expiryAt config noti
  | notiTimeout noti == 0 = 1e12
  | otherwise =
      let ms = if notiTimeout noti > 0
                 then fromIntegral (notiTimeout noti)
                 else fromIntegral (configNotiDefaultTimeout config)
      in realToFrac (utcTimeToPOSIXSeconds (notiCreatedAt noti)) + ms / 1000

-- Each surface draws with its own ImGui and GL context (a GLX context
-- switched between SDL windows presents on only one of them).
drawOn :: Surface -> IO () -> IO ()
drawOn surf draw = do
  SDL3.makeCurrent (sWindow surf) (sGLContext surf)
  Raw.setCurrentContext (sContext surf)
  openGL3NewFrame
  ImGuiSdl3.newFrame
  newFrame
  draw
  glClearColor 0 0 0 0
  glClear GL_COLOR_BUFFER_BIT
  render
  openGL3RenderDrawData =<< getDrawData
  SDL3.swapWindow (sWindow surf)

eventRoutes :: AppState -> [(Word32, Raw.Context)]
eventRoutes app =
  [ (sWindowId s, sContext s)
  | s <- [ surfacesTray (appSurfaces app)
         , surfacesPopups (appSurfaces app)
         , surfacesMenus (appSurfaces app)
         , surfacesCenter (appSurfaces app)
         , surfacesTooltip (appSurfaces app)
         ]
  ]
