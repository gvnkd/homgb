{-# LANGUAGE OverloadedStrings #-}

-- | A surface: one borderless transparent SDL window hosting one
-- ImGui context. Per-surface ImGui contexts let the stock
-- imgui_impl_sdl3 backend work unchanged: each context has its own
-- backend data bound to its own window, so events routed to the right
-- context are accepted. One GL context is made current per surface
-- per frame (all surfaces share the same ARGB visual).
module Homgb.Surface
  ( Surface(..)
  , Surfaces(..)
  , createSurface
  , tagSurface
  , initSurfaceBackend
  , surfaceX11Id
  , showSurface
  , hideSurface
  , surfaceShown
  , resizeSurfaceWindow
  , moveSurfaceWindow
  , surfaceWindowSize
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forM_, unless, when)
import Foreign.C.Types (CInt(..))
import Data.Word (Word32, Word64)
import DearImGui (Context)
import qualified DearImGui.Raw as Raw (createContext, setCurrentContext)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import qualified Graphics.X11.Types as X11 (Window)
import Graphics.X11.Xlib.Types (Display(..))
import Linear (V2(..))
import System.IO (hPutStrLn, stderr)

import SDL3.Sys.Video (SDL_Window, getWindowID, setWindowSize)
import qualified SDL3.Sys.Video as RawVideo (getWindowSize)

import Homgb.ImGui.SDL3 (initForOpenGL)
import Homgb.SDL3 (GLContext, Window, x11WindowId)
import qualified Homgb.SDL3 as SDL3
import Homgb.WMProps (WmClass, setSurfaceProps)

data Surface = Surface
  { sName :: String
  , sWindow :: Window
  , sContext :: Context
  , sGLContext :: GLContext
    -- ^ each surface owns its GL context: one GLX context cannot be
    -- switched between SDL windows and present on both (clear test
    -- proved it), and no sharing is needed because textures are
    -- uploaded only under the owning surface's context
  , sWindowId :: Word32
    -- ^ SDL_WindowID for event routing
  , sShown :: TVar Bool
  }

data Surfaces = Surfaces
  { surfacesTray :: Surface
  , surfacesPopups :: Surface
  }

-- | Create a hidden, untagged, borderless transparent window with its
-- own ImGui context. EWMH tagging and showing happen later (tagging
-- pre-map). glContext is needed to make the surface current for
-- backend init.
createSurface :: String -> V2 Int -> IO Surface
createSurface name (V2 w h) = do
  window <- SDL3.createSurfaceWindow w h
  wid <- fromIntegral <$> getWindowID window
  glCtx <- SDL3.createGLContext window
  ctx <- Raw.createContext
  shown <- newTVarIO False
  return Surface
    { sName = name
    , sWindow = window
    , sContext = ctx
    , sGLContext = glCtx
    , sWindowId = wid
    , sShown = shown
    }

-- | Tag with EWMH props; call BEFORE the window is mapped.
tagSurface :: Display -> Surface -> WmClass -> IO ()
tagSurface dpy surf cls = do
  mId <- x11WindowId (sWindow surf)
  case mId of
    Just wid -> setSurfaceProps dpy (fromIntegral wid) cls
    Nothing ->
      hPutStrLn stderr $ "surface " ++ sName surf ++ ": no X11 window id"

-- | Bind the imgui SDL3 backend to this surface's context+window.
initSurfaceBackend :: Surface -> IO ()
initSurfaceBackend surf = do
  SDL3.makeCurrent (sWindow surf) (sGLContext surf)
  Raw.setCurrentContext (sContext surf)
  initForOpenGL (castPtr (sWindow surf)) (SDL3.glContextPtr (sGLContext surf))

surfaceX11Id :: Surface -> IO (Maybe Word64)
surfaceX11Id = x11WindowId . sWindow

-- SDL_ShowWindow/SDL_HideWindow manage SDL's internal state (needed:
-- SDL_GL_SwapWindow no-ops on SDL-hidden windows, and SDL maps hidden
-- windows on SwapWindow); the X map/unmap covers SDL's ShowWindow
-- reporting success while the window stays withdrawn.
foreign import ccall "homgb_x_map" c_x_map
  :: Display -> X11.Window -> IO ()
foreign import ccall "homgb_x_unmap" c_x_unmap
  :: Display -> X11.Window -> IO ()

showSurface :: Display -> Surface -> IO ()
showSurface dpy surf = do
  shown <- readTVarIO (sShown surf)
  unless shown $ do
    -- both: SDL must think the window is shown (else SwapWindow
    -- no-ops) AND the X window must actually be mapped (SDL's own
    -- ShowWindow reported success but left it withdrawn)
    SDL3.showWindow (sWindow surf)
    mId <- surfaceX11Id surf
    forM_ mId $ \wid -> c_x_map dpy (fromIntegral wid)
    atomically $ writeTVar (sShown surf) True

hideSurface :: Display -> Surface -> IO ()
hideSurface dpy surf = do
  shown <- readTVarIO (sShown surf)
  when shown $ do
    SDL3.hideWindow (sWindow surf)
    mId <- surfaceX11Id surf
    forM_ mId $ \wid -> c_x_unmap dpy (fromIntegral wid)
    atomically $ writeTVar (sShown surf) False

surfaceShown :: Surface -> IO Bool
surfaceShown = readTVarIO . sShown

resizeSurfaceWindow :: Surface -> Int -> Int -> IO ()
resizeSurfaceWindow surf w h =
  void' (setWindowSize (sWindow surf) (fromIntegral w) (fromIntegral h))

moveSurfaceWindow :: Surface -> Int -> Int -> IO ()
moveSurfaceWindow = SDL3.setWindowPosition . sWindow

surfaceWindowSize :: Surface -> IO (V2 Int)
surfaceWindowSize surf = do
  V2 w h <- SDL3.windowSize (sWindow surf)
  return (V2 (fromIntegral w) (fromIntegral h))

void' :: IO a -> IO ()
void' a = a >> return ()
