{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | The Wayland backend: a plain SDL3 Wayland client that talks to
-- xmonad-on-river over its org.xmonad.WM dbus service
-- (Homgb.Wayland.WmClient). See design_docs/wayland.md.
--
-- What disappears compared to X11: EWMH tagging (surfaces are
-- identified by the SDL window's Wayland app_id, set at creation from
-- the surface name), X map/unmap shims (visibility is SDL state),
-- struts (the WM's layout reserves the strip; this backend only
-- records the rect so popups place below the bar), stacking
-- re-asserts (PlaceSurface stackOrder is a standing request the WM
-- re-applies), window positioning (clients cannot position on
-- Wayland; bkMoveSurface asks the WM), and the XEmbed host (SNI
-- only).
module Homgb.Backend.Wayland (waylandBackend) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', readTVarIO, writeTVar)
import Control.Monad (unless)
import Data.Bits ((.&.))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Word (Word64)
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (peekArray0)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek)
import Linear (V2(..))

import qualified Homgb.SDL3 as SDL3
import SDL3.Sys.Bindgen.Rect (SDL_Rect(..))
import SDL3.Sys.Mouse
  ( pattern SDL_BUTTON_LMASK, pattern SDL_BUTTON_RMASK
  , getGlobalMouseState, getMouseState)
import SDL3.Sys.Video (getDisplayBounds, getDisplays)

import Homgb.Backend
import Homgb.Bar (BarActions(..), BarState(..), WinInfo(..))
import Homgb.Monitors (Monitor(..))
import Homgb.Surface (Surface(..), surfaceWindowSize)
import Homgb.Tray (TrayEnv(..), reapZombieItems)
import Homgb.Wayland.WmClient
  (WmClient(..), resolvePseudoIds, wmFocusWindow, wmKbUi, wmPlaceSurface
  , wmSwitchWorkspace)

-- | homgb surface stacking, lowest to highest; the WM keeps placed
-- surfaces stacked by this (restackWindows re-applies it every
-- frame).
stackOrderOf :: String -> Int
stackOrderOf "homgb-tray" = 1
stackOrderOf "homgb-center" = 2
stackOrderOf "homgb-popups" = 3
stackOrderOf "homgb-tooltip" = 4
stackOrderOf "homgb-menu" = 5
stackOrderOf _ = 1

waylandBackend :: WmClient -> Backend
waylandBackend wc = Backend
  { bkName = "wayland"
  , bkScreenSize = primarySize
  , bkMonitors = sdlMonitors
  , bkTagSurface = \_ _ -> return ()
    -- the Wayland app_id was set at SDL window creation from the
    -- surface name; there is nothing to tag afterwards
  , bkShowSurface = SDL3.showWindow . sWindow
  , bkHideSurface = SDL3.hideWindow . sWindow
  , bkStartEmbedHost = \_ _ _ -> return ()
    -- SNI-only under Wayland: no XEmbed protocol exists (design
    -- decision, design_docs/wayland.md)
  , bkStartBarEvents = \_ _ -> return ()
    -- the WM client sets the dirty flag from its signal handlers
  , bkBarUpkeep = barUpkeep wc
  , bkBarActions = waylandBarActions wc
  , bkUpdateStrut = recordStrut
  , bkMoveSurface = moveSurface wc
  , bkPollPointer = sdlPointer
  , bkPressEdge = pressEdgeSDL
  , bkStartKeyboard = \_ _ -> return (Just (wmKbUi wc))
  }

-- | Button-edge detection from SDL state: button events reach SDL
-- for homgb's own surfaces (the only place a menu interaction can
-- happen anyway). The global position is valid over homgb's own
-- surfaces; elsewhere it goes stale — accept it: unlike X11, a
-- click on a FOREIGN window cannot close the menu (Wayland hides
-- foreign input), the menu stays open until an item or its own
-- surface is clicked.
pressEdgeSDL :: TVar (Bool, Bool) -> IO (Bool, Int, Int)
pressEdgeSDL prevVar = do
  prev <- readTVarIO prevVar
  (bx, by, btns) <- alloca $ \xPtr -> alloca $ \yPtr -> do
    b <- getMouseState xPtr yPtr
    x <- peek xPtr
    y <- peek yPtr
    return (realToFrac (x :: CFloat) :: Double
           ,realToFrac (y :: CFloat) :: Double, b)
  let left = (btns .&. SDL_BUTTON_LMASK) /= 0
      right = (btns .&. SDL_BUTTON_RMASK) /= 0
  atomically $ writeTVar prevVar (left, right)
  let pressed = (left && not (fst prev)) || (right && not (snd prev))
  return (pressed, floor bx, floor by)

-- | Translate the signal TVars into the BarState the renderers read.
-- barPid stays 0: own-surface filtering is by app_id prefix below
-- (homgb's surfaces are ordinary river windows).
barUpkeep :: WmClient -> BarUpkeep -> IO (Bool, Bool)
barUpkeep wc bu = do
  ws <- readTVarIO (wcWorkspaces wc)
  wins <- readTVarIO (wcWindows wc)
  -- pseudo xids for every known identifier (assigns new ones in
  -- first-seen order)
  resolved <- resolvePseudoIds wc [ ident | (ident, _, _, _, _) <- wins ]
  let pseudoOf = Map.fromList resolved
      names = [ n | (n, _, _) <- ws ]
      cur = case [ i | (i, (_, c, _)) <- zip [0 :: Int ..] ws, c ] of
        (i:_) -> i
        [] -> -1
      currentWs = case drop cur names of
        (n:_) -> n
        [] -> ""
      isOwn appId = "homgb-" `T.isPrefixOf` appId
      barWins =
        [ WinInfo (fromIntegral (pseudoOf Map.! ident)) title
        | (ident, title, appId, wWs, _) <- wins
        , wWs == currentWs
        , not (isOwn appId)
        ]
      focusedXid =
        [ fromIntegral (pseudoOf Map.! ident)
        | (ident, _, _, _, True) <- wins ]
      newBar = BarState
        { barPid = 0
        , barCurrent = cur
        , barNames = names
        , barActiveWindow = fromMaybe 0 (listToMaybe' focusedXid)
        , barWindows = barWins
        , barCovered = False
          -- the WM's layout reserves the strip; nothing tiles over it
        }
  oldBar <- readTVarIO (buBar bu)
  atomically $ writeTVar (buBar bu) newBar
  removed <- reapZombieItems (trayClient (buTray bu)) (trayState (buTray bu))
  unless (null removed) $ atomically $
    modifyTVar' (trayMenus (buTray bu))
      (Map.filterWithKey (\k _ -> k `notElem` removed))
  return (oldBar /= newBar, False)
  where
    listToMaybe' (x:_) = Just x
    listToMaybe' [] = Nothing

waylandBarActions :: WmClient -> BarActions
waylandBarActions wc = BarActions
  { baSwitchWs = \st i -> do
      s <- readTVarIO st
      case drop i (barNames s) of
        (n:_) -> wmSwitchWorkspace wc n
        [] -> return ()
  , baActivateWin = \xid ->
      wmFocusWindow wc =<< pseudoToIdent wc (fromIntegral xid)
  }

pseudoToIdent :: WmClient -> Word64 -> IO T.Text
pseudoToIdent wc xid = do
  m <- readTVarIO (wcPseudoIds wc)
  return $ case [ i | (i, x) <- Map.toList m, x == xid ] of
    (i:_) -> i
    [] -> ""

-- | Popups must place below the bar's reserved strip even though no
-- strut exists: record the rect exactly like the X11 backend does.
recordStrut :: Bool -> TVar (Maybe (Int, Int, Int)) -> Surface -> Monitor -> Int -> IO ()
recordStrut _enabled tv _surf mon depth =
  atomically $ writeTVar tv (Just (depth, monX mon, monX mon + monW mon - 1))

moveSurface :: WmClient -> Surface -> Int -> Int -> IO ()
moveSurface wc surf x y = do
  V2 w h <- surfaceWindowSize surf
  wmPlaceSurface wc (sName surf) x y w h (stackOrderOf (sName surf))

-- | SDL display enumeration (main thread only — called at startup).
sdlMonitors :: IO [Monitor]
sdlMonitors = do
  ids <- displays
  mapM bounds ids
  where
    displays = alloca $ \nPtr -> do
      arr <- getDisplays nPtr
      if arr == nullPtr
        then return []
        else peekArray0 0 arr
    bounds did = alloca $ \rPtr -> do
      ok <- getDisplayBounds did rPtr
      if not ok
        then return (Monitor 0 0 1920 1080)
        else do
          SDL_Rect rx ry rw rh <- peek rPtr
          return Monitor
            { monX = fromIntegral rx
            , monY = fromIntegral ry
            , monW = fromIntegral rw
            , monH = fromIntegral rh
            }

primarySize :: IO (Int, Int)
primarySize = do
  ms <- sdlMonitors
  return $ case ms of
    (m:_) -> (monW m, monH m)
    [] -> (1920, 1080)

-- | SDL's global mouse state. On Wayland this is the position SDL
-- last saw (its own windows plus whatever the compositor reports);
-- follow-mouse and menu outside-click work over homgb's own
-- surfaces, and may lag elsewhere.
sdlPointer :: IO (Maybe (Int, Int))
sdlPointer = alloca $ \xPtr -> alloca $ \yPtr -> do
  _buttons <- getGlobalMouseState xPtr yPtr
  x <- peek xPtr
  y <- peek yPtr
  return (Just (floor x, floor y))
