{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Live-tuning widget for the wlroots HDR ITM prototype
-- (patches/wlroots-itm.patch in nix.config). wlroots re-reads
-- @$XDG_RUNTIME_DIR/wlr-hdr-itm.conf@ every frame (mtime-cached) and
-- its values override WLR_HDR_ITM_* for that frame; a value change
-- damages the whole scene output so the effect is visible immediately,
-- even on a static screen.
--
-- The widget renders into the bar row: an enable checkbox, target/sdr
-- nits sliders, and a mode cycling button (boost = linear luminance
-- gain, curve = luma-only gain with a highlight shoulder, bt2446a =
-- ITM). Every change rewrites the file; startup reads it back (plus
-- the WLR_HDR_ITM_* env as defaults) so the tuning survives homgb
-- restarts.
module Homgb.HdrTune
  ( HdrTune(..)
  , HdrTuneState(..)
  , newHdrTune
  , hdrTuneWidth
  , renderHdrTune
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (IOException, catch)
import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Text.Read (double)
import DearImGui hiding (begin, w)
import qualified DearImGui.Raw as Raw
import Foreign.C.Types (CBool(..), CFloat(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek, poke)
import Homgb.Bar (framePadX, framePadY, sameLineS)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

data HdrTuneState = HdrTuneState
  { htEnable :: Bool
  , htSdr :: Float
  , htTarget :: Float
  , htMode :: Int
    -- ^ 0 = bt2446a ITM, 1 = linear boost, 2 = luma curve
  } deriving (Show, Eq)

data HdrTune = HdrTune
  { htConfPath :: FilePath
  , htVar :: TVar HdrTuneState
  }

-- | Resolve the conf path and load initial state: WLR_HDR_ITM_* env as
-- defaults, then the conf file on top. Nothing without XDG_RUNTIME_DIR.
newHdrTune :: IO (Maybe HdrTune)
newHdrTune = do
  mDir <- lookupEnv "XDG_RUNTIME_DIR"
  case mDir of
    Nothing -> return Nothing
    Just dir -> do
      let path = dir </> "wlr-hdr-itm.conf"
      sdr <- envFloat "WLR_HDR_ITM_SDR_NITS" 203
      target <- envFloat "WLR_HDR_ITM_TARGET_NITS" 800
      mode <- envMode
      st <- readConf path (HdrTuneState True sdr target mode)
      var <- newTVarIO st
      return (Just (HdrTune path var))
  where
    envMode = do
      m <- lookupEnv "WLR_HDR_ITM_MODE"
      return $ case m of
        Just "bt2446a" -> 0
        Just "curve" -> 2
        _ -> 1
    envFloat name def = do
      m <- lookupEnv name
      return $ case m of
        Just s -> fst' (double (T.pack s)) def
        Nothing -> def
    fst' (Right (n, _)) _ = realToFrac n
    fst' _ def = def

-- | Pre-Begin width measure (the layout anchor math runs outside
-- Begin; all widths are analytic — the same constants the renderer
-- uses). `gap` is the inter-widget spacing (tray spacing).
hdrTuneWidth :: Float -> IO Float
hdrTuneWidth gap = do
  ImVec2 hw hh <- calcTextSize "HDR" True 0
  ImVec2 tw _ <- calcTextSize "tgt" True 0
  ImVec2 sw _ <- calcTextSize "sdr" True 0
  ImVec2 bw _ <- calcTextSize "bt2446a" True 0
  let sq = hh + 2 * framePadY
      checkW = sq + 4 + hw
      sliderW lblW = 90 + 4 + lblW
      btnW = bw + 2 * framePadX
  return (checkW + sliderW tw + sliderW sw + btnW + 3 * gap)

-- | Draw the widget row and persist every change to the conf file.
renderHdrTune :: HdrTune -> Float -> IO ()
renderHdrTune ht gap = do
  st <- readTVarIO (htVar ht)
  (enChanged, en) <- alloca $ \p -> do
    poke p (CBool (if htEnable st then 1 else 0))
    changed <- BS.useAsCString "HDR##ht-en" (\l -> Raw.checkbox l p)
    v <- peek p
    return (changed, unCB v)
  sameLineS gap
  Raw.setNextItemWidth 90
  (tgChanged, tg) <- alloca $ \p -> do
    poke p (CFloat (htTarget st))
    changed <- BS.useAsCString "tgt##ht" $ \l ->
      BS.useAsCString "%.0f" $ \fmt ->
        Raw.sliderFloat l p 203 1000 fmt
    v <- peek p
    return (changed, unCF v)
  sameLineS gap
  Raw.setNextItemWidth 90
  (sdChanged, sd) <- alloca $ \p -> do
    poke p (CFloat (htSdr st))
    changed <- BS.useAsCString "sdr##ht" $ \l ->
      BS.useAsCString "%.0f" $ \fmt ->
        Raw.sliderFloat l p 80 300 fmt
    v <- peek p
    return (changed, unCF v)
  sameLineS gap
  modeChanged <- BS.useAsCString (modeLabel (htMode st)) $ \l ->
    Raw.smallButton l
  when (enChanged || tgChanged || sdChanged || modeChanged) $ do
    let st' = st
          { htEnable = if enChanged then en else htEnable st
          , htTarget = if tgChanged then tg else htTarget st
          , htSdr = if sdChanged then sd else htSdr st
          , htMode = if modeChanged then (htMode st + 1) `mod` 3 else htMode st
          }
    atomically $ writeTVar (htVar ht) st'
    writeConf (htConfPath ht) st'
  where
    unCB (CBool v) = v /= 0
    unCF (CFloat v) = v
    modeLabel m =
      ([ "bt2446a##ht", "boost##ht", "curve##ht" ] :: [BS.ByteString]) !! m

writeConf :: FilePath -> HdrTuneState -> IO ()
writeConf path st =
  writeFile path $
    "enable=" ++ (if htEnable st then "1" else "0") ++ "\n"
    ++ "sdr_nits=" ++ show (round (htSdr st) :: Int) ++ "\n"
    ++ "target_nits=" ++ show (round (htTarget st) :: Int) ++ "\n"
    ++ "mode=" ++ (["bt2446a", "boost", "curve"] !! htMode st) ++ "\n"

readConf :: FilePath -> HdrTuneState -> IO HdrTuneState
readConf path def = do
  contents <- readFile path `catch` \(_ :: IOException) -> return ""
  return (foldl' apply def (map parseLine (lines contents)))
  where
    parseLine l = case break (== '=') l of
      (k, '=':v) -> Just (k, v)
      _ -> Nothing
    apply st (Just (k, v)) = case k of
      "enable" -> st { htEnable = v /= "0" }
      "sdr_nits" -> maybe st (\n -> st { htSdr = n }) (readNum v)
      "target_nits" -> maybe st (\n -> st { htTarget = n }) (readNum v)
      "mode" -> st { htMode = case v of
        "boost" -> 1
        "curve" -> 2
        _ -> 0 }
      _ -> st
    apply st Nothing = st
    readNum s = case double (T.pack s) of
      Right (n, rest) | T.null (T.dropAround (== ' ') rest) -> Just (realToFrac n)
      _ -> Nothing
