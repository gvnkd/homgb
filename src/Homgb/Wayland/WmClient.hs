{-# LANGUAGE OverloadedStrings #-}

-- | Client for the xmonad-on-river panel service (org.xmonad.WM,
-- XMonad.River.DBus on the WM side). This is the Wayland backend's
-- replacement for every EWMH read and client message: workspace and
-- window state arrives as signals into TVars, clicks and surface
-- placement go out as method calls.
--
-- Wire shapes (design_docs/wayland.md):
--   WorkspacesChanged a(ssb)   (name, current, nonEmpty) — ORDERED
--   WindowsChanged    a(ssssb) (id, title, appId, workspace, focused)
--   FocusChanged      (ss)     (title, appId)
--   LayoutChanged     (ias)    (group, names)
module Homgb.Wayland.WmClient
  ( WmClient(..)
  , startWmClient
  , resolvePseudoIds
  , wmSwitchWorkspace
  , wmFocusWindow
  , wmNextLayout
  , wmSetLayoutGroup
  , wmPlaceSurface
  , wmKbUi
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
  (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (void)
import Data.Int (Int32)
import Data.Maybe (listToMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word64)
import System.IO (hPutStrLn, stderr)

import DBus
  (Variant, fromVariant, methodCall, methodCallBody
  , methodCallDestination, parseMemberName, signalBody, signalMember
  , toVariant, variantType)
import DBus.Client
  (Client, addMatch, callNoReply, connectSession, matchAny, matchInterface)
import DBus.Internal.Types (MemberName)

import Homgb.Keyboard (KbUi(..), LayoutState(..))

data WmClient = WmClient
  { wcClient :: Client
  , wcWake :: IO ()
    -- ^ wake the render loop after signal-driven TVar writes
  , wcWorkspaces :: TVar [(T.Text, Bool, Bool)]
  , wcWindows :: TVar [(T.Text, T.Text, T.Text, T.Text, Bool)]
  , wcFocus :: TVar (T.Text, T.Text)
  , wcLayout :: TVar LayoutState
  , wcPseudoIds :: TVar (Map T.Text Word64)
    -- ^ window identifier -> pseudo xid, assigned in first-seen
    -- order so the taskbar can key clicks the BarState way
  , wcNextId :: TVar Word64
  }

-- | Connect and subscribe. `dirty` is the bar upkeep gate (set on
-- every signal; the upkeep diff suppresses no-change renders) and
-- `wake` re-renders. The initial WorkspacesChanged burst the WM
-- emits during startup lands here without any polling.
startWmClient :: TVar Bool -> IO () -> IO WmClient
startWmClient dirty wake = do
  client <- connectSession
  ws <- newTVarIO []
  wins <- newTVarIO []
  foc <- newTVarIO ("", "")
  now <- getCurrentTime
  layout <- newTVarIO (LayoutState [] 0 now)
  ids <- newTVarIO Map.empty
  nextId <- newTVarIO 1
  let wc = WmClient client wake ws wins foc layout ids nextId
  _ <- addMatch client matchAny { matchInterface = Just "org.xmonad.WM" }
         $ \sig -> do
    let body = signalBody sig
    case signalMember sig of
      "WorkspacesChanged" -> case listToMaybe body of
        Just v | Just x <- fromVariant v -> atomically (writeTVar ws x) >> markDirty
        _ -> parseWarn "WorkspacesChanged" body
      "WindowsChanged" -> case listToMaybe body of
        Just v | Just x <- fromVariant v -> atomically (writeTVar wins x) >> markDirty
        _ -> parseWarn "WindowsChanged" body
      "FocusChanged" -> case listToMaybe body of
        Just v | Just x <- fromVariant v -> atomically (writeTVar foc x) >> markDirty
        _ -> parseWarn "FocusChanged" body
      "LayoutChanged" -> case listToMaybe body of
        Just v | Just (g, names) <- fromVariant v -> do
          t <- getCurrentTime
          atomically $ writeTVar layout LayoutState
            { lsLayouts = map T.pack names
            , lsGroup = fromIntegral (g :: Int32)
            , lsQueriedAt = t
            }
          markDirty
        _ -> parseWarn "LayoutChanged" body
      _ -> return ()
  return wc
  where
    markDirty = atomically (writeTVar dirty True) >> wake
    parseWarn name body = hPutStrLn stderr
      ("homgb: wm: failed to parse " ++ name ++ ": "
        ++ show (map variantTypeName body))
    variantTypeName = show . variantType

-- | Assign pseudo xids to any not-yet-seen identifiers; returns the
-- resolved pairs. Called from the bar upkeep (single-threaded there).
resolvePseudoIds :: WmClient -> [T.Text] -> IO [(T.Text, Word64)]
resolvePseudoIds wc idents = atomically $ do
  m <- readTVar (wcPseudoIds wc)
  n0 <- readTVar (wcNextId wc)
  let new = [ i | i <- idents, Map.notMember i m ]
      m' = Map.union m (Map.fromList (zip new [n0 ..]))
  writeTVar (wcPseudoIds wc) m'
  writeTVar (wcNextId wc) (n0 + fromIntegral (length new))
  return [ (i, m' Map.! i) | i <- idents ]

-- method proxies (fire-and-forget: callNoReply never blocks on a
-- reply, so these are safe from the render thread)
wmSwitchWorkspace :: WmClient -> T.Text -> IO ()
wmSwitchWorkspace wc name = send wc "SwitchWorkspace" [toVariant name]

wmFocusWindow :: WmClient -> T.Text -> IO ()
wmFocusWindow wc ident = send wc "FocusWindow" [toVariant ident]

wmNextLayout :: WmClient -> IO ()
wmNextLayout wc = send wc "NextLayout" []

wmSetLayoutGroup :: WmClient -> Int -> IO ()
wmSetLayoutGroup wc g =
  send wc "SetLayoutGroup" [toVariant (fromIntegral g :: Int32)]

wmPlaceSurface :: WmClient -> String -> Int -> Int -> Int -> Int -> Int -> IO ()
wmPlaceSurface wc appId x y w h stackOrder =
  send wc "PlaceSurface"
    [ toVariant appId
    , toVariant (fromIntegral x :: Int32)
    , toVariant (fromIntegral y :: Int32)
    , toVariant (fromIntegral w :: Int32)
    , toVariant (fromIntegral h :: Int32)
    , toVariant (fromIntegral stackOrder :: Int32)
    ]

send :: WmClient -> String -> [Variant] -> IO ()
send wc member args =
  void $ callNoReply (wcClient wc)
    (methodCall "/org/xmonad/WM" "org.xmonad.WM" (fromStringM member))
    { methodCallDestination = Just "org.xmonad.WM"
      -- without a Destination the bus never DELIVERS the call (a
      -- monitor still sees it — this cost an evening)
    , methodCallBody = args
    }

-- | The keyboard indicator's data source: LayoutChanged feeds the
-- state TVar; rotate goes to the WM; the 1s poll is a no-op (signals
-- already wake the loop).
wmKbUi :: WmClient -> KbUi
wmKbUi wc = KbUi
  { kbUiState = wcLayout wc
  , kbUiRotate = wmNextLayout wc
  , kbUiPoll = return False
  , kbUiSyncFocus = \_ -> return False
  }

fromStringM :: String -> MemberName
fromStringM s = case parseMemberName s of
  Just m -> m
  Nothing -> error ("homgb: invalid member name " ++ s)
