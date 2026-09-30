# Milestone 4: multi-window architecture (+ notification center panel)

Goal: replace the single 500x700 overlay with one borderless ARGB
window per surface, give each surface correct EWMH properties, stop
swallowing clicks on empty overlay area, and use the new architecture
to add the notification center panel.

Read `.opencode/MEMORIES.md`, `design_docs/milestone_1.md` ..
`milestone_3.md`, then this file.

## Why

The single overlay (M1 shortcut) is now actively wrong:

- eats all mouse clicks in its 500x700 rect (empty areas included);
- one `_NET_WM_WINDOW_TYPE` for tray + popups + menus (DOCK for
  everything transient is wrong; NOTIFICATION for the tray is wrong);
- windows can't be placed per-monitor — everything is relative to one
  window's client area;
- xmonad draws borders whenever manage-time tagging races the map
  (fixed in M3 by pre-map tagging, but the single type remains wrong).

This restores the architecture from the project design notes:
"Surfaces (one SDL borderless always-on-top window each): tray bar,
notification popups, notification center panel."

## Design decisions

1. **One SDL window per surface.** Surfaces at M4:
   - `TrayBar` — EWMH DOCK, holds tray icons, layout indicator,
     dbusmenu windows (menus live in the tray surface initially).
   - `NotiPopups` — EWMH NOTIFICATION, stacked popup cards at a screen
     corner (one window hosting the stack, as today).
   - `NotiCenter` — EWMH DOCK, the new notification center panel
     (toggled by hotkey, lists persistent notifications, M4 feature).
   - Menus get their own POPUP_MENU surface in a later phase (they
     already work inside the tray surface).

2. **Per-surface ImGui context, one shared GL context.**
   - `DearImGui.Raw.createContext` / `setCurrentContext` per surface.
     Each context auto-builds its own default font atlas; fine for M4.
   - ONE `GLContext` created on the first surface's window, then
     `SDL.Video.glMakeCurrent window glContext` per surface per frame.
     All SDL windows must use the same X visual (our ARGB visualid
     hint already forces one) — this is what makes single-context
     legal on GLX.
   - Consequence: GL texture ids are valid across surfaces
     (same context namespace); existing texture caches keep working.

3. **Input: own per-surface event shim (fork dear-imgui).** The
   vendored `imgui_impl_sdl2.cpp` is single-window: it drops events
   whose `windowID` isn't the main window (GetViewportForWindowID
   returns only the main viewport) and has no multi-viewport support.
   Rather than write a C++ PlatformIO backend, we fork the
   dear-imgui Hackage package (source-repository-package in
   cabal.project) and add small Raw bindings:
   - `Raw.addMousePosEvent/addMouseButtonEvent/addMouseWheelEvent`
     (`ImGui::GetIO().Add*Event` — 1.87+ event API),
   - `Raw.setDisplaySize` / `Raw.setDeltaTime`,
   - keep everything else unchanged.
   homgb's event loop routes each SDL event to its surface's context
   by `eventWindow` (mouse pos translated into that window's client
   coords via `windowPosition`) and feeds io directly. Keyboard/text
   events go to the focused surface (the one under the cursor, which
   is the only interactive surface at a time in practice).

4. **EWMH per surface, pre-map.** Generalize `Homgb.WMProps`: tag each
   surface window with its type before `showWindow`. Reuse the C shim
   (find-by-pid must become find-by-pid+index or take the window id
   from SDL — SDL's `getWindowWMInfo` isn't bound; simplest is to set
   `_NET_WM_PID` plus a unique `WM_NAME`/class per surface and match
   on that, or enumerate root children by pid and tag all of them —
   one tag call per surface window with its own expected class).

5. **Surface sizing/positioning.** Each surface's ImGui window uses
   `AlwaysAutoResize` + `NoMove` + `setNextWindowPos`, positioned in
   the owning surface's OWN client coordinates (same code as today,
   since each surface window is now its own coordinate space).
   Popups stack top-down from `configDistanceTop` relative to the
   NotiPopups window placed at the target corner. Multi-monitor
   comes in a later phase via Xinerama/XRandR + one NotiPopups
   surface per monitor.

## Render loop (per frame)

```
pollEvents  (one SDL queue; route by windowID to surfaces)
for each surface:
  glMakeCurrent (sWindow surface) glContext
  Raw.setCurrentContext (sImGui surface)
  setDisplaySize (drawable size of sWindow)
  setDeltaTime dt
  openGL3NewFrame; newFrame
  drawSurfaceWidgets surface   -- renderTray / renderPopups / renderCenter
  glClearColor 0 0 0 0; glClear
  renderDrawData =<< getDrawData
  glSwapWindow (sWindow surface)
```

Hide/close a surface by not rendering it (`SDL.hideWindow`/`showWindow`
on toggle, e.g. notification center).

## Phases

- **4.1 infra**: fork dear-imgui into `vendor/dear-imgui` (git
  submodule or in-tree copy), cabal.project source dep, Raw event
  bindings, `Homgb.Surface` type + surface registry, render loop
  rework, event router, WMProps generalized per window. Tray moves
  to its own surface. Behavior identical to M3 otherwise.
- **4.2 popups**: NotiPopups surface (NOTIFICATION type), stacking
  logic unchanged, expiry unchanged.
- **4.3 notification center**: NotiCenter surface (DOCK), config
  `notification-center.*`, toggle hotkey (reuse the X11 grab thread
  with a second binding or a key like Super+N), lists persistent
  notifications, dismiss buttons, "clear all"; keeps M1 daemon state.
- **4.4 menus** (stretch): separate POPUP_MENU surface anchored at
  cursor.
- **4.5 multi-monitor**: monitor enumeration, per-monitor popup
  surface, `monitor`/`follow-mouse` config keys start working.

## Acceptance criteria (M4 core: 4.1–4.3)

- `xprop` shows DOCK on tray + center, NOTIFICATION on popups.
- No WM borders on any homgb window (pre-map tagging).
- Clicks outside surfaces reach other X apps.
- Notification center toggles via hotkey, lists/dismisses
  notifications, doesn't affect popup behavior.
- M1–M3 features (daemon, tray, menus, layouts) unaffected.

## Risks / open questions

- **Click-through within a surface's own empty pixels**: not
  addressed (SDL X11 hit-test support is uncertain under
  sdl2-compat). Surfaces shrink-wrap content, so the swallowed area
  is bounded by the surface rect, not a fullscreen overlay.
- **Shared-context caveat**: all surfaces must share the ARGB visual;
  if the visualid probe fails we fall back to today's single opaque
  overlay (keep the M3 code path as fallback).
- **Keyboard events**: routed to the surface under the cursor; if
  text input is ever needed in multiple surfaces simultaneously,
  revisit with focus tracking.
- Fork upkeep: record our delta to upstream dear-imgui 2.5 in
  `vendor/README` (or submodule + patch file) so rebasing is cheap.
