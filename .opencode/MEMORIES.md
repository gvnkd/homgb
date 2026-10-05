# Taiga

- Project: HomgB — the DB was WIPED on 2026-10-01 (postgres lost its
  schema; migrations + fixtures re-applied via `manage.py migrate` +
  `loaddata initial_project_templates/initial_user` as the taiga user,
  env copied from /proc/<gunicorn>/environ). Re-created project:
  slug `homgb-2` (id 3; the old slug `homgb` was taken by a rolled-back
  row and Taiga 6 slugs are immutable), milestone "Milestone 4" (id 1),
  tasks #1-5 = M4.5/theming backlog.
- `taiga-cli` quirks: init needs full `http://127.0.0.1:8000/api/v1`
  URL (bare `init` rewrites base to `http://localhost:8000` WITHOUT
  /api/v1 — silent breakage; localhost may also resolve ::1 where
  nothing listens); token file key is `auth_token`; `task list` is
  NOT filtered by active project; PATCH needs current `version`.
  For milestone/task changes use curl with the token (see session
  history 2026-09-28).

# homgb

## HDR prototype (2026-10-05, wlroots + river patches)

- Display: LG C1 65" on card1-HDMI-A-1 (only connected output; DPs dead).
  EDID has ST2084 + static metadata type 1 + BT2020; driver exposes
  HDR_OUTPUT_METADATA + Colorspace BT2020_RGB + vrr_capable=1. Full HDR
  chain viable on NVIDIA 595 proprietary.
- HDR needs wlroots' VULKAN renderer (GLES lacks input_color_transform →
  river skips wp_color_manager_v1). Session exports WLR_RENDERER=vulkan;
  verified wp_color_manager_v1 v2 live on the session.
- SDR→HDR expansion (gamescope's BT.2446a ITM) ported into wlroots 0.20
  Vulkan output pipe: patches/wlroots-itm.patch in nix.config (output.frag
  + pass.c + renderer.c + vulkan.h; env WLR_HDR_ITM_ENABLE, _SDR_NITS=203,
  _TARGET_NITS=1000). river toggle: patches/river-hdr.patch (WLR_RIVER_HDR=1
  → PQ/BT2020 image description, gated on supported_transfer_functions).
  Both wired via overlays in modules/xmonad-river.nix (river-hdr pkg,
  session env exports). ITM math validated in C: black→0, white→target,
  monotonic; known ~5% dip at fast-path polynomial junction (inherited
  from gamescope). NOT yet verified end-to-end on the TV (needs session
  restart). Prototype artifacts in /tmp/opencode (wlroots-src, river-0.4.5,
  itm_test.c, tinywl harness with TINYWL_HDR=1).
- Nested/headless backends REJECT image descriptions ("basic output test
  failed") — HDR testing needs a real KMS HDR output; tinywl trick works
  only on DRM.
- BURN FIX (2026-10-05, live on the C1): chromium sees the HDR output and
  sends PQ/BT.2020 color-managed surfaces; wlroots decodes them to linear
  in the texture pass and the output-stage ITM expanded them AGAIN →
  burned images. Fix: per-frame gate — wlr_scene scans the render list for
  HDR-terms buffers (TF PQ or ext_linear, primaries BT2020; sRGB/gamma
  tags still count as SDR and ARE expanded), passes
  has_hdr_content via wlr_buffer_pass_options, vulkan pass skips ITM when
  set. Known tradeoff: one HDR surface disables expansion for the whole
  frame (per-surface ITM would need texture-pass integration).   If BT.2446a
  aesthetics still displease, next step is a linear luminance-boost mode
  (KWin sdrbrightness-style) in output.frag.
- LIVE ON THE C1 (2026-10-05, VERIFIED): log shows "HDR toggle: enabled=true
  supported_transfer_functions=0x2" + "HDR ITM: expanding (hdr_content=0)"
  for SDR and "pass-through (hdr_content=1)" with color-managed surfaces
  (chromium). TWO ordering bugs cost rounds: (1) image description must be
  set BEFORE scene_output.buildState() — after it, the scene's combine
  diff-suppression never picks it up (frames stayed gamma22-encoded while
  the TV was in PQ mode = "burned colors"); (2) the running session keeps
  the OLD river/wlroots until re-login — always verify via pgrep + strings
  on the running binary's libwlroots, not just nixos-rebuild switch.
  nix.config builds river/wlroots from PATCHES in nix.config/patches/ —
  editing /tmp/opencode sources does nothing until the patch file is
  regenerated (git diff in river-git / wlr-git pristine-first repos).
- PER-SURFACE ITM (2026-10-05, second iteration, switched in f2595fd):
  expansion moved from the output pipe into the Vulkan TEXTURE shader
  (texture.frag bt2446a branch, push constants itm_sdr/target_nits in
  wlr_vk_frag_texture_pcr_data, new wlr_render_texture_options
  hdr_expand_* fields). Scene (wlr_scene.c render_data) enables it only
  when the output image description is PQ; per-buffer gate: PQ/ext_linear
  TF or BT2020 primaries skip expansion. Blend-scale math: rgb(1.0=SDR
  white=203nits) -> bt2446a(rgb*(203/sdr),sdr,target)*(target/203) —
  the output.frag hdr_itm wrapper must NOT be reused (absolute scale).
  Output-stage ITM is now legacy, gated by WLR_HDR_ITM_OUTPUT (default
  OFF; WLR_HDR_ITM_ENABLE drives per-surface only). Fullscreen PQ video
  can direct-scanout (bypasses renderer, true HDR); SDR never scans out
  on a PQ output so it always goes through the expanding texture path.
  Scene rects/background are NOT expanded (xmonad root is black anyway).
- FULLSCREEN (2026-10-05, fork 663a0b6, pushed, nix.config wqz44s):
  client fullscreen requests honored end to end. New ops OpFullscreen /
  OpExitFullscreen (Plan.hs) executed in the manage sequence (WM.hs):
  river_window_v1.fullscreen(hinted-or-screen-matched output) +
  inform_fullscreen / exit_fullscreen + inform_not_fullscreen. Output
  matched by position like nominateLayerOutput; repeated requests
  suppressed by capturing rwFullscreen BEFORE adjust (adjust lands before
  the queued action reads it). e2e proof: /tmp/opencode/fullscreen-test.c
  asserts the fullscreen state (value 2) in xdg_toplevel.configure both
  directions — river only sets it when the WM honors the request.
  GOTCHAS: headless wl_display name is auto wayland-N (WAYLAND_DISPLAY is
  the PARENT for the wayland backend, ignored otherwise — stale locks
  shift N; check $RT dir); river needs WLR_BACKENDS=headless explicitly
  when the launching shell has WAYLAND_DISPLAY set (autocreate nests
  instead); wl_buffer.release needs a non-NULL listener.
  headless-dbus.sh 7/7 still pass. REMAINING: no WM-INITIATED fullscreen
  op exported to configs (e.g. a Meta+f binding).
- UTF-8 TITLES (2026-10-05, fork ba89b7b, switched i13j7yp): river titles
  are UTF-8 ByteStrings; BC.unpack/pack at the dbus boundary is LATIN-1 →
  Cyrillic titles hit homgb as Ð¢ÐµÑ... mojibake. Fix: utf8ToString/
  stringToUtf8 in Types.hs gating every crossing (DBus signals, panel
  matching, PlaceSurface lookup, ManageHook title/className). Verified
  headless via busctl monitor (Тест русского заголовка intact).
  homgb side needs theme.font.cyrillic: true (GetGlyphRangesCyrillic in
  the shim) AND a configured family (default = ImGui ProggyClean, no
  Cyrillic regardless of the flag) — dropped ~/.config/homgb/config.yml
  with DejaVu Sans + cyrillic. GOTCHA (again): river ignores
  WAYLAND_DISPLAY for its own socket — it uses addSocketAuto and sets
  WAYLAND_DISPLAY for its INIT CHILDREN; override it (e.g. hardcode in
  init.sh) and clients connect nowhere. Also busctl monitor block-buffers:
  only grep its output after the dbus session tears down, never after
  SIGKILL of the compositor.

## Wayland / river (2026-10-04)

- Sergey switched the VM to river + mgsloan's xmonad-on-river fork
  (module ~/work/nix.config/modules/xmonad-river.nix, rev
  dec3b72d). The fork IS the WM (river-window-management-v1); its
  README.river.md: no libwayland dep, prompts are layer-shell clients,
  "real keyboard input, workspace switching not run" yet.
- Plan: design_docs/wayland.md. Architecture decision: homgb does NOT
  learn Wayland protocols; xmonad owns all WM state and exposes it over
  a new dbus API org.xmonad.WM (signals WorkspacesChanged/
  WindowsChanged/LayoutChanged/FocusChanged; methods SwitchWorkspace/
  FocusWindow/NextLayout/SetLayoutGroup/PlaceSurface). homgb stays a
  plain SDL3 Wayland client (per-surface app_id); surface placement =
  xmonad floats via PlaceSurface; struts become an xmonad layout
  margin. XKB gap: river holds the seat state; xmonad applies switches
  (river keyboard-layout, VERIFY on pinned river 0.4.5) and tracks the
  group. XEmbed: SNI-only under Wayland.
- WAYLAND BACKEND STEP 2 landed (2026-10-04, homgb uncommitted): WmClient
  (org.xmonad.WM subscriber + callNoReply proxies), Backend.Wayland
  (SDL display enumeration, global mouse state, SDL-only show/hide,
  strut TVar, BarState translation with pseudo-xid map + homgb-*
  filtering, KbUi fed by LayoutChanged). New seams: BarActions/
  BarSection (renderWorkspaces/renderWinButtons take actions instead
  of Display), KbUi (KeyboardEnv projected via kbToUi dpy; carries
  kbUiSyncFocus for per-app restore). SDL windows created with
  createWindowWithProperties (title + SDL.window.create.app_id +
  flags). Selection: preferredBackend (HOMGB_BACKEND or
  XDG_SESSION_TYPE=wayland) BEFORE SDL_Init; sets SDL_VIDEODRIVER=
  wayland — CRITICAL: with DISPLAY set (XWayland) SDL picks X11 and
  the WM never sees the windows.
- Fork updates pushed: 823fbb8 (WorkspacesChanged a(ssb) ORDERED —
  a{s(bb)} sorted "10" between "1" and "2"), f94fb93 (PlaceSurface
  placements PERSISTENT, retried per manage sequence, change-
  suppressed — the first placement usually precedes the surface's
  map and was dropped), 9bffd3a (surface lookup falls back to TITLE:
  SDL ignores the per-window app_id property; homgb surfaces arrive
  with app_id "homgb", title "homgb-tray" etc). nix.config pinned
  9bffd3a (fa5aae4).
- MID-SESSION WM SWAP WEDGES RIVER (cost a session): SIGKILLing the
  WM and attaching a freshly-built one left org.xmonad.WM owned but
  the loop dead (black screen, no signals, methods ACK but no
  effect). Recovery = pkill -9 river → sddm greeter → re-login.
  Don't test WM swaps on the live session; use headless-river.sh.
  river takes ~10s to release the WM slot after a kill ("another
  window manager is already running" until then).
- LIVE smoke results (river session): popups render and the WM
  places them natively via PlaceSurface (visible, correct size) —
  the whole dbus channel works end-to-end. Still open: bar surface
  visibility (tray renders + PlaceSurface flows; verify against a
  fresh session running WM >= 9bffd3a), and SDL monitor geometry
  looked like one 3840-wide display (check getDisplays output on the
  2-monitor node).
- STEP 2 VERIFIED LIVE (2026-10-04, pushed e643cb1): on the fresh
  river session the bar renders natively — "2 | 1 | 3 | 4 | 5 | 6 | 7
  | 8 | 9 | 0" workspaces (current highlighted), active title, clock
  at the right — and popups are placed by the WM. Left running:
  WAYLAND_DISPLAY must match the session (check /proc/<wm>/environ —
  shells surviving a re-login keep the stale wayland-N); no
  ~/.config/homgb on this node = defaults (bar.workspaces on,
  bar.windows off). OPEN ITEMS: (1) SDL sees ONE 3840-wide display
  instead of two 1920s (bar spans both monitors; check getDisplays on
  this node — may be river reporting a combined output or a GDK_SCALE
  interaction); (2) workspace order in the bar read "2 1 3 4..."
  once — verify the a(ssb) order matches the WM's; (3) surface takes
  keyboard focus ("homgb-tray" as active title) — probably wants the
  WM to refuse focus to panel surfaces; (4) click-through of bar
  items untested (needs a real pointer).
- PANEL FIXES BATCH (2026-10-04, fork 1087f39, nix.config fd46333):
  focus guard (panels never hold focus; emitter restores last
  non-panel focus each sequence), NextLayout now rotates the KEYBOARD
  group via dcSetGroup (was xmonad's NextLayout = layout algo!),
  applySurfaces logs floats + unmatched panel ids (the live float
  failure was undiagnosable from silence). Config gained a TopGap
  LayoutClass wrapper (54px strip; the avoidStruts equivalent — no
  strut protocol on river-wm) + dcLayouts [us,ru]. headless-dbus.sh
  now asserts the float with the LIVE ORDERING (PlaceSurface before
  the window exists; foot -T/-a homgb-tray as the client — foot's
  single-instance DROPS --title on a second invocation!). All 6 pass.
  GOTCHAS: busctl arg form is `Method siiiii v1 10 ...` (signature
  then values); `shomgb-tray i 10` form misfires on the 'h'. In-sh-c
  comments can't contain apostrophes. grep -c exits 1 on zero matches
  (breaks && chains). ~3 stray test hangs came from pkill patterns
  matching the wrapper shell itself.
  KEYBOARD REALITY on this stack: nixpkgs river-0.4.5 has NO
  riverctl (binary says "does not support riverctl" — the wm-protocol
  world has no compositor CLI) and river_window_management has NO
  keymap/group request. So SetLayoutGroup's dcSetGroup has nothing to
  call; real switching needs either XKB_DEFAULT_LAYOUTS/OPTIONS env
  (native grp:alt_shift_toggle; WM can't see the group, indicator
  goes blind) or a small river patch exposing the xkb group. Sergey
  to decide.
- THE FLOAT BUG ROOT CAUSE (2026-10-04, homgb 43fc1f5): WmClient.send
  never set methodCallDestination — dbus messages WITHOUT a
  Destination header are NEVER DELIVERED by the bus, but busctl
  monitor SEES them (it taps the bus). So every PlaceSurface looked
  like it reached the WM; the panel was never floated; the bar tiled.
  Cost an evening + a wedge. LESSON: when a dbus call "arrives" per
  the monitor but the peer never acts, diff the FULL headers —
  Destination first. Verified live after the fix: WM logs
  "floated/moved homgb-tray to (0,0) (3840,54)", bar renders
  workspaces+title+date+clock natively, TopGap strip reserved.
  WM per-sequence entry log dropped again in bc8b9e5 (nix pin update
  not urgent — pure log cleanup; 1087f39 is functionally current).
- PANEL ROUND 3 (2026-10-04, fork 89f9e4d, nix.config 1b99aff): (1)
  bar only visible on ws 3 — river hides windows on background
  workspaces; panels now FOLLOW the current workspace each sequence
  (shiftWin; the fork's StackSet has no copy). (2) ToggleStruts: none
  existed — the TopGap wrapper now handles a ToggleGap message,
  M-b bound, the gap drops to 0 (config in module defaultConfig +
  node xmonad.hs, compile-verified). (3) steam menu item clicks dead
  — instrumented (HOMGB_DEBUG "menu click item=" in Tray/Menu/Render
  and "menu Event clicked" in Menu/Client); awaiting Sergey's log to
  see whether ImGui sees the click or the dbus Event is the dead half.
- PANEL ROUND 4 (2026-10-04, fork cbb911a, homgb 3e51241, nix.config
  ab88fca): (1) workspace order rotates per switch — W.workspaces puts
  CURRENT first; signal now ordered by the CONFIG's workspace list.
  (2) "Bar at vertical center, clock only" — two suspicions, one fix:
  applySurfaces matched against riverWindows INCLUDING closed entries
  (ids recycled — a restarted panel floats a DEAD window; live one
  stays tiled as Tall's second column; workspaces empty is a separate
  open question). Fixed: rwClosed filter + object ids in float logs +
  known-window dump in the no-match warn. homgb WmClient now logs
  every signal receipt (HOMGB_DEBUG). NEXT DATA: after rebuild,
  wayland-session.log's "known:" dump + homgb's "wm: signal" lines.
  MENU CLICKS still unresolved (ydotool works: daemon needs sudo,
  socket /tmp/ydo.sock, `YDOTOOL_SOCKET=... ydotool mousemove/click`
  — nixpkgs#ydotool; XAUTHORITY error seen when X tools leak into
  env).
- THE SIGNAL STARVATION (2026-10-04, homgb e56f0cd) — the empty-
  workspaces root cause: Wayland kbUiPoll never refreshed
  lsQueriedAt → nextDeadline's kbD = startup+1s = PAST FOREVER →
  waitMs clamps to 1ms → ~190 wakes/s idle spin (MEMORIES already
  documented this failure mode for tooltips; the Wayland keyboard
  path reintroduced it). On the DEFAULT SINGLE CAPABILITY the
  1ms-spinning render thread starved dbus-haskell's receiver —
  addMatch succeeded, zero signals received (probe with the same
  code received fine because it was IDLE). Fixes: refresh
  lsQueriedAt in kbUiPoll + -with-rtsopts=-N2. Verified: stable
  workspace order, title, clock, idle 0.5%. LESSON: any new KbUi/
  poll path MUST keep its deadline TVar fresh — grep lsQueriedAt
  writes when touching poll paths.
- WORKSPACE BOUNCE (2026-10-04, fork 46bf894, nix.config c120c35):
  switching workspaces snapped back immediately — chained causes:
  shiftWin (sticky panels) leaves the moved panel FOCUSED, then the
  focus guard restored sLastFocus whose window still lived on the
  PREVIOUS workspace → focusWindow views that workspace → bounce.
  Fix: keep focus across the sticky move + only restore when
  findTag == currentTag. headless-dbus.sh gained a real anti-bounce
  assertion (second call goes to gamma, alpha-current-at-end =
  bounce; first version of the assertion "failed" only because the
  script's own round-trip switched back to alpha — check the script
  before suspecting the code). GOTCHA: emitter/applySurfaces runs
  inside the manage sequence; a windows()/focusWindow on a foreign-
  workspace window changes the VIEW — any WM-side focus restore must
  verify the target's workspace first. dbus-run-session teardown
  hangs after river gets SIGKILL'd from a script — outer timeout +
  pkill cleanup always.
- MENU CLICKS ROOT CAUSE (2026-10-04, homgb a60142a): the menu
  outside-click detector polled XQueryPointer on trayDisplay —
  XWayland is BLIND over native Wayland surfaces, so the pointer
  read as (0,0) forever: every item press computed "outside" and
  CLOSEMENU swallowed the click (steam Exit did nothing). Fix:
  bkPressEdge backend hook — X11 keeps XQueryPointer (global, sees
  foreign windows); Wayland uses SDL button state (valid over
  homgb's own surfaces; trade-off: clicking a FOREIGN window no
  longer closes the menu — Wayland hides foreign input). Verified:
  right-click opens the steam menu with all items; item-activation
  click awaits Sergey's real mouse (ydotool absolute moves are
  scaled by pointer accel — "disable mouse speed acceleration";
  relative moves amplify too; SDL_GetGlobalMouseState only reports
  over SDL surfaces, (0,0) elsewhere — homgb has HOMGB_PTRDEBUG 1Hz
  probe now; ydotool: buttons are HEX masks, left click = C0, right
  = C1, plain numbers are button INDICES (click 2 = middle!). wev
  prints nothing until hovered — empty log ≠ broken events).
- DBUSMENU EVENT VARIANT (2026-10-04, homgb 7b5991d): the Event data
  arg must be a VARIANT on the wire — Event(iisvu), not isuu. dbus-
  haskell toVariant makes a plain value; force it with
  Variant (ValueVariant (toVariant v)) (constructors from
  DBus.Internal.Types; `import DBus hiding (Variant)` to avoid the
  type-only export clash). steam silently ignored the malformed
  Event — item clicks no-op'd including Exit. Verified: steam exits.
  Debug recipe that cracked it: ydotool pointer hops (absolute move
  onto the bar saturates right-edge due to pointer accel; then TWO
  probed relative hops), HOMGB_PTRDEBUG probe (SDL reads local coords
  of the hovered surface), click, watch busctl monitor for the call
  + compare with a manual busctl call using the correct signature.
- LIVE SESSION VERIFIED (2026-10-04): after session recreate, the WM
  owns org.xmonad.WM; busctl SwitchWorkspace s 5 returned rc=0 and the
  next WorkspacesChanged showed "5" current with "1" nonEmpty —
  full signal trio (Workspaces/Windows/Focus) emitted. Caveat: an
  IDLE WM emits nothing (diff suppression) — the initial burst fires
  during startup before any monitor can attach; test with a method
  call, not passive monitoring.
- Node switched to the fork (2026-10-04): nix.config
  modules/xmonad-river.nix pins omgbebebe/xmonad@b5ef196 (hash
  sha256-/YrvAi1H2XEQO7Bd16qRNN8VK9Tch0obVZ01Wf3yREo=), ghcEnv has
  p.dbus, defaultConfig + ~/.config/xmonad-river/xmonad.hs both
  start dbusService from startupHook (the node copy was read-only
  0444 from the store cp — chmod u+w first). nix.config pushed
  (cd3e349). ghcWithPackages[xmonad,dbus] verified building on the
  pinned nixpkgs. homgb seam pushed: a41a85f on gvnkd/homgb master.
  GOTCHA: `nix-prefetch-url --unpack` printed a 39-char non-SRI hash
  (useless for fetchFromGitHub); `nix store prefetch-file --unpack
  --json` gives the right sha256-...= SRI.
- xmonad-side dbus service DONE (2026-10-04,
  omgbebebe/xmonad@xmonad-on-river b5ef196): XMonad.River.DBus owns
  org.xmonad.WM, signals WorkspacesChanged a{s(bb)} / WindowsChanged
  a(ssssb) / FocusChanged (ss) / LayoutChanged (ias), methods
  SwitchWorkspace/FocusWindow/NextLayout/SetLayoutGroup/PlaceSurface.
  Emission = self-requeuing afterLayout snapshot diff + 1s fallback
  timer; handlers re-enter via postAction. Window handle on the wire =
  river's stable identifier hex string, NOT the ObjectId. dcSetGroup
  has NO default backend (session policy — riverctl/keyboard-layout
  wasn't found in the river 0.4.5 nix output; decide with Sergey).
  Local checkout: ~/work/dev/xmonad-river (cabal build works with
  env-wrap; push via git@github.com:omgbebebe/xmonad.git — the default
  id_ed25519 key; HTTPS origin HANGS on credential prompt).
  tests/headless-dbus.sh = end-to-end proof (headless river +
  dbus-run-session + busctl; foot provides a toplevel). Fork API facts
  that shape the homgb client: W.peek takes the StackSet (not a Stack);
  W.workspaces returns [Workspace] (use W.tag); NextLayout is a
  constructor of ChangeLayout; dbus tuples IsVariant up to 11; busctl
  monitor prints Member= capitalized and races signal bursts — attach
  unfiltered before starting the WM.
- Step 1 (seam) DONE: Homgb.Backend record + Homgb.Backend.X11
  (selectBackend, HOMGB_BACKEND env); all X touchpoints in Homgb.hs/
  Render.hs route via appBackend. X11 behavior unchanged (smoke test
  on the river VM: homgb ran as XWayland client — daemon/SNI/XEmbed
  fine, bar empty as expected since river has no EWMH).
- Smoke-test gotcha: on the river session XWayland root spans BOTH
  outputs (3840x1080) and river/xmonad-river places X clients wherever
  the WM wants — homgb surfaces appear at odd spots; that's the hybrid
  setup, not a regression. pkill -f 'homgb' matched the wrapper shell
  (timeout) — use the binary path pattern.

## Flake packaging (nix build / nix run github:gvnkd/homgb)

- `nix/` holds per-dependency pins (callHackageDirect) for what
  nixpkgs lacks: dear-imgui 2.5.0, status-notifier-item 0.3.2.16,
  sdl3-bindgen-sys. callHackageDirect sha256 = the UNPACKED tarball
  hash (`nix-prefetch-url --unpack`), NOT the flat-file hash.
- cabal2nix lists default-ON flag deps unconditionally: dear-imgui's
  `sdl` flag is disabled via `haskell.lib.overrideCabal
  (configureFlags + "-f-sdl")`, but the sdl2/SDL2 ARGUMENTS must
  still exist — stub them with `null` and filter nulls out of the
  depends lists (nixpkgs sdl2/SDL2 are sdl2-compat wrappers whose
  closure is enormous). Passing `flags = {...}` to .override FAILS
  ("unexpected argument") — the generated lambda has no flags param.
- homgb's pkgconfig-depends (xcb, xcb-xkb, x11, sdl3) become
  cabal2nix lambda arguments resolved from the haskell package set
  scope — inject them as attributes via the overrides extension
  (xcb-xkb = xorg.libxcb; the .pc ships inside libxcb).
- nixpkgs' sdl3 defaults pull ibus + libayatana-appindicator (gtk+3!)
  + pipewire/pulseaudio/jack into every pkg-config consumer's
  buildInputs; nixpkgs' generic builder turns every buildInput into
  --extra-include/lib-dirs, and the giant single argument blows the
  GHC linker's posix_spawn (E2BIG "Argument list too long"). Fix:
  `sdl3.override { ibusSupport/pipewireSupport/pulseaudioSupport/
  jackSupport/traySupport/vulkanSupport/libusbSupport = false; }`
  (+ doCheck=false: SDL's testautomation expects the disabled
  backends).
- The flake builds via `import nixpkgs { overlays = [ (import
  nix/overlay.nix) ]; }` — overlay files are PLAIN `self: super:` /
  `final: prev:` functions; a `{ }:` prefix arg breaks composition
  with infinite recursion.
- Startup CPU/font pathology (laptop repro, strace): never shell out
  to fontconfig per lookup — with a cold cache EACH fc-match pass
  re-opens every font file (60K+ syscalls with google-fonts), and
  homgb did 1+n-fallbacks per surface = minutes of 100% CPU with no
  UI. Theme.fontDb memoizes ONE `fc-list -f "%{file}\t%{family}"`
  pass per process; family matching is pure Haskell after that
  (fc-match only as a no-exact-match fallback). mkTheme went from
  minutes to ~50ms. Killing test instances: `pkill -x homgb` does
  NOT match nix-built binaries — their argv[0] is `.homgb-wrapped`;
  use `pkill -f homgb` carefully or check `busctl --user list` for
  stray owners of org.freedesktop.Notifications /
  org.kde.StatusNotifierHost-homgb (a squatter leaves every new
  instance in NameInQueue with an empty tray).
- SNI host startup race (status-notifier-item lib): items that
  re-register between the watcher name appearing and the host's
  initial item-map fetch land in the map WITHOUT ItemAdded reaching
  update handlers — the tray silently stays empty (worse right after
  homgb restarts; exposed when startup became fast). Tray.runHost
  watchdog: 3s after a successful build, if the watcher's
  RegisteredStatusNotifierItems outnumber our tray items, rebuild
  the host (a fresh build replays the full map).
- SNI unread-badge rework (2026-10-04, fixes "chat app icons never get
  the red dot"): THREE bugs. (1) `applyUpdate` bumped tiVersion but
  kept the STALE ItemInfo — NewIcon re-resolved the old pixmap/name
  forever (Slack/chromium badges the pixmap in place). Now stores the
  fresh info (pure fn, exported for repl tests). (2) StatusUpdated was
  ignored (no wake, no re-render); now bumps + refetches. (3) The
  status-notifier-item host NEVER reads AttentionIconName/Pixmap and
  never registers NewAttentionIcon — homgb fetches them itself
  (Homgb.Tray.Icons.fetchAttentionIcon, dbus DISPATCHER thread only,
  cached in TrayItem.tiAttention) and registers
  I.registerForNewAttentionIcon in runHost. Raw client pixmaps are
  network order (A,R,G,B → argbToRgba); attention icon REPLACES the
  normal icon while NeedsAttention (KDE semantics, no overlay on top).
  Overlay icons (the other badge channel) are composited top-left at
  2/5 height (gtk-sni-tray geometry) by addOverlay (pure nearest-
  neighbor scale + src-over blend, blendOver/scaleToHeight exported).
- SNI PIXMAP BYTE ORDER — the old memory note was WRONG: the host
  lib's networkToSystemByteOrder (0.3.2.16, StatusNotifier.Util) maps
  [A,R,G,B] → 0xAABBGGRR word → R,G,B,A bytes on LE. Host-delivered
  pixmaps are RGBA AS-IS; homgb's bgraToRgba double-swapped R↔B.
  Invisible for years because every real icon (flameshot purple, steam
  white, slack mono) is R≈B symmetric — caught by a pure-blue test
  pixmap rendering red. pixmapRgba/overlayRgba now pass bytes through.
- Watcher restart kills CHROMIUM SNI registrations permanently
  (Slack/chrome_status_icon don't monitor for new watchers — the
  gtk-sni-tray README warns about exactly this); flameshot
  re-registers. Restarting homgb loses Slack's SNI item until Slack
  restarts. Telegram (flatpak xdg-dbus-proxy) exposes NO SNI object at
  all — XEmbed only.
- Synthetic SNI item testing recipe: raw DBus exports + timer/file-
  driven phase switches (pixmap badge + NewIcon = Slack style;
  NeedsAttention + AttentionIconPixmap = Discord style; overlay). TWO
  gotchas: (1) readOnlyProperty takes the raw IO value — wrapping in
  toVariant DOUBLE-WRAPS (busctl shows `v s "x"` instead of `s "x"`)
  and the generated client fails every property with
  org.ClientTypeMismatch (ItemInfo all defaults: iconName=bus name,
  pixmaps=[], status=Nothing); (2) pgrep/pkill -f with a pattern that
  appears in your own zsh -c command line kills YOUR shell — use the
  [e] bracket trick.
- XEmbed tray host (tray.xembed, Homgb.Tray.Embed +
  cbits/homgb-tray-embed.c): homgb owns _NET_SYSTEM_TRAY_S0, sends
  the ICCCM MANAGER ClientMessage (ICCCM 2.8) so running apps dock
  without restart (this is how trayer "magically" collects running
  apps). Gotchas learned the hard way:
  * XCheckMaskEvent SILENTLY DROPS ClientMessages (sent-event mask
    matching is unreliable across sender conventions) — the dock
    request sat in the queue while polls returned nothing. Use
    XCheckIfEvent with an always-true predicate (also needed for
    NoEventMask XEMBED protocol messages).
  * A reparented icon whose new parent is unmapped gets UNMAPPED; we
    XMapWindow(client) after EMBEDDED_NOTIFY. Real clients create
    their icon UNMAPPED and map on EMBEDDED_NOTIFY — never map under
    root (the WM would tile it; the "one" test icon ended up
    2302x2104 adopted by xmonad).
  * When the embedder dies, X11 DESTROYS docked icon windows (all
    inferiors go). Real clients recreate + re-dock (Qt semantics) —
    verified with a test client. homgb rejects docks of dead windows
    (XQueryTree parent check after reparent).
  * Slot windows are created on the SCREEN DEFAULT visual and
    _NET_SYSTEM_TRAY_VISUAL is deliberately NOT set (trayer does the
    same). Advertising the SDL window's 32-bit ARGB visual broke
    docks BOTH ways: honoring clients made 32-bit icons, non-honoring
    ones (several Telegram builds) made 24-bit — any cross-depth
    reparent is BadMatch (request code 7). No property => every
    spec-aware client uses the default visual, the only depth a slot
    can host.
  * Selection/MANAGER timestamps: real server timestamp from a dummy
    property change (grab_timestamp), never CurrentTime (ICCCM).
  * Only one XEmbed owner per screen: if trayer owns the selection,
    acquire fails -> log + SNI-only.
  * Test client: /tmp/opencode/xembed-test.c (gcc -lX11); watch
    MANAGER on root with StructureNotifyMask, recreate the window on
    DestroyNotify.
- ImGui auto-fit (AlwaysAutoResize) windows are CLAMPED to the
  viewport: a surface that hugs such a window FEEDBACK-DEADLOCKS
  (window can't outgrow the surface, surface waits on the window),
  and fixed-size surfaces clip tall/wide content. Size analytically
  (font line height + char-count) and setNextWindowSize explicitly
  (axis 0 = auto-fit the other axis does NOT dodge the clamp).
  calcTextSize SIGSEGVed (in ImGui::FindRenderedTextEnd) on
  dbusmenu-parsed label Texts — plain valid ASCII, unresolved; label
  WIDTHS now use char-count estimates; calcTextSize on string
  literals/constructed Text is fine everywhere else.

X11 notification daemon + StatusNotifierItem tray host + keyboard layout manager.
SDL2 windowing, dear-imgui (OpenGL3) rendering. No Wayland in early milestones.

## Milestone status

- M1 (notification daemon): done, `160aee7`.
- M2 (SNI tray + dbusmenu): done, core `2a6e958`; menus in follow-up commit.
  Design: `design_docs/milestone_2.md`.
- M3 (keyboard layout manager): done. XCB group lock instead of
  setxkbmap (Sergey's call). Design: `design_docs/milestone_3.md`.
- M4+: notification center panel, multi-monitor.
- M4 backlog (2026-10-01, uncommitted): theming (Homgb.Theme: fonts,
  colors, tray icon size, margins/paddings), Cyrillic font,
  default-timeout 10000, menu GetLayout log rate-limit, modification
  margin-top/right honored in popup placement, M4.5 multi-monitor
  (Homgb.Monitors: Xinerama; monitor/follow-mouse keys for tray,
  popups, center).

## Bar / xmobar replacement (phase 1: workspaces, 2026-10-02)

- Homgb.Bar renders xmonad workspaces INSIDE the tray surface (left
  edge): reads root _NET_DESKTOP_NAMES / _NET_CURRENT_DESKTOP via
  Graphics.X11.Xlib.Extras (getWindowProperty8/32; X11 lib ALSO binds
  sendEvent/allocaXEvent — no shim needed for reads), polled 5Hz in
  frameUpkeep alongside the stacking re-assert. Clicking a workspace
  sends the _NET_CURRENT_DESKTOP client message (C shim
  homgb_set_current_desktop) — XMonad.Hooks.EwmhDesktops honors it;
  NO xmonad.hs changes needed for the workspace part.
- Caps-as-Hyper is the PRIMARY switch on this node (2026-10-03):
  `setxkbmap -option grp:alt_shift_toggle,caps:hyper` + xmonad
  `("<Hyper_L>", spawn busctl ... NextLayout)` (plain-press EZConfig
  binding — no modifier prefix). Sergey's call: grp:caps_toggle can
  STOP WORKING SILENTLY (any setxkbmap re-run without the options
  drops it; then Caps capitalizes again). The hyper route cannot die
  silently — the press visibly rotates homgb's indicator. xmonad
  needs `xmonad --recompile && xmonad --restart` to pick up the
  binding; recompile works with plain ghc on this node. Verified:
  full per-app flow driven by Hyper_L presses on :0. Test-tool notes:
  after remapping, the Caps_Lock KEYSYM has no keycode — XTEST probes
  must look up Hyper_L (/tmp/opencode/hyperpress.c); and per-app
  memory pollution across test runs makes focus-switch sequences look
  "laggy" (each change is a legit restore) — restart homgb for a
  clean test run.
- XKB STATE-NOTIFY listener (2026-10-03, Keyboard eventLoop):
  event-driven group tracking on a THIRD xcb connection (kbEventConn),
  thread blocks in xcb_wait_for_event (GHC 'safe' FFI — unsafe pins
  the capability, the SDL lesson). Every group change — homgb lock,
  caps (grp:caps_toggle), Alt+Shift, xkb-switch — now updates the
  indicator instantly AND feeds per-app memory (recordForFocused in
  the event handler), so ALL switch methods record. TWO xcb-xkb
  gotchas cost a debugging round: (1) SelectEvents stateDetails must
  be 0x3fff — wider masks (0xffff) get BadValue; (2) ALL XKB events
  arrive with response_type == first_event ONLY — the specific type
  is the xkbType byte (XCB_XKB_STATE_NOTIFY=2); first_event+type is
  NOT the wire encoding. Verified on :0: caps-only per-app flow
  (alacritty↔chromium) restores both ways.
- Layout switch via CAPS (2026-10-03): pure xmonad CANNOT do it —
  XKB applies the Caps lock state at the server even when a passive
  XGrabKey/xmonad binding grabs the key. The fix is the XKB option
  `grp:caps_toggle` (setxkbmap -option grp:alt_shift_toggle,...
  in xmonad.hs startupHook): Caps toggles the group natively and
  never capitalizes; homgb's indicator follows via the 1s group poll.
  Same caveat as Alt+Shift: caps/alt-shift toggles bypass homgb's
  per-app recording (only homgb-issued NextLayout records).
  XTEST-verified on :0 (probe: /tmp/opencode/capsprobe.c; xdotool
  key Caps_Lock reads stale via a separate process — use one-process
  send+read probes for XKB state checks).
- xmonad integration (~/.xmonad/xmonad.hs): xmobar spawnPipe +
  dynamicLogWithPP removed, deadd spawnOnce commented, homgb started
  via spawnOnce "/home/pion/bin/homgb-start &" — the launcher pgrep-
  guards because spawnOnce RE-FIRES on `xmonad --restart` (a second
  homgb would steal org.freedesktop.Notifications / the SNI watcher).
  env-wrap only loads direnv env for the CWD (it does not cd): the
  launcher cds to the project itself. trayer stays until homgb hosts
  XEmbed icons (sunshine).
- Taskbar phase: _NET_CLIENT_LIST_STACKING + per-window
  _NET_WM_DESKTOP/_NET_WM_NAME/_NET_WM_PID/_NET_WM_WINDOW_TYPE, 5Hz
  poll in refreshBar (Homgb.Bar). Filters: own PID, DOCK/DESKTOP type,
  empty/other-desktop. Click -> _NET_ACTIVE_WINDOW client message;
  xmonad's ewmh focuses the window AND views its workspace
  (W.focusWindow). _NET_WM_NAME is UTF-8 — decodeUtf8' via
  getWindowProperty8.
- Bar layout (bar.layout, default true): full-monitor-width surface,
  widgets [workspaces][title][windows?][SPACER][icons][kb][clock HH:MM]
  [date dd.mm]. The ImGui window MUST get an explicit setNextWindowSize
  — AlwaysAutoResize shrink-wraps DIRECT content only, so the
  SameLine-spacer-pushed right group clipped to nothing (silent
  debugging trap: a failed `cabal build` left a stale binary looking
  identical — confirm build success from its output, not grep -c).
  _NET_WM_STRUT_PARTIAL (setStrutPartial, changeProperty32) makes
  xmonad's avoidStruts reserve the strip: new windows map below the
  bar; pre-existing windows relayout on their next workspace refresh.
  Strut writes are change-suppressed via appStrut (every write
  re-runs avoidStruts). Title cap bar.window-title-max is PIXELS
  (fitTitleWidth binary-searches the ellipsis cut).
- Bar auto-hide (barCovered): refreshBar intersects each
  current-workspace window's geometry (getGeometry + waIsViewable —
  MUST filter viewable: steam's 10x10 UNMAPPED stub windows are in
  _NET_CLIENT_LIST and latched the bar hidden forever) with the bar's
  strut rect; mainLoop hides the tray surface while covered
  (ToggleStruts, Full layout, floats). drawTraySurface must
  showSurface every frame (idempotent via sShown) — hiding used to be
  one-way because the startup showSurface ran exactly once.
- Bar EWMH refresh is EVENT-DRIVEN since 2026-10-02: startBarEvents
  (Homgb.Bar) blocks in XNextEvent on its OWN display (Xlib displays
  are not thread-safe — never share with the render thread) with root
  substructure+property selection, setting appBarDirty; frameUpkeep
  re-reads only when dirty + 5s safety re-sync (root selection cannot
  see client _NET_WM_NAME changes — needs per-window selection, not
  worth it). NEVER draw widgets outside Begin: the bar's spacer
  measurement originally called the render functions pre-Begin —
  every-frame usage error auto-opened ImGui's Debug##Default window
  (the "V Debug" under the workspaces). Measure-only variants
  (measureWorkspaces/measureWinButtons) exist for the pre-Begin math.
- BAR RIGHT-ANCHOR SameLine trap (2026-10-03): the bar's right group
  is placed by an ABSOLUTE setCursorPos jump (slRightX), but
  SameLine() reverts to the PREVIOUS LINE ITEM — so a SameLine from
  the group's FIRST widget silently chains off the left sections
  (the title) instead of the anchor. Manifested with an EMPTY tray:
  the indicator (whose `follow` wrongly included ws/title/win) became
  the first post-jump widget. Rule: after an absolute cursor jump,
  the first widget must draw at the cursor (no SameLine); `follow`
  args must only reflect items on the ANCHORED line. Verified with a
  private-bus homgb instance (zero tray items).
- MENU POLL LOOP (2026-10-03): while a menu is open the loop must
  re-render ~10-20Hz (outside-click close polls XQueryPointer edges in
  renderMenus; only runs inside a render). THREE designs: (1)
  per-frame wake from renderMenus = frame-locked at GL speed
  (~13-15% CPU); (2) rate-limited wake = DEAD LOOP (a timeout wake has
  sawEvents=False → changed=False → no render → poll stops → close
  and hover break); (3) WORKING: menuD deadline (now+0.1) +
  mainLoop ORs menuOpen into the render gate + menu surface drawn on
  `changed || menuOpen` but ONLY the menu surface on menu ticks (full
  re-render per tick ≈10%). Each tick costs ~7-9ms (GL swap) so 20Hz
  ≈14%, 10Hz ≈2-3%. GOTCHA: the menu HIDE must run OUTSIDE the
  (changed || menuOpen) gate — on the close-transition iteration both
  are false (closeMenu doesn't wake) and a gated hide leaves the
  surface mapped forever (design 1's trailing wake had masked this).
- STALE-TOOLTIP DEADLINE SPIN (2026-10-03, cost a long debugging round):
  offerTooltip writes trayTooltip ONLY while hovered; nothing clears
  it, so after the pointer leaves the TVar holds TooltipInfo with
  tiLastSeen/tiHoverAt in the PAST. The SURFACE hides via the
  freshness gate in anyTooltipOpen, but nextDeadline computed
  tipD = min(tiHoverAt+0.36, tiLastSeen+0.2) = PAST FOREVER →
  waitMs = max 1 (ceiling negative) = 1ms → SDL's X-pump loop spun
  at ~870Hz (~2.5-8% CPU) PERMANENTLY (until restart). Trigger looked
  like "open any SNI menu" but was really the ICON HOVER that
  precedes the right-click — any widget hover planted the landmine.
  Trace signature: main thread in recvmsg(EAGAIN)-drains of the X fd
  + ppoll(~0.86ms)=Timeout repeating. Fix: nextDeadline applies the
  same freshness gate as anyTooltipOpen before honoring tipD.
  LESSON: any deadline derived from a TVar that outlives its event
  MUST be staleness-gated at read time — a deadline in the past is
  a 1ms busy-loop (waitMs clamps at 1, never negative).
- IDLE CPU (2026-10-03): 2-2.5% at "idle" came from TWO unconditional
  wake paths rendering full frames on background churn: (1)
  startBarEvents pushed `wake` on EVERY root X event (steam/chromium
  map/unmap/configure storm) and sawEvents is indiscriminate →
  render; fix: dirty flag only, processed within 0.25s by the
  deadline cap, render gated by upBarChanged (max bar-update latency
  now 0.25s). (2) SNI updateHandler woke on EVERY host update incl.
  Tooltip/Title (steam's download progress lives in its tooltip);
  fix: applyUpdate returns whether state changed, wake only then.
  Diagnostic recipe: HOMGB_DEBUG=1 counts renders ("tray surface="
  lines/s); strace -c -p needs the starter's namespace (ptrace_scope
  blocks other sessions' attaches).
- RENDER-ON-WAKE since 2026-10-03 (power rework): mainLoop blocks in
  SDL_WaitEventTimeout (SDL3.pumpEventsTimeout, src/Homgb/SDL3.hs) until
  the nearest deadline (nextDeadline in Homgb.hs: popup expiry via
  expiryAt, clock minute rollover, XKB poll, bar 5s re-sync, tooltip
  staleness/hover-delay) or an SDL input event / pushed user event
  (SDL_RegisterEvents + SDL_PushEvent; appUserEvent/appWake in
  AppState). frameUpkeep returns Upkeep change flags; mainLoop renders
  only when events arrived or something changed — idle = 0% CPU.
  Wake producers: daemon notify/close/expire, SNI updateHandler,
  menu fetchLayout/watch/openItemMenu, Control NextLayout/ToggleCenter,
  startBarEvents (root events), offerTooltip (hover-delay deadline),
  renderMenus (while a menu is open, ~20Hz for the outside-click
  poll). SURFACE GOTCHAS: (1) a popup's measured height is only known
  after one draw — popUnmeasured forces one extra popup draw;
  (2) clock widgets need the minute-rollover deadline or the bar
  freezes while idle; (3) tooltips need the staleness deadline
  (tiLastSeen+0.2) or a pointer that left without an SDL event leaves
  the tooltip up forever; (4) hover-delay needs tiHoverAt (set even
  when the widget has no tooltip lines) or a stationary pointer never
  pops the tooltip. XKB pollGroup moved from renderIndicator to
  frameUpkeep (1s deadline, returns Bool = group changed). Stacking
  re-assert is EVENT-DRIVEN: same dirty gate as the bar, and
  reassertStacking takes the current root children (homgb_query_tree
  C shim — the X11 package does NOT bind XQueryTree; free with
  homgb_x_free) and skips the raise/lower while the children list
  equals sStackOrder (fingerprint TVar per surface). While tray.xembed
  host is active the deadline is +200ms (dock requests arrive on the
  X queue, pumped in renderTray) — still 0% CPU, ~13 wakeups/s.
  homgb_ensure_sticky already read-compares (only writes on drift).
  Verified 2026-10-03: idle 0.0% CPU (was ~100%), popup Notify →
  viewable, 5s expiry → unmapped.
- CRITICAL (cost a debugging session): SDL_WaitEventTimeout's UNSAFE
  FFI flavor (sdl3-bindgen exports both) blocks the whole GHC
  capability for the entire wait — dbus-haskell's reply dispatch then
  never runs and every blocking dbus `call` hits its 5s timeout
  (status-notifier-item reports it as a serial-0
  Error.Failed MethodError; SNI item fetches fail, reapZombieItems
  times out NameHasOwner → live items judged dead → "reaped N zombie
  item(s)"). Symptom looked like a wedged dbus peer but bus-monitor
  showed replies flowing. Homgb.SDL3 uses waitEventTimeoutSafe.
  Repro recipe: build SHost.build while a thread loops
  pumpEventsTimeout 250ms → ITEMS=0; without the loop → ITEMS=1.
- SNI watchdog (Tray.runHost): never rebuild the host on watchdog
  triggers — a second SHost.build requests
  org.kde.StatusNotifierHost-homgb which the SAME process still owns
  → NameAlreadyOwner retry spam, "failed to start SNI host". Instead
  compare the watcher's registered-name SET (parsed with
  splitServiceName semantics: break at the first '/'; entries can be
  "uniqueName/object/path" — blueman registers by object path) against
  the tray's item names and replay missing ones via SHost.forceUpdate
  (the library dedups already-tracked names). Watchdog false
  positives are normal: the watcher persists registrations to
  ~/.cache/status-notifier-item/*.json and restores them, and
  blueman-tray RESPAWNS with a new unique name on every homgb restart
  (old name → ItemRemoved → reap → set mismatch → replay adds the new
  name). All of that is expected noise, not a fault.
- SNI tooltips: own surface (homgb-tooltip, EWMH TOOLTIP, created
  LAST = topmost float) — in-window tooltips clip against the bar's
  54px viewport. offerTooltip (Tray/Render) writes trayTooltip TVar
  (hover key + delay + root anchor + lastSeen staleness); the surface
  draws when fresh. Same AlwaysAutoResize trap as the bar: flag +
  setNextWindowSize circularly collapses wrapped text (6px window);
  use axis-0 auto-fit WITHOUT the flag. Every new surface goes into
  eventRoutes AND the xmonad float rules (xmonad.hs).
- SURFACE ORDERING GOTCHA (cost two debugging rounds): surfaces that
  shrink-wrap to variable content MUST be shown BEFORE
  resize/moveSurfaceWindow — xmonad restores a re-mapped float's
  geometry from its float map, DISCARDING resizes that happened while
  the window was withdrawn (during a hide->show cycle). Symptom:
  second show keeps the PREVIOUS content's size. Working pattern =
  drawPopupSurface (showSurface first, resize at the end); broken =
  the tooltip's original resize->move->show.   Also: auto-fit window
  heights cannot be read mid-frame (getWindowSize returns the stale
  size during the frame) — analytic sizing only.
- Font fallback chain (theme.font.fallbacks): candidates from
  `fc-match -a`, pre-filtered by the sfnt directory (homgb
  loadableFontFile: reject OTTO/CFF, ttcf, CBDT/CBLC/sbix; KEEP
  variable fonts — stb ignores gvar and rasterizes the default
  instance; NotoSans.ttf is variable and loads fine), merged with
  ImFontConfig.MergeMode after the primary. CRITICAL: dear-imgui is
  built with -DNDEBUG (cabal.project package stanza) so an
  unparseable font returns NULL instead of ABORTING via IM_ASSERT —
  without it, trying candidates is impossible. Nerd Fonts cover only
  Private-Use-Area icons; real emoji (e.g. blueman's U+1F50B) need a
  symbol font (Symbola works; Noto Color Emoji is CBDT-bitmap →
  rejected; monochrome Noto Emoji is variable-and-stb-broken → NULL →
  skipped). Nerd Font = icons for future bar widgets, NOT emoji.
- xmonad stacking facts (probed): WM_STATE presence does NOT prove a
  window is managed (doIgnore'd windows keep it); xwininfo -root
  -children lists TOP-first; floats stack by window-id order (menu
  created LAST => topmost float); toggling struts off puts tiled apps
  OVER unmanaged docks.

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
  fastcompmgr). M4 step 1: real SDL3 via `sdl3-bindgen-sys` (lithon,
  Hackage 0.0.x, pin minor) gives `SDL_WINDOW_TRANSPARENT` — native
  depth-32 windows, the entire GLX visualid hack is DELETED (was:
  nixpkgs SDL2 = sdl2-compat; SDL_VIDEO_X11_WINDOW_VISUALID read once
  at video init; Mesa glXChooseFBConfig lies about depth). Keep
  `glClearColor 0 0 0 0` + transparent `ImGuiCol_WindowBg` on the tray.
- sdl3-bindgen-sys: flake needs sdl3 + its full Requires.private chain
  (alsa jack pipewire pulseaudio libXcursor/Xi/Xfixes/Xtst libdrm
  mesa libgbm libxkbcommon wayland wayland-protocols libdecor libusb1)
  or pkg-config configure fails. Generated from SDL 3.4.16 headers —
  matches nixpkgs sdl3 exactly. Idioms: `alloca @SDL_Event`, peek type
  via `peek (castPtr ev :: Ptr SDL_EventType)`, pattern synonyms
  SDL_EVENT_*, opaque types under `Ptr` (SDL_GLContext is a Storable
  newtype — `SDL_GLContext nullPtr` for null checks), Bool results,
  `getError`+ConstPtr for errors. Window position is NOT a
  createWindow arg in SDL3 — WM places it (xmonad tiled homgb to
  1670,730; fine for now).
- dear-imgui's `DearImGui.SDL` binds the sdl2 package — unusable on
  SDL3. homgb compiles upstream imgui_impl_sdl3.cpp (vendored
  vendor/imgui, imgui 1.92.8 = dear-imgui 2.5's core) behind an
  extern "C" shim (cbits/homgb-imgui-sdl3.cpp), linking imgui core
  symbols from libHSdear-imgui. MUST compile with dear-imgui's defines:
  `-DIMGUI_USE_WCHAR32 "-DImDrawIdx=unsigned int"`. ImGui_ImplSDL3_
  NewFrame only sets io (DisplaySize/DeltaTime/mouse) — still need
  dear-imgui's `newFrame` (ImGui::NewFrame) after it.
- dear-imgui cabal.project flags now `-sdl +opengl3` (drops the sdl2
  dep entirely; flake keeps no SDL2/sdl2-compat).

## Multi-window surfaces (M4 step 2, commit 4265b3b)

- One SDL window per surface, EACH WITH ITS OWN ImGui context
  (`DearImGui.Raw.createContext`); ONE GL context made current per
  surface per frame (all surfaces share the ARGB visual -> texture ids
  valid everywhere). `ImGui_ImplOpenGL3` backend data is PER-CONTEXT
  (`io.BackendRendererUserData`) — call openGL3Init/Shutdown once per
  surface context or NewFrame asserts. `ImGui_ImplSDL3_NewFrame` only
  fills io; `DearImGui.newFrame` (ImGui::NewFrame) still required.
- Event routing: SDL_WindowID is byte offset 16 of every
  window-targeted event (type/reserved/timestamp/windowID); route each
  event to its surface's context BEFORE `ProcessEvent` — the backend
  drops events whose windowID isn't its own bd->WindowID, and per-
  context bd makes the stock backend multi-window-clean. No fork.
- `xwininfo -root -tree` on XWayland LISTS WITHDRAWN WINDOWS — check
  "Map State" (IsUnMapped) before believing a window is visible.
  XWayland restarts when its last client exits -> window ids repeat.
- `SDL_GL_SwapWindow` on a hidden SDL window MAPS IT: surfaces that
  start hidden must be skipped entirely in the render loop (not drawn-
  and-hidden). Same for SDL_GL_MakeCurrent during init (re-hide after).
- Tray shrink-wrap: NEVER measure inside the ImGui window (viewport
  clips to the SDL window -> feedback collapse to minimum size);
  compute content size analytically (items*btn + spacing + indicator).
  An item's real row advance is `btn + 2*style.FramePadding` (4,4
  default — pixel-probe the pitch if metrics ever look wrong) plus the
  explicit SameLine spacing; `tray.spacing` is applied via
  `homgb_same_line` in the sdl3 cpp shim (dear-imgui's sameLine binds
  SameLine() with no spacing arg). Height = btn + 2*FramePadding.y +
  2*windowPadding. Undershooting the analytic width clips the trailing
  icons/indicator — with many tray items this LOOKS like overlapping
  icons and right-clicks on clipped items dead-stick.
- **One GLX context CANNOT be switched between SDL windows**: it
  presents only on the window it was created on (blue-clear probe
  showed nothing on the second window). Each surface owns its GL
  context; no sharing needed because popup textures upload/delete
  under the popup context (syncTextures/pruneCache run inside
  drawPopupSurface).
- Surface visibility needs BOTH SDL_ShowWindow/HideWindow (SDL state:
  SwapWindow no-ops on SDL-hidden windows, and SwapWindow MAPS hidden
  windows) AND XMapWindow/XUnmapWindow (SDL ShowWindow returned True
  but the window stayed withdrawn). XMap/Unmap via C shim
  homgb_x_map/unmap (the Haskell X11 package doesn't bind them).
- Fresh X session => XAUTHORITY cookie changes (env-wrap caches the
  old one in direnv): export XAUTHORITY=/run/user/1000/xauth_* from
  the xmonad process environ before env-wrap.
- Wayland session (Plasma): SDL3 uses the Wayland backend by default —
  no X11 windows, x11WindowId = Nothing, EWMH dead, XGrabKey/xcb only
  see XWayland. Run with SDL_VIDEODRIVER=x11 to stay an X client
  (works: DOCK/NOTIFICATION types, transparency via KWin compositing).
  XQueryPointer button state is BLIND over Wayland-native windows, so
  menu outside-click-close only fires over X clients under XWayland.
  Menu windows clip at the tray surface viewport (menus need their own
  surface, M4 step 4.4). dbus: REPLACE_EXISTING cannot steal
  org.freedesktop.Notifications from Plasma (owner didn't allow
  replacement); NameInQueue is optimal — we take over if Plasma's
  daemon dies.
- WM properties (Homgb.WMProps, C shim): homgb's single SDL window is
  tagged _NET_WM_WINDOW_TYPE=DOCK + SKIP_TASKBAR/PAGER +
  _NET_WM_DESKTOP=0xFFFFFFFF, found by _NET_WM_PID (SDL sets it).
  CRITICAL: the props must be set BEFORE the window maps — xmonad's
  ManageDocks reads _NET_WM_WINDOW_TYPE at manage time; setting it
  after mapping leaves the xmonad border drawn. Window is created with
  windowVisible=False, tagged, then showWindow (Homgb.run). Separately,
  WMs overwrite _NET_WM_DESKTOP when adopting the window, so a
  background thread on its OWN X display re-asserts it every 2s (Xlib
  displays are not thread-safe; render thread already polls via
  trayDisplay). Per-surface types (NOTIFICATION/POPUP_MENU) need
  separate X windows per surface — M4 multi-window refactor.
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
- Modification rules (`notification.modifications`): matching + Script
  support are deadd-ported (rules match the pre-modification
  notification). margin-top/margin-right affect popup PLACEMENT since
  2026-10-01: margin-right shifts that popup (the popup surface hugs the
  union), margin-top is that popup's root y and restarts the stack
  below it (drawPopupSurface: rootTop/idealX).
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
- dbusmenu rendering (Menu/Render): slack's exporter nests sibling items
  in a chain (every item children-display:submenu holding the next);
  proper clients never expand those eagerly (children are only valid
  after AboutToShow). homgb renders via ONE shared `menuRows`
  flattener (invisible dropped, indent capped at ONE level for any
  depth) consumed by BOTH measureMenu and renderMenus — measure/render
  divergence was the bottom-empty-space bug (plus invisible rows
  counted, headers measured as padded selectables, spacing
  double-counted). Window height CONVERGES instead of pure analytics:
  after drawing, cursorY + padY + 2 → msFitH drives the next frame's
  setNextWindowSize (analytic height = first-frame fallback only;
  reset on open/refetch). Screenshot-verified on :0 (blueman menu hugs
  content).
- dbusmenu: `Event`/`GetLayout`/`AboutToShow` must be sent to the item's
  **Menu object path** (from the `Menu` property, e.g.
  `/org/ayatana/NotificationItem/steam/Menu`), NOT the item path. Root
  layout node (id 0) is virtual — steam marks even it
  `children-display: submenu`; always render `lnChildren` of the root.
  GetLayout reply = `(u revision, (ia{sv}av))`; parseable via
  `fromVariant :: Variant -> Maybe (Int32, Map Text Variant, [Variant])`.
  GetLayout error logs are rate-limited (1 per 5s per item, MenuState
  msErrLogAt) — steam/blueman can emit LayoutUpdated bursts that
  otherwise spam stderr; the `dbus` package itself NEVER prints.
- Default ImGui font has NO Cyrillic glyphs (steam's Russian menu labels
  render as ?????). Fixed via theming: `theme.font.family` (fontconfig
  name or path, resolved with `fc-match`, fallback: keep default font)
  loaded per surface context by `homgb_add_font` in
  cbits/homgb-imgui-sdl3.cpp — with `cyrillic: true` it passes
  `io.Fonts->GetGlyphRangesCyrillic()` and sets `io.FontDefault`. Must
  be called per ImGui context BEFORE the renderer builds the atlas
  (applyFont in Homgb.Theme, called in Homgb.run right after
  createSurface). No font configured → default ProggyClean, no
  Cyrillic (by design). applyFont returns the ImFont* which is stored
  per surface (Surface.sMainFont); widgets that must NOT inherit the
  big default size (tray layout indicator) draw via
  `DearImGui.Raw.Font.pushFontWithSize` (imgui 1.92 PushFont with size
  override — dear-imgui re-exports it; two-pass measure-then-scale in
  renderIndicator fits text height to the icon row).
- Per-app layouts (2026-10-03, `keyboard.per-app`, DEFAULT ON,
  KDE-style): KeyboardEnv gained `kbPerApp :: Maybe PerAppState`
  (paFocus = cached (xid, WM_CLASS), paGroups = Map class->group).
  Recording happens in rotateLayout (manual switch → remember group
  for the focused class); restore happens in syncFocus, called from
  frameUpkeep right after refreshBar whenever `barActiveWindow` read
  changed — root _NET_ACTIVE_WINDOW changes fire the bar event thread
  (dirty+wake), so no new deadline was needed. Focus tracking reuses
  the bar's read; keying is resClass with resName fallback via
  Graphics.X11.Xlib.Extras.getClassHint on trayDisplay (X11 1.10.3
  binds it). syncFocus locks via kbPollConn (render thread's own xcb
  conn) — kbSwitchConn stays Control-thread-only. Group changes from
  syncFocus OR into upKbChanged so the indicator redraws. Windows
  without WM_CLASS and xid 0 are ignored (layout stays, nothing
  remembered). Layouts switched OUTSIDE homgb (raw xkb tools) are not
  attributed to any app — same limitation as KDE.
- Per-app VERIFIED on node 2026-10-03 (DISPLAY :0): focus alacritty →
  NextLayout (ru) → focus chromium → NextLayout (us) → back: group
  restored per class (read via a tiny xcb tool; xcb_xkb_get_state needs
  xcb_xkb_use_extension first — /tmp/opencode/xkbg.c). GOTCHA that cost
  a false "won't work": the running homgb was the PRE-feature binary
  (cabal list-bin path in homgb-start — process keeps OLD code after
  `cabal build`; MUST kill+restart to pick up a build). Also: don't
  truncate a live log file (`> log`) — the fd offset leaves sparse
  garbage and interleaved lines become unreadable; note the offset and
  tail from it instead.
- Rotation no-op trap: the layout list comes from root
  `_XKB_RULES_NAMES` (live). If the X session has ONE layout
  (`setxkbmap -query` shows just "us"), NextLayout locks group 0 and
  nothing visibly happens — "Meta+Space doesn't switch" is the X
  keymap, not homgb. `setxkbmap us,ru` fixes it live (XKB group lock
  survives setxkbmap reloads, see M3 notes). `setxkbmap -query` shows
  the CONFIGURED layouts, not the locked group — verify switches via
  the tray indicator (or xcb_xkb_get_state), not setxkbmap.
- Theming: Homgb.Theme is the ONLY thing renderers read for style
  (colors/sizes/paddings). YAML `theme:` section: `font.{family,size,
  cyrillic}`, flat `colors:` map with dotted keys (`popup.bg`,
  `popup.bg-critical`, `menu.bg`, ...; `#RRGGBB[AA]` via parseHexColor),
  `sizes.{tray,popup,menu}.padding-x/y` + `sizes.tray.{icon-size,
  spacing}` (theme wins over legacy `tray.icon-size`/`tray.spacing`).
  Window padding applied per window with Raw.pushStyleVar
  ImGuiStyleVar_WindowPadding (exists in dear-imgui 2.5; the
  withWindowOpen wrappers take no flags, Raw is the way).
- Multi-monitor: Homgb.Monitors (Xinerama via the X11 package's  Graphics.X11.Xinerama — libXinerama already in flake). `monitor:` /
  `follow-mouse:` keys now work for tray (`tray.monitor/follow-mouse`),
  popups (`notification.popup.*`), center (`notification-center.*`).
  appMonitors in AppState (queried once at startup; Xinerama inactive →
  single full-screen monitor). follow-mouse reads appPointer, polled per
  frame in frameUpkeep via queryPointer on trayDisplay (only when some
  follow-mouse is set). Menus clamp inside the monitor containing the
  cursor. Surfaces stay single per type (no per-monitor popup surfaces).
- **`Raw.imageButton` arg order is (label, texRef, size, uv0, uv1,
  bg_col, tint_col)** — passing (tint, bg) swapped makes tint alpha 0
  with a white bg → every tray icon renders as a SOLID WHITE SQUARE.
  Cost a debugging session; the bg is invisible so it looks like an
  upload/decode bug (decode was fine — always verify source PNG pixels
  first). `drawImage`/`Raw.image` have no such params.
- SNI Activate/ContextMenu calls must NEVER run on the render thread:
  flameshot never replies to Activate, and a synchronous `DBus.Client
  .call` blocks ~25s (DBus default timeout) — the entire UI freezes
  and the queued SDL input replays afterwards (menus appear to toggle
  randomly). Fork the call (see renderItem) and log failures async.
  Send the click as ROOT coordinates (winPos + ImGui mouse pos);
  fabricated window-local coords made flameshot misbehave.
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
- **Every new surface must be added to `eventRoutes` in Homgb.hs** —
  twice bitten (menus wid=4, center wid=5 dropped: hover frozen on one
  element). Symptom: hover works once then never changes.
- Stacking / z-order (2026-10-02): xmonad (and most WMs) re-restacks
  managed windows on every focus/layout change, undoing any client-side
  raise/lower within one event. Deterministic order needs BOTH:
  (1) map-time raise/lower per surface (sRaiseOnMap in Surface; tray
  maps LOWERED via homgb_x_map_lowered, transients raised), and
  (2) a 5Hz re-assert in frameUpkeep (reassertStacking) that re-lowers
  the tray / re-raises the menu — pure client-side, WM-agnostic.
  _NET_WM_STATE BELOW (tray) / ABOVE (everything else) is set in
  WMProps (c_set_type_props stack_state) — KWin honors it, xmonad
  ignores it. xmonad stacks floats by window-id order, so homgb creates
  the menu surface LAST (highest id = topmost float, above center).
  WM_STATE presence does NOT prove a window is managed (doIgnore'd
  windows keep it). xwininfo -root -children lists TOP-first.
  Caveat: a lowered tray under an overlapping bar/apps is unclickable
  in the overlap — fine for homgb's endgame (it replaces xmobar and
  will own the strut zone); partial-strut support (tray.struts) is the
  future fix if an overlapping foreign bar stays.
- **imgui.ini is DISABLED for all contexts** (homgb_imgui_disable_ini
  in the sdl3 cpp shim): four ImGui contexts shared the CWD's ini and
  corrupted each other's window settings. All windows are positioned
  via setNextWindowPos Always, persistence is useless.
- **Interactive-vs-rendered offset quirk**: widgets on a sameLine row
  after a `text` have interactive rects ~130px LEFT of the rendered
  position (root cause unknown; per-context font metrics suspected).
  Left-edge widgets (like item rows) are exact. When clicks/hover miss
  by a consistent offset, grid-probe with an isItemHovered debug log
  instead of trusting screenshot geometry.
- NO global key grabs since 855d8c6: homgb exposes
  `org.homgb.Control` on the session bus (path /org/homgb/Control;
  `busctl --user call org.homgb /org/homgb/Control org.homgb.Control
  NextLayout`). WMs bind shortcuts to busctl calls - works on Wayland
  too. dbus-haskell autoMethod: zero-arg IO () methods work fine
  (2026-10: verified; earlier "not running" was grep missing garbled
  interleaved log lines + block-buffered stdout - trust exit-state
  checks, not absence-of-log when debugging).
- Tray menus: only one open at a time (`hideOthers` in
  Tray/Menu/Render). Close-on-outside-click polls button edges via
  XQueryPointer on the tray's OWN X display (`trayDisplay` in Tray.hs) —
  SDL's getMouseButtons only sees clicks delivered to homgb's window.
  ImGui MousePos is -FLT_MAX when the pointer leaves the SDL window;
  that counts as outside (foreign click closes the menu). The opening
  press is ignored via msOpenedAt 0.25s guard. A press shorter than one
  frame (synthetic `xdotool click`, not human clicks) falls between the
  polls and is missed — use mousedown/sleep/mouseup when testing. Menus render after the
  tray window and the tray has NoBringToFrontOnFocus — otherwise the
  right-click focuses the tray and ImGui draws it OVER the menu.
  xdotool `click` is faster than a frame — use mousedown/sleep/mouseup
  to test click handling, or polling misses the press entirely.
- Timeout semantics (deadd `startTimeoutThread`): 0 = never, >0 = ms,
  <0 = `popup.default-timeout` ms. Expiry is checked in the render frame
  loop (`isExpired` in Render.hs), no threads. Default is 10000
  (deadd README value; homgb's shipped defaultConfigText once had `10`
  = 10ms flash). busctl eats `-1` as a flag — expire tests use positive
  ms.
- `parseHtmlEntities` was ported without regex-tdfa (hand-rolled scanner);
  Helpers only carries pure functions (no i18n/ConfigFile).
- deadd's `Notification` gained `notiCreatedAt :: UTCTime` (needed for
  frame-loop expiry); `notiClassName` and `rawImgToPixBuf` dropped.

## Roadmap

- Milestone 0: `design_docs/milestone_0.md` — SDL+GL+ImGui skeleton.
- Then: port notification daemon → tray → keyboard layouts.
