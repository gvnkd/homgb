{-# LANGUAGE OverloadedStrings #-}

module Homgb.Tray.Menu.Render
  ( MenuState(..)
  , Menus
  , newMenus
  , openItemMenu
  , renderMenus
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (when, forM_, void)
import Data.Bits ((.|.))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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

import DBus.Client (Client)
import DBus.Internal.Types (BusName(..), ObjectPath)

import DearImGui hiding (begin)
import qualified DearImGui.Raw as Raw (begin, separator, getMousePos
                                       , setNextWindowPos)

import StatusNotifier.Host.Service (ItemInfo(..))

import Homgb.Tray.Menu.Client
import Homgb.Tray.Menu.Tree

-- | Per-item menu state. The tree is refetched on open and whenever the
-- item emits LayoutUpdated. Rendered as a plain anchored window (ImGui
-- popup stack semantics proved unreliable here).
data MenuState = MenuState
  { msTree :: Maybe LayoutNode
  , msRevision :: Word32
  , msWatched :: Bool
  , msVisible :: Bool
  , msPos :: ImVec2
  }

-- | Keyed by the item's bus name string; keeps the ItemInfo around so
-- render-time Event calls have the BusName and object path.
type Menus = TVar (Map.Map String (ItemInfo, ObjectPath, MenuState))

newMenus :: IO Menus
newMenus = newTVarIO Map.empty

menuKey :: ItemInfo -> String
menuKey info = case itemServiceName info of
  BusName s -> s

-- | Called on right-click: toggles the menu, anchors it at the mouse
-- cursor (clamped inside the overlay window), and fetches the layout
-- (in a forked thread; dbus blocks).
openItemMenu :: Client -> Menus -> ItemInfo -> ImVec2 -> IO ()
openItemMenu client menus info winSize =
  case menuPath info of
    Nothing -> return ()
    Just path -> do
      let key = menuKey info
      ImVec2 mx my <- Raw.getMousePos
      let ImVec2 wx wy = winSize
          pos = ImVec2 (min mx (wx - 180)) (min my (wy - 60))
      nowVisible <- atomically $ do
        m <- readTVar menus
        case Map.lookup key m of
          Just (_, _, st) -> do
            let v = not (msVisible st)
            writeTVar menus (Map.insert key (info, path, st
              { msVisible = v, msPos = pos }) m)
            return v
          Nothing -> do
            writeTVar menus (Map.insert key
              (info, path, MenuState Nothing 0 False True pos) m)
            return True
      when nowVisible $ void $ forkIO $ do
        fetchLayout client menus key
        watch client menus key

renderMenus :: Client -> Menus -> IO ()
renderMenus client menus = do
  m <- readTVarIO menus
  myPid <- getProcessID
  forM_ (Map.toList m) $ \(key, (info, path, st)) -> do
    when (msVisible st) $ do
      let winId = "homgbmenu-" ++ show myPid ++ "-" ++ key
          menuFlags = foldl1 combineFlags
            [ ImGuiWindowFlags_NoTitleBar
            , ImGuiWindowFlags_NoResize
            , ImGuiWindowFlags_NoMove
            , ImGuiWindowFlags_NoCollapse
            , ImGuiWindowFlags_AlwaysAutoResize
            , ImGuiWindowFlags_NoFocusOnAppearing
            ]
      withImVec2 (msPos st) $ \posPtr ->
        Raw.setNextWindowPos posPtr ImGuiCond_Always Nothing
      hoveredRef <- newIORef False
      beginVisible <- BS.useAsCString (T.encodeUtf8 (T.pack winId))
        $ \label -> Raw.begin label Nothing (Just menuFlags)
      when beginVisible $ do
        -- The root node (id 0) is virtual and may itself claim
        -- "children-display: submenu" (steam does) - always flatten it.
        forM_ (msTree st) $ \tree ->
          forM_ (lnChildren tree) $
            renderNode client menus key path info hoveredRef
      end
      -- close on left-click outside the menu
      anyHovered <- readIORef hoveredRef
      outsideClick <- isItemClicked ImGuiMouseButton_Left
      when (outsideClick && not anyHovered) $
        closeMenu menus key
  where
    combineFlags (ImGuiWindowFlags a) (ImGuiWindowFlags b) =
      ImGuiWindowFlags (a .|. b)
    withImVec2 v f = alloca $ \p -> poke p v >> f p

-- | Renders one node; records hover in the ref. Closes the menu (via
-- 'closeMenu') when a leaf item is clicked.
renderNode :: Client -> Menus -> String -> ObjectPath -> ItemInfo -> IORef Bool
           -> LayoutNode -> IO ()
renderNode client menus key path info hoveredRef node =
  renderNode' client menus key path info hoveredRef node

renderNode' :: Client -> Menus -> String -> ObjectPath -> ItemInfo -> IORef Bool
            -> LayoutNode -> IO ()
renderNode' client menus key path info hoveredRef node
  | not (menuItemVisible node) = return ()
  | menuItemIsSeparator node = Raw.separator
  | menuItemChildrenDisplay node == Just "submenu" = do
      -- beginMenu is unreliable outside menu bars in this ImGui version;
      -- render submenu headers as non-clickable labels with indented
      -- children (dbusmenu submenus are rare in tray menus).
      textDisabled (menuItemLabel node)
      hovered <- isItemHovered
      when hovered $ writeIORef hoveredRef True
      forM_ (lnChildren node) $ \child -> do
        indent 14
        renderNode client menus key path info hoveredRef child
      unindent 14
  | otherwise = do
      let label = toggleLabel node
      beginDisabled (not (menuItemEnabled node))
      clicked <- selectable label
      endDisabled
      hovered <- isItemHovered
      when hovered $ writeIORef hoveredRef True
      when clicked $ do
        ts <- fmap (round . (realToFrac :: POSIXTime -> Double)) getPOSIXTime
        void $ forkIO $
          sendClicked client (itemServiceName info)
            path (lnId node) ts
        closeMenu menus key

closeMenu :: Menus -> String -> IO ()
closeMenu menus key = atomically $ modifyTVar' menus $
  Map.adjust (\(i, p, st) -> (i, p, st { msVisible = False })) key

toggleLabel :: LayoutNode -> T.Text
toggleLabel node =
  case menuItemToggleState node of
    Just 1 -> "[x] " <> menuItemLabel node
    Just 0 -> "[ ] " <> menuItemLabel node
    _ -> menuItemLabel node

fetchLayout :: Client -> Menus -> String -> IO ()
fetchLayout client menus key = do
  m <- readTVarIO menus
  case Map.lookup key m of
    Nothing -> return ()
    Just (info, path, _) -> do
      result <- getLayout client (itemServiceName info) path 0
      case result of
        Left err -> hPutStrLn stderr $ "menu GetLayout: " ++ show err
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
                Map.adjust (\(i, p, st) ->
                  (i, p, st { msTree = Just tree, msRevision = revision })) key

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
 