{-# LANGUAGE OverloadedStrings #-}

module Homgb (run) where

import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO)
import Control.Exception (bracket_)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Class
import Control.Monad.Managed
import Data.Word (Word32)
import qualified Data.Text.IO as T
import DearImGui
import DearImGui.OpenGL3
import qualified DearImGui.Raw as Raw (Context, setCurrentContext)
import Foreign.Ptr (castPtr)
import Graphics.GL
import Linear (V2(..))

import System.Directory (doesFileExist, getXdgDirectory, XdgDirectory(..))
import Data.Maybe (fromMaybe)
import System.FilePath ((</>))

import Homgb.Config (Config(..), getConfig, defaultConfigText)
import Homgb.Control (startControl)
import Homgb.ImGui.SDL3 (initForOpenGL, shutdown)
import qualified Homgb.ImGui.SDL3 as ImGuiSdl3 (newFrame)
import Homgb.Keyboard (startKeyboard)
import qualified Homgb.Keyboard.Xcb as Xcb
import Homgb.Notifications.Daemon (NotifyState(..), startNotificationDaemon)
import Homgb.Render
import Homgb.SDL3 (GLContext)
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Surface
import Homgb.Tray (TrayEnv(..), startTray)
import Homgb.WMProps (WmClass(..))

run :: IO ()
run = do
  SDL3.initializeVideo
  config <- loadConfig
  tState <- startNotificationDaemon config
  tray <- startTray
  kb <- startKeyboard config
  screen <- fromMaybe (1920, 1080) <$> Xcb.screenSize
  centerVisible <- newTVarIO False
  startControl kb centerVisible
  traySurf <- createSurface "homgb-tray" (V2 500 80)
  popSurf <- createSurface "homgb-popups" (V2 340 200)
  menuSurf <- createSurface "homgb-menu" (V2 360 560)
  centerSurf <- createSurface "homgb-center" (V2 (configWidth config) 800)
  -- EWMH tags must be set BEFORE the windows map
  forM_ (trayDisplay tray) $ \dpy -> do
    tagSurface dpy traySurf WmDock
    tagSurface dpy popSurf WmNotification
    tagSurface dpy menuSurf WmPopupMenu
    tagSurface dpy centerSurf WmDock
  mapM_ initSurfaceBackend [traySurf, popSurf, menuSurf, centerSurf]
  -- making a GL context current maps a hidden SDL window; the
  -- popup surface starts hidden (skip-draw while no popups live)
  SDL3.hideWindow (sWindow popSurf)
  SDL3.hideWindow (sWindow menuSurf)
  SDL3.hideWindow (sWindow centerSurf)
  app <- initialAppState tState tray kb
    (Surfaces traySurf popSurf menuSurf centerSurf) screen centerVisible
  runManaged $ do
    -- the OpenGL3 renderer keeps per-ImGui-context backend data
    -- (io.BackendRendererUserData): init/shutdown it once per surface
    managed_ $ bracket_
      (mapM_ (withSurfaceContext (void openGL3Init))
        [traySurf, popSurf, menuSurf, centerSurf])
      (mapM_ (withSurfaceContext openGL3Shutdown)
        [centerSurf, menuSurf, popSurf, traySurf])
    liftIO $ do
      SDL3.hideWindow (sWindow popSurf)
      SDL3.hideWindow (sWindow menuSurf)
      SDL3.hideWindow (sWindow centerSurf)
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

mainLoop :: AppState -> IO ()
mainLoop app = do
  shouldQuit <- SDL3.pumpEvents (eventRoutes app)
  unless shouldQuit $ do
    frameUpkeep app
    drawOn (surfacesTray (appSurfaces app)) (drawTraySurface app)
    -- swapWindow on a hidden SDL window maps it, so the popup surface
    -- must be skipped entirely (not just drawn-and-hidden) while no
    -- popups are live
    popCount <- length . notiStList <$> readTVarIO (appNotify app)
    if popCount == 0
      then forM_ (trayDisplay (appTray app)) $ \dpy ->
             hideSurface dpy (surfacesPopups (appSurfaces app))
      else drawOn (surfacesPopups (appSurfaces app)) (drawPopupSurface app)
    -- the menu surface is drawn only while a menu is open: swapping a
    -- hidden SDL window maps it (stale black frame over other surfaces)
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
    mainLoop app

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
         ]
  ]
