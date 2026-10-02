{-# LANGUAGE OverloadedStrings #-}

-- | The status-bar section of the tray surface — the start of the
-- xmobar replacement. Phase 1: xmonad workspaces from the EWMH root
-- properties (_NET_DESKTOP_NAMES / _NET_CURRENT_DESKTOP, maintained
-- by XMonad.Hooks.EwmhDesktops), rendered as clickable buttons; a
-- left click sends the _NET_CURRENT_DESKTOP client message back.
-- No xmonad.hs changes needed.
--
-- Also hosts the shared tray-layout helpers (sameLineS, framePad*):
-- both this module and Homgb.Tray.Render need them.
module Homgb.Bar
  ( BarState(..)
  , newBarState
  , refreshBar
  , renderBar
  , sameLineS
  , framePadX
  , framePadY
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (when)
import Data.Char (chr)
import qualified Data.Text as T
import Foreign.C.Types (CFloat(..), CLong(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (poke)
import Graphics.X11.Types (Window)
import Graphics.X11.Xlib.Types (Display(..))
import Graphics.X11.Xlib.Atom (internAtom)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Extras (getWindowProperty8, getWindowProperty32)

import DearImGui hiding (begin)
import qualified DearImGui.Raw as Raw (pushStyleColor)

import Homgb.Theme (Theme(..))

-- | Cached EWMH desktop state (see 'refreshBar').
data BarState = BarState
  { barCurrent :: Int
  , barNames :: [T.Text]
  } deriving (Show)

newBarState :: IO (TVar BarState)
newBarState = newTVarIO (BarState (-1) [])

-- | Re-read the EWMH desktop properties into the TVar. Cheap Xlib
-- reads; call at a few Hz from the frame loop.
refreshBar :: Display -> TVar BarState -> IO ()
refreshBar dpy st = do
  aCur <- internAtom dpy "_NET_CURRENT_DESKTOP" False
  aNames <- internAtom dpy "_NET_DESKTOP_NAMES" False
  let root = defaultRootWindow dpy
  mCur <- getWindowProperty32 dpy aCur root
  mNames <- getWindowProperty8 dpy aNames root
  let cur = case mCur of
        Just (v:_) -> fromIntegral v
        _ -> -1
      names = case mNames of
        Nothing -> []
        Just bs -> filter (not . T.null)
          (T.split (== '\0') (T.pack (map (chr . fromIntegral) bs)))
  atomically $ writeTVar st (BarState cur names)

-- | EWMH switch-to-desktop client message (xmonad ewmh honors it).
foreign import ccall "homgb_set_current_desktop" c_set_current_desktop
  :: Display -> Window -> CLong -> IO ()

switchTo :: Display -> Int -> IO ()
switchTo dpy idx =
  c_set_current_desktop dpy (defaultRootWindow dpy) (fromIntegral idx)

-- | Draw the workspace buttons at the current cursor position (the
-- tray window's left edge). Active workspace is highlighted with the
-- theme menu background. Returns the content width (0 when nothing
-- is rendered).
renderBar :: Display -> TVar BarState -> Theme -> Float -> IO Float
renderBar dpy st theme gap = do
  s <- readTVarIO st
  if null (barNames s)
    then return 0
    else do
      widths <- mapM (renderOne s) (zip [0 :: Int ..] (barNames s))
      return (sum widths + fromIntegral (length widths - 1) * gap)
  where
    renderOne s (i, name) = do
      when (i > 0) $ sameLineS gap
      clicked <-
        if i == barCurrent s && i < length (barNames s)
          then withImVec4 (thMenuBg theme) $ \ptr -> do
            Raw.pushStyleColor ImGuiCol_Button ptr
            c <- smallButton name
            popStyleColor 1
            return c
          else smallButton name
      when clicked $ switchTo dpy i
      ImVec2 tw _ <- calcTextSize name True 0
      return (tw + 2 * framePadX)

-- | ImGui's default FramePadding (pixel-probed from the rendered
-- tray: item pitch = btn + 8 + ItemSpacing 8).
framePadX, framePadY :: Float
framePadX = 4
framePadY = 4

-- | dear-imgui's sameLine binds @SameLine()@ without the spacing
-- argument; go through the shim for theme-controlled gaps.
sameLineS :: Float -> IO ()
sameLineS sp = c_same_line (realToFrac sp)

foreign import ccall "homgb_same_line" c_same_line :: CFloat -> IO ()

withImVec4 :: ImVec4 -> (Ptr ImVec4 -> IO a) -> IO a
withImVec4 v f = alloca $ \p -> poke p v >> f p
