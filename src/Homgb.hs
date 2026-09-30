{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb (run) where

import Control.Exception (bracket, bracket_)
import Control.Monad (forM_, unless)
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
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import Numeric (showHex)

import Homgb.Config (Config, getConfig, defaultConfigText)
import Homgb.GL.Visual (glxAlphaVisual)
import Homgb.Keyboard (startKeyboard)
import Homgb.Notifications.Daemon (startNotificationDaemon)
import Homgb.Render
import Homgb.State
import Homgb.Tray (TrayEnv(..), startTray)
import Homgb.WMProps (setWindowProperties)

run :: IO ()
run = do
  -- SDL (via sdl2-compat) reads SDL_VIDEO_X11_WINDOW_VISUALID once at
  -- video init, so the ARGB visual must be chosen BEFORE initializeAll.
  -- SDL picks an alpha-capable GLX FB config (glColorPrecision) but
  -- creates the X window with a 24-bit visual unless the hint forces
  -- the config's own visual — query GLX for it.
  mVisual <- glxAlphaVisual
  forM_ mVisual $ \v -> do
    setEnv "SDL_VIDEO_X11_WINDOW_VISUALID" ("0x" ++ showHex v "")
    hPutStrLn stderr $ "homgb: using ARGB visual 0x" ++ showHex v ""
  initializeAll
  config <- loadConfig
  tState <- startNotificationDaemon config
  tray <- startTray
  kb <- startKeyboard config
  app <- initialAppState tState tray kb
  window <- createMainWindow
  forM_ (trayDisplay tray) setWindowProperties
  showWindow window
  runManaged $ do
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
    -- hidden at first: EWMH props (_NET_WM_WINDOW_TYPE=DOCK) must be
    -- set BEFORE the window maps — WMs read them at manage time and
    -- xmonad's ManageDocks skips borders only for pre-tagged docks
    , windowVisible = False
    , windowInitialSize = V2 500 700
    , windowPosition = Absolute (P (V2 80 60))
    , windowGraphicsContext = OpenGLContext defaultOpenGL
        { glColorPrecision = V4 8 8 8 8
          -- 8-bit alpha so a compositor can see through the window
        }
    }

mainLoop :: AppState -> Window -> IO ()
mainLoop app window = unlessQuit $ do
  openGL3NewFrame
  sdl2NewFrame
  newFrame

  renderFrame app window

  glClearColor 0 0 0 0
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
 
