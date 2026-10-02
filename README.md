# homgb

X11 notification daemon, StatusNotifierItem tray host, keyboard layout
manager, and status bar — one Haskell process, SDL3 windowing,
dear-imgui (OpenGL3) rendering. No GTK. No Wayland (yet).

Built to replace [deadd-notification-center](https://github.com/phuhl/linux_notification-center)
(GTK3), `xmobar`/`trayer`, and the usual assortment of tray applets
and layout indicators with a single immediate-mode application.

## Features

- **Notification daemon** — `org.freedesktop.Notifications`,
  deadd-compatible config semantics: per-urgency styling, actions,
  modification rules (match + modify, incl. `margin-top`/`margin-right`
  placement), timeout semantics (0 = never, <0 = configured default).
  Popup stack at a screen corner plus a persistent **notification
  center panel** (toggle over DBus, history, dismiss/clear-all).
- **SNI tray host** — `org.kde.StatusNotifierWatcher` via the
  GTK-free `status-notifier-item` package; icon theme / pixmap / SVG
  icons; right-click **dbusmenu** on its own `POPUP_MENU` surface;
  hover tooltips (incl. multi-line, emoji) on their own `TOOLTIP`
  surface; left-click `Activate` (async, never blocks the UI).
- **Keyboard layout manager** — XKB group lock via xcb (no
  `setxkbmap` round-trips, survives keymap reloads); **no global key
  grabs**: the WM binds shortcuts to the `org.homgb.Control` DBus
  interface (`NextLayout`, `ToggleCenter`), which also works on
  Wayland sessions.
- **Status bar** (xmobar replacement, phase 1–3): xmonad workspaces
  from EWMH (left-click switches), active window title (flexible
  width), optional taskbar (`bar.windows`), tray icons, layout
  indicator, clock (`HH:MM`), date (`dd.mm`) — event-driven (X event
  listener, no polling), auto-hide when a window covers the strip
  (ToggleStruts/fullscreen), `_NET_WM_STRUT_PARTIAL` for
  `avoidStruts`.
- **Theming** — `theme:` config section: fonts (fontconfig family or
  path, per-widget sizing, merged fallback chain for emoji/Nerd Font
  icons, Cyrillic glyph ranges), hex colors (`#RRGGBB[AA]`), tray
  icon size/spacing, margins/paddings.
- **Multi-monitor** — Xinerama enumeration; `monitor`/`follow-mouse`
  placement for the bar, popups, and the center panel; menus/tooltips
  clamp to the monitor under the cursor.

## Build & run

With Nix (flakes) — no checkout needed:

```sh
nix run github:gvnkd/homgb        # fetch, build, run
nix build github:gvnkd/homgb      # just build
```

From a checkout (development uses the dev shell; agents must use the
wrapper — see `.opencode/MEMORIES.md` for the full pitfall list, read
it before hacking):

```sh
direnv allow          # once, and after touching flake.nix / cabal.project
cabal build           # build
cabal run exe:homgb   # run
cabal repl lib:homgb  # REPL
nix build             # build via the flake (package set pinned in nix/)
```

The flake pins the Haskell dependencies nixpkgs doesn't carry
(`nix/*.nix`: dear-imgui 2.5.0, status-notifier-item 0.3.2.16,
sdl3-bindgen-sys) and builds SDL3 without audio/IME/tray/vulkan
support — homgb needs none of them, and nixpkgs' defaults pull
ibus/gtk+3/pipewire into every consumer's closure.

Runtime requirements: X11 (XWayland works), fontconfig (`fc-match`),
optional compositor for translucency. Recommended fonts:
`noto-fonts-monochrome-emoji` (or Symbola) for emoji and
`nerd-fonts.symbols-only` for icon glyphs — see `theme.font.fallbacks`.

## Configuration

`~/.config/homgb/config.yml`; when absent, the built-in defaults
(`defaultConfigText` in `src/Homgb/Config.hs`) apply — copy that as a
starting point. Sections: `notification` (popups, image, dbus,
modifications), `notification-center`, `buttons`, `tray` (icon size,
spacing, position, monitor, `behind-windows`), `bar` (`layout`,
`workspaces`, `windows`, `window-title-max`, `struts`), `theme`
(font/colors/sizes), `keyboard`.

## xmonad integration

`XMonad.Hooks.EwmhDesktops` maintains the EWMH root properties the
bar reads, so no log pipe is needed. Minimal bits:

```haskell
xmonad $ (docks . ewmh . ewmhFullscreen) def { ... }

myStartupHook = do
  ...
  spawnOnce "/path/to/homgb-start &"   -- pgrep-guarded launcher

myManageHook = composeOne
  [ className =? "homgb-menu"    -?> (doFloat <> hasBorder False)
  , className =? "homgb-tooltip" -?> (doFloat <> hasBorder False)
  , className =? "homgb-popups"  -?> (doFloat <> hasBorder False)
  , className =? "homgb-center"  -?> (doFloat <> hasBorder False)
  , ...
  ]

-- no global grabs in homgb: the WM binds the shortcuts
, ("M-<Space>", spawn "busctl --user call org.homgb /org/homgb/Control org.homgb.Control NextLayout")
, ("M-n", spawn "busctl --user call org.homgb /org/homgb/Control org.homgb.Control ToggleCenter")
```

## Architecture

One process:

- **DBus threads** (`forkIO`): notification daemon, SNI watcher/host
  (item updates arrive as signals; callbacks write TVars).
- **X event thread**: blocks in `XNextEvent` on its own connection
  (root substructure+property selection) and dirties the bar state —
  the EWMH workspace/taskbar data is refreshed on events only.
- **Render loop**: one SDL3 window per surface (tray bar, popups,
  menus, center, tooltip), each with its own ImGui + GL context;
  per-frame TVar diffs; z-order re-asserted after WM restacks.

```
app/Main.hs               entry point
src/Homgb.hs              run, surfaces, mainLoop, event routing
src/Homgb/Bar.hs          EWMH workspaces/taskbar/clock, X event listener
src/Homgb/Config.hs       YAML config (deadd-compatible keys)
src/Homgb/Theme.hs        theming: fonts (merged fallbacks), colors, sizes
src/Homgb/Monitors.hs     Xinerama monitor enumeration/selection
src/Homgb/Render.hs       popups, center panel, menus, tooltip surfaces
src/Homgb/Tray.hs         SNI host state, tooltip handoff
src/Homgb/Tray/Render.hs  tray icons, layout indicator, workspace row
src/Homgb/Tray/Menu/      dbusmenu client/tree/render
src/Homgb/Notifications/  DBus notification daemon
src/Homgb/Keyboard/       xcb XKB group lock/poll
src/Homgb/Control.hs      org.homgb.Control DBus interface
src/Homgb/Surface.hs      surface lifecycle (map/lower/raise, struts)
src/Homgb/WMProps.hs      EWMH tagging, _NET_WM_STRUT_PARTIAL
cbits/                    C++ shims: SDL3 ImGui backend, font loading
vendor/imgui              upstream imgui 1.92.8 (SDL3 backend source)
design_docs/              milestone designs
.opencode/MEMORIES.md     build pitfalls, WM behavior notes, debugging traps
```

## Key dependencies

| Package | Role |
|---|---|
| `sdl3-bindgen-sys` | complete generated SDL3 bindings |
| `dear-imgui` 2.5 | UI (`-sdl +opengl3`; SDL3 backend compiled in-tree) |
| `dbus` | DBus client+server |
| `status-notifier-item` | GTK-free SNI watcher/host (0.3.2.16) |
| `X11` / `xcb` + `xcb-xkb` | EWMH reads, monitor info, XKB group lock |
| `yaml`/`aeson` | config |

## Status & roadmap

Milestones 1–4 shipped (daemon, tray + dbusmenu, keyboard manager,
multi-window surfaces + notification center, multi-monitor, the bar
phases). Rough next steps: render-on-demand frame loop (power), more
bar widgets (layout name, sysinfo), XEmbed tray icons (to retire
`trayer` fully).

## License

BSD-3-Clause
