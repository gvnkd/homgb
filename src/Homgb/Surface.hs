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
import Control.Monad (unless, when)
import Data.Word (Word32, Word64)
import DearImGui (Context)
import qualified DearImGui.Raw as Raw (createContext, setCurrentContext)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Graphics.X11.Xlib.Types (Display)
import Linear (V2(..))
import System.IO (hPutStrLn, stderr)

import SDL3.Sys.Video (SDL_Window, getWindowID, setWindowSize)
import qualified SDL3.Sys.Video as RawVideo (getWindowSize)

import Homgb.ImGui.SDL3 (initForOpenGL)
import Homgb.SDL3 (Window, x11WindowId)
import qualified Homgb.SDL3 as SDL3
import Homgb.WMProps (WmClass, setSurfaceProps)

data Surface = Surface
  { sName :: String
  , sWindow :: Window
  , sContext :: Context
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
  ctx <- Raw.createContext
  shown <- newTVarIO False
  return Surface
    { sName = name
    , sWindow = window
    , sContext = ctx
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
-- The GL context must already be current on this window.
initSurfaceBackend :: Ptr () -> Surface -> IO ()
initSurfaceBackend glContext surf = do
  Raw.setCurrentContext (sContext surf)
  initForOpenGL (castPtr (sWindow surf)) glContext

surfaceX11Id :: Surface -> IO (Maybe Word64)
surfaceX11Id = x11WindowId . sWindow

showSurface :: Surface -> IO ()
showSurface surf = do
  shown <- readTVarIO (sShown surf)
  unless shown $ do
    SDL3.showWindow (sWindow surf)
    atomically $ writeTVar (sShown surf) True

hideSurface :: Surface -> IO ()
hideSurface surf = do
  shown <- readTVarIO (sShown surf)
  when shown $ do
    SDL3.hideWindow (sWindow surf)
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
