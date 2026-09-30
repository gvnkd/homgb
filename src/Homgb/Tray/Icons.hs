{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray.Icons (iconRgba, iconRgbaSrc) where

import Control.Exception (catch, IOException, try)
import Control.Monad (filterM, forM)
import Data.Char (toLower)
import Data.Int (Int32)
import Data.List (sortOn, isPrefixOf, isSuffixOf)
import Data.Maybe (listToMaybe, catMaybes, fromMaybe)
import qualified Data.ByteString as BS
import qualified Data.Vector.Storable as VS
import qualified Data.ByteString.Internal as BSI
import System.Directory (doesFileExist, doesDirectoryExist, listDirectory, getHomeDirectory, findExecutable)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeExtension, splitPath)
import System.IO (hClose)
import System.Process (createProcess, proc, std_out, StdStream(..), waitForProcess)

import Codec.Picture
import Codec.Picture.Types (DynamicImage(..), imageWidth, imageHeight
                           , promoteImage)

import StatusNotifier.Host.Service (ItemInfo(..))

import Homgb.GL.Texture

-- | Resolve an item's icon to RGBA pixel data. Priority (matching
-- taffybar/deadd): provided ARGB pixmaps, icon-name as file path or
-- inside iconThemePath, freedesktop theme PNG lookup. SVG is a known
-- limitation (no GTK-free SVG renderer) — returns Nothing.
iconRgba :: Int -> ItemInfo -> IO (Maybe SizedRgba)
iconRgba size info = fmap snd <$> iconRgbaSrc size info

-- | Like 'iconRgba' but also reports which resolution source produced
-- the pixels ("pixmap", "path", "theme") for debugging.
iconRgbaSrc :: Int -> ItemInfo -> IO (Maybe (String, SizedRgba))
iconRgbaSrc size info =
      tag "pixmap" (pixmapRgba size info)
  `orElseIO` tag "path" (pathRgba size (iconName info) (iconThemePath info))
  `orElseIO` tag "theme" (themeRgba size (iconName info))
  where
    tag s m = fmap ((,) s) <$> m

orElseIO :: IO (Maybe a) -> IO (Maybe a) -> IO (Maybe a)
orElseIO a b = do
  ra <- a
  case ra of
    Just _ -> return ra
    Nothing -> b

-- | Pixmaps come from the host in host byte order: on little-endian
-- B,G,R,A per pixel.
pixmapRgba :: Int -> ItemInfo -> IO (Maybe SizedRgba)
pixmapRgba size info =
  case pickClosest size (iconPixmaps info) of
    Just (w, h, bs)
      | w > 0 && h > 0
      , BS.length bs >= fromIntegral (w * h * 4) ->
          return $ Just $ SizedRgba (fromIntegral w) (fromIntegral h)
                        (bgraToRgba bs)
    _ -> return Nothing

pickClosest :: Int -> [(Int32, Int32, BS.ByteString)] -> Maybe (Int32, Int32, BS.ByteString)
pickClosest _ [] = Nothing
pickClosest size pics =
  listToMaybe $ sortOn (\(w, _, _) -> abs (fromIntegral w - size)) pics

pathRgba :: Int -> String -> Maybe String -> IO (Maybe SizedRgba)
pathRgba _ name mThemePath
  | null name = return Nothing
  | "/" `isPrefixOf` name = loadPngFile name
  | otherwise = do
      let inTheme dir = [ dir </> name, dir </> (name ++ ".png") ]
      existing <- case mThemePath of
        Just dir -> filterM doesFileExist (inTheme dir)
        Nothing -> return []
      case existing of
        (p:_) -> loadPngFile p
        [] -> return Nothing

-- | Minimal freedesktop icon-theme lookup: walk the standard icon base
-- directories (bounded depth) for @<name>.png@, preferring the size
-- closest to the requested one; falls back to @<name>.svg@ rasterized
-- through the first available of rsvg-convert/magick/convert. No
-- index.theme parsing (inheritance) — good enough for M2.
themeRgba :: Int -> String -> IO (Maybe SizedRgba)
themeRgba size name
  | null name || looksLikePath name = return Nothing
  | otherwise = do
      bases <- iconBaseDirs
      found <- fmap catMaybes $ forM bases $ \base ->
        findIconIn size base (name ++ ".png")
      case sortOn snd found of
        ((path,_):_) -> loadPngFile path
        [] -> do
          foundSvg <- fmap catMaybes $ forM bases $ \base ->
            findIconIn size base (name ++ ".svg")
          case sortOn snd foundSvg of
            ((path,_):_) -> rasterizeSvg size path
            [] -> return Nothing

-- Icon names may contain dots (e.g. "dev.lizardbyte.app.Sunshine-tray")
-- without being file paths; only skip names that look like files.
looksLikePath :: String -> Bool
looksLikePath name =
  let ext = map toLower (takeExtension name)
  in any (`isPrefixOf` name) ["/", "./", "../"]
       || ext `elem` [".png", ".svg", ".jpg", ".jpeg", ".gif", ".bmp", ".xpm"]

-- | Rasterize an SVG icon to @size x size@ PNG bytes using the first
-- available external tool, then decode as PNG.
rasterizeSvg :: Int -> FilePath -> IO (Maybe SizedRgba)
rasterizeSvg size path = do
  tools <- catMaybes <$> mapM findExecutable ["rsvg-convert", "magick", "convert"]
  case tools of
    [] -> return Nothing
    (tool:_) -> do
      out <- tryIO $ do
        (_, Just hout, _, ph) <-
          createProcess (proc tool (argsFor tool)) { std_out = CreatePipe }
        bytes <- BS.hGetContents hout
        hClose hout
        _ <- waitForProcess ph
        return bytes
      return $ case out of
        Right bytes -> decodePngRgba bytes
        Left (_ :: IOException) -> Nothing
  where
    px = show size
    argsFor t
      | t `endsWith` "rsvg-convert" = ["-w", px, "-h", px, path]
      | t `endsWith` "magick" = [path, "-background", "none", "-resize", px ++ "x" ++ px, "png:-"]
      | otherwise = [path, "-background", "none", "-resize", px ++ "x" ++ px, "png:-"]

endsWith :: String -> String -> Bool
endsWith s suffix = suffix `isSuffixOf` s

iconBaseDirs :: IO [FilePath]
iconBaseDirs = do
  home <- getHomeDirectory
  xdgDataHome <- fromMaybe (home </> ".local/share")
    <$> lookupEnv "XDG_DATA_HOME"
  xdgDataDirs <- fromMaybe "/usr/local/share:/usr/share"
    <$> lookupEnv "XDG_DATA_DIRS"
  let bases =
        [ home </> ".icons"
        , xdgDataHome </> "icons"
        ] ++ map (</> "icons") (splitOn ':' xdgDataDirs)
  filterM doesDirectoryExist bases

splitOn :: Char -> String -> [String]
splitOn c s = case rest of
                []      -> [chunk]
                _:rest' -> chunk : splitOn c rest'
  where (chunk, rest) = break (== c) s

-- | Bounded recursive search for a file; returns paths with a size
-- score (Int found in a path component like @22x22@).
findIconIn :: Int -> FilePath -> FilePath -> IO (Maybe (FilePath, Int))
findIconIn size base fileName = go 0 base
  where
    go :: Int -> FilePath -> IO (Maybe (FilePath, Int))
    go depth dir
      | depth > (3 :: Int) = return Nothing
      | otherwise = do
          let candidate = dir </> fileName
          exists <- doesFileExist candidate
          if exists
            then return $ Just (candidate, score dir)
            else do
              subdirs <- listDirectory dir `catch` (\(_ :: IOException) -> return [])
              results <- catMaybes <$> mapM (go (depth + 1) . (dir </>)) subdirs
              return $ listToMaybe $ sortOn snd results
    score dir =
      let sizes = [ n
                  | comp <- splitPath dir
                  , let dims = filter (`notElem` ("/\\" :: String)) comp
                  , (n, rest) <- reads dims
                  , rest == "x" ++ show n
                  ]
      in case sizes of
           (n:_) -> abs (n - size)
           []    -> 1000

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO = catch

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

loadPngFile :: FilePath -> IO (Maybe SizedRgba)
loadPngFile path = do
  contents <- BS.readFile path `catchIO` const (return "")
  if BS.null contents
    then return Nothing
    else return $ decodePngRgba contents

decodePngRgba :: BS.ByteString -> Maybe SizedRgba
decodePngRgba bytes = do
  img <- either (const Nothing) Just (decodePng bytes)
  rgba <- dynToRgba img
  let w = imageWidth rgba
      h = imageHeight rgba
      v = imageData rgba
      (fp, off, len) = VS.unsafeToForeignPtr v
  return $ SizedRgba w h (BSI.fromForeignPtr fp off len)

dynToRgba :: DynamicImage -> Maybe (Image PixelRGBA8)
dynToRgba (ImageRGBA8 i) = Just i
dynToRgba (ImageRGB8 i) = Just (promoteImage i)
dynToRgba _ = Nothing
