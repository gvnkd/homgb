# Taiga

- Project: HomgB (id 15, slug `homgb`), milestone "Milestone 1" (id 182).
- `taiga-cli` quirks: init needs full `http://localhost:8000/api/v1` URL;
  token goes to `~/.taiga_token` (not project `.taiga/`); `task list` is
  NOT filtered by active project (shows other projects' tasks); PATCH
  needs current `version` field. For milestone/task changes use curl with
  `~/.taiga_token` (see session history 2026-09-28).

# homgb

X11 notification daemon + StatusNotifierItem tray host + keyboard layout manager.
SDL2 windowing, dear-imgui (OpenGL3) rendering. No Wayland in early milestones.

## Architecture

One process:

- **DBus threads** (`forkIO`): `org.freedesktop.Notifications` daemon (ported from
  deadd-notification-center), `org.kde.StatusNotifierWatcher` host via the
  `status-notifier-item` Hackage package.
- **X11 thread**: global hotkeys via `XGrabKey` (SDL cannot grab global keys),
  keyboard layout state.
- **SDL render loop**: dear-imgui frames, reads `TVar` state (no GLib `idleAdd`
  — DBus threads write TVars, render loop polls/diffs each frame).

Surfaces (one SDL borderless always-on-top window each): tray bar, notification
popups, notification center panel.

## Build / run

Commands must run inside the flake env — this repo has `.envrc`, so use the
wrapper (see AGENTS.md): `~/bin/env-wrap cabal build`.

- Build: `cabal build`
- Run: `cabal run exe:homgb`
- REPL: `cabal repl lib:homgb`

## Key dependencies

| Package | Role | Notes |
|---|---|---|
| `dear-imgui` | UI | flags set in `cabal.project`: `+sdl +opengl3 -vulkan` |
| `sdl2` | windowing/input | no always-on-top flag exposed; may need X11-side raise |
| `status-notifier-item` | SNI watcher+host | GTK-free; seam is `StatusNotifier.Host.Service`'s `UpdateHandler = UpdateType -> ItemInfo -> IO ()`; `ItemInfo` carries `iconName`/`iconThemePath`/raw ARGB pixmaps |
| `dbus-menu` | tray item menus | client side is DBus-only; render menus as ImGui widgets |
| `dbus` | notification daemon | same package deadd uses |
| `X11` | hotkeys, monitor info | needs xorg dev libs in shell (in flake.nix) |

## Reference code

- `/home/pion/work/dev/taffybar` — SNI implementation source of truth.
  `packages/status-notifier-item` is the GTK-free library we depend on;
  `packages/gtk-sni-tray/src/StatusNotifier/Icon/` has icon-resolution and
  ARGB-pixmap logic to crib for texture upload.
- `/home/pion/work/dev/linux_notification_center` — the daemon being replaced.
  Portable parts: `src/Config.hs`, `src/Helpers.hs`,
  `src/NotificationCenter/Notifications.hs` (DBus core, ~75% portable),
  `src/NotificationCenter/Notifications/Data.hs`. Replace `addSource`
  marshaling with TVar writes.

## Keyboard layouts

- Switch: shell out to `setxkbmap` (what `xkb-switch` does internally).
- Indicator: poll `setxkbmap -query` on tray refresh.
- No `xkbcommon` Haskell binding needed for now.

## Known pitfalls

- **direnv/nix**: after creating/modifying `flake.nix` or `cabal.project`,
  `git add` them (nix flakes only see git-tracked files) and re-run
  `direnv allow`, or `~/bin/env-wrap` silently falls back to the outer env.
- **dear-imgui opengl3 backend needs `glew`** (pkg-config) — in flake.nix.
- `status-notifier-item` pulls `zlib` C lib — in flake.nix.
- **`dbus-menu` (Hackage) is unusable**: its Cabal file requires pkg-config
  `gtk+-3.0`. When we get to tray menus, vendor `DBusMenu/Client.hs` +
  `DBusMenu/Reconcile.hs` from the taffybar checkout (they are GTK-free)
  as an internal library.
- dear-imgui 2.5 `withWindowOpen` requires `MonadUnliftIO` — keep render
  functions in `IO`, don't generalize.
- `sdl2` (2.5.6.1) `windowPosition :: WindowPosition` is
  `Centered | Wherever | Absolute (P (V2 x y))`; `P`/`V2` come from
  `SDL.Vect` (re-exported by `SDL`). No `SDL_WINDOW_ALWAYS_ON_TOP` flag.
- Transparency requires a running compositor (picom/compton).
- SDL2's OpenGL alpha on X11 needs verification — if the window comes out
  opaque, request an 8-bit alpha GL attribute before context creation.
- The Haskell `X11` package builds against system libs; they are in the flake.
  Building `X11` from a git checkout additionally needs autoreconf — use the
  Hackage tarball.
- `dear-imgui` compiles C++ via inline-c-cpp; needs `gcc` in PATH (in flake).
- cabal v2 rebuild checks ignore `touch` (content-hash based); edit the file
  to force recompilation when iterating on warnings.
- In zsh, `echo ===` fails (`=cmd` expansion) — quote it.
- deadd's `getTime` uses `System.Locale.Current`; we use
  `defaultTimeLocale "%H:%M"` (Data.Time).
- dear-imgui 2.5 has no high-level `image`/flagged `begin`; use
  `DearImGui.Raw` (ptr-based: `Raw.begin label Nothing (Just flags)`,
  `Raw.image`, `Raw.pushStyleColor`) with `withImVec2`/`withImVec4` poke
  helpers. `ImVec2/ImVec4/ImTextureRef` are re-exported from `DearImGui`
  and are `Storable`. No `Semigroup ImGuiWindowFlags` — combine with
  bitwise `.|.` on the underlying `CInt`.
- GL constants in the `gl` package are polymorphic (`Num a`); annotate
  (`fromIntegral (GL_LINEAR :: GLenum) :: GLint`) to silence defaulting.
- `ImTextureRef nullPtr texId` works as an OpenGL texture ref (texID =
  GLuint as u64); no picom on Sergey's XWayland — transparent bg untested.
- `dbus` package `connectSession` per call; name ownership:
  `requestName` with `nameReplaceExisting` only steals the name if the
  current owner allowed replacement — Plasma does NOT. Test with
  `dbus-run-session -- ...` (private bus); `notify-send` is not installed,
  use `dbus-send`. `busctl --user monitor org.freedesktop.Notifications`
  watches signals.
- deadd semantics kept: `NotificationClosed` is only emitted when
  `notification.dbus.send-noti-closed: true` (config), NOT by default.
- Self-testing recipe (Sergey's X11/xmonad session, Display :1):
  xdotool, imagemagick, flameshot, xprop, xwininfo, libnotify
  (notify-send), dbus (dbus-run-session/dbus-monitor) are all in the
  flake devShell now. Screenshots: `DISPLAY=:1 flameshot full -p /tmp/`,
  then `magick <png> -crop WxH+X+Y +repage -resize 150% /tmp/crop.png` and
  view the file. NEVER `pkill -f` with a pattern that appears in the
  wrapper shell's own command line (it kills the shell) — use `pkill -x`.
  busctl Notify syntax: dicts need an entry COUNT —
  `busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications
  org.freedesktop.Notifications Notify susssasa{sv}i app 0 x title body 0 1 urgency y 2 0`
  (array `0` = empty, dict `1 urgency y 2` = one entry). dbus-send
  `dict:string:variant:urgency:byte:2` fails with "Malformed dictionary"
  — use busctl.
- Keep homgb alive across tool calls:
  `setsid ~/bin/env-wrap dbus-run-session -- sh -c '... homgb & busctl monitor &; echo export DBUS...=/tmp/bus.env; sleep 300' < /dev/null > /dev/null 2>&1 &`,
  then `source /tmp/bus.env` in later commands.
- Timeout semantics (deadd `startTimeoutThread`): 0 = never, >0 = ms,
  <0 = `popup.default-timeout` ms. Expiry is checked in the render frame
  loop (`isExpired` in Render.hs), no threads.
- `parseHtmlEntities` was ported without regex-tdfa (hand-rolled scanner);
  Helpers only carries pure functions (no i18n/ConfigFile).
- deadd's `Notification` gained `notiCreatedAt :: UTCTime` (needed for
  frame-loop expiry); `notiClassName` and `rawImgToPixBuf` dropped.

## Roadmap

- Milestone 0: `design_docs/milestone_0.md` — SDL+GL+ImGui skeleton.
- Then: port notification daemon → tray → keyboard layouts.
