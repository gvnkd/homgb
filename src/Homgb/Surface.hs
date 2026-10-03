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
  , reassertStacking
  , rootChildren
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forM_, unless, when)
import Data.Word (Word32, Word64)
import DearImGui (Context)
import qualified DearImGui.Raw as Raw (createContext, setCurrentContext)
import Foreign.C.Types (CUInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import qualified Graphics.X11.Types as X11 (Window)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Types (Display(..))
import Linear (V2(..))
import System.IO (hPutStrLn, stderr)

import SDL3.Sys.Video (getWindowID, setWindowSize)

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
  , sMainFont :: Ptr ()
    -- ^ the theme font added to this context's atlas (nullPtr when no
    -- font is configured); lets widgets PushFont(font, size) for
    -- size-matched text (e.g. the tray layout indicator)
  , sRaiseOnMap :: Bool
    -- ^ True for transients (menu/popup/center): mapping raises them
    -- above the tray dock. False for the tray: it maps LOWERED so it
    -- stays behind every app window (see homgb_x_map_lowered).
  , sWindowId :: Word32
    -- ^ SDL_WindowID for event routing
  , sShown :: TVar Bool
  , sLastPos :: TVar (Maybe (Int, Int))
  , sLastSize :: TVar (Maybe (Int, Int))
  , sStackOrder :: TVar (Maybe [Word64])
    -- ^ root children (bottom-to-top) at the last stacking re-assert;
    -- the render loop skips the raise/lower when the order is
    -- unchanged (event-driven re-assert instead of a 5Hz timer)
  }

data Surfaces = Surfaces
  { surfacesTray :: Surface
  , surfacesPopups :: Surface
  , surfacesMenus :: Surface
  , surfacesCenter :: Surface
  , surfacesTooltip :: Surface
  }

-- | Create a hidden, untagged, borderless transparent window with its
-- own ImGui context. EWMH tagging and showing happen later (tagging
-- pre-map). glContext is needed to make the surface current for
-- backend init. raiseOnMap: see 'sRaiseOnMap'.
createSurface :: String -> V2 Int -> Bool -> IO Surface
createSurface name (V2 w h) raiseOnMap = do
  window <- SDL3.createSurfaceWindow w h
  wid <- fromIntegral <$> getWindowID window
  glCtx <- SDL3.createGLContext window
  ctx <- Raw.createContext
  Raw.setCurrentContext ctx
  c_disable_ini
  shown <- newTVarIO False
  lastPos <- newTVarIO Nothing
  lastSize <- newTVarIO Nothing
  stackOrder <- newTVarIO Nothing
  return Surface
    { sName = name
    , sWindow = window
    , sContext = ctx
    , sGLContext = glCtx
    , sMainFont = nullPtr
    , sRaiseOnMap = raiseOnMap
    , sWindowId = wid
    , sShown = shown
    , sLastPos = lastPos
    , sLastSize = lastSize
    , sStackOrder = stackOrder
    }

-- | Tag with EWMH props; call BEFORE the window is mapped. The
-- surface name becomes the WM_CLASS res_class ("homgb-menu" etc).
tagSurface :: Display -> Surface -> WmClass -> IO ()
tagSurface dpy surf cls = do
  mId <- x11WindowId (sWindow surf)
  case mId of
    Just wid -> setSurfaceProps dpy (fromIntegral wid) cls (sName surf)
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
foreign import ccall "homgb_x_map_lowered" c_x_map_lowered
  :: Display -> X11.Window -> IO ()
foreign import ccall "homgb_x_unmap" c_x_unmap
  :: Display -> X11.Window -> IO ()
foreign import ccall "homgb_imgui_disable_ini" c_disable_ini
  :: IO ()

showSurface :: Display -> Surface -> IO ()
showSurface dpy surf = do
  shown <- readTVarIO (sShown surf)
  unless shown $ do
    -- both: SDL must think the window is shown (else SwapWindow
    -- no-ops) AND the X window must actually be mapped (SDL's own
    -- ShowWindow reported success but left it withdrawn)
    SDL3.showWindow (sWindow surf)
    mId <- surfaceX11Id surf
    forM_ mId $ \wid ->
      if sRaiseOnMap surf
        then c_x_map dpy (fromIntegral wid)
        else c_x_map_lowered dpy (fromIntegral wid)
    atomically $ writeTVar (sShown surf) True

hideSurface :: Display -> Surface -> IO ()
hideSurface dpy surf = do
  shown <- readTVarIO (sShown surf)
  when shown $ do
    SDL3.hideWindow (sWindow surf)
    mId <- surfaceX11Id surf
    forM_ mId $ \wid -> c_x_unmap dpy (fromIntegral wid)
    atomically $ do
      writeTVar (sShown surf) False
      -- the WM re-places the window when it is mapped again; forget
      -- the cached geometry so the next move/resize is re-applied
      writeTVar (sLastPos surf) Nothing
      writeTVar (sLastSize surf) Nothing

surfaceShown :: Surface -> IO Bool
surfaceShown = readTVarIO . sShown

-- | Re-assert this surface's stacking position when the root's
-- stacking order changed (WMs restack managed windows on focus/layout
-- changes, undoing the map-time raise/lower; without this the tray
-- randomly jumps above app windows and back). `children` is the
-- CURRENT root children list (bottom-to-top, see 'rootChildren');
-- when it equals the order recorded at the last re-assert the X
-- raise/lower is skipped entirely, so map/unmap/configure churn that
-- did not move our window costs one cheap compare, not X requests.
-- No-op while hidden.
reassertStacking :: Display -> [Word64] -> Surface -> IO ()
reassertStacking dpy children surf = do
  shown <- surfaceShown surf
  when shown $ do
    prev <- readTVarIO (sStackOrder surf)
    unless (prev == Just children) $ do
      mId <- surfaceX11Id surf
      forM_ mId $ \wid ->
        if sRaiseOnMap surf
          then c_x_map dpy (fromIntegral wid)
          else c_x_map_lowered dpy (fromIntegral wid)
      atomically $ writeTVar (sStackOrder surf) (Just children)

-- | Root window children in bottom-to-top stacking order (XQueryTree
-- order; xwininfo lists top-first).
rootChildren :: Display -> IO [Word64]
rootChildren dpy = do
  alloca $ \nPtr -> do
    kids <- c_query_tree dpy (defaultRootWindow dpy) nPtr
    if kids == nullPtr
      then return []
      else do
        n <- peek nPtr
        ws <- peekArray (fromIntegral n :: Int) kids
        c_x_free kids
        return (map fromIntegral (ws :: [X11.Window]))

foreign import ccall "homgb_query_tree" c_query_tree
  :: Display -> X11.Window -> Ptr CUInt -> IO (Ptr X11.Window)
foreign import ccall "homgb_x_free" c_x_free
  :: Ptr a -> IO ()

-- | Configure calls are suppressed when nothing changed: repeated
-- XMove/XResize make xmonad restack/refocus the window every frame
-- (observed as a flickering WM border and occlusion of the menu by
-- the tray surface).
resizeSurfaceWindow :: Surface -> Int -> Int -> IO ()
resizeSurfaceWindow surf w h = do
  prev <- readTVarIO (sLastSize surf)
  when (prev /= Just (w, h)) $ do
    void' (setWindowSize (sWindow surf) (fromIntegral w) (fromIntegral h))
    atomically $ writeTVar (sLastSize surf) (Just (w, h))

moveSurfaceWindow :: Surface -> Int -> Int -> IO ()
moveSurfaceWindow surf x y = do
  prev <- readTVarIO (sLastPos surf)
  when (prev /= Just (x, y)) $ do
    SDL3.setWindowPosition (sWindow surf) x y
    atomically $ writeTVar (sLastPos surf) (Just (x, y))

surfaceWindowSize :: Surface -> IO (V2 Int)
surfaceWindowSize surf = do
  V2 w h <- SDL3.windowSize (sWindow surf)
  return (V2 (fromIntegral w) (fromIntegral h))

void' :: IO a -> IO ()
void' a = a >> return ()
