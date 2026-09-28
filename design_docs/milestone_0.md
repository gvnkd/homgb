# Milestone 0: platform skeleton

Goal: prove the SDL2 + OpenGL3 + dear-imgui platform layer on X11. One
borderless window, one ImGui frame loop, TVar state flowing from a background
thread into the UI. Nothing else.

## Why first

Every later feature (notifications, tray, layouts) hangs off this loop. If
transparent always-on-top windows don't work here, better to know now.

## Deliverables

- [x] cabal project with `dear-imgui` (+sdl +opengl3 flags), `sdl2`, `gl`
- [x] flake.nix devShell with SDL2/libGL/xorg build deps
- [x] `Homgb.run`: SDL init → GL context → ImGui context → frame loop
- [x] `Homgb.State`: `TVar AppState`
- [x] `Homgb.Render`: per-frame UI reading the TVar
- [x] `cabal build all` green (ghc-9.10.3, dear-imgui-2.5.0, sdl2-2.5.6.1)
- [x] Verified running under X11 (2026-09-28): borderless window renders,
  ImGui frame live, button/counter TVar plumbing works
- [ ] Verified transparent background — window shows black; unclear if
      compositor alpha is working or clear color is opaque. Check with
      `picom` running and alpha-sized GL attribute (see open question 2)
- [ ] Window positioned relative to screen edges (top-right default)

## Module layout (established by this milestone)

```
app/Main.hs          thin entry point
src/Homgb.hs         run, window creation, mainLoop
src/Homgb/State.hs   app state TVars
src/Homgb/Render.hs  per-frame ImGui widgets
```

Later modules slot in next to these: `Homgb.DBus.*`, `Homgb.Tray`,
`Homgb.Keyboard`, `Homgb.Platform` (multi-window).

## Open questions to resolve here

1. **Always-on-top**: the `sdl2` binding does not expose
   `SDL_WINDOW_ALWAYS_ON_TOP`. Options: raw X11 (`X11` package) raise loop,
   `_NET_WM_STATE` toggle, or patch upstream binding. Pick before M2 (popups).
2. **Alpha channel**: if the window is opaque, set an 8-bit alpha GL
   attribute before `glCreateContext` and clear with alpha 0.
3. **Multi-window**: one ImGui context per SDL window, or a single overlay
   window with internal panels? Decide before M2 — it determines whether
   popup stacking is OS-window management or ImGui layout.

## Acceptance criteria

- `cabal run exe:homgb` opens a borderless 400x300 window.
- Clicking the button increments the counter (proves TVar plumbing).
- Window closes cleanly on WM close / Ctrl-C.
- No GTK libraries in `ldd` output of the binary.

## Out of scope

DBus, tray, keyboard layouts, notification rendering, config files.
