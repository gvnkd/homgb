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

## Milestone status

- M1 (notification daemon): done, `160aee7`.
- M2 (SNI tray + dbusmenu): done, core `2a6e958`; menus in follow-up commit.
  Design: `design_docs/milestone_2.md`.
- M3 (keyboard layout manager): done. XCB group lock instead of
  setxkbmap (Sergey's call). Design: `design_docs/milestone_3.md`.
- M4+: notification center panel, multi-monitor.

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

- M3 implemented via XCB, NOT setxkbmap: `cbits/homgb-xkb.c` +
  `Homgb.Keyboard.Xcb` FFI. Group lock = `xcb_xkb_latch_lock_state`
  (lockGroup=1); current group = `xcb_xkb_get_state`; layout rotation
  list = root `_XKB_RULES_NAMES` property (3rd string, comma-separated).
- **libxcb in nixpkgs ships libxcb-xkb** (header `xcb/xkb.h`,
  `xcb-xkb.pc`) — no extra package; but flake.nix needs BOTH
  `xorg.libxcb` and `xorg.libXdmcp` (`xcb.pc` Requires.private xdmcp,
  pkg-config configure fails otherwise). Cabal: `pkgconfig-depends:
  xcb, xcb-xkb` + `c-sources`.
- xcb 1.17: `xcb_xkb_get_state_reply_t` field is `group` (NOT
  `groupState` — that name is from Xlib docs).
- An xcb connection is NOT thread-safe for concurrent requests:
  homgb opens one per thread (switch thread vs render-poll thread).
- XKB group lock PERSISTS across `setxkbmap` reloads; indicator staleness
  is handled by polling `get_state` from the render loop, rate-limited
  to 1/s (`pollGroup`).
- `XGrabKey` on an already-grabbed combo (e.g. a second homgb instance)
  = BadAccess printed by Xlib's default error handler, then process
  exit. Check `pgrep homgb` before testing.
- Grab matching: server masks LockMask/Mod2Mask, one grab per exact
  combo suffices. Hotkey parse: `stringToKeysym` for the key name,
  `keysymToKeycode` for the grab.

## Threaded RTS (CRITICAL)

- exe MUST be built with `-threaded` (homgb.cabal ghc-options). Without
  it any blocking C call freezes the ENTIRE runtime. Symptom: process
  alive, log file ends mid-line, wedge point moves between runs (GC /
  preemption timer fires at random spots). M1/M2 only survived because
  dbus/SDL used non-blocking fds; M3's XNextEvent + xcb reply-waits
  exposed it. `binary +RTS -N2 -RTS` errors with "requires -threaded"
  if you need to check a build.

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
- Transparency requires a running compositor (picom/compton/
  fastcompmgr). Implemented: depth-32 window + `glClearColor 0 0 0 0` +
  transparent `ImGuiCol_WindowBg` on the tray window (popups/menus keep
  opaque bgs).
- **nixpkgs SDL2 is sdl2-compat (SDL3)**: `SDL_GL_ALPHA_SIZE` alone
  still yields a depth-24 (opaque) window, and
  `SDL_VIDEO_X11_WINDOW_VISUALID` is read ONCE at SDL video init —
  setting it after `initializeAll` is silently ignored. homgb therefore
  queries GLX BEFORE initializeAll (`Homgb.GL.Visual.glxAlphaVisual`,
  C shim `homgb_glx_alpha_visual`) and sets the hint.
- Mesa gotcha: `glXChooseFBConfig` with GLX_ALPHA_SIZE 8 returns a
  FB config whose XVisualInfo is depth 24 on this driver — compositors
  treat that as opaque. Must check `vi->depth == 32`; fallback scans
  depth-32 TrueColor visuals for GLX capability (`glXGetConfig
  GLX_USE_GL/GL_ALPHA_SIZE`). Visual ids are driver-specific; never
  hardcode (0x7a works here, 0x23 BadMatches).
- Without a compositor an ARGB window renders black — same as before,
  acceptable.
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
  `setsid -f ~/bin/env-wrap dbus-run-session -- sh -c '... homgb & ...; sleep 300' < /dev/null > /dev/null 2>&1`
  (plain `setsid ... &` intermittently never starts the child; `-f` forks
  reliably). When the wrapped command's sleep expires, dbus-run-session
  TEARS DOWN the private bus — homgb then logs fatal ClientError per
  connection ("Unexpected end of input while parsing message header").
  That error means THE BUS DIED, not a parse bug.
- Tray testing: DON'T bother with private buses — kded on the real session
  bus already runs `org.kde.StatusNotifierWatcher`; blueman/steam register
  there and homgb's host attaches without name conflicts (only
  Notifications is queue-blocked by Plasma). Screenshot-verified.
- `steam_tray_mono` is a *white monochrome* icon — renders as a white blob
  at 22px; not a bug. SNI pixmaps from the host arrive in HOST byte order
  (B,G,R,A on LE — `Homgb.GL.Texture.bgraToRgba`); M1 notification
  `image-data` hints arrive in NETWORK order (A,R,G,B — `argbToRgba`).
- dear-imgui 2.5 has `setItemTooltip :: Text -> IO ()` (tooltip for the
  last item) — used for tray hover text. There is NO mouse-wheel binding:
  tray Scroll support needs SDL wheel events (TODO).
- **`withWindowOpen`/`with` take NO window flags** — a `let flags = ...`
  next to them is silently unused (GHC warns, heed it!). The window then
  gets a title bar + a tiny remembered size, and clips all content: looks
  exactly like "widgets render but only 1-2 clipped rows appear". ALWAYS
  use `Raw.begin label Nothing (Just flags)` + `end` for decorated-less
  windows (see Tray.Render/Menu.Render). This cost hours: the "mystery
  ▼+glyph window" following the tray was the menu's own title-bar/collapse
  arrow sitting on top of a clipped menu.
- ImGui auto-opens a collapsed `Debug##Default` (Debug Log) window on
  usage errors; it then persists its position in `imgui.ini` (gitignored —
  DELETE it when window geometry acts weird). `HOMGB_METRICS=1` env shows
  the metrics window (`Raw.showMetricsWindow`); its Windows/DrawLists
  sections enumerate every ImGui window with vertex counts — the fastest
  way to find who renders what.
- dbusmenu: `Event`/`GetLayout`/`AboutToShow` must be sent to the item's
  **Menu object path** (from the `Menu` property, e.g.
  `/org/ayatana/NotificationItem/steam/Menu`), NOT the item path. Root
  layout node (id 0) is virtual — steam marks even it
  `children-display: submenu`; always render `lnChildren` of the root.
  GetLayout reply = `(u revision, (ia{sv}av))`; parseable via
  `fromVariant :: Variant -> Maybe (Int32, Map Text Variant, [Variant])`.
- Default ImGui font has NO Cyrillic glyphs (steam's Russian menu labels
  render as ?????). Load a font with `GetGlyphRangesCyrillic` when needed.
- **`Raw.imageButton` arg order is (label, texRef, size, uv0, uv1,
  bg_col, tint_col)** — passing (tint, bg) swapped makes tint alpha 0
  with a white bg → every tray icon renders as a SOLID WHITE SQUARE.
  Cost a debugging session; the bg is invisible so it looks like an
  upload/decode bug (decode was fine — always verify source PNG pixels
  first). `drawImage`/`Raw.image` have no such params.
- SNI icon NAMES can contain dots ("dev.lizardbyte.app.Sunshine-tray") —
  don't use `takeExtension` to detect file paths; check for known image
  extensions / leading slashes instead. Sunshine's icon is SVG-only:
  `themeRgba` falls back to `<name>.svg` rasterized through the first
  available of rsvg-convert/magick/convert (spawn per icon-version
  change, cached after). `process` pkg has no System.Process.ByteString
  here — use createProcess + BS.hGetContents.
- steam ships only `steam_tray_mono.png` (grey glyph on WHITE opaque
  bg) via IconThemePath — the white square is the actual icon. Plasma
  recolors it; we render as-is (glyph visible after the tint/bg fix).
- Tray menus: only one open at a time (`hideOthers` in
  Tray/Menu/Render). Close-on-outside-click polls button edges via
  XQueryPointer on the tray's OWN X display (`trayDisplay` in Tray.hs) —
  SDL's getMouseButtons only sees clicks delivered to homgb's window.
  ImGui MousePos is -FLT_MAX when the pointer leaves the SDL window;
  that counts as outside (foreign click closes the menu). The opening
  press is ignored via msOpenedAt 0.25s guard. Menus render after the
  tray window and the tray has NoBringToFrontOnFocus — otherwise the
  right-click focuses the tray and ImGui draws it OVER the menu.
  xdotool `click` is faster than a frame — use mousedown/sleep/mouseup
  to test click handling, or polling misses the press entirely.
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
