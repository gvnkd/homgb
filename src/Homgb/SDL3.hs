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
  , pumpEventsTimeout
  , registerUserEvent
  , pushWakeEvent
  , x11WindowId
  ) where

import Control.Monad (unless, void, when)
import Data.Bits ((.|.))
import Data.Int (Int32)
import Data.Word (Word32, Word64)
import DearImGui (Context)
import qualified DearImGui.Raw as Raw (setCurrentContext)
import Foreign.C.ConstPtr (ConstPtr(..))
import Foreign.C.String (peekCString, withCString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, peekByteOff, poke, sizeOf)
import Linear (V2(..))
import System.Exit (exitFailure)


import Prelude hiding (init)

import SDL3.Sys.Error (getError)
import SDL3.Sys.Events
  ( SDL_Event
  , SDL_EventType(..)
  , pollEvent
  , waitEventTimeoutSafe
  , pushEvent
  , registerEvents
  , pattern SDL_EVENT_QUIT
  )
import SDL3.Sys.Init (init, quit, pattern SDL_INIT_VIDEO)
import SDL3.Sys.Properties
  ( SDL_PropertiesID(..), createProperties, destroyProperties
  , getNumberProperty, setNumberProperty, setStringProperty)
import qualified SDL3.Sys.Video as RawVideo
  (glCreateContext, glMakeCurrent, glSwapWindow, getWindowPosition
  , getWindowSize, hideWindow, setWindowPosition, showWindow)
import SDL3.Sys.Video
  ( SDL_GLContext(..)
  , SDL_Window
  , createWindowWithProperties
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
createMainWindow = createSurfaceWindow "homgb" 500 700

-- | Hidden borderless transparent OpenGL window. `name` becomes both
-- the title and the Wayland app_id (SDL_PROP_WINDOW_CREATE_APP_ID) —
-- the WM (xmonad-on-river) identifies homgb's surfaces by it; on X11
-- WMProps tags the window the EWMH way instead. Caller positions,
-- tags, shows.
createSurfaceWindow :: String -> Int -> Int -> IO Window
createSurfaceWindow name w h = do
  props <- createProperties
  setStr props "SDL.window.create.title" name
  setStr props "SDL.window.create.app_id" name
  setNum props "SDL.window.create.flags" (fromIntegral flags)
  win <- createWindowWithProperties props
  _ <- destroyProperties props
  if win == nullPtr then dieSDL else return win
  where
    flags =
      SDL_WINDOW_OPENGL
        .|. SDL_WINDOW_BORDERLESS
        .|. SDL_WINDOW_TRANSPARENT
        .|. SDL_WINDOW_HIDDEN
    setStr props k v =
      withCString k $ \kp ->
        withCString v $ \vp ->
          void' (setStringProperty props (ConstPtr kp) (ConstPtr vp))
    setNum props k v =
      withCString k $ \kp ->
        void' (setNumberProperty props (ConstPtr kp) v)

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

-- | Block up to the given number of milliseconds for events, then drain
-- the queue. Returns (sawQuit, sawAnyEvent): when the timeout elapses
-- with no events both are False and the caller can skip rendering
-- entirely (render-on-wake; the idle CPU stays blocked in SDL).
-- `userEv` is a registered SDL_EVENT_USER type used by other threads to
-- wake the loop on state changes; it is counted as an event but not
-- routed to an ImGui context.
pumpEventsTimeout :: Word32 -> [(Word32, Context)] -> Int -> IO (Bool, Bool)
pumpEventsTimeout userEv routes ms = alloca @SDL_Event $ \ev -> do
  -- the SAFE flavor: the unsafe FFI would freeze the capability for
  -- the whole wait and starve dbus-haskell's reply dispatch (SNI
  -- property fetches then hit their 5s timeout — observed as
  -- serial-0 Error.Failed from the host library)
  got <- waitEventTimeoutSafe ev (i32 (max 0 (min ms maxBoundInt32)))
  if not got
    then return (False, False)
    else go ev False True
  where
    maxBoundInt32 = fromIntegral (maxBound :: Int32) :: Int
    go ev sawQuit _sawAny = do
      evType <- peek (castPtr ev :: Ptr SDL_EventType)
      if evType == SDL_EVENT_QUIT
        then next ev True
        else
          if evType /= SDL_EventType (fromIntegral userEv)
            then do
              wid <- peekByteOff ev 16
              case lookup (wid :: Word32) routes of
                Just ctx -> do
                  Raw.setCurrentContext ctx
                  _ <- processEvent (castPtr ev)
                  return ()
                Nothing -> return ()
              next ev sawQuit
            else next ev sawQuit
    next ev sawQuit = do
      pending <- pollEvent ev
      if pending then go ev sawQuit True else return (sawQuit, True)

-- | Register one application event type (SDL_RegisterEvents) for
-- cross-thread wakeups of the render loop.
registerUserEvent :: IO Word32
registerUserEvent = registerEvents 1

-- | Push a zeroed user event of the given type onto the SDL queue.
-- Thread-safe; wakes the render loop out of its timed wait. Callers:
-- DBus threads (notifications, SNI host, menus, control) and X event
-- listeners, whenever they mutate state the renderer displays.
pushWakeEvent :: Word32 -> IO ()
pushWakeEvent userEv = do
  let n = sizeOf (undefined :: SDL_Event)
  allocaBytes n $ \ev -> do
    fillBytes ev 0 n
    poke (castPtr ev :: Ptr Word32) userEv
    void (pushEvent ev)

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
