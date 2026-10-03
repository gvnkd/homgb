{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Application theming: fonts, colors, sizes, margins and paddings.
--
-- The YAML config carries an optional @theme:@ section (flat
-- @colors:@ map with dotted keys like @popup.bg-critical@, plus
-- @sizes:*@ padding). Legacy deadd-compatible keys (@tray.icon-size@,
-- @tray.spacing@) feed the same 'Theme' record; theme values win
-- when both are set. Renderers read only 'Theme', never raw config
-- style keys, so new knobs slot into one place.
module Homgb.Theme
  ( Theme(..)
  , FontSpec(..)
  , mkTheme
  , applyFont
  , themePopupBg
  , themePopupBorder
  , themePopupTitle
  , parseHexColor
  ) where

import Control.Exception (IOException, catch)
import Control.Monad (filterM, forM_, when)
import Data.Char (isHexDigit, digitToInt)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CFloat(..), CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Directory (doesFileExist, findExecutable)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readCreateProcess, proc)
import System.IO (hPutStrLn, stderr)

import DearImGui (ImVec4(..))
import Homgb.Config (Config(..), ThemeConfig(..))
import Homgb.Notifications.Data (Urgency(..))

-- | A font resolved to a file on disk. Applied per ImGui context
-- (each surface context has its own font atlas).
data FontSpec = FontSpec
  { fontPath :: FilePath
  , fontSizePx :: Float
  , fontCyrillic :: Bool
    -- ^ include ImGui's Cyrillic glyph ranges (default font has none)
  } deriving (Show)

-- | Runtime theme: everything renderers need, with all defaults
-- resolved.
data Theme = Theme
  { thFont :: Maybe FontSpec
  , thFontFallbacks :: [Text]
    -- ^ merged into the primary font (glyph fallback: emoji, Nerd
    -- Font icons); same size, resolved the same way
  -- popup palette per urgency
  , thPopupBgLow :: ImVec4
  , thPopupBgNormal :: ImVec4
  , thPopupBgHigh :: ImVec4
  , thPopupBorderLow :: ImVec4
  , thPopupBorderNormal :: ImVec4
  , thPopupBorderHigh :: ImVec4
  , thPopupTitleLow :: ImVec4
  , thPopupTitleNormal :: ImVec4
  , thPopupTitleHigh :: ImVec4
  -- tray menu
  , thMenuBg :: ImVec4
  , thMenuBorder :: ImVec4
  -- status bar (bar layout mode): window background (alpha-aware) and
  -- the right-edge clock/date text colors
  , thBarBg :: ImVec4
  , thBarClock :: ImVec4
  , thBarDate :: ImVec4
  -- status bar border (theme sizes.bar.border-size, 0 = off)
  , thBarBorder :: ImVec4
  , thBarBorderSize :: Float
  -- status bar widget style: separator between left-section items,
  -- bright color for the active/hovered item text, hover tint for
  -- real buttons (keyboard indicator)
  , thBarSeparator :: ImVec4
  , thBarWsActive :: ImVec4
  , thBarButtonHovered :: ImVec4
  -- sizes (icon size / spacing fall back to the legacy config keys)
  , thTrayIconSize :: Int
  , thTraySpacing :: Int
  -- margins / paddings (pixels)
  , thTrayPadX :: Float
  , thTrayPadY :: Float
  , thPopupPadX :: Float
  , thPopupPadY :: Float
  , thMenuPadX :: Float
  , thMenuPadY :: Float
  }

themePopupBg :: Theme -> Urgency -> ImVec4
themePopupBg t Low = thPopupBgLow t
themePopupBg t Normal = thPopupBgNormal t
themePopupBg t High = thPopupBgHigh t

themePopupBorder :: Theme -> Urgency -> ImVec4
themePopupBorder t Low = thPopupBorderLow t
themePopupBorder t Normal = thPopupBorderNormal t
themePopupBorder t High = thPopupBorderHigh t

themePopupTitle :: Theme -> Urgency -> ImVec4
themePopupTitle t Low = thPopupTitleLow t
themePopupTitle t Normal = thPopupTitleNormal t
themePopupTitle t High = thPopupTitleHigh t

-- The raw @theme:@ section parser lives in Homgb.Config (Config
-- carries a ThemeConfig field; Theme would otherwise import Config
-- circularly).
-- | Build the runtime theme: merge config over defaults, resolve the
-- font file (a path, or a fontconfig family via @fc-match@).
mkTheme :: Config -> IO Theme
mkTheme config = do
  font <- case tcFontFamily tc of
    Nothing -> return Nothing
    Just fam -> resolveFont fam (fromMaybe 14 (tcFontSize tc))
                (fromMaybe False (tcFontCyrillic tc))
  return Theme
    { thFont = font
    , thFontFallbacks = fromMaybe [] (tcFontFallbacks tc)
    , thPopupBgLow = color "popup.bg-low" (ImVec4 0.10 0.10 0.11 1.0)
    , thPopupBgNormal = color "popup.bg" (ImVec4 0.13 0.14 0.15 1.0)
    , thPopupBgHigh = color "popup.bg-critical" (ImVec4 0.16 0.11 0.11 1.0)
    , thPopupBorderLow = color "popup.border-low" (ImVec4 0.20 0.20 0.22 1.0)
    , thPopupBorderNormal = color "popup.border" (ImVec4 0.25 0.26 0.28 1.0)
    , thPopupBorderHigh = color "popup.border-critical" (ImVec4 0.80 0.20 0.20 1.0)
    , thPopupTitleLow = color "popup.title-low" (ImVec4 0.75 0.75 0.75 1.0)
    , thPopupTitleNormal = color "popup.title" (ImVec4 0.90 0.90 0.90 1.0)
    , thPopupTitleHigh = color "popup.title-critical" (ImVec4 0.95 0.40 0.40 1.0)
    , thMenuBg = color "menu.bg" (ImVec4 0.20 0.24 0.32 0.97)
    , thMenuBorder = color "menu.border" (ImVec4 0.55 0.62 0.78 0.90)
    , thBarBg = color "bar.bg" (ImVec4 0.09 0.10 0.11 0.85)
    , thBarClock = color "bar.clock" (ImVec4 0.95 0.95 0.95 1.0)
    , thBarDate = color "bar.date" (ImVec4 0.55 0.58 0.62 1.0)
    , thBarBorder = color "bar.border" (ImVec4 0.43 0.43 0.50 0.50)
    , thBarBorderSize = fromMaybe 0 (tcBarBorderSize tc)
    , thBarSeparator = color "bar.separator" (ImVec4 0.42 0.44 0.48 1.0)
    , thBarWsActive = color "bar.ws-active" (ImVec4 0.95 0.95 0.95 1.0)
    , thBarButtonHovered = color "bar.button-hovered" (ImVec4 1.0 1.0 1.0 0.10)
    , thTrayIconSize = fromMaybe (configTrayIconSize config) (tcTrayIconSize tc)
    , thTraySpacing = fromMaybe (configTraySpacing config) (tcTraySpacing tc)
    , thTrayPadX = fromMaybe 8 (tcTrayPadX tc)
    , thTrayPadY = fromMaybe 8 (tcTrayPadY tc)
    , thPopupPadX = fromMaybe 8 (tcPopupPadX tc)
    , thPopupPadY = fromMaybe 8 (tcPopupPadY tc)
    , thMenuPadX = fromMaybe 8 (tcMenuPadX tc)
    , thMenuPadY = fromMaybe 8 (tcMenuPadY tc)
    }
  where
    tc = configTheme config
    color key def = maybe def id (parseHexColor =<< Map.lookup key (tcColors tc))

-- | Add the theme font to the CURRENT ImGui context (call once per
-- surface context, before the renderer builds the font atlas). No-op
-- when no font is configured; ImGui's default font is the fallback.
-- Returns the loaded ImFont* (nullPtr when no font / load failed) so
-- widgets can draw with explicit sizes via PushFont(font, size).
applyFont :: Theme -> IO (Ptr ())
applyFont theme = case thFont theme of
  Nothing -> return nullPtr
  Just fs -> withCString (fontPath fs) $ \pathPtr -> do
    font <- c_add_font pathPtr (realToFrac (fontSizePx fs))
            (if fontCyrillic fs then 1 else 0)
    when (font == nullPtr) $
      hPutStrLn stderr $ "theme: failed to load font " ++ fontPath fs
    -- merged fallbacks: glyphs the primary lacks (emoji, NF icons);
    -- each family may resolve to several candidates (e.g. color vs
    -- outline emoji) — merge the first that loads
    forM_ (thFontFallbacks theme) $ \fam ->
      mergeFallback (fontSizePx fs) fam
    return font

resolveFont :: Text -> Float -> Bool -> IO (Maybe FontSpec)
resolveFont family sizePx cyrillic = do
  let asPath = T.unpack family
  isFile <- doesFileExist asPath
  okFile <- if isFile then loadableFontFile asPath else return False
  mPath <- if okFile
    then return (Just asPath)
    else do
      cands <- fcCandidates family
      return (listToMaybe cands)
  return (fmap (\p -> FontSpec p sizePx cyrillic) mPath)

-- | All candidate files for a fontconfig family. Served from a
-- memoized one-shot `fc-list` font database: on font-heavy systems
-- (google-fonts etc.) a single fontconfig pass over a cold cache
-- takes tens of seconds and must NEVER be repeated (measured: ~60K
-- syscalls per lookup, and homgb resolves 1+n-fallbacks per surface
-- context). Exact family name matches only; if none, ask fc-match
-- for its single best match (rare path).
fcCandidates :: Text -> IO [FilePath]
fcCandidates family = do
  db <- fontDb
  let exact = [ f | (fam, f) <- db, fam == T.toLower family ]
  cands <-
    if null exact
      then fcMatchBest family
      else return (nub exact)
  filterM loadableFontFile cands

-- | Memoized (lower-cased family, file) pairs from ONE fc-list pass.
fontDb :: IO [(Text, FilePath)]
fontDb = do
  cached <- readIORef fontDbRef
  case cached of
    Just db -> return db
    Nothing -> do
      db <- query
      writeIORef fontDbRef (Just db)
      return db
  where
    query = do
      mFc <- findExecutable "fc-list"
      case mFc of
        Nothing -> return []
        Just fc -> do
          out <- readCreateProcess
            (proc fc ["-f", "%{file}\t%{family}\n"]) ""
            `catch` (\(_ :: IOException) -> return "")
          return
            [ (T.toLower (T.dropWhile (== ' ') fam), path)
            | l <- lines out
            , (path, fams) <- [splitTab l]
            , not (null path)
            , fam <- splitComma (T.pack fams)
            ]
    splitTab l = case break (== '\t') l of
      (p, _ : rest) -> (p, rest)
      _ -> ("", "")
    splitComma t = case T.break (== ',') t of
      (a, _) | T.null a -> []
      (a, rest) -> a : if T.null rest then []
                       else splitComma (T.drop 1 rest)

{-# NOINLINE fontDbRef #-}
fontDbRef :: IORef (Maybe [(Text, FilePath)])
fontDbRef = unsafePerformIO (newIORef Nothing)

-- | The single best-matching file for a family/pattern (only used
-- when the font database has no exact family match).
fcMatchBest :: Text -> IO [FilePath]
fcMatchBest family = do
  mFc <- findExecutable "fc-match"
  case mFc of
    Nothing -> return []
    Just fc -> do
      out <- readCreateProcess
        (proc fc ["-f", "%{file}", T.unpack family]) ""
      let path = dropWhileEnd' isSpace' (dropWhile isSpace' out)
      return (if null path then [] else [path])
  where
    dropWhileEnd' p = foldr (\c cs -> if p c && null cs then [] else c : cs) []
    isSpace' c = c == ' ' || c == '\n' || c == '\t'

-- | Stb/ImGui can only rasterize TrueType-outline fonts: reject CFF
-- ('OTTO') and bitmap-emoji ('CBDT'/'CBLC'/'sbix') sfnts — passing
-- those to AddFontFromFileTTF ABORTS the process via IM_ASSERT, so
-- candidates must be filtered before any load attempt. Reads just
-- the sfnt table directory.
loadableFontFile :: FilePath -> IO Bool
loadableFontFile path = inspect `catch` (\(_ :: IOException) -> return False)
  where
    inspect = do
      bs <- BS.readFile path
      if BS.length bs < 12 then return False else do
        let version = BS.take 4 bs
            nTables = fromIntegral (be16 (BS.drop 4 bs)) :: Int
            entry i = BS.take 16 (BS.drop (12 + 16 * i) bs)
            tags = [ BS.take 4 (entry i) | i <- [0 .. nTables - 1]
                   , BS.length (entry i) == 16 ]
        return (version /= "OTTO" && version /= "ttcf"
          && "glyf" `elem` tags
          && all (`notElem` tags) ["CBDT", "CBLC", "sbix"])
      -- NB: variable fonts (gvar/fvar) are fine — stb ignores the
      -- variation tables and rasterizes the default instance
      -- (NotoSans.ttf is variable and loads perfectly). Unparseable
      -- fonts return NULL thanks to -DNDEBUG (no IM_ASSERT abort).
    be16 :: BS.ByteString -> Int
    be16 b = fromIntegral (BS.index b 0) * 256 + fromIntegral (BS.index b 1)
-- | Merge the first loadable candidate of a fallback family into the
-- primary font; glyphs the primary lacks resolve through it. Returns
-- True when a font was merged.
mergeFallback :: Float -> Text -> IO Bool
mergeFallback sizePx family = do
  cands <- do
    let asPath = T.unpack family
    isFile <- doesFileExist asPath
    okFile <- if isFile then loadableFontFile asPath else return False
    if okFile then return [asPath] else fcCandidates family
  go cands
  where
    go [] = do
      hPutStrLn stderr $ "theme: no loadable fallback font for "
        ++ T.unpack family
      return False
    go (p:rest) =
      withCString p $ \pPtr -> do
        ok <- c_add_merged_font pPtr (realToFrac sizePx) 0
        if ok == nullPtr then go rest else return True

-- | Parse @#RRGGBB@ or @#RRGGBBAA@ into an 'ImVec4'.
parseHexColor :: Text -> Maybe ImVec4
parseHexColor t0 = do
  let t = T.dropWhile (== '#') t0
  if T.length t /= 6 && T.length t /= 8 then Nothing else do
    let ds = map hexVal (T.unpack t)
    if any (== -1) ds then Nothing
    else case ds of
      [r1, r2, g1, g2, b1, b2] ->
        Just (mkVec (pair r1 r2) (pair g1 g2) (pair b1 b2) 255)
      [r1, r2, g1, g2, b1, b2, a1, a2] ->
        Just (mkVec (pair r1 r2) (pair g1 g2) (pair b1 b2) (pair a1 a2))
      _ -> Nothing -- unreachable: the length is checked above
  where
    hexVal c = if isHexDigit c then fromIntegral (digitToInt c) else -1
    pair a b = a * 16 + b
    mkVec r g b a = ImVec4 (r / 255) (g / 255) (b / 255) (a / 255)

foreign import ccall "homgb_add_font" c_add_font
  :: CString -> CFloat -> CInt -> IO (Ptr ())
foreign import ccall "homgb_add_merged_font" c_add_merged_font
  :: CString -> CFloat -> CInt -> IO (Ptr ())
