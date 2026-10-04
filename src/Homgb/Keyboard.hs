{-# LANGUAGE OverloadedStrings #-}

-- | X11 keyboard layout manager (M3, revised).
--
-- Switching and group queries go through XCB (xcb-xkb group lock)
-- instead of shelling out to setxkbmap; see design_docs/milestone_3.md.
-- There is NO global key grab: the WM (or anything) binds shortcuts
-- and calls the DBus control interface (Homgb.Control), e.g.
-- `busctl --user call org.homgb /org/homgb/Control org.homgb.Control
-- NextLayout` - which also works on Wayland, where XGrabKey cannot
-- see other apps' input. Group changes arrive event-driven via
-- XCB_XKB_STATE_NOTIFY on a dedicated connection (a thread blocks in
-- xcb_wait_for_event until the server signals a group change), so
-- switches made by ANY means — homgb, caps lock (grp:caps_toggle),
-- Alt+Shift, xkb-switch — update the tray indicator instantly and
-- feed the per-app layout memory. The render loop additionally polls
-- the group (cheap xcb request, rate-limited to 1/s) as a fallback.
module Homgb.Keyboard
  ( LayoutState(..)
  , KeyboardEnv(..)
  , PerAppState(..)
  , KbUi(..)
  , kbToUi
  , startKeyboard
  , currentLayout
  , pollGroup
  , rotateLayout
  , syncFocus
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forever, forM_, void, when)
import Control.Exception (SomeException, try)
import Foreign.C.Types (CLong)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Graphics.X11.Types (Window)
import Graphics.X11.Xlib.Extras (ClassHint, getClassHint, resClass, resName)
import Graphics.X11.Xlib.Types (Display)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, hFlush, stderr)

import Homgb.Config (Config(..))
import qualified Homgb.Keyboard.Xcb as Xcb

data LayoutState = LayoutState
  { lsLayouts :: [T.Text]  -- ^ rotation list ("us", "ru", ...)
  , lsGroup :: Int         -- ^ current XKB locked group (index into lsLayouts)
  , lsQueriedAt :: UTCTime -- ^ last time the group was polled via XCB
  }

data KeyboardEnv = KeyboardEnv
  { kbState :: TVar LayoutState
  , kbSwitchConn :: Xcb.ConnPtr  -- ^ used by the grab thread (rotations)
  , kbPollConn :: Xcb.ConnPtr    -- ^ used by the render loop (indicator)
  , kbEventConn :: Maybe Xcb.ConnPtr
    -- ^ dedicated connection for the XKB state-notify event thread
    -- (a connection is not thread-safe; each thread owns one)
  , kbPerApp :: Maybe PerAppState
    -- ^ Nothing when config keyboard.per-app is off
  }

-- | The UI-facing slice of the keyboard manager: what the tray
-- indicator, the control interface and the per-app restore need.
-- X11 projects 'KeyboardEnv' through 'kbToUi'; the Wayland backend
-- builds one fed by the WM's LayoutChanged signal over dbus (per-app
-- restore there is a no-op for now).
data KbUi = KbUi
  { kbUiState :: TVar LayoutState
  , kbUiRotate :: IO ()
    -- ^ rotate to the next layout (indicator click / NextLayout cmd)
  , kbUiPoll :: IO Bool
    -- ^ the 1s render-loop poll; True when the group changed
  , kbUiSyncFocus :: CLong -> IO Bool
    -- ^ per-app layout restore for the focused window's xid (X11);
    -- False when unsupported or nothing changed
  }

kbToUi :: Display -> KeyboardEnv -> KbUi
kbToUi dpy kb = KbUi
  { kbUiState = kbState kb
  , kbUiRotate = rotateLayout kb
  , kbUiPoll = pollGroup kb
  , kbUiSyncFocus = syncFocus kb dpy
  }

-- | Per-application layout memory (config keyboard.per-app, default on;
-- KDE-style). @paFocus@ caches the last seen focused window and its
-- WM_CLASS so the render loop can diff cheaply; @paGroups@ maps a
-- class name to the group the user last locked while a window of that
-- class was focused. Apps without an entry keep whatever layout is
-- current and get an entry on the first manual switch.
data PerAppState = PerAppState
  { paFocus :: TVar (CLong, T.Text)
  , paGroups :: TVar (Map T.Text Int)
  }

-- | Layout name for the current group ("us"); "" when unknown.
currentLayout :: LayoutState -> T.Text
currentLayout s = case drop (lsGroup s) (lsLayouts s) of
  (l:_) -> l
  [] -> ""

startKeyboard :: Config -> IO () -> IO (Maybe KeyboardEnv)
startKeyboard config wake = do
  mSwitch <- Xcb.connect
  mPoll <- Xcb.connect
  mEvent <- Xcb.connect
  case (mSwitch, mPoll) of
    (Just switchConn, Just pollConn) -> do
      layouts <- case configKbLayouts config of
        [] -> do
          mNames <- Xcb.rulesLayouts switchConn
          return (maybe [] id mNames)
        ls -> return (map T.pack ls)
      mGroup <- Xcb.group switchConn
      now <- getCurrentTime
      tState <- newTVarIO LayoutState
        { lsLayouts = layouts
        , lsGroup = maybe 0 id mGroup
        , lsQueriedAt = now
        }
      pa <- if configKbPerApp config
        then Just <$> (PerAppState <$> newTVarIO (0, "") <*> newTVarIO Map.empty)
        else return Nothing
      let kb = KeyboardEnv
            { kbState = tState
            , kbSwitchConn = switchConn
            , kbPollConn = pollConn
            , kbEventConn = mEvent
            , kbPerApp = pa
            }
      -- event-driven group tracking: block on XKB state-notify
      forM_ mEvent $ \evConn -> do
        ok <- Xcb.selectStateEvents evConn
        if ok
          then do
            debugLn "keyboard: xkb state-notify events subscribed"
            void $ forkIO $ eventLoop wake kb evConn
          else hPutStrLn stderr "keyboard: xkb select events failed"
      return (Just kb)
    _ -> do
      hPutStrLn stderr "keyboard: failed to open xcb connection"
      return Nothing

-- | XKB state-notify listener: blocks until the server reports a
-- group change (homgb lock, caps lock, Alt+Shift, setxkbmap, ...),
-- then adopts it — indicator updates on the next wake, and the new
-- group is attributed to the focused app's per-app entry so EVERY
-- switch method feeds the per-app memory. Dies quietly when the
-- connection closes.
eventLoop :: IO () -> KeyboardEnv -> Xcb.ConnPtr -> IO ()
eventLoop wake kb evConn = forever $ do
  mG <- Xcb.awaitGroup evConn
  case mG of
    Nothing -> return ()
    Just newGroup -> do
      now <- getCurrentTime
      changed <- atomically $ do
        s <- readTVar (kbState kb)
        let changedNow = newGroup /= lsGroup s
        writeTVar (kbState kb)
          s { lsGroup = newGroup, lsQueriedAt = now }
        return changedNow
      -- no-op when the change originated from homgb itself
      -- (rotateLayout/syncFocus already recorded it)
      recordForFocused kb newGroup
      debugLn $ "keyboard: xkb event group -> " ++ show newGroup
      when changed wake

-- | Rotate to the next layout: lock group (current+1) mod n via XCB.
-- Called from the grab thread; also used by indicator clicks.
rotateLayout :: KeyboardEnv -> IO ()
rotateLayout kb = do
  s <- readTVarIO (kbState kb)
  -- refresh the layout list: the rotation list is fetched at startup,
  -- but the user may change layouts (setxkbmap) while homgb runs
  mNames <- Xcb.rulesLayouts (kbSwitchConn kb)
  let layouts = case mNames of
        Just ns@(_:_) -> ns
        _ -> lsLayouts s
  case layouts of
    [] -> hPutStrLn stderr "keyboard: no layouts known, cannot rotate"
    _ -> do
      let next = (lsGroup s + 1) `mod` length layouts
      ok <- Xcb.lockGroup (kbSwitchConn kb) next
      if ok
        then do
          now <- getCurrentTime
          atomically $ modifyTVar' (kbState kb) $ \st ->
            st { lsLayouts = layouts, lsGroup = next, lsQueriedAt = now }
          recordForFocused kb next
          debugLn $ "keyboard: group -> " ++ show next
        else hPutStrLn stderr "keyboard: xcb lock group failed"

-- | Per-app bookkeeping for a manual switch: remember the new group
-- for the focused window's class (no-op without a class or when
-- per-app is off).
recordForFocused :: KeyboardEnv -> Int -> IO ()
recordForFocused kb g = mapM_ record (kbPerApp kb)
  where
    record pa = do
      (_, klass) <- readTVarIO (paFocus pa)
      if T.null klass
        then return ()
        else atomically $ modifyTVar' (paGroups pa) (Map.insert klass g)

debugLn :: String -> IO ()
debugLn msg = do
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr msg >> hFlush stderr
    Nothing -> return ()

-- | Re-read the locked group if the cached value is older than 1s.
-- Called from frameUpkeep when the render loop's 1s deadline fires;
-- returns True when the group actually changed (the tray indicator
-- needs a redraw).
pollGroup :: KeyboardEnv -> IO Bool
pollGroup kb = do
  now <- getCurrentTime
  s <- readTVarIO (kbState kb)
  if diffUTCTime now (lsQueriedAt s) > 1
    then do
      mGroup <- Xcb.group (kbPollConn kb)
      let newGroup = maybe (lsGroup s) id mGroup
      atomically $ modifyTVar' (kbState kb) $ \st ->
        st { lsGroup = newGroup, lsQueriedAt = now }
      return (newGroup /= lsGroup s)
    else return False

-- | Follow the focused window (per-app layout): called from
-- frameUpkeep with the bar's current @barActiveWindow@ read whenever it
-- may have changed. When the focused xid differs from the cached one,
-- reads the new window's WM_CLASS and — if a layout was remembered for
-- that class — locks it (via the render thread's own xcb connection).
-- Returns True when the group actually changed (indicator redraw).
-- Windows without a WM_CLASS (and the no-focus state, xid 0) are
-- ignored: the current layout stays and nothing is remembered.
syncFocus :: KeyboardEnv -> Display -> CLong -> IO Bool
syncFocus kb dpy xid = case kbPerApp kb of
  Nothing -> return False
  Just pa -> do
    (oldXid, _) <- readTVarIO (paFocus pa)
    if oldXid == xid
      then return False
      else do
        klass <- if xid > 0 then windowClass dpy (fromIntegral xid) else return ""
        atomically $ writeTVar (paFocus pa) (xid, klass)
        remembered <-
          if T.null klass
            then return Nothing
            else Map.lookup klass <$> readTVarIO (paGroups pa)
        case remembered of
          Nothing -> return False
          Just g -> do
            s <- readTVarIO (kbState kb)
            if g == lsGroup s
              then return False
              else do
                ok <- Xcb.lockGroup (kbPollConn kb) g
                if ok
                  then do
                    now <- getCurrentTime
                    atomically $ modifyTVar' (kbState kb) $ \st ->
                      st { lsGroup = g, lsQueriedAt = now }
                    debugLn $ "keyboard: per-app " ++ T.unpack klass
                      ++ " -> group " ++ show g
                    return True
                  else return False

-- | WM_CLASS of a window (class part, falling back to the instance
-- name); "" when unreadable (window died mid-read, no class set).
windowClass :: Display -> Window -> IO T.Text
windowClass dpy win = do
  res <- try (getClassHint dpy win) :: IO (Either SomeException ClassHint)
  return $ case res of
    Left _ -> ""
    Right ch ->
      let c = T.pack (resClass ch)
      in if T.null c then T.pack (resName ch) else c
