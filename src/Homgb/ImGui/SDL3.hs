-- | FFI to the vendored imgui_impl_sdl3 backend (compiled in
-- cbits/homgb-imgui-sdl3.cpp). dear-imgui's own `DearImGui.SDL`
-- module binds the sdl2 package, which homgb no longer uses.
module Homgb.ImGui.SDL3
  ( initForOpenGL
  , shutdown
  , newFrame
  , processEvent
  ) where

import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr)
import System.IO (hPutStrLn, stderr)

foreign import ccall "homgb_imgui_sdl3_init_for_opengl" c_init
  :: Ptr () -> Ptr () -> IO CInt
foreign import ccall "homgb_imgui_sdl3_shutdown" c_shutdown :: IO ()
foreign import ccall "homgb_imgui_sdl3_new_frame" c_new_frame :: IO ()
foreign import ccall "homgb_imgui_sdl3_process_event" c_process_event
  :: Ptr () -> IO CInt

initForOpenGL :: Ptr () -> Ptr () -> IO ()
initForOpenGL window glContext = do
  ok <- c_init window glContext
  if ok /= 0
    then return ()
    else hPutStrLn stderr "imgui-sdl3: InitForOpenGL failed"

shutdown :: IO ()
shutdown = c_shutdown

newFrame :: IO ()
newFrame = c_new_frame

processEvent :: Ptr () -> IO ()
processEvent ev = void' (c_process_event ev)
  where
    void' action = action >> return ()
