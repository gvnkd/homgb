{-# LANGUAGE OverloadedStrings #-}

module Homgb (run) where

import Control.Exception (bracket, bracket_)
import Control.Monad (forM_, unless)
import Control.Monad.IO.Class
import Control.Monad.Managed
import qualified Data.Text.IO as T
import DearImGui
import DearImGui.OpenGL3
import Foreign.Ptr (Ptr, castPtr)
import Graphics.GL

import System.Directory (doesFileExist, getXdgDirectory, XdgDirectory(..))
import System.FilePath ((</>))

import Homgb.Config (Config, getConfig, defaultConfigText)
import Homgb.ImGui.SDL3 (initForOpenGL, shutdown)
import qualified Homgb.ImGui.SDL3 as ImGuiSdl3 (newFrame)
import Homgb.Keyboard (startKeyboard)
import Homgb.Notifications.Daemon (startNotificationDaemon)
import Homgb.Render
import Homgb.SDL3 (Window, GLContext)
import qualified Homgb.SDL3 as SDL3
import Homgb.State
import Homgb.Tray (TrayEnv(..), startTray)
import Homgb.WMProps (setWindowProperties, setWindowPropsById)

run :: IO ()
run = do
  SDL3.initializeVideo
  config <- loadConfig
  tState <- startNotificationDaemon config
  tray <- startTray
  kb <- startKeyboard config
  app <- initialAppState tState tray kb
  window <- SDL3.createMainWindow
  glContext <- SDL3.createGLContext window
  SDL3.makeCurrent window glContext
  -- EWMH props must be set BEFORE the window maps
  forM_ (trayDisplay tray) $ \dpy -> do
    mId <- SDL3.x11WindowId window
    case mId of
      Just wid -> setWindowPropsById dpy wid
      Nothing -> setWindowProperties dpy
  runManaged $ do
    _ <- managed $ bracket createContext destroyContext
    managed_ $ bracket_ openGL3Init openGL3Shutdown
    managed_ $ bracket_ (initForOpenGL (castPtr window) (SDL3.glContextPtr glContext)) shutdown
    liftIO $ SDL3.showWindow window
    liftIO $ mainLoop app window glContext
  SDL3.quitVideo

loadConfig :: IO Config
loadConfig = do
  path <- (</> "config.yml") <$> getXdgDirectory XdgConfig "homgb"
  exists <- doesFileExist path
  if exists
    then getConfig =<< T.readFile path
    else getConfig defaultConfigText

mainLoop :: AppState -> Window -> GLContext -> IO ()
mainLoop app window glContext = do
  shouldQuit <- SDL3.pumpEvents
  unless shouldQuit $ do
    openGL3NewFrame
    ImGuiSdl3.newFrame
    newFrame

    renderFrame app window

    glClearColor 0 0 0 0
    glClear GL_COLOR_BUFFER_BIT
    render
    openGL3RenderDrawData =<< getDrawData

    SDL3.swapWindow window
    mainLoop app window glContext
