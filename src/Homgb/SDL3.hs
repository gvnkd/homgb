{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

-- | Thin platform layer over sdl3-bindgen-sys (lithon). Replaces the
-- sdl2 package: one hidden borderless transparent GL window, an event
-- pump feeding the vendored imgui SDL3 backend, and the X11 window id
-- for EWMH tagging.
module Homgb.SDL3
  ( initializeVideo
  , quitVideo
  , Window
  , GLContext
  , createMainWindow
  , createSurfaceWindow
  , destroyWindow
  , showWindow
  , hideWindow
  , setWindowPosition
  , windowPosition
  , windowSize
  , createGLContext
  , glContextPtr
  , makeCurrent
  , swapWindow
  , pumpEvents
  , x11WindowId
  ) where

import Control.Monad (unless, when)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.Word (Word8, Word32, Word64)
import DearImGui (Context)
import qualified DearImGui.Raw as Raw (setCurrentContext)
import Foreign.C.ConstPtr (ConstPtr(..))
import Foreign.C.String (peekCString, withCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, peekByteOff)
import Linear (V2(..))
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO (hPutStrLn, stderr)

import Prelude hiding (init)

import SDL3.Sys.Error (getError)
import SDL3.Sys.Events
  ( SDL_Event
  , SDL_EventType
  , pollEvent
  , pattern SDL_EVENT_QUIT
  , pattern SDL_EVENT_MOUSE_MOTION
  )
import SDL3.Sys.Init (init, quit, pattern SDL_INIT_VIDEO)
import SDL3.Sys.Properties (SDL_PropertiesID(..), getNumberProperty)
import qualified SDL3.Sys.Video as RawVideo
  (glCreateContext, glMakeCurrent, glSwapWindow, getWindowPosition
  , getWindowSize, hideWindow, setWindowPosition, showWindow)
import SDL3.Sys.Video
  ( SDL_GLContext(..)
  , SDL_Window
  , createWindow
  , destroyWindow
  , getWindowProperties
  , pattern SDL_WINDOW_BORDERLESS
  , pattern SDL_WINDOW_HIDDEN
  , pattern SDL_WINDOW_OPENGL
  , pattern SDL_WINDOW_TRANSPARENT
  )

import Homgb.ImGui.SDL3 (processEvent)

type Window = Ptr SDL_Window
type GLContext = SDL_GLContext

-- | The raw pointer form, for the imgui backend shim.
glContextPtr :: GLContext -> Ptr ()
glContextPtr (SDL_GLContext p) = castPtr p

initializeVideo :: IO ()
initializeVideo = do
  ok <- init SDL_INIT_VIDEO
  unless ok dieSDL

quitVideo :: IO ()
quitVideo = quit

-- | Borderless, transparent, hidden. Shown by the caller AFTER EWMH
-- props are set (WMs read them at manage time).
createMainWindow :: IO Window
createMainWindow = createSurfaceWindow 500 700

-- | Hidden borderless transparent OpenGL window. Caller positions,
-- tags, shows.
createSurfaceWindow :: Int -> Int -> IO Window
createSurfaceWindow w h =
  withCString "homgb" $ \title ->
    createWindow (ConstPtr title) (i32 w) (i32 h) flags
  where
    flags =
      SDL_WINDOW_OPENGL
        .|. SDL_WINDOW_BORDERLESS
        .|. SDL_WINDOW_TRANSPARENT
        .|. SDL_WINDOW_HIDDEN

showWindow :: Window -> IO ()
showWindow w = void' (RawVideo.showWindow w)

hideWindow :: Window -> IO ()
hideWindow w = void' (RawVideo.hideWindow w)

setWindowPosition :: Window -> Int -> Int -> IO ()
setWindowPosition w x y = void' (RawVideo.setWindowPosition w (i32 x) (i32 y))

windowPosition :: Window -> IO (Int, Int)
windowPosition w =
  alloca $ \xp ->
    alloca $ \yp -> do
      ok <- RawVideo.getWindowPosition w xp yp
      unless ok dieSDL
      (,) <$> (fromIntegral <$> peek xp) <*> (fromIntegral <$> peek yp)

windowSize :: Window -> IO (V2 Int)
windowSize w =
  alloca $ \wp ->
    alloca $ \hp -> do
      ok <- RawVideo.getWindowSize w wp hp
      unless ok dieSDL
      V2 <$> (fromIntegral <$> peek wp) <*> (fromIntegral <$> peek hp)

createGLContext :: Window -> IO GLContext
createGLContext w = do
  ctx <- RawVideo.glCreateContext w
  when (ctx == SDL_GLContext nullPtr) dieSDL
  return ctx

makeCurrent :: Window -> GLContext -> IO ()
makeCurrent w ctx = do
  ok <- RawVideo.glMakeCurrent w ctx
  unless ok dieSDL

swapWindow :: Window -> IO ()
swapWindow w = void' (RawVideo.glSwapWindow w)

-- | Drain the SDL event queue for this frame. Each event is routed to
-- the ImGui context of its target window (by SDL_WindowID, the third
-- member of every window-targeted event struct) and handed to the
-- imgui backend under that context. Events with an unknown window id
-- are dropped (ImGui would ignore them anyway). True on SDL_EVENT_QUIT.
pumpEvents :: [(Word32, Context)] -> IO Bool
pumpEvents routes = alloca @SDL_Event $ \ev -> drain ev False
  where
    drain ev sawQuit = do
      pending <- pollEvent ev
      if not pending
        then return sawQuit
        else do
          evType <- peek (castPtr ev :: Ptr SDL_EventType)
          if evType == SDL_EVENT_QUIT
            then drain ev True
            else do
              wid <- peekByteOff ev 16
              case lookup (wid :: Word32) routes of
                Just ctx -> do
                  Raw.setCurrentContext ctx
                  _ <- processEvent (castPtr ev)
                  return ()
                Nothing -> return ()
              drain ev sawQuit

-- | X11 window id of the SDL window (for EWMH tagging), if running on
-- X11.
x11WindowId :: Window -> IO (Maybe Word64)
x11WindowId w = do
  props <- getWindowProperties w
  case props of
    SDL_PropertiesID 0 -> return Nothing
    _ ->
      withCString "SDL.window.x11.window" $ \name -> do
        wid <- getNumberProperty props (ConstPtr name) 0
        return (if wid == 0 then Nothing else Just (fromIntegral wid))

dieSDL :: IO a
dieSDL = do
  err <- getError
  msg <- peekCString (unConstPtr err)
  putStrLn ("homgb: SDL error: " ++ msg)
  exitFailure

void' :: IO a -> IO ()
void' a = a >> return ()

i32 :: Int -> Int32
i32 = fromIntegral
