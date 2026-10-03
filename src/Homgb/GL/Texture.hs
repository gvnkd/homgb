{-# LANGUAGE OverloadedStrings #-}

module Homgb.GL.Texture
  ( SizedRgba(..)
  , argbToRgba
  , bgraToRgba
  , uploadRgba
  , deleteTextures
  , drawImage
  ) where


import qualified Data.ByteString as BS
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray, pokeArray)
import Foreign.Ptr (castPtr, nullPtr)
import Foreign.Storable (poke)
import Graphics.GL hiding (glBindTexture)
import qualified Graphics.GL as GL (glBindTexture)

import DearImGui hiding (image, begin, w)
import qualified DearImGui.Raw as Raw (image)

-- | Raw RGBA8 pixel data ready for GL upload.
data SizedRgba = SizedRgba
  { srWidth :: Int
  , srHeight :: Int
  , srData :: BS.ByteString
  } deriving (Show)

-- | DBus sends ARGB32 in network byte order (bytes A,R,G,B).
argbToRgba :: BS.ByteString -> BS.ByteString
argbToRgba = BS.pack . go . BS.unpack
  where
    go (a:r:g:b:rest) = r:g:b:a : go rest
    go _ = []

-- | The SNI host converts pixmaps to host byte order; on little-endian
-- that is bytes B,G,R,A. Convert to R,G,B,A.
bgraToRgba :: BS.ByteString -> BS.ByteString
bgraToRgba = BS.pack . go . BS.unpack
  where
    go (b:g:r:a:rest) = r:g:b:a : go rest
    go _ = []

uploadRgba :: SizedRgba -> IO GLuint
uploadRgba (SizedRgba w h dat) = do
  [tex] <- allocaArray 1 $ \ptr -> do
    glGenTextures 1 ptr
    peekArray 1 ptr
  GL.glBindTexture GL_TEXTURE_2D tex
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER
    (fromIntegral (GL_LINEAR :: GLenum) :: GLint)
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER
    (fromIntegral (GL_LINEAR :: GLenum) :: GLint)
  glPixelStorei GL_UNPACK_ROW_LENGTH 0
  BS.useAsCString dat $ \ptr ->
    glTexImage2D GL_TEXTURE_2D 0 (fromIntegral (GL_RGBA :: GLenum) :: GLint)
      (fromIntegral w) (fromIntegral h) 0 GL_RGBA GL_UNSIGNED_BYTE (castPtr ptr)
  return tex

deleteTextures :: [GLuint] -> IO ()
deleteTextures [] = return ()
deleteTextures texes =
  allocaArray (length texes) $ \ptr -> do
    pokeArray ptr texes
    glDeleteTextures (fromIntegral (length texes)) ptr

drawImage :: GLuint -> Float -> Float -> IO ()
drawImage tex w h = do
  let ref = ImTextureRef nullPtr (fromIntegral tex)
      imgSize = ImVec2 w h
      uv0 = ImVec2 0 0
      uv1 = ImVec2 1 1
  alloca $ \refPtr ->
    alloca $ \sizePtr ->
      alloca $ \uv0Ptr ->
        alloca $ \uv1Ptr -> do
          poke refPtr ref
          poke sizePtr imgSize
          poke uv0Ptr uv0
          poke uv1Ptr uv1
          Raw.image refPtr sizePtr uv0Ptr uv1Ptr
