# Wayland support: river backend via dbus-to-xmonad

Goal: run homgb natively on Wayland under river with mgsloan's
xmonad-on-river fork as the window manager. No X11 code is reachable in
this mode: no EWMH, no xcb-xkb, no XEmbed, no Xlib anywhere in the
process.

Read `.opencode/MEMORIES.md` and `design_docs/milestone_0.md` ..
`milestone_4.md` first.

## Why dbus-to-xmonad, not Wayland protocols in homgb

river master delegates ALL window-management policy — position, size,
focus, keybindings, stacking — to an external WM process speaking
`river-window-management-v1`. The xmonad-on-river fork (pinned in
`~/work/nix.config/modules/xmonad-river.nix`, rev
`dec3b72d726c766dfeba2a605f51e52073d96538`) is that process. It
already holds everything homgb's bar/taskbar/keyboard read over X11
today:

- workspaces (its own StackSet; hidden workspaces = river_window hide/show)
- window list, titles, app_id, focus, stacking, geometry
- layer-shell bindings (`river_layer_shell_v1`) — the fork, not river,
  decides which layer surfaces exist
- screens reconciled from river outputs

So homgb does NOT learn Wayland protocols. It stays a plain SDL3
Wayland client (xdg_toplevel surfaces, per-surface app_id) and talks
dbus to xmonad. This is the same division of labor as X11 (WM owns
state, homgb renders), with EWMH reads/client-messages replaced by dbus
signals/methods. The existing `org.homgb.Control` bus stays the
inbound path (WM keybindings -> busctl -> homgb); the new
`org.xmonad.WM` bus is the outbound state channel (xmonad -> homgb).

## Architecture

```
 xmonad-on-river (WM process)          homgb (client process)
 ┌────────────────────────────┐  dbus   ┌─────────────────────────┐
 │ river-window-management-v1 │◄───────►│ SDL3 Wayland windows    │
 │ StackSet (workspaces,      │ signals │  (app_id per surface)   │
 │  windows, focus, stacking) │────────►│ ImGui + GL render loop  │
 │ geometry (set_position)    │◄────────│                         │
 │ xkb layout (river seat,    │ methods │ SNI host + dbusmenu     │
 │  via river keyboard-layout)│         │ Notifications daemon    │
 └────────────────────────────┘         └─────────────────────────┘
```

Surface placement: homgb sizes surfaces itself (analytic, as today)
and asks xmonad to position floats: `PlaceSurface(appId, x, y, w, h,
stackOrder)`. xmonad applies `river_window_v1.set_position` and keeps
homgb floats stacked above toplevels, ordered among themselves by
stackOrder (menu > tooltip > popup > bar, matching today's window-id
ordering). Visibility stays client-side (don't draw / don't commit);
there is no map/unmap protocol dance.

The struts question disappears: xmonad IS the layout, so reserving the
bar strip is a layout margin in the xmonad config — no
_NET_WM_STRUT_PARTIAL, no exclusive zone, no stacking re-assert, no
show-then-resize float-map workaround.

Keyboard layouts: XKB lives in river's seat; homgb's xcb-xkb code is
X11-only and has no Wayland equivalent. xmonad applies group switches
via `river keyboard-layout` (VERIFY: exists on the pinned river rev)
and tracks the current group itself; homgb renders what xmonad
reports. Per-app memory keys on focused app_id from FocusChanged —
cleaner than WM_CLASS. Limitation carried over from X11: layout
changes made outside this channel are not attributed.

## DBus contract: org.xmonad.WM (session bus)

Implemented in the fork (new `XMonad.River.DBus` module; dbus-haskell
added to the `hpRiver` package set in the nix module). All state is
pushed as signals; homgb never polls.

Signals (xmonad -> homgb):

- `WorkspacesChanged a{s(bb)}` — name -> (current, nonEmpty)
- `WindowsChanged a(ssssb)`: identifier, title, app_id, workspace,
  focused — full list on any change (homgb diffs, as it does today);
  identifier is river's stable window identifier (a hex string), never
  the recycled object id
- `LayoutChanged (ias)`: current group index, layout names
- `FocusChanged (ss)`: title, app_id of the focused window ("" when
  none)

xmonad-side implementation: `XMonad.River.DBus`
(omgbebebe/xmonad@xmonad-on-river, commit b5ef196). Emission is a
self-requeuing `afterLayout` action (snapshot diff per manage
sequence) plus a 1s fallback timer for title/app_id changes; method
handlers run on dbus-haskell threads and re-enter via `postAction`.
`dbusService :: DBusConfig -> X ()` from startupHook; `dcSetGroup`
is the config's xkb hook (no default backend — session policy).
Verified by tests/headless-dbus.sh: name owned, initial burst, and
SwitchWorkspace flipping current — all passing against a headless
river.

Methods (homgb -> xmonad):

- `SwitchWorkspace(s name)`
- `FocusWindow(u id)`
- `NextLayout()` / `SetLayoutGroup(i n)`
- `PlaceSurface(s appId, i x, i y, i w, i h, i stackOrder)`

## homgb-side changes

### Step 1 — backend seam — DONE (2026-10-04)

`Homgb.Backend` (record) + `Homgb.Backend.X11` (existing code with the
tray display captured; `selectBackend` honors HOMGB_BACKEND=x11|
wayland). AppState carries `appBackend`; Homgb.hs/Render.hs route
show/hide/tag/strut/pointer/bar-upkeep/embed-host/keyboard through it.
Behavior unchanged on X11 (built warning-free; smoke-tested on the
river VM via XWayland: daemon + SNI + XEmbed host up, popup
accepted/expired). Wayland selection currently exits with "not
implemented yet".

### Step 1 — backend seam (original plan)

Introduce `Homgb.Backend`: a record of effect bundles abstracting every
X touchpoint, with the existing code as the X11 instance, moved
verbatim, behavior unchanged:

- `backendMonitors :: IO [Monitor]` (Xinerama now; SDL displays later)
- `backendPointer :: IO (Int32, Int32)` (root coords)
- `backendTagSurface :: Surface -> ...` — pre-map EWMH tagging
- `backendSurfaceOps` — map/lower/raise/unmap, query-tree fingerprint
- `backendSetStrut` / strut depth
- `backendBarEvents` — the startBarEvents thread + EWMH refresh behind
  a `BarSource` producing `BarState`
- `backendKeyboard` — the Xcb effect bundle
- `backendTrayEmbed` — the XEmbed host (absent under Wayland)

Selection of backend: env (`HOMGB_BACKEND=x11|wayland`), defaulting to
x11 when `DISPLAY` is set and wayland when `WAYLAND_DISPLAY` is set
and DISPLAY is not. XEmbed host only initializes on the x11 backend.

### Step 2 — Wayland backend

`Homgb.Backend.Wayland`: dbus client for the contract above; per-
surface app_id on SDL windows; SDL3 global mouse state for pointer;
XEmbed absent (SNI-only tray). Bar/keyboard modules take their state
from TVars filled by dbus signal handlers, same as today's event
threads.

Already portable, untouched: Notifications daemon, SNI host, dbusmenu,
menus, Control interface, theming, fonts, GL textures.

### xmonad-side work (separate repo) — dbus service DONE

- `XMonad.River.DBus` (omgbebebe/xmonad@xmonad-on-river, b5ef196):
  owns org.xmonad.WM, emits the signals above (snapshot diff per
  manage sequence + 1s fallback), applies methods via postAction.
  Verified end-to-end by tests/headless-dbus.sh against headless
  river.
- Still config-level: `startupHook = dbusService defaultDBusConfig`
  in xmonad-river's xmonad.hs; layout margin for the bar strip; float
  rules per homgb app_id; `dcSetGroup` backend (riverctl
  keyboard-layout was absent from the river 0.4.5 nix output — decide
  the xkb switch path).

## Status of dependencies

The fork's README.river.md (pinned rev): "it manages a window against
a real compositor... real keyboard input, the mailbox, workspace
switching have not run". The Wayland backend assumes the fork reaches
a working desktop; until then the X11 backend remains the daily
driver and the seam keeps both alive.

## Known gaps / non-goals

- XEmbed tray: SNI-only under Wayland (decided 2026-10-04).
- Menu outside-click close over foreign Wayland-native surfaces:
  compositors don't expose global button state; SDL3 global mouse
  state covers homgb's own surfaces and is the fallback. If it proves
  blind, menus become keyboard-grab layer surfaces owned by xmonad
  (escalation, later).
- XWayland apps get river's seat xkb like everyone else; no separate
  X11 layout state exists to manage.
