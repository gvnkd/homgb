{-# LANGUAGE OverloadedStrings #-}

module Homgb.Tray.Menu.Render
  ( MenuState(..)
  , Menus
  , MenuFrame(..)
  , newMenus
  , openItemMenu
  , renderMenus
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (when, unless, forM, forM_, void)
import Data.Bits ((.|.))
import Data.Maybe (catMaybes, listToMaybe)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime, POSIXTime)
import Data.Word (Word32)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (poke)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (getProcessID)

import Data.Bits ((.&.))
import Graphics.X11.Types (button1Mask, button3Mask)
import Graphics.X11.Xlib (Display)
import Graphics.X11.Xlib.Display (defaultRootWindow)
import Graphics.X11.Xlib.Misc (queryPointer)

import DBus.Client (Client)
import DBus.Internal.Types (BusName(..), ObjectPath)

import DearImGui hiding (begin, x, y, w, size)
import qualified DearImGui.Raw as Raw (begin, separator, getMousePos
  , setNextWindowSize
                                       , setNextWindowPos, pushStyleColor
                                       , pushStyleVar, popStyleVar)

import StatusNotifier.Host.Service (ItemInfo(..))

import Homgb.Bar (framePadY)
import Homgb.Theme (Theme(..))
import Homgb.Tray.Menu.Client
import Homgb.Tray.Menu.Tree

-- | Fully analytic menu content size (menuW, menuH). Auto-fit
-- windows are clamped to the viewport, so the surface can never
-- learn the content size from the window (feedback deadlock) — and
-- fixed-size surfaces clip long/wide menus. Labels measure pre-Begin
-- via calcTextSize; heights derive from the font line height.
measureMenu :: Theme -> Maybe LayoutNode -> IO (Float, Float)
measureMenu theme mTree = do
  ImVec2 _ lineH <- calcTextSize "A" True 0
  let nodes = maybe [] lnChildren mTree
      -- submenu headers render their children indented one level
      flat = concatMap
        (\n -> (0 :: Int, n)
          : [ (1, c) | menuItemChildrenDisplay n == Just "submenu"
                     , c <- lnChildren n ])
        nodes
  ws <- mapM (\(depth, n) -> do
    let est = fromIntegral (T.length (toggleLabel n)) * lineH * 0.55
    return (est + fromIntegral depth * 14)) flat
  let heights =
        [ if menuItemIsSeparator nd then lineH * 0.6
          else lineH + 2 * framePadY + 4
        | (_, nd) <- flat ]
      menuW = maximum (0 : ws) + 2 * thMenuPadX theme + 12
      menuH = sum heights + fromIntegral (max 0 (length flat - 1)) * 4
        + 2 * thMenuPadY theme + lineH * 0.5
  return (menuW, menuH)

-- | Per-item menu state. The tree is refetched on open and whenever the
-- item emits LayoutUpdated. Rendered as a plain anchored window (ImGui
-- popup stack semantics proved unreliable here).
data MenuState = MenuState
  { msTree :: Maybe LayoutNode
  , msRevision :: Word32
  , msWatched :: Bool
  , msVisible :: Bool
  , msPos :: ImVec2
  , msOpenedAt :: POSIXTime
  , msErrLogAt :: POSIXTime
    -- ^ last time a GetLayout error was logged (rate limiting)
  }

-- | Keyed by the item's bus name string; keeps the ItemInfo around so
-- render-time Event calls have the BusName and object path.
type Menus = TVar (Map.Map String (ItemInfo, ObjectPath, MenuState))

newMenus :: IO Menus
newMenus = newTVarIO Map.empty

menuKey :: ItemInfo -> String
menuKey info = case itemServiceName info of
  BusName s -> s

-- | Called on right-click: toggles the menu. The menu lives on its
-- own surface window (EWMH POPUP_MENU), so the stored position is in
-- ROOT screen coordinates. It opens BELOW the tray row (like GTK/Qt
-- tray menus), horizontally anchored at the cursor, clamped inside
-- the screen.
openItemMenu :: Client -> Menus -> ItemInfo -> (Int, Int) -> Int -> (Int, Int) -> IO ()
openItemMenu client menus info trayWinPos trayH screenSize =
  case menuPath info of
    Nothing -> return ()
    Just path -> do
      let key = menuKey info
      ImVec2 mx _ <- Raw.getMousePos
      now <- getPOSIXTime
      let (wx, wy) = trayWinPos
          (sw, _sh) = screenSize
          rx = min (max 0 (floor mx + wx)) (sw - 60)
          ry = wy + trayH + 2
          pos = ImVec2 (fromIntegral rx) (fromIntegral ry)
      nowVisible <- atomically $ do
        m <- readTVar menus
        case Map.lookup key m of
          Just (_, _, st) -> do
            let v = not (msVisible st)
                others = if v then hideOthers key m else m
            writeTVar menus (Map.insert key (info, path, st
              { msVisible = v
              , msPos = pos
              , msOpenedAt = if v then now else msOpenedAt st
              }) others)
            return v
          Nothing -> do
            writeTVar menus (Map.insert key
              (info, path, MenuState
                { msTree = Nothing
                , msRevision = 0
                , msWatched = False
                , msVisible = True
                , msPos = pos
                , msOpenedAt = now
                , msErrLogAt = 0
                })
              (hideOthers key m))
            return True
      when nowVisible $ void $ forkIO $ do
        fetchLayout client menus key
        watch client menus key

-- | The menu currently being rendered (single-open invariant) and its
-- root position, for the caller to move the menu surface window.
data MenuFrame = MenuFrame
  { mfKey :: String
  , mfRootPos :: (Float, Float)
  , mfSize :: (Float, Float)
  }

-- | Renders all visible menus into the current (menu surface) ImGui
-- context; each menu window sits at the surface's local origin (the
-- surface window itself is moved to the stored root position). Closes
-- a menu on any mouse press outside its window; presses are detected
-- by polling XQueryPointer (root coordinates) once per frame — ImGui's
-- own mouse position goes stale once the pointer leaves our surfaces.
renderMenus :: Client -> Menus -> TVar (Bool, Bool) -> Maybe Display -> Theme
            -> (Int, Int) -> IO (Maybe MenuFrame)
renderMenus client menus prevButtons mDisplay theme winPos = do
  (pressed, rootX, rootY) <- samplePressEdge mDisplay prevButtons
  m <- readTVarIO menus
  myPid <- getProcessID
  now <- getPOSIXTime
  frames <- forM (Map.toList m) $ \(key, (info, path, st)) ->
    if msVisible st
      then do
        let winId = "homgbmenu-" ++ show myPid ++ "-" ++ key
            menuFlags = foldl1 combineFlags
              [ ImGuiWindowFlags_NoTitleBar
              , ImGuiWindowFlags_NoResize
              , ImGuiWindowFlags_NoMove
              , ImGuiWindowFlags_NoCollapse
              , ImGuiWindowFlags_NoScrollbar
              , ImGuiWindowFlags_NoFocusOnAppearing
              ]
        -- fully analytic menu size: auto-fit windows are clamped to
        -- the viewport, so a surface that hugs the window deadlocks
        -- (window can't outgrow the surface, surface waits for the
        -- window). Labels measure fine pre-Begin; heights use the
        -- font's line height (frame height + item spacing).
        (menuW, menuH) <- measureMenu theme (msTree st)
        withImVec2 (ImVec2 0 0) $ \posPtr ->
          Raw.setNextWindowPos posPtr ImGuiCond_Always Nothing
        withImVec2 (ImVec2 menuW menuH) $ \sizePtr ->
          Raw.setNextWindowSize sizePtr ImGuiCond_Always
        -- themed menu background (alpha < 1 keeps the desktop faintly
        -- visible under compositing)
        mRect <- withImVec4 (thMenuBg theme) $ \bgPtr ->
          withImVec4 (thMenuBorder theme) $ \borderPtr ->
            withImVec2 (ImVec2 (thMenuPadX theme) (thMenuPadY theme)) $ \padPtr -> do
              Raw.pushStyleColor ImGuiCol_WindowBg bgPtr
              Raw.pushStyleColor ImGuiCol_Border borderPtr
              Raw.pushStyleVar ImGuiStyleVar_WindowPadding padPtr
              beginVisible <- BS.useAsCString (T.encodeUtf8 (T.pack winId))
                $ \label -> Raw.begin label Nothing (Just menuFlags)
              r <- if beginVisible
                then do
                  forM_ (msTree st) $ \tree ->
                    forM_ (lnChildren tree) $
                      renderNode client menus key path info
                  -- measure AFTER drawing: auto-resize windows only
                  -- update their size at frame end, so a pre-content
                  -- read is stale (an empty bbox) — this value also
                  -- drives the surface hug in drawMenusSurface
                  rect <- windowRect
                  -- Ignore the press that opened this menu (same frame /
                  -- fresh press right after opening).
                  let openedAgo = now - msOpenedAt st
                  when (pressed && openedAgo > 0.25) $ do
                    -- rect is menu-surface-local, pointer is root (XQueryPointer)
                    let (wx, wy) = winPos
                        (rx, ry, rw, rh) = rect
                        inside = fromIntegral rootX >= wx + floor rx
                          && fromIntegral rootX < wx + ceiling (rx + rw)
                          && fromIntegral rootY >= wy + floor ry
                          && fromIntegral rootY < wy + ceiling (ry + rh)
                    unless inside $ closeMenu menus key
                  return (Just rect)
                else return Nothing
              end
              Raw.popStyleVar 1
              popStyleColor 2
              return r
        let ImVec2 px py = msPos st
            size = case mRect of
              Just (_, _, rw, rh) -> (rw, rh)
              Nothing -> (0, 0)
        return (MenuFrame key (px, py) size <$ mRect)
      else return Nothing
  return (listToMaybe (catMaybes frames))
  where
    combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
      ImGuiWindowFlags (a .|. b)
    withImVec2 v f = alloca $ \p -> poke p v >> f p
    withImVec4 v f = alloca $ \p -> poke p v >> f p
    windowRect = do
      ImVec2 x y <- getWindowPos
      ImVec2 w h <- getWindowSize
      return (x, y, w, h)

-- | True if the left or right button went down since the last frame,
-- polled globally via XQueryPointer (SDL misses clicks on other
-- windows); also returns the pointer's root position. Nothing display
-- -> no edge detection.
samplePressEdge :: Maybe Display -> TVar (Bool, Bool) -> IO (Bool, Int, Int)
samplePressEdge Nothing _ = return (False, 0, 0)
samplePressEdge (Just dpy) prevVar = do
  (_, _, _, rx, ry, _, _, mask) <- queryPointer dpy (defaultRootWindow dpy)
  let cur = (mask .&. button1Mask /= 0, mask .&. button3Mask /= 0)
  prev <- readTVarIO prevVar
  atomically $ writeTVar prevVar cur
  let pressed = fst cur && not (fst prev) || snd cur && not (snd prev)
  return (pressed, fromIntegral rx, fromIntegral ry)

-- | Renders one node; closes the menu (via 'closeMenu') when a leaf
-- item is clicked.
renderNode :: Client -> Menus -> String -> ObjectPath -> ItemInfo
           -> LayoutNode -> IO ()
renderNode client menus key path info node
  | not (menuItemVisible node) = return ()
  | menuItemIsSeparator node = Raw.separator
  | menuItemChildrenDisplay node == Just "submenu" = do
      -- beginMenu is unreliable outside menu bars in this ImGui version;
      -- render submenu headers as non-clickable labels with indented
      -- children (dbusmenu submenus are rare in tray menus).
      textDisabled (stripMnemonic (menuItemLabel node))
      forM_ (lnChildren node) $ \child -> do
        indent 14
        renderNode client menus key path info child
      unindent 14
  | otherwise = do
      let label = toggleLabel node
      beginDisabled (not (menuItemEnabled node))
      clicked <- selectable label
      endDisabled
      when clicked $ do
        ts <- fmap (round . (realToFrac :: POSIXTime -> Double)) getPOSIXTime
        void $ forkIO $
          sendClicked client (itemServiceName info)
            path (lnId node) ts
        closeMenu menus key

closeMenu :: Menus -> String -> IO ()
closeMenu menus key = atomically $ modifyTVar' menus $
  Map.adjust (\(i, p, st) -> (i, p, st { msVisible = False })) key

-- Only one tray menu may be open at a time: opening one hides the rest.
hideOthers :: String -> MenusMap -> MenusMap
hideOthers self = Map.mapWithKey $ \k (i, p, st) ->
  if k == self then (i, p, st) else (i, p, st { msVisible = False })

type MenusMap = Map.Map String (ItemInfo, ObjectPath, MenuState)

toggleLabel :: LayoutNode -> T.Text
toggleLabel node =
  case menuItemToggleState node of
    Just 1 -> "[x] " <> label
    Just 0 -> "[ ] " <> label
    _ -> label
  where
    label = stripMnemonic (menuItemLabel node)

-- dbusmenu labels carry '_' mnemonic markers (like GTK/Qt); ImGui
-- renders them literally, so strip ("Send _Files" -> "Send Files").
stripMnemonic :: T.Text -> T.Text
stripMnemonic = T.filter (/= '_')

fetchLayout :: Client -> Menus -> String -> IO ()
fetchLayout client menus key = do
  m <- readTVarIO menus
  case Map.lookup key m of
    Nothing -> return ()
    Just (info, path, st) -> do
      result <- getLayout client (itemServiceName info) path 0
      case result of
        Left err -> do
          -- steam/blueman can emit LayoutUpdated bursts; rate-limit
          -- error logs to one per 5s so a misbehaving item can't spam
          now <- getPOSIXTime
          when (now - msErrLogAt st > 5) $ do
            atomically $ modifyTVar' menus $
              Map.adjust (\(i, p, s) ->
                (i, p, s { msErrLogAt = now })) key
            hPutStrLn stderr $ "menu GetLayout: " ++ show err
        Right (revision, layoutVar) ->
          case parseLayout layoutVar of
            Nothing -> hPutStrLn stderr "menu GetLayout: unparsable layout"
            Just tree -> do
              dbg <- lookupEnv "HOMGB_DEBUG"
              case dbg of
                Just _ -> hPutStrLn stderr $ "menu fetched rev=" ++ show revision
                  ++ " children=" ++ show (length (lnChildren tree))
                Nothing -> return ()
              atomically $ modifyTVar' menus $
                Map.adjust (\(i, p, s) ->
                  (i, p, s { msTree = Just tree, msRevision = revision })) key

watch :: Client -> Menus -> String -> IO ()
watch client menus key = do
  already <- atomically $ do
    m <- readTVar menus
    case Map.lookup key m of
      Just (_, _, st) | msWatched st -> return True
      Just (i, p, st) -> do
        writeTVar menus (Map.insert key (i, p, st { msWatched = True }) m)
        return False
      Nothing -> return True
  when (not already) $ do
    m <- readTVarIO menus
    case Map.lookup key m of
      Just (info, path, _) ->
        void $ registerLayoutUpdated client (itemServiceName info) path
          $ \_ -> fetchLayout client menus key
      Nothing -> return ()
 