{-# LANGUAGE ForeignFunctionInterface #-}

-- | FFI to the minimal PipeWire client in cbits/homgb-pipewire.c.
--
-- Volumes on the wire are LINEAR channel gains. WirePlumber applies
-- its cubic volume scale on top, so the cubic mapping lives in
-- "Homgb.Volume" (pure functions, repl-testable).
--
-- The change callback fires on the pw_thread_loop thread: it must
-- only write TVars and push the SDL user event (see
-- "Homgb.Volume.startVolume").
module Homgb.PipeWire
  ( PwHandle
  , pwConnect
  , pwDestroy
  , pwSetCallback
  , pwSetVolume
  , pwSetMute
  ) where

import Foreign (FunPtr, Ptr)
import Foreign.C.Types (CFloat(..), CInt(..))

data PwHandle

type PwCb = CFloat -> CInt -> CInt -> IO ()

foreign import ccall safe "homgb_pw_connect" c_pwConnect
  :: IO (Ptr PwHandle)
foreign import ccall safe "homgb_pw_destroy" c_pwDestroy
  :: Ptr PwHandle -> IO ()
foreign import ccall safe "homgb_pw_set_callback" c_pwSetCallback
  :: Ptr PwHandle -> FunPtr PwCb -> IO ()
foreign import ccall safe "homgb_pw_set_volume" c_pwSetVolume
  :: Ptr PwHandle -> CFloat -> IO CInt
foreign import ccall safe "homgb_pw_set_mute" c_pwSetMute
  :: Ptr PwHandle -> CInt -> IO CInt
foreign import ccall "wrapper" c_mkCallback
  :: PwCb -> IO (FunPtr PwCb)

-- | Connect to the pipewire-0 socket, following the default audio
-- sink. NULL when no PipeWire server is reachable.
pwConnect :: IO (Ptr PwHandle)
pwConnect = c_pwConnect

pwDestroy :: Ptr PwHandle -> IO ()
pwDestroy = c_pwDestroy

-- | Register the state-change callback. It fires immediately with
-- the cached state, then on every volume/mute/default-sink change.
pwSetCallback :: Ptr PwHandle -> PwCb -> IO ()
pwSetCallback h cb = do
  fn <- c_mkCallback cb
  c_pwSetCallback h fn

-- | Set the default sink's channel volumes; argument is the LINEAR
-- gain (cubic-converted on the Haskell side), clamped to 0..1.
-- Returns False when no sink is available.
pwSetVolume :: Ptr PwHandle -> Float -> IO Bool
pwSetVolume h v = (/= 0) <$> c_pwSetVolume h (CFloat v)

-- | 0 = unmute, 1 = mute, 2 = toggle. Returns False when no sink is
-- available.
pwSetMute :: Ptr PwHandle -> Int -> IO Bool
pwSetMute h mode = (/= 0) <$> c_pwSetMute h (CInt (fromIntegral mode))
