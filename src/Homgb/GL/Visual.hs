{-# LANGUAGE ScopedTypeVariables #-}

-- | Find the X visual that SDL should use for a transparent GL window.
module Homgb.GL.Visual (glxAlphaVisual) where

import Control.Exception (SomeException, catch)
import Data.Word (Word32)
import Foreign.C.Types (CInt(..), CLong(..))
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Display (defaultScreen, openDisplay)
import System.IO (hPutStrLn, stderr)

foreign import ccall "homgb_glx_alpha_visual" c_glx_alpha_visual
  :: Display -> CInt -> IO CLong

-- | Visual id of the first GLX FB config with 8-bit alpha, if any.
-- Nothing when X/GLX is unavailable or no alpha visual exists.
glxAlphaVisual :: IO (Maybe Word32)
glxAlphaVisual = catch openAndQuery warnAndNone
  where
    openAndQuery = do
      dpy <- openDisplay ""
      v <- c_glx_alpha_visual dpy (fromIntegral (defaultScreen dpy))
      return $ if v >= 0 then Just (fromIntegral v) else Nothing
    warnAndNone (e :: SomeException) = do
      hPutStrLn stderr $ "homgb: GLX alpha visual query failed: " ++ show e
      return Nothing
