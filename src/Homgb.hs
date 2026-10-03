{-# LANGUAGE OverloadedStrings #-}

module Homgb (run) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO, writeTVar)
import Control.Exception (bracket_)
import Control.Monad (forM, forM_, unless, void, when)
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
import Data.Maybe (fromMaybe)
import System.FilePath ((</>))

import Homgb.Config (Config(..), getConfig, defaultConfigText)
import Homgb.Control (startControl)
import Homgb.Bar (barCovered, startBarEvents)
import qualified Homgb.ImGui.SDL3 as ImGuiSdl3 (newFrame)
import Homgb.Keyboard (KeyboardEnv(..), LayoutState(..), startKeyboard)
import qualified Homgb.Keyboard.Xcb as Xcb
import Homgb.Monitors (fallbackMonitor, getMonitors)
import Homgb.Notifications.Daemon (NotifyState(..), startNotificationDaemon)
import Homgb.Notifications.Data (Notification(..))
import Homgb.Render
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Surface
import Homgb.Theme (applyFont, mkTheme)
import Homgb.Tray (TrayEnv(..), TooltipInfo(..), startTray)
import Homgb.Tray.Embed (acquireTraySelection)
import Homgb.WMProps (WmClass(..))

run :: IO ()
run = do
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
  kb <- startKeyboard config
  screen <- fromMaybe (1920, 1080) <$> Xcb.screenSize
  monitors <- case trayDisplay tray of
    Just dpy -> getMonitors dpy screen
    Nothing -> return (fallbackMonitor screen)
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
  forM_ (trayDisplay tray) $ \dpy -> do
    tagSurface dpy traySurf WmDock
    tagSurface dpy popSurf WmNotification
    tagSurface dpy centerSurf WmDock
    tagSurface dpy menuSurf WmPopupMenu
    tagSurface dpy tooltipSurf WmTooltip
  mapM_ initSurfaceBackend [traySurf, popSurf, centerSurf, menuSurf, tooltipSurf]
  -- become the XEmbed tray host (trayer must not be running):
  -- the ICCCM MANAGER broadcast wakes already-running XEmbed apps
  -- (Telegram-desktop) so they dock without a restart.
  mEmbed <- case (configTrayXEmbed config, trayDisplay tray) of
    (True, Just dpy) -> do
      mId <- surfaceX11Id traySurf
      case mId of
        Just wid -> acquireTraySelection dpy (fromIntegral wid)
        Nothing -> return Nothing
    _ -> return Nothing
  atomically $ writeTVar (trayXEmbedHost tray) mEmbed
  -- making a GL context current maps a hidden SDL window; the
  -- popup/menu/center/tooltip surfaces start hidden (skip-draw while
  -- idle)
  SDL3.hideWindow (sWindow popSurf)
  SDL3.hideWindow (sWindow menuSurf)
  SDL3.hideWindow (sWindow centerSurf)
  SDL3.hideWindow (sWindow tooltipSurf)
  app <- initialAppState tState tray kb
    (Surfaces traySurf popSurf menuSurf centerSurf tooltipSurf) screen
    monitors theme centerVisible userEv wake
  startBarEvents (appBarDirty app) wake
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
      forM_ (trayDisplay tray) $ \dpy -> showSurface dpy traySurf
      mainLoop app
  SDL3.quitVideo

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
  unless shouldQuit $ do
    up <- frameUpkeep app
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
    when changed $ do
      -- bar auto-hide: when a window covers the bar's strip
      -- (ToggleStruts, fullscreen layouts, floated windows), hide
      -- the surface entirely
      bar <- readTVarIO (appBar app)
      let covered = configBarLayout config && barCovered bar
      if covered
        then forM_ (trayDisplay (appTray app)) $ \dpy ->
               hideSurface dpy (surfacesTray (appSurfaces app))
        else drawOn (surfacesTray (appSurfaces app)) (drawTraySurface app)
      -- SNI hover tooltips: own TOOLTIP surface (in-window tooltips
      -- clip against the bar viewport)
      ttOpen <- anyTooltipOpen app
      if ttOpen
        then drawOn (surfacesTooltip (appSurfaces app)) (drawTooltipSurface app)
        else forM_ (trayDisplay (appTray app)) $ \dpy ->
               hideSurface dpy (surfacesTooltip (appSurfaces app))
      -- swapWindow on a hidden SDL window maps it, so the popup
      -- surface must be skipped entirely (not just drawn-and-hidden)
      -- while no popups are live
      if popCount == 0
        then forM_ (trayDisplay (appTray app)) $ \dpy ->
               hideSurface dpy (surfacesPopups (appSurfaces app))
        else drawOn (surfacesPopups (appSurfaces app)) (drawPopupSurface app)
      -- the menu surface is drawn only while a menu is open: swapping
      -- a hidden SDL window maps it (stale black frame over other
      -- surfaces)
      menuOpen <- anyMenuOpen app
      if menuOpen
        then drawOn (surfacesMenus (appSurfaces app)) (drawMenusSurface app)
        else forM_ (trayDisplay (appTray app)) $ \dpy ->
               hideSurface dpy (surfacesMenus (appSurfaces app))
      centerOpen <- readTVarIO (appCenterVisible app)
      if centerOpen
        then drawOn (surfacesCenter (appSurfaces app)) (drawCenterSurface app)
        else forM_ (trayDisplay (appTray app)) $ \dpy ->
               hideSurface dpy (surfacesCenter (appSurfaces app))
      when popUnmeasured $
        drawOn (surfacesPopups (appSurfaces app)) (drawPopupSurface app)
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
      s <- readTVarIO (kbState kb)
      return (realToFrac (utcTimeToPOSIXSeconds (lsQueriedAt s)) + 1)
    Nothing -> return far
  tipD <- do
    mTip <- readTVarIO (trayTooltip (appTray app))
    case mTip of
      Just tip -> return (min (tiHoverAt tip + 0.36) (tiLastSeen tip + 0.2))
      Nothing -> return far
  embedD <- do
    mHost <- readTVarIO (trayXEmbedHost (appTray app))
    return (if isJust mHost then now + 0.2 else far)
  let config = notiConfig state
      followAny = configNotiFollowMouse config
        || configNotiCenterFollowMouse config
        || configTrayFollowMouse config
      cap = now + (if followAny then 0.1 else 0.25)
      clock = fromInteger ((floor (now / 60) + 1) * 60) :: POSIXTime
      expiries = [ expiryAt config n | n <- notiStList state ]
  return (foldl' min cap (clock : lastBar + 5 : kbD : tipD : embedD : expiries))
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
