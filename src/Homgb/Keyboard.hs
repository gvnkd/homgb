{-# LANGUAGE OverloadedStrings #-}

-- | X11 keyboard layout manager (M3).
--
-- Switching and group queries go through XCB (xcb-xkb group lock)
-- instead of shelling out to setxkbmap; see design_docs/milestone_3.md.
-- One Xlib connection (separate XCB connection) owns the global
-- hotkey grab: SDL cannot grab global keys, so a forkIO thread blocks
-- in nextEvent and rotates the group via XCB on KeyPress. The render
-- loop polls the group (cheap xcb request, rate-limited to 1/s) so
-- switches made outside homgb still show up in the tray indicator.
module Homgb.Keyboard
  ( LayoutState(..)
  , KeyboardEnv(..)
  , startKeyboard
  , currentLayout
  , pollGroup
  , rotateLayout
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forever, when)
import Data.Bits ((.|.))
import Data.Char (toLower)
import Data.List (foldl')
import Data.List.Split (splitOn)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, hFlush, stderr)

import Graphics.X11.Xlib (Display)
import Graphics.X11.Xlib.Display (openDisplay, defaultRootWindow)
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Event (allocaXEvent, nextEvent, get_EventType)
import Graphics.X11.Xlib.Misc (grabKey, keysymToKeycode, stringToKeysym)
import Graphics.X11.Types
  (KeySym, KeyMask, controlMask, shiftMask, mod1Mask, mod4Mask
  , grabModeAsync, keyPress)

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
      startGrab config kb
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

-- Hotkey grab ---------------------------------------------------------

-- | @"ctrl-shift-space"@ -> (keysym, modifier mask). One grab per
-- exact modifier combination; no anyModifier (steals keys from apps).
-- Xlib's default error handler exits the process on any X error;
-- install ours so a failed grab (combo taken, e.g. by another homgb)
-- logs and leaves the app running without the hotkey.
foreign import ccall "homgb_x_ignore_errors" c_ignore_errors
  :: Display -> IO ()

startGrab :: Config -> KeyboardEnv -> IO ()
startGrab config kb =
  case parseHotkey (configKbHotkey config) of
    Nothing ->
      hPutStrLn stderr $ "keyboard: bad hotkey " ++ show (configKbHotkey config)
    Just (keysym, mods) -> do
      dpy <- openDisplay ""
      c_ignore_errors dpy
      let root = defaultRootWindow dpy
      keycode <- keysymToKeycode dpy keysym
      if keycode == 0
        then hPutStrLn stderr "keyboard: keysym has no keycode"
        else do
          -- the server masks LockMask/Mod2Mask for grab matching, so a
          -- single grab catches the combo with caps/num lock either way
          grabKey dpy keycode mods root False grabModeAsync grabModeAsync
          _ <- forkIO $ eventLoop dpy kb
          hPutStrLn stderr $ "keyboard: grabbed " ++ configKbHotkey config

-- | Block in nextEvent; any KeyPress on our grab is the hotkey.
eventLoop :: Display -> KeyboardEnv -> IO ()
eventLoop dpy kb = forever $
  allocaXEvent $ \ev -> do
    nextEvent dpy ev
    evType <- get_EventType ev
    when (evType == keyPress) $ rotateLayout kb

parseHotkey :: String -> Maybe (KeySym, KeyMask)
parseHotkey str =
  case splitOn "-" str of
    [] -> Nothing
    parts -> do
      let (modParts, keyParts) = splitAt (length parts - 1) parts
      keyPart <- case keyParts of
        [k] -> Just k
        _ -> Nothing
      mods <- mapM modifier modParts
      keysym <- keySym keyPart
      return (keysym, foldl' (.|.) 0 mods)
  where
    modifier m = case map toLower m of
      "ctrl" -> Just controlMask
      "control" -> Just controlMask
      "shift" -> Just shiftMask
      "alt" -> Just mod1Mask
      "mod1" -> Just mod1Mask
      "super" -> Just mod4Mask
      "win" -> Just mod4Mask
      "mod4" -> Just mod4Mask
      _ -> Nothing
    keySym k =
      let sym = stringToKeysym k
      in if sym == 0 then Nothing else Just sym
