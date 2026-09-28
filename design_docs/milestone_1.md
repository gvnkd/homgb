# Milestone 1: notification daemon on ImGui

Goal: homgb accepts `org.freedesktop.Notifications` over DBus and renders
notifications as ImGui popups — feature parity with deadd's popup path.

This document is written to be picked up by an agent with no prior context.
Read `.opencode/MEMORIES.md` first, then this file.

## Reference repos

### 1. `/home/pion/work/dev/linux_notification_center` — the daemon to port

Port these modules (they are the portable ~40% of deadd):

| deadd module | What to take | What to drop |
|---|---|---|
| `src/NotificationCenter/Notifications.hs` | `NotifyState`, `notify`, `modifyNoti`, `notificationDaemon`, DBus method table, `closeNotification`, `NotificationClosed`/`ActionInvoked` emission | `addSource` calls (GLib marshaling) — replace with direct TVar writes; `GI.Gio` icon guessing (drop for now, use `Image` raw data only); popup creation calls |
| `src/NotificationCenter/Notifications/Data.hs` | `Notification`, `Urgency`, `CloseType`, `Config` usage, Aeson instances | `rawImgToPixBuf` (GdkPixbuf) — replace with raw RGBA `(Int, Int, ByteString)` |
| `src/Config.hs` | whole module (YAML config, modification rules) | GTK-specific config fields (markup size hints are fine; drop `className`-style CSS hooks or map to style vars) |
| `src/Helpers.hs` | `removeAllTags`, `markupify` handling, list utils, gettext | nothing — pure |
| `src/NotificationCenter/Notifications/Action.hs` | action-button data model | GTK rendering |

Do **not** port: anything Glade, `TransparentWindow.hs`,
`NotificationPopup.hs`, `AbstractNotification.hs`, `NotificationInCenter.hs`,
`Button.hs` — those are the GTK presentation layer being replaced.

DBus interface spec: same methods deadd implements —
`GetCapabilities` (keep advertising `body-markup` only if you implement rich
text; otherwise drop it), `GetServerInformation`, `Notify`,
`CloseNotification`, signals `NotificationClosed`, `ActionInvoked`. Verify
against the freedesktop notification spec; deadd's implementation is the
working reference.

### 2. `/home/pion/work/dev/taffybar` — SNI tray (milestone 2, don't build yet)

`packages/status-notifier-item` is already a Hackage dependency of homgb
(GTK-free watcher + host). Milestone 2 will:

- run `StatusNotifier.Watcher.Service` + `StatusNotifier.Host.Service`,
- plug a `TVar`-writing `UpdateHandler` (`StatusNotifier.Host.Service`),
- render `ItemInfo` icons (raw ARGB pixmaps / icon-name + theme-path) as GL
  textures, crib icon-resolution logic from
  `packages/gtk-sni-tray/src/StatusNotifier/Icon/`,
- vendor `DBusMenu/Client.hs` + `DBusMenu/Reconcile.hs` from
  `packages/dbus-menu` as an internal library (Hackage `dbus-menu` drags
  gtk+-3.0 pkg-config — see MEMORIES.md).

### 3. dear-imgui API — local cabal store

Docs: https://hackage.haskell.org/package/dear-imgui-2.5.0 — modules
`DearImGui`, `DearImGui.Raw.*`. Working example of the full frame loop:
`src/Homgb.hs` (this repo).

## Design decisions for M1

1. **Single overlay window, panels inside.** Do not create one OS window per
   popup. One borderless always-on-top SDL window per monitor (or just the
   primary for M1); notification popups are ImGui windows laid out
   bottom-to-top (or top-right per config) inside it. This eliminates deadd's
   popup-stacking window-management code (`findBefore`, `windowMove`) —
   stacking becomes pure layout. Always-on-top and alpha stay open questions
   from M0; solve them inside this model (raw X11 raise loop / alpha GL attr).
2. **Timeouts in the render loop.** deadd uses `forkIO + threadDelay +
   addSource`. Instead store `notiExpiresAt :: UTCTime` in state; the frame
   loop checks expiry each frame and removes/close-signals them. No threads,
   no races.
3. **State model.** `TVar NotifyState` (ported from deadd, minus GTK
   callbacks) is written by the DBus thread; render reads it once per frame.
   ImGui interaction results (button click → action) go back through a
   `TVar [OutboxMsg]` (ActionInvoked/NotificationClosed calls) drained by the
   DBus thread, or call the DBus client directly from IO since `dbus` client
   calls are thread-safe — prefer the direct call, keep a comment.
4. **Images.** `Image` in Data.hs carries raw RGBA bytes. Load PNGs with
   `JuicyPixels` (add to cabal when you get there), upload once to a GL
   texture (dear-imgui `DearImGui.OpenGL3`/`Raw` texture helpers), cache by
   notification id. Freedesktop named-icon lookup is M2 (tray will share it).
5. **Rich text.** ImGui has no markup. For M1 render body as plain text
   (`removeAllTags`) and do NOT advertise `body-markup` in GetCapabilities.
   Note in code where a rich-text renderer would slot in.
6. **Styling.** Map deadd config (`notification-center.*`, urgency colors)
   to ImGui style colors/pushStyleColor at frame start. Ignore CSS.

## Tasks

- [ ] Port `Config.hs` → `src/Homgb/Config.hs` (drop CSS fields, keep YAML)
- [ ] Port `Helpers.hs` → `src/Homgb/Helpers.hs`
- [ ] Port `Data.hs` → `src/Homgb/Notifications/Data.hs` (raw RGBA Image)
- [ ] Port daemon core → `src/Homgb/Notifications/Daemon.hs`:
      own session-bus name `org.freedesktop.Notifications`, method table,
      `NotifyState` TVar
- [ ] `src/Homgb/Notifications/Render.hs`: popup panels (title, body, image,
      action buttons, close button, timeout progress), stacking layout,
      expiry handling
- [ ] Wire daemon into `Homgb.run` (forkIO DBus thread alongside render loop)
- [ ] `notify-send "hello"` shows a popup; default timeout closes it
- [ ] Action buttons fire `ActionInvoked` with the right index
- [ ] `CloseNotification` from a client removes the popup and emits
      `NotificationClosed` with correct reason code
- [ ] Urgency styling via `pushStyleColor`
- [ ] Update `.opencode/MEMORIES.md` with anything new learned

## Acceptance criteria

```sh
notify-send -u critical -t 5000 "title" "body"
notify-send --action="ok=OK" "actions test"
```

- Popup appears top-right (per config), styled by urgency, auto-closes.
- Clicking an action button emits `ActionInvoked` (watch with
  `dbus-monitor "interface='org.freedesktop.NotificationDaemon'"` or run
  a client like `notify-send` variants / `dbus-monitor` on the session bus).
- Multiple notifications stack vertically without overlap.
- No GTK in `ldd` output.

## Out of scope (later milestones)

Notification center panel (SIGUSR1 toggle), SNI tray, keyboard layouts,
multi-monitor, Wayland.
