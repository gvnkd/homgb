{-# LANGUAGE OverloadedStrings #-}

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

import Control.Monad (when)
import Data.Char (isHexDigit, digitToInt)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CFloat(..), CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Directory (doesFileExist, findExecutable)
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
    return font

resolveFont :: Text -> Float -> Bool -> IO (Maybe FontSpec)
resolveFont family sizePx cyrillic = do
  let asPath = T.unpack family
  isFile <- doesFileExist asPath
  mPath <- if isFile
    then return (Just asPath)
    else fcMatch family
  return (fmap (\p -> FontSpec p sizePx cyrillic) mPath)

-- | Resolve a fontconfig family to a file path.
fcMatch :: Text -> IO (Maybe FilePath)
fcMatch family = do
  mFc <- findExecutable "fc-match"
  case mFc of
    Nothing -> return Nothing
    Just fc -> do
      out <- readCreateProcess (proc fc ["-f", "%{file}", T.unpack family]) ""
      let path = trim out
      if null path
        then return Nothing
        else do
          ok <- doesFileExist path
          return (if ok then Just path else Nothing)
  where
    trim = dropWhileEnd' isSpace' . dropWhile isSpace'
    dropWhileEnd' p = foldr (\x xs -> if p x && null xs then [] else x : xs) []
    isSpace' c = c == ' ' || c == '\n' || c == '\t'

-- | Parse @#RRGGBB@ or @#RRGGBBAA@ into an 'ImVec4'.
parseHexColor :: Text -> Maybe ImVec4
parseHexColor t0 = do
  let t = T.dropWhile (== '#') t0
  if T.length t /= 6 && T.length t /= 8 then Nothing else do
    let ds = map hexVal (T.unpack t)
    if any (== -1) ds then Nothing else
      let [r, g, b, a] = case ds of
            [r1, r2, g1, g2, b1, b2] ->
              [pair r1 r2, pair g1 g2, pair b1 b2, 255]
            [r1, r2, g1, g2, b1, b2, a1, a2] ->
              [pair r1 r2, pair g1 g2, pair b1 b2, pair a1 a2]
            _ -> [0, 0, 0, 255]
      in Just (ImVec4 (r / 255) (g / 255) (b / 255) (a / 255))
  where
    hexVal c = if isHexDigit c then fromIntegral (digitToInt c) else -1
    pair a b = a * 16 + b

foreign import ccall "homgb_add_font" c_add_font
  :: CString -> CFloat -> CInt -> IO (Ptr ())
