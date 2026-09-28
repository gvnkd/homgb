# Milestone 2: StatusNotifierItem tray on ImGui

Goal: homgb hosts a system tray (`org.kde.StatusNotifierWatcher` watcher +
host) and renders tray items as an ImGui tray bar with icons, clicks,
scrolls, and (stretch) DBusMenu popup menus. The notification daemon from
M1 keeps working in the same process.

This document is written to be picked up by an agent with no prior context.
Read `.opencode/MEMORIES.md` first, then `design_docs/milestone_1.md`, then
this file.

## Reference repos

### 1. `/home/pion/work/dev/taffybar` — source of truth for SNI

| Component | Path | What we use |
|---|---|---|
| Watcher service | `packages/status-notifier-item/src/StatusNotifier/Watcher/Service.hs` | `buildWatcher :: WatcherParams -> IO (Interface, IO RequestNameReply)` — already a Hackage dep of homgb (`status-notifier-item`), GTK-free |
| Host service | `packages/status-notifier-item/src/StatusNotifier/Host/Service.hs` | `build :: Params -> IO (Maybe Host)`, then `addUpdateHandler`. `Params{startWatcher = True}` makes the host start the watcher itself. Also already a Hackage dep |
| Item client | `packages/status-notifier-item/src/StatusNotifier/Item/Client.hs` | TH-generated `activate`/`scroll`/`contextMenu`/`get*`. Re-exported by the Hackage package |
| Icon resolution | `packages/gtk-sni-tray/src/StatusNotifier/Tray.hs` (`getIconPixbufByName`, `getIconPathFromThemePath`, `trayPreferPixmaps`) | **Logic to crib**, but its concrete implementation uses GTK `IconTheme` — we re-implement the freedesktop lookup ourselves (see decision 3) |
| DBusMenu client | `packages/dbus-menu/src/DBusMenu/Client.hs` | TH-generated (`generateClientFromFile` from `dbus-xml/com.canonical.dbusmenu.xml`). GTK-free, but the Cabal file has `pkgconfig-depends: gtk+-3.0` → vendor |
| DBusMenu layout | `packages/dbus-menu/src/DBusMenu.hs` | GTK-heavy (718 lines, `GI.Gtk`). Port **only**: `LayoutNode`, `variantToLayout`, `tupleToLayout`, property accessors (`menuItemLabel`, `menuItemVisible`, `menuItemEnabled`, `menuItemToggleType/State`, `menuItemChildrenDisplay`), `sendClicked`, `getLayout`, `aboutToShow`. Drop `populateGtkMenu*` entirely |
| DBusMenu reconcile | `packages/dbus-menu/src/DBusMenu/Reconcile.hs` | 64 lines, pure. Vendor as-is |

Key types (from `StatusNotifier.Host.Service`, re-exported by the Hackage
package — verify names with `:browse StatusNotifier.Host.Service` in the
repl before use):

```haskell
data UpdateType = ItemAdded | ItemRemoved | IconUpdated
                | OverlayIconUpdated | StatusUpdated | TitleUpdated
                | ToolTipUpdated
type UpdateHandler = UpdateType -> ItemInfo -> IO ()
data ItemInfo = ItemInfo
  { itemServiceName  :: BusName, itemServicePath :: ObjectPath
  , itemId, itemStatus, itemCategory :: Maybe String
  , itemToolTip      :: Maybe (String, [(Int32,Int32,ByteString)], String, String)
  , iconTitle        :: String, iconName :: String
  , overlayIconName  :: Maybe String, iconThemePath :: Maybe String
  , iconPixmaps      :: [(Int32,Int32,ByteString)]      -- ARGB, host byte order
  , overlayIconPixmaps :: [(Int32,Int32,ByteString)]
  , menuPath         :: Maybe ObjectPath, itemIsMenu :: Bool }
data Host = Host { itemInfoMap :: IO (Map BusName ItemInfo)
                 , addUpdateHandler :: UpdateHandler -> IO Unique
                 , removeUpdateHandler :: Unique -> IO ()
                 , forceUpdate :: BusName -> IO () }
```

### 2. homgb M1 (this repo)

- `src/Homgb/Render.hs` — popup rendering, GL texture upload
  (`uploadTexture`, `argbToRgba`), texture cache pattern in `AppState`.
  Tray reuses all of it.
- `src/Homgb/Notifications/Daemon.hs` — the DBus forkIO pattern to copy for
  starting watcher+host.

## Design decisions

1. **Same process, second DBus thread group.** `startTray` in a new
   `src/Homgb/Tray.hs` runs `forkIO $ do mhost <- SHost.build
   SHost.defaultParams{SHost.startWatcher = True,
   SHost.uniqueIdentifier = "homgb"}; ...`. The `UpdateHandler` writes
   `TVar TrayState`; the render loop reads it each frame (M1 pattern, no
   callbacks into ImGui).
2. **Tray state model.**
   ```haskell
   data TrayItem = TrayItem { tiInfo :: ItemInfo, tiIconTex :: Maybe GLuint }
   data TrayState = TrayState { trayItems :: [TrayItem] }  -- stable order
   ```
   `ItemRemoved` deletes its GL texture. `IconUpdated` invalidates the
   texture (delete + let next frame re-upload from new pixmaps).
3. **Icon resolution, GTK-free.** Priority (matching deadd/taffybar
   behavior, `trayPreferPixmaps`):
   1. `iconPixmap` closest to the tray icon size (ARGB → RGBA, reuse M1's
      `uploadTexture` logic — factor it out of Render.hs into
      `Homgb.GL.Texture`).
   2. `iconName` as an absolute path or inside `iconThemePath`.
   3. Freedesktop theme lookup, reimplemented: parse `index.theme`
      (`Directories` + `Inherits`) in `$XDG_DATA_HOME/icons`,
      `$XDG_DATA_DIRS/icons`, `~/.icons`; load PNG with **JuicyPixels**
      (add to cabal). SVG icons are a known M2 limitation (no GTK-free SVG
      renderer; most tray apps provide pixmaps anyway) — log and skip.
   4. Fallback: first letter of `iconTitle` rendered as text (like deadd).
   Cache resolved textures keyed by `(BusName, iconVersion)` where
   `iconVersion` bumps on every `IconUpdated`.
4. **Tray bar surface.** For M2 keep the single-SDL-window model: the tray
   bar is a row of square buttons (icon size + padding, tray icon size
   default 22px, config `tray.icon-size`) rendered as an ImGui window
   anchored to a screen edge (config `tray.position`: top-left|top-right|
   bottom-left|bottom-right, default top-right) **inside the existing
   homgb window** — same constraint as M1 popups. One OS window for the
   whole app stays a M3 topic.
5. **Interaction.** Left click → `I.activate` (via TH-generated client,
   coords = button center in item window space); right click →
   `I.contextMenu`; wheel → `I.scroll delta direction`. Hover → ImGui
   tooltip from `itemToolTip` title/body. Hide items with
   `itemStatus == "Passive"`.
6. **Menus (stretch goal, still M2).** On right-click, if `menuPath` is
   set: `getLayout` → render ImGui menu windows from `LayoutNode` tree,
   `aboutToShow` before opening submenus, `sendClicked id` on click.
   Vendor as internal library `homgb-tray-menu` (or just modules under
   `Homgb.Tray.Menu`): `DBusMenu.Client` (TH, needs the
   `com.canonical.dbusmenu.xml` file in-repo — copy from taffybar),
   `DBusMenu.Reconcile`, ported layout accessors. Reconciliation between
   menu revisions is render-side: rebuild the ImGui tree from the fresh
   `LayoutNode` (menu trees are small; skip fancy diffing, re-fetch on
   `ItemsPropertiesUpdated`).
7. **Name contention.** Plasma owns `org.kde.StatusNotifierWatcher` on the
   real bus; `startWatcher = True` only starts one if none exists
   (taffybar checks name owner first — see `startWatcherIfNeeded`). On the
   real session our host registers with Plasma's watcher; on the private
   test bus we run our own. Items register with the watcher by bus name,
   so both cases work.

## Tasks

- [ ] Factor GL texture bits out of `Homgb.Render` into
      `Homgb.GL.Texture` (upload ARGB, delete, cache helper)
- [ ] `src/Homgb/Tray.hs`: `startTray :: TVar TrayState -> IO ()`,
      `TrayState`/`TrayItem`, UpdateHandler writing the TVar
- [ ] `src/Homgb/Tray/Icons.hs`: icon resolution (pixmaps → theme path →
      freedesktop theme PNG lookup via JuicyPixels → letter fallback)
- [ ] `src/Homgb/Tray/Render.hs`: tray bar ImGui window, icon buttons,
      tooltips, activate/contextMenu/scroll calls
- [ ] Wire `startTray` into `Homgb.run`
- [ ] Vendor DBusMenu client (TH + XML), Reconcile, layout accessors as
      `Homgb/Tray/Menu/*`; render context menus (stretch)
- [ ] `tray.*` config section (icon-size, position, spacing)
- [ ] Verify: `nm-applet`/`blueman`/`keepassxc` icon appears; click
      activates; scroll forwards; menu renders (stretch)
- [ ] Update `.opencode/MEMORIES.md`

## Acceptance criteria

```sh
# private bus, real X:
dbus-run-session -- sh -c 'homgb & nm-applet & sleep 5'
```

- Tray bar renders on configured edge with item icons (screenshot
  verified).
- Left click on an item emits `Activate` on the item (watch with
  `busctl --user monitor`; nm-applet shows its menu window, keepassxc
  unlocks, etc.).
- Item removal (kill the app) removes the icon within seconds.
- M1 notifications still work in the same process.
- No GTK in `ldd`; no new pkg-config deps beyond flake's.

## Out of scope (later milestones)

Notification center panel, keyboard layouts, multi-monitor tray placement,
overlay icons, `itemIsMenu` inline menus, Ayatana `X-NewIcon` signal,
SVG icon rendering, appindicator emulation (`org.kde.*` legacy).
