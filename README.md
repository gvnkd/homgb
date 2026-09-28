# homgb

X11 notification daemon, StatusNotifierItem tray host, and keyboard layout
manager — one Haskell process, SDL2 windowing, dear-imgui (OpenGL3) rendering.
No GTK. No Wayland (initially).

Built to replace [deadd-notification-center](https://github.com/phuhl/linux_notification-center)
(GTK3) and the usual assortment of tray applets and layout indicators with a
single immediate-mode application.

## Status

Milestone 0 done: SDL2 + OpenGL3 + dear-imgui skeleton builds and runs,
TVar state flows into the ImGui frame. See `design_docs/milestone_0.md`.

Current milestone: porting the notification daemon — `design_docs/milestone_1.md`.

## Build & run

Requires Nix (flakes). The repo has `.envrc`; agents must use the wrapper
(see `.opencode/MEMORIES.md` for the full pitfall list).

```sh
direnv allow          # once, and after touching flake.nix / cabal.project
cabal build           # build
cabal run exe:homgb   # run
cabal repl lib:homgb  # REPL
```

Runtime requirements: X11, a compositor (`picom`) for transparency,
`setxkbmap` for keyboard layout switching.

## Architecture

One process, three kinds of threads:

- **DBus threads** (`forkIO`): notification daemon
  (`org.freedesktop.Notifications`), later the SNI watcher/host via
  `status-notifier-item`.
- **X11 thread**: global hotkeys (`XGrabKey`), layout state.
- **SDL render loop**: dear-imgui frames; reads `TVar` state each frame.
  No GLib `idleAdd` — DBus threads write TVars, the render loop diffs.

Surfaces (borderless SDL windows): tray bar, notification popups,
notification center panel.

```
app/Main.hs        entry point
src/Homgb.hs       run, window creation, mainLoop
src/Homgb/State.hs app state TVars
src/Homgb/Render.hs per-frame ImGui widgets
design_docs/       milestones
.opencode/MEMORIES.md  build pitfalls, dependency notes, roadmap
```

## Key dependencies

| Package | Role |
|---|---|
| dear-imgui | UI (flags in `cabal.project`: `+sdl +opengl3 -vulkan`) |
| sdl2 | windowing/input |
| dbus | DBus client+server (same lib deadd uses) |
| status-notifier-item | GTK-free SNI watcher/host (Hackage 0.3.2.16) |
| X11 | hotkeys, monitor geometry |
| yaml/aeson/tagsoup/haskell-gettext | ported from deadd (config, markup, i18n) |

## License

BSD-3-Clause
