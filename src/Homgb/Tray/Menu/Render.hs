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
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
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

-- | Rows exactly as rendered: invisible nodes dropped (they take no
-- height in renderNode), submenu children indented ONE level
-- regardless of actual tree depth — slack's exporter nests sibling
-- chains (every item a children-display:submenu header holding the
-- next), and proper dbusmenu clients never expand those eagerly
-- (children are only valid after AboutToShow), so deeper indentation
-- is noise. Shared by measureMenu and renderMenus so the analytic
-- size can never diverge from what is drawn.
menuRows :: LayoutNode -> [(Int, LayoutNode)]
menuRows root = concatMap (row 0) (lnChildren root)
  where
    row depth n
      | not (menuItemVisible n) = []
      | menuItemChildrenDisplay n == Just "submenu"
      = (depth, n) : concatMap (row (min (depth + 1) 1)) (lnChildren n)
      | otherwise = [(depth, n)]

-- | Fully analytic menu content size (menuW, menuH). Auto-fit
-- windows are clamped to the viewport, so the surface can never
-- learn the content size from the window (feedback deadlock) — and
-- fixed-size surfaces clip long/wide menus. Labels measure pre-Begin
-- via calcTextSize; heights derive from the font line height and
-- MUST mirror menuRows/renderRow: separator 0.6*lineH, submenu
-- header a bare textDisabled label (lineH), selectable a framed
-- widget (lineH + 2*framePadY); 4px item spacing BETWEEN rows.
measureMenu :: Theme -> Maybe LayoutNode -> IO (Float, Float)
measureMenu theme mTree = do
  ImVec2 _ lineH <- calcTextSize "A" True 0
  let rows = maybe [] menuRows mTree
      labelOf n
        | menuItemIsSeparator n = ""
        | menuItemChildrenDisplay n == Just "submenu" =
            stripMnemonic (menuItemLabel n)
        | otherwise = toggleLabel n
      heightOf (_, n)
        | menuItemIsSeparator n = lineH * 0.6
        | menuItemChildrenDisplay n == Just "submenu" = lineH
        | otherwise = lineH + 2 * framePadY
      est (depth, n) =
        fromIntegral (T.length (labelOf n)) * lineH * 0.55
          + fromIntegral depth * 14
      menuW = maximum (0 : map est rows) + 2 * thMenuPadX theme + 12
      menuH = sum (map heightOf rows)
        + fromIntegral (max 0 (length rows - 1)) * 4
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
  , msFitH :: Maybe Float
    -- ^ content height measured from the drawn cursor position (exact,
    --   font-agnostic); Nothing until the first drawn frame, then it
    --   drives setNextWindowSize — the analytic 'measureMenu' height is
    --   only the first-frame fallback
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
openItemMenu :: Client -> Menus -> ItemInfo -> (Int, Int) -> Int -> (Int, Int)
             -> IO () -> IO ()
openItemMenu client menus info trayWinPos trayH screenSize wake =
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
      dbg <- lookupEnv "HOMGB_DEBUG"
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
              , msFitH = if v then Nothing else msFitH st
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
                , msFitH = Nothing
                })
              (hideOthers key m))
            return True
      case dbg of
        Just _ -> hPutStrLn stderr $ "menu toggle " ++ take 30 key
          ++ " -> " ++ if nowVisible then "OPEN" else "CLOSED"
        Nothing -> return ()
      when nowVisible $ void $ forkIO $ do
        fetchLayout wake client menus key
        watch wake client menus key
      wake

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
            -> (Int, Int) -> IO () -> IO (Maybe MenuFrame)
renderMenus client menus prevButtons mDisplay theme winPos _wake = do
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
        (menuW, menuH0) <- measureMenu theme (msTree st)
        let menuH = fromMaybe menuH0 (msFitH st)
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
                    forM_ (menuRows tree) $ \(depth, node) -> do
                      when (depth > 0) $ indent 14
                      renderRow client menus key path info node
                      when (depth > 0) $ unindent 14
                  -- exact content height for the NEXT frame's
                  -- setNextWindowSize: the cursor sits below the last
                  -- row in window coordinates (WindowPadding pushed at
                  -- the top), so cursorY + bottom padding + border is
                  -- the fitted window height — immune to font metrics,
                  -- separator heights, and item spacing (the analytic
                  -- measureMenu is only the pre-first-frame fallback)
                  ImVec2 _ cursorY <- getCursorPos
                  let fittedH = cursorY + thMenuPadY theme + 2
                  atomically $ modifyTVar' menus $
                    Map.adjust (\(i, p, s) -> (i, p, s { msFitH = Just fittedH })) key
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
  -- The ~20Hz poll-while-open loop is driven by the MAIN LOOP's menu
  -- deadline (Homgb.nextDeadline adds 50ms while anyMenuOpen) plus
  -- the menuOpen render gate in mainLoop — NOT by per-frame wakes: an
  -- unthrottled wake makes SDL's wait return immediately and the loop
  -- renders frame-locked at GL speed (~13-15% CPU), and a wake-gated
  -- throttle dies as soon as a timeout-wake finds no SDL event.
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

-- | Renders one menuRows row; closes the menu (via 'closeMenu') when
-- a leaf item is clicked. Submenu headers are non-clickable labels
-- (beginMenu is unreliable outside menu bars in this ImGui version);
-- their children are flattened into the row list by menuRows.
renderRow :: Client -> Menus -> String -> ObjectPath -> ItemInfo
          -> LayoutNode -> IO ()
renderRow client menus key path info node
  | menuItemIsSeparator node = Raw.separator
  | menuItemChildrenDisplay node == Just "submenu" =
      textDisabled (stripMnemonic (menuItemLabel node))
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
closeMenu menus key = do
  dbg <- lookupEnv "HOMGB_DEBUG"
  case dbg of
    Just _ -> hPutStrLn stderr $ "menu close " ++ take 30 key
    Nothing -> return ()
  atomically $ modifyTVar' menus $
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

fetchLayout :: IO () -> Client -> Menus -> String -> IO ()
fetchLayout wake client menus key = do
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
                  (i, p, s { msTree = Just tree, msRevision = revision
                           , msFitH = Nothing })) key
              wake

watch :: IO () -> Client -> Menus -> String -> IO ()
watch wake client menus key = do
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
          $ \_ -> fetchLayout wake client menus key
      Nothing -> return ()
 