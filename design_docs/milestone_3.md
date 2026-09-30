# Milestone 3: keyboard layout manager

Goal: homgb manages X11 keyboard layouts — global hotkey to switch
layouts, current-layout indicator rendered in the tray bar.

This document is written to be picked up by an agent with no prior
context. Read `.opencode/MEMORIES.md` first, then
`design_docs/milestone_1.md` / `milestone_2.md`, then this file.

## References

- MEMORIES.md "Keyboard layouts" section: switch by shelling out to
  `setxkbmap` (what `xkb-switch` does internally); indicator by polling
  `setxkbmap -query`; no xkbcommon binding needed.
- `X11` Hackage package (already a homgb dependency). Relevant bits:
  - `Graphics.X11.Xlib`: `openDisplay`, `defaultScreen`, `rootWindow`,
    `grabKey`, `nextEvent`, `pendingEvent`, `KeyPress` events,
    `keysymToKeycode`, `XKeyEvent` accessors (`Graphics.X11.Xlib.Event`).
  - `Graphics.X11.Xlib.Extras` / `Graphics.X11.Xkb` for
    `XkbGetState`-style queries — optional; shelling out is acceptable.
  - Grabbed keys must be in `XKeymapEvent`-delivered
    `KeyPress` events on the ROOT window; use `grabKey` with
    `anyModifier` carefully or per-modifier grabs (see decision 2).
- taffybar has no equivalent; `xkb-switch` and `xkbmon` (C) are small
  reference implementations of the same ideas.

## Design decisions

1. **Separate X11 thread.** SDL cannot grab global keys, so a `forkIO`
   thread opens its own `Display` (`openDisplay ""`), grabs the
   configured key(s) on the root window, and blocks in `nextEvent`.
   Key events write `TVar LayoutState`; the render loop polls it, same
   pattern as the DBus threads (no callbacks into ImGui).
2. **Hotkeys: one grab per modifier combination.** X11 grabs are
   (keycode, modifiers, window). For a hotkey like
   `Ctrl+Shift+Space` grab exactly that combination (avoid
   `anyModifier` — it steals keys from apps). Config:
   ```yaml
   keyboard:
     hotkey: ctrl-shift-space   # parsed to (keysym, [modifiers])
     layouts: ["us", "ru"]      # rotation list; empty = query xkb
   ```
3. **Layout model.**
   ```haskell
   data LayoutState = LayoutState
     { lsLayouts :: [Text]  -- rotation list from config
     , lsCurrent :: Text    -- e.g. "us", "ru"
     , lsNext    :: IO ()   -- switch action
     }
   ```
   On hotkey: rotate to the next layout and apply it. **Implemented
   via XCB, not setxkbmap** (decision revised during implementation):
   `xcb_xkb_latch_lock_state` locks the group server-side,
   `xcb_xkb_get_state` reads it, and the rotation list comes from the
   root `_XKB_RULES_NAMES` property — no process spawning, and the
   indicator can poll cheaply (1 xcb roundtrip). `lsNext` is
   `rotateLayout` in `Homgb.Keyboard`.
4. **Indicator in the tray bar.** Extend `renderTray` with a trailing
   segment: current layout as text (`"US"`/`"RU"` — uppercase, 2-3
   chars) styled as a button-like label; config `keyboard.indicator:
   true|false`. Layout name source: poll `setxkbmap -query` after each
   switch and at startup (parse `layout:` line); cache in the TVar
   (MEMORIES: poll on tray refresh is fine — switches are rare).
5. **Startup state.** On start, query `setxkbmap -query` once; set
   `lsCurrent`. If the user changes layout outside homgb (KDE/xmonad),
   the indicator goes stale until the next homgb switch — acceptable
   for M3 (poll every N seconds only if cheap; XkbGetState is the
   better long-term answer, note in code).

## Tasks

- [x] `src/Homgb/Keyboard.hs`: `startKeyboard :: Config -> IO (Maybe
      KeyboardEnv)` — parse config, initial XCB group query, forkIO
      grab thread
- [x] Hotkey parsing: `ctrl-shift-space` string → keysym + modifier set
      (X11 `ControlMask`/`ShiftMask`/`Mod1Mask`/`Mod4Mask`)
- [x] X11 grab thread: `grabKey` per modifier-combo, `nextEvent` loop,
      atomic rotate + XCB group lock (replaces `setxkbmap` shell-out)
- [x] Tray indicator: layout label at the tray bar edge (config
      `keyboard.indicator`, default true); click rotates too
- [x] `keyboard.*` config section (hotkey / layouts / indicator)
- [x] Wire `startKeyboard` into `Homgb.run`
- [x] Verify: switch layouts with the hotkey under xmonad (xdotool
      XTEST), indicator updates (screenshot-verified US↔RU), external
      server-side toggle (grp:alt_shift_toggle) picked up by the 1s
      render-loop poll
- [x] Update `.opencode/MEMORIES.md`
- [x] `-threaded` added to the exe: blocking C calls (XNextEvent, xcb
      reply waits) froze the whole non-threaded RTS

## Acceptance criteria

- With `homgb` running, pressing the configured hotkey changes the
  X keyboard layout (verified: XKB group lock via xcb + indicator).
- Tray bar shows the current layout code; updates after each switch.
- No key grabbing conflicts with xmonad defaults (test with
  `xmonad` defaults + common apps open).
- M1/M2 features unaffected.

## Out of scope (later milestones)

Notification center panel (M4), per-window layout memory, layout
activation OSD popup, xkb variant/options editing UI, Wayland
(`zwp_keyboard_shortcuts_inhibit` etc.), mouse-follow-layout.
