{-# LANGUAGE OverloadedStrings #-}

module Homgb (run) where

import Control.Exception (bracket, bracket_)
import Control.Monad (unless)
import Control.Monad.IO.Class
import Control.Monad.Managed
import qualified Data.Text.IO as T
import DearImGui
import DearImGui.OpenGL3
import DearImGui.SDL
import DearImGui.SDL.OpenGL
import Graphics.GL
import SDL

import System.Directory (doesFileExist, getXdgDirectory, XdgDirectory(..))
import System.FilePath ((</>))

import Homgb.Config (Config, getConfig, defaultConfigText)
import Homgb.Notifications.Daemon (startNotificationDaemon)
import Homgb.Render
import Homgb.State

run :: IO ()
run = do
  initializeAll
  config <- loadConfig
  tState <- startNotificationDaemon config
  app <- initialAppState tState
  runManaged $ do
    window <- managed $ bracket createMainWindow destroyWindow
    glContext <- managed $ bracket (glCreateContext window) glDeleteContext
    _ <- managed $ bracket createContext destroyContext
    managed_ $ bracket_ (sdl2InitForOpenGL window glContext) sdl2Shutdown
    managed_ $ bracket_ openGL3Init openGL3Shutdown
    liftIO $ mainLoop app window

loadConfig :: IO Config
loadConfig = do
  path <- (</> "config.yml") <$> getXdgDirectory XdgConfig "homgb"
  exists <- doesFileExist path
  if exists
    then getConfig =<< T.readFile path
    else getConfig defaultConfigText

createMainWindow :: IO Window
createMainWindow =
  createWindow "homgb" defaultWindow
    { windowBorder = False
    , windowResizable = False
    , windowInitialSize = V2 400 300
    , windowPosition = Absolute (P (V2 80 60))
    , windowGraphicsContext = OpenGLContext defaultOpenGL
    }

mainLoop :: AppState -> Window -> IO ()
mainLoop app window = unlessQuit $ do
  openGL3NewFrame
  sdl2NewFrame
  newFrame

  renderFrame app window

  glClear GL_COLOR_BUFFER_BIT
  render
  openGL3RenderDrawData =<< getDrawData

  glSwapWindow window
  mainLoop app window
  where
    unlessQuit action = do
      shouldQuit <- gotQuitEvent
      unless shouldQuit action

    gotQuitEvent = do
      event <- pollEventWithImGui
      case event of
        Nothing -> return False
        Just ev -> (isQuit ev ||) <$> gotQuitEvent

    isQuit ev = eventPayload ev == QuitEvent
 