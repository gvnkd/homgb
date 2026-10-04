{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Homgb.Tray.Icons
  ( iconRgba
  , iconRgbaSrc
  , orElseIO
  , AttentionIcon(..)
  , fetchAttentionIcon
  , attentionRgba
  , addOverlay
  , scaleToHeight
  , blendOver
  ) where

import Control.Exception (catch, IOException, try, SomeException)
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
import Codec.Picture.Types (promoteImage)

import DBus.Client (Client)
import DBus.Internal.Message (MethodError)
import qualified StatusNotifier.Item.Client as I

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

-- | Pixmaps come from the host library already converted with
-- 'networkToSystemByteOrder': ARGB network bytes -> 0xAABBGGRR word
-- -> R,G,B,A in memory on little-endian. They are RGBA as-is — do
-- NOT byte-swap them (the old bgraToRgba call double-swapped, only
-- invisible because every icon in the wild was R~B symmetric).
pixmapRgba :: Int -> ItemInfo -> IO (Maybe SizedRgba)
pixmapRgba size info =
  case pickClosest size (iconPixmaps info) of
    Just (w, h, bs)
      | w > 0 && h > 0
      , BS.length bs >= fromIntegral (w * h * 4) ->
          return $ Just $ SizedRgba (fromIntegral w) (fromIntegral h) bs
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

-- | The SNI spec's unread/mention badge channel: apps set
-- @Status=NeedsAttention@ plus @AttentionIconName@/@AttentionIconPixmap@
-- (chat apps put their red dot there). The status-notifier-item host
-- library never reads those properties, so we fetch them ourselves on
-- the dbus dispatcher thread (NEVER the render thread) and stash the
-- result in the 'TrayItem'.
data AttentionIcon
  = AttentionPixmaps [(Int32, Int32, BS.ByteString)]
    -- ^ raw client-side pixmaps: NETWORK byte order (A,R,G,B)
  | AttentionName String
  deriving (Eq, Show)

-- | Fetch the attention icon for an item, or 'Nothing' when the item
-- is not in @NeedsAttention@ (or exposes no attention icon). Safe to
-- call from dbus callbacks: the getters are ordinary method calls.
fetchAttentionIcon :: Client -> ItemInfo -> IO (Maybe AttentionIcon)
fetchAttentionIcon client info
  | itemStatus info /= Just "NeedsAttention" = return Nothing
  | otherwise = do
      ePix <- try (I.getAttentionIconPixmap client name path)
      case [ (w, h, bs)
           | Right (Right ps) <- [ePix :: Either SomeException
                                    (Either MethodError [(Int32, Int32, BS.ByteString)])]
           , (w, h, bs) <- ps
           , w > 0, h > 0
           , BS.length bs >= fromIntegral (w * h * 4) ] of
        (p:_) -> return (Just (AttentionPixmaps [p]))
        [] -> do
          eName <- try (I.getAttentionIconName client name path)
          case eName :: Either SomeException (Either MethodError String) of
            Right (Right nm) | not (null nm) ->
              return (Just (AttentionName nm))
            _ -> return Nothing
  where
    name = itemServiceName info
    path = itemServicePath info

-- | Resolve an attention icon to RGBA pixels (same fallback chain as
-- the normal icon: pixmap, theme path, freedesktop theme).
attentionRgba :: Int -> Maybe String -> AttentionIcon
              -> IO (Maybe (String, SizedRgba))
attentionRgba size mThemePath att =
  case att of
    AttentionPixmaps ps ->
      return $ case pickClosest size ps of
        Just (w, h, bs)
          | w > 0 && h > 0
          , BS.length bs >= fromIntegral (w * h * 4) ->
              Just ("attention-pixmap", SizedRgba (fromIntegral w)
                       (fromIntegral h) (argbToRgba bs))
        _ -> Nothing
    AttentionName nm ->
          tag "attention-path" (pathRgba size nm mThemePath)
      `orElseIO` tag "attention-theme" (themeRgba size nm)
  where
    tag s m = fmap ((,) s) <$> m

-- | Composite the item's overlay icon (top-left, scaled to 2/5 of the
-- base — gtk-sni-tray's geometry) onto the resolved base image. The
-- host library already tracks @OverlayIconPixmap@/@OverlayIconName@;
-- apps that badge via overlay instead of attention icon get their dot
-- this way.
addOverlay :: Int -> ItemInfo -> (String, SizedRgba)
           -> IO (String, SizedRgba)
addOverlay _ info (src, base@(SizedRgba _ bh _)) = do
  mOverlay <- overlayRgba oSize info
  case mOverlay of
    Nothing -> return (src, base)
    Just ov -> return (src ++ "+overlay", blendOver 0 0 (scaleToHeight oSize ov) base)
  where
    oSize = max 1 (bh * 2 `div` 5)

overlayRgba :: Int -> ItemInfo -> IO (Maybe SizedRgba)
overlayRgba size info =
      pixmapOverlay
  `orElseIO` nameOverlay
  where
    pixmapOverlay =
      return $ case pickClosest size (overlayIconPixmaps info) of
        Just (w, h, bs)
          | w > 0 && h > 0
          , BS.length bs >= fromIntegral (w * h * 4) ->
              -- host-library-converted: already RGBA (see pixmapRgba)
              Just $ SizedRgba (fromIntegral w) (fromIntegral h) bs
        _ -> Nothing
    nameOverlay = case overlayIconName info of
      Just nm ->
            pathRgba size nm (iconThemePath info)
        `orElseIO` themeRgba size nm
      Nothing -> return Nothing

-- | Nearest-neighbor scale preserving aspect ratio; the target is the
-- new HEIGHT (icons are square in practice).
scaleToHeight :: Int -> SizedRgba -> SizedRgba
scaleToHeight targetH (SizedRgba w h dat)
  | h == targetH = SizedRgba w h dat
  | h <= 0 || w <= 0 = SizedRgba w h dat
  | otherwise = SizedRgba w' targetH (BS.pack out)
  where
    w' = max 1 (round (fromIntegral w * fromIntegral targetH
                       / fromIntegral h :: Double))
    n = w' * targetH
    srcPx x y = BS.take 4 (BS.drop ((y * w + x) * 4) dat)
    out = concat [ BS.unpack (srcPx (x * w `div` w') (y * h `div` targetH))
                 | i <- [0 .. n - 1]
                 , let (y, x) = i `divMod` w' ]

-- | Alpha-blend (src-over) @src@ onto @dst@ at offset (ox, oy),
-- clipped to dst bounds.
blendOver :: Int -> Int -> SizedRgba -> SizedRgba -> SizedRgba
blendOver ox oy (SizedRgba sw sh sd) (SizedRgba w h dd) =
  SizedRgba w h (BS.pack (concatMap outPx [0 .. w * h - 1]))
  where
    inSrc x y = x >= ox && y >= oy && x < ox + sw && y < oy + sh
    outPx px =
      let (y, x) = px `divMod` w
          dBase = px * 4
          dCh c = fromIntegral (BS.index dd (dBase + c)) :: Int
      in if not (inSrc x y)
           then [ BS.index dd (dBase + c) | c <- [0 .. 3] ]
           else let sBase = ((y - oy) * sw + (x - ox)) * 4
                    sCh c = fromIntegral (BS.index sd (sBase + c)) :: Int
                    sa = sCh 3
                    over c = (sCh c * sa + dCh c * (255 - sa) + 127)
                               `div` 255
                    a = sa + (dCh 3 * (255 - sa) + 127) `div` 255
                in map (fromIntegral . over) [0, 1, 2]
                     ++ [fromIntegral a]
