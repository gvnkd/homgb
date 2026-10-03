{-# LANGUAGE ScopedTypeVariables #-}

-- | XEmbed system-tray host (the legacy X11 tray protocol alongside
-- SNI). homgb owns the _NET_SYSTEM_TRAY_S0 selection and announces
-- itself with the ICCCM MANAGER broadcast, so already-running apps
-- (Telegram-desktop, Electron clients in XEmbed mode) dock without a
-- restart. Docked icons are foreign X windows reparented into slot
-- children of the tray surface — they draw and receive input
-- themselves; homgb only lays the slots out and tracks their
-- lifecycle. See cbits/homgb-tray-embed.c.
module Homgb.Tray.Embed
  ( EmbedState
  , XEmbedIcon(..)
  , acquireTraySelection
  , newEmbedState
  , pumpEmbedEvents
  , layoutEmbedIcons
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, modifyTVar')
import Control.Exception (IOException, catch)
import Control.Monad (forM_, when)
import Foreign.C.Types (CLong(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Graphics.X11.Types (Window)
import Graphics.X11.Xlib.Types (Display(..))
import System.IO (hPutStrLn, stderr)

-- | One docked XEmbed icon: the foreign client window and the slot
-- window it is reparented into (a child of the tray surface).
data XEmbedIcon = XEmbedIcon
  { eiClient :: Window
  , eiSlot :: Window
  }

-- | State of the tray selection (acquired once, pumped per frame).
data EmbedState = EmbedState
  { esDisplay :: Display
  , esTrayWindow :: Window
    -- ^ the tray surface's X window (parent of the slots)
  , esTimestamp :: CLong
  , esOpcodeAtom :: CLong

  }

-- | Try to become the XEmbed tray host on the given display/tray
-- window. Returns Nothing (with a log line) when another tray owns
-- the selection or there is no display.
acquireTraySelection :: Display -> Window -> IO (Maybe EmbedState)
acquireTraySelection dpy trayWin = do
  res <- alloca $ \ownerPtr -> alloca $ \tsPtr -> do
    ok <- c_acquire dpy trayWin 0 ownerPtr tsPtr
    if ok == 0 then return Nothing
      else Just <$> ((,) <$> peek ownerPtr <*> peek tsPtr)
  case res of
    Nothing -> do
      hPutStrLn stderr
        "tray: XEmbed selection owned by another tray (trayer?); XEmbed icons disabled"
      return Nothing
    Just (o, ts) -> do
      atom <- c_opcode_atom dpy
      hPutStrLn stderr "tray: XEmbed host active"
      return (Just (EmbedState dpy trayWin ts atom))

-- | The docked-icon list lives in a plain TVar the renderer reads
-- (length) and mutates (dock/undock) per frame.
newEmbedState :: IO (TVar [XEmbedIcon])
newEmbedState = newTVarIO []

-- | Drain pending dock/undock events. Call once per frame from the
-- render thread (XCheckMaskEvent is cheap when idle). `slotPos` maps
-- a docked icon's index to its (x, y, size) in tray-surface-local
-- pixels.
pumpEmbedEvents :: EmbedState -> TVar [XEmbedIcon]
                -> (Int -> (Int, Int, Int)) -> IO ()
pumpEmbedEvents env icons slotPos = drain
  where
    dpy = esDisplay env
    drain = do
      mEv <- pollOne
      case mEv of
        Nothing -> return ()
        Just ev -> do
          handle ev
          drain
    pollOne = alloca $ \tPtr -> alloca $ \wPtr -> alloca $ \d0 ->
      alloca $ \d1 -> alloca $ \d2 -> do
        ok <- c_poll dpy tPtr wPtr d0 d1 d2
        if ok == 0 then return Nothing else do
          t <- peek tPtr
          w <- peek wPtr
          a <- peek d0
          b <- peek d1
          c <- peek d2
          return (Just (t, w, a, b, c))
    handle (evType, win, _d0, d1, d2) = do
      if evType == destroyNotifyConst
        then undock win
        else when (evType == esOpcodeAtom env && d1 == 0) $ dock (fromIntegral d2)
    dock client = do
      existing <- readTVarIO icons
      when (client `notElem` map eiClient existing) $ do
        let (x, y, sz) = slotPos (length existing)
        slot <- c_dock dpy (esTrayWindow env) client x y sz (esTimestamp env)
        case slot of
          0 -> hPutStrLn stderr "tray: XEmbed dock failed (client gone?)"
          _ -> do
            atomically $ modifyTVar' icons (++ [XEmbedIcon client slot])
            hPutStrLn stderr "tray: XEmbed icon docked"
    undock w = do
      existing <- readTVarIO icons
      case [ i | i <- existing, eiSlot i == w || eiClient i == w ] of
        [] -> return ()
        (i:_) -> do
          c_undock dpy (eiSlot i) `catch` (\(_ :: IOException) -> return ())
          atomically $ modifyTVar' icons (filter (\j -> eiSlot j /= eiSlot i))
          hPutStrLn stderr "tray: XEmbed icon gone"

destroyNotifyConst :: CLong
destroyNotifyConst = 17 -- Xlib DestroyNotify event type

-- | Move every slot to its layout position (tray-surface-local px).
layoutEmbedIcons :: EmbedState -> TVar [XEmbedIcon]
                 -> (Int -> (Int, Int, Int)) -> IO ()
layoutEmbedIcons env icons slotPos = do
  existing <- readTVarIO icons
  forM_ (zip [0 :: Int ..] existing) $ \(i, icon) -> do
    let (x, y, sz) = slotPos i
    c_move (esDisplay env) (eiSlot icon) x y sz

foreign import ccall "homgb_xembed_acquire" c_acquire
  :: Display -> Window -> Int -> Ptr Window -> Ptr CLong -> IO Int
foreign import ccall "homgb_xembed_opcode_atom" c_opcode_atom
  :: Display -> IO CLong
foreign import ccall "homgb_xembed_dock" c_dock
  :: Display -> Window -> Window -> Int -> Int -> Int -> CLong -> IO Window
foreign import ccall "homgb_xembed_move" c_move
  :: Display -> Window -> Int -> Int -> Int -> IO ()
foreign import ccall "homgb_xembed_undock" c_undock
  :: Display -> Window -> IO ()
foreign import ccall "homgb_xembed_poll" c_poll
  :: Display -> Ptr CLong -> Ptr Window -> Ptr CLong -> Ptr CLong -> Ptr CLong
  -> IO Int
