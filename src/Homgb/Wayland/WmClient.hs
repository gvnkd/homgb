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
  (TVar, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void, when)
import Data.Int (Int32)
import Data.Maybe (listToMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word64)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import DBus
  (Signal, Variant, fromVariant, methodCall, methodCallBody
  , methodCallDestination, parseMemberName, signalBody, signalMember
  , toVariant, variantType)
import DBus.Client
  (Client, addMatch, callNoReply, connectSession, matchAny, matchInterface)
import DBus.Internal.Types (MemberName)

import Homgb.Keyboard (KbUi(..), LayoutState(..), PerAppState(..))

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
  , wcPerApp :: Maybe PerAppState
    -- ^ per-app layout memory (config keyboard.per-app); fed by the
    -- FocusChanged/LayoutChanged handlers, keyed by app_id
  , wcDebug :: Maybe String
  }

-- | Connect and subscribe. `dirty` is the bar upkeep gate (set on
-- every signal; the upkeep diff suppresses no-change renders) and
-- `wake` re-renders. The initial WorkspacesChanged burst the WM
-- emits during startup lands here without any polling. `perApp`
-- enables the per-application layout memory (config
-- keyboard.per-app).
startWmClient :: TVar Bool -> IO () -> Bool -> IO WmClient
startWmClient dirty wake perApp = do
  client <- connectSession
  ws <- newTVarIO []
  wins <- newTVarIO []
  foc <- newTVarIO ("", "")
  now <- getCurrentTime
  layout <- newTVarIO (LayoutState [] 0 now)
  ids <- newTVarIO Map.empty
  nextId <- newTVarIO 1
  pa <- if perApp
    then Just <$> (PerAppState <$> newTVarIO ("", "") <*> newTVarIO Map.empty)
    else return Nothing
  dbg <- lookupEnv "HOMGB_DEBUG"
  let wc = WmClient client wake ws wins foc layout ids nextId pa dbg
  subResult <- try
    (addMatch client matchAny { matchInterface = Just "org.xmonad.WM" }
       (\sig -> do
          r <- try (handleSignal wc dirty sig)
            :: IO (Either SomeException ())
          case r of
            Left e -> hPutStrLn stderr
              ("homgb: wm: handler exc: " ++ show e)
            Right () -> return ()))
  case subResult of
    Left e -> hPutStrLn stderr
      ("homgb: wm: addMatch FAILED: " ++ show (e :: SomeException))
    Right _ -> hPutStrLn stderr "homgb: wm: subscribed to org.xmonad.WM"
  return wc

handleSignal :: WmClient -> TVar Bool -> Signal -> IO ()
handleSignal wc dirty sig = do
  let body = signalBody sig
  case wcDebug wc of
    Just _ -> hPutStrLn stderr
      ("homgb: wm: signal " ++ show (signalMember sig))
    Nothing -> return ()
  case signalMember sig of
      "WorkspacesChanged" -> case listToMaybe body of
        Just v | Just x <- fromVariant v ->
          atomically (writeTVar (wcWorkspaces wc) x) >> markDirty
        _ -> parseWarn "WorkspacesChanged" body
      "WindowsChanged" -> case listToMaybe body of
        Just v | Just x <- fromVariant v ->
          atomically (writeTVar (wcWindows wc) x) >> markDirty
        _ -> parseWarn "WindowsChanged" body
      "FocusChanged" -> case listToMaybe body of
        Just v | Just (t, a) <- fromVariant v -> do
          atomically $ writeTVar (wcFocus wc) (t, a)
          syncFocusApp wc a
          markDirty
        _ -> parseWarn "FocusChanged" body
      "LayoutChanged" -> case listToMaybe body of
        Just v | Just (g, names) <- fromVariant v -> do
          now <- getCurrentTime
          let g' = fromIntegral (g :: Int32)
          atomically $ writeTVar (wcLayout wc) LayoutState
            { lsLayouts = map T.pack names
            , lsGroup = g'
            , lsQueriedAt = now
            }
          recordAppGroup wc g'
          markDirty
        _ -> parseWarn "LayoutChanged" body
      _ -> return ()
  where
    markDirty = atomically (writeTVar dirty True) >> wcWake wc
    parseWarn name body = hPutStrLn stderr
      ("homgb: wm: failed to parse " ++ name ++ ": "
        ++ show (map variantTypeName body))
    variantTypeName = show . variantType

-- | Per-app layout restore, KDE-style (config keyboard.per-app — the
-- X11 feature, ported to this backend's signals): focus changes
-- arrive as FocusChanged(title, app_id), and app_id is this backend's
-- WM_CLASS. When the focused app changes and a group was remembered
-- for it, re-apply the group through the WM.
--
-- Panel and classless focus is IGNORED ENTIRELY, not cached as an
-- empty key: clicking the bar focuses a homgb surface for the moment
-- the WM's focus guard needs to restore the real focus, and a rotate
-- issued by that click would otherwise (a) be recorded against no
-- app, and (b) be reverted by the restore when the app's
-- FocusChanged lands — the user's switch visibly undone. X11 never
-- sees this because its DOCK surfaces never take keyboard focus. The
-- cost: a rotate on an empty desktop updates the last app's entry
-- instead of nothing — harmless, arguably the intent.
syncFocusApp :: WmClient -> T.Text -> IO ()
syncFocusApp wc appId = mapM_ go (wcPerApp wc)
  where
    go pa = do
      let key = if T.null appId || appId == "homgb" then "" else appId
      unless (T.null key) $ do
        (oldKey, _) <- readTVarIO (paFocus pa)
        when (oldKey /= key) $ do
          atomically $ writeTVar (paFocus pa) (key, key)
          remembered <- Map.lookup key <$> readTVarIO (paGroups pa)
          case remembered of
            Nothing -> return ()
            Just g -> do
              cur <- lsGroup <$> readTVarIO (wcLayout wc)
              when (g /= cur) $ do
                wmDebug wc ("wm: per-app " ++ T.unpack key ++ " -> group " ++ show g)
                wmSetLayoutGroup wc g

-- | Every group change feeds the per-app memory — the counterpart of
-- the X11 state-notify listener's recordForFocused, keeping KDE
-- parity: whatever caused the switch (Caps rotation, a restore, an
-- external SetLayoutGroup), the focused app's entry follows it.
recordAppGroup :: WmClient -> Int -> IO ()
recordAppGroup wc g = mapM_ go (wcPerApp wc)
  where
    go pa = do
      (_, klass) <- readTVarIO (paFocus pa)
      unless (T.null klass) $
        atomically $ modifyTVar' (paGroups pa) (Map.insert klass g)

wmDebug :: WmClient -> String -> IO ()
wmDebug wc msg = case wcDebug wc of
  Just _ -> hPutStrLn stderr msg
  Nothing -> return ()

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
-- already wake the loop); per-app restore is signal-driven
-- (syncFocusApp on FocusChanged), not this render-loop hook.
wmKbUi :: WmClient -> KbUi
wmKbUi wc = KbUi
  { kbUiState = wcLayout wc
  , kbUiRotate = wmNextLayout wc
  , kbUiPoll = do
      -- keep lsQueriedAt fresh: nextDeadline adds 1s to it, and a
      -- stale value is a deadline in the past — waitMs clamps to 1ms
      -- and the render loop spins (dbus dispatch starves on -N1)
      now <- getCurrentTime
      atomically $ modifyTVar' (wcLayout wc) (\st -> st { lsQueriedAt = now })
      return False
  , kbUiSyncFocus = \_ -> return False
  }

fromStringM :: String -> MemberName
fromStringM s = case parseMemberName s of
  Just m -> m
  Nothing -> error ("homgb: invalid member name " ++ s)
