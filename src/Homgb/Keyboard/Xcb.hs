{-# LANGUAGE OverloadedStrings #-}

-- | Thin FFI wrapper over @cbits/homgb-xkb.c@ (libxcb + libxcb-xkb).
-- One xcb connection is not thread-safe for concurrent requests, so
-- homgb opens one connection per thread (switch thread, render poll).
module Homgb.Keyboard.Xcb
  ( Conn
  , ConnPtr
  , connect
  , group
  , lockGroup
  , rulesLayouts
  , argbVisuals
  , screenSize
  ) where

import qualified Data.Text as T
import Data.List.Split (splitOn)
import Data.Word (Word32, Word64)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt(..), CUChar(..))
import Foreign.Marshal.Alloc (alloca, free)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)

data Conn

type ConnPtr = Ptr Conn

foreign import ccall "homgb_xcb_connect" c_connect :: IO ConnPtr
foreign import ccall "homgb_xcb_disconnect" c_disconnect :: ConnPtr -> IO ()
foreign import ccall "homgb_xkb_supported" c_supported :: ConnPtr -> IO CInt
foreign import ccall "homgb_xkb_get_group" c_get_group :: ConnPtr -> IO CInt
foreign import ccall "homgb_xkb_lock_group" c_lock_group :: ConnPtr -> CUChar -> IO CInt
foreign import ccall "homgb_xkb_rules_layouts" c_rules :: ConnPtr -> IO CString
foreign import ccall "homgb_argb_visuals" c_argb_visuals
  :: ConnPtr -> Ptr CInt -> IO (Ptr Word64)
foreign import ccall "homgb_screen_size" c_screen_size
  :: ConnPtr -> Ptr CInt -> Ptr CInt -> IO CInt

-- | Open a connection to the X server and check the XKB extension.
-- The connection is never disconnected; process exit cleans up.
connect :: IO (Maybe ConnPtr)
connect = do
  p <- c_connect
  if p == nullPtr
    then return Nothing
    else do
      ok <- c_supported p
      if ok /= 0
        then return (Just p)
        else c_disconnect p >> return Nothing

-- | Current locked group index (index into the layouts list), if any.
group :: ConnPtr -> IO (Maybe Int)
group p = do
  g <- c_get_group p
  return $ if g < 0 then Nothing else Just (fromIntegral g)

-- | Lock the given group (the XKB "group lock" = current layout).
lockGroup :: ConnPtr -> Int -> IO Bool
lockGroup p g = do
  rc <- c_lock_group p (CUChar (fromIntegral g))
  return (rc == 0)

-- | Layout rotation list from the root @\_XKB_RULES_NAMES@ property
-- (the comma-separated "layout" field, e.g. @["us","ru"]@).
rulesLayouts :: ConnPtr -> IO (Maybe [T.Text])
rulesLayouts p = do
  cs <- c_rules p
  if cs == nullPtr
    then return Nothing
    else do
      s <- peekCString cs
      free cs
      return $ Just (map T.pack (splitOn "," s))

-- | Depth-32 visual ids of screen 0 (candidates for a transparent
-- window). Empty when X is unreachable or has no 32-bit visuals.
-- | Screen size in pixels of screen 0, if X is reachable.
screenSize :: IO (Maybe (Int, Int))
screenSize = do
  mConn <- connect
  case mConn of
    Nothing -> return Nothing
    Just conn ->
      alloca $ \wp ->
        alloca $ \hp -> do
          ok <- c_screen_size conn wp hp
          if ok == 0
            then return Nothing
            else do
              w <- peek wp
              h <- peek hp
              return (Just (fromIntegral w, fromIntegral h))

argbVisuals :: IO [Word32]
argbVisuals = do
  mConn <- connect
  case mConn of
    Nothing -> return []
    Just conn -> do
      alloca $ \countPtr -> do
        arr <- c_argb_visuals conn countPtr
        n <- peek countPtr
        if arr == nullPtr || n <= 0
          then return []
          else do
            visuals <- peekArray (fromIntegral n) arr
            free arr
            return (map fromIntegral visuals)
