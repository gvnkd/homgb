{-# LANGUAGE OverloadedStrings #-}

-- | X11 keyboard layout manager (M3, revised).
--
-- Switching and group queries go through XCB (xcb-xkb group lock)
-- instead of shelling out to setxkbmap; see design_docs/milestone_3.md.
-- There is NO global key grab: the WM (or anything) binds shortcuts
-- and calls the DBus control interface (Homgb.Control), e.g.
-- `busctl --user call org.homgb /org/homgb/Control org.homgb.Control
-- NextLayout` - which also works on Wayland, where XGrabKey cannot
-- see other apps' input. The render loop polls the group (cheap xcb
-- request, rate-limited to 1/s) so switches made outside homgb still
-- show up in the tray indicator.
module Homgb.Keyboard
  ( LayoutState(..)
  , KeyboardEnv(..)
  , startKeyboard
  , currentLayout
  , pollGroup
  , rotateLayout
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (when)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
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
  }

-- | Layout name for the current group ("us"); "" when unknown.
currentLayout :: LayoutState -> T.Text
currentLayout s = case drop (lsGroup s) (lsLayouts s) of
  (l:_) -> l
  [] -> ""

startKeyboard :: Config -> IO (Maybe KeyboardEnv)
startKeyboard config = do
  mSwitch <- Xcb.connect
  mPoll <- Xcb.connect
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
      let kb = KeyboardEnv
            { kbState = tState
            , kbSwitchConn = switchConn
            , kbPollConn = pollConn
            }
      return (Just kb)
    _ -> do
      hPutStrLn stderr "keyboard: failed to open xcb connection"
      return Nothing

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
          debugLn $ "keyboard: group -> " ++ show next
        else hPutStrLn stderr "keyboard: xcb lock group failed"

debugLn :: String -> IO ()
debugLn msg = do
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr msg >> hFlush stderr
    Nothing -> return ()

-- | Re-read the locked group if the cached value is older than 1s.
-- Called every frame from the tray indicator; the rate limit keeps
-- it to ~1 xcb roundtrip per second.
pollGroup :: KeyboardEnv -> IO ()
pollGroup kb = do
  now <- getCurrentTime
  s <- readTVarIO (kbState kb)
  when (diffUTCTime now (lsQueriedAt s) > 1) $ do
    mGroup <- Xcb.group (kbPollConn kb)
    atomically $ modifyTVar' (kbState kb) $ \st ->
      st { lsGroup = maybe (lsGroup st) id mGroup, lsQueriedAt = now }
