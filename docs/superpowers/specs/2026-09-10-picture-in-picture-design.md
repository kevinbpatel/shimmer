# Picture in Picture — design

**Goal.** Let a running stream pop out into the native macOS Picture in
Picture window (the same floating, corner-snapping, always-on-top window
Safari/QuickTime use for video), so the game stays visible in a corner while
the user works in other apps. Controller input keeps flowing to the host while
in PiP; keyboard/mouse stay with whatever app the user is in.

**Non-goals.** Playing with keyboard/mouse from inside the PiP window (system
PiP windows accept no such input). Preserving HDR/EDR inside the PiP window
(the PiP compositor tone-maps; SDR is fine for a corner view). A resizable
"windowed" stream mode.

## Why this is cheap here

Glimmer already renders through an `AVSampleBufferDisplayLayer` installed as
the stream window's root layer. `AVPictureInPictureController` takes exactly
that layer as a content source
(`ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`, macOS 12+).
A throwaway spike on this machine (macOS 26.3, `scratchpad/pipspike`)
confirmed:

| Question | Result |
| --- | --- |
| PiP starts from a sample-buffer root layer in a borderless window | yes |
| PiP starts while the app is **not** active | yes |
| PiP starts while the source window is already `orderOut`'d | yes |
| PiP keeps rendering after the source window is `orderOut`'d | yes |
| Renderer keeps accepting `enqueue` while the window is hidden | yes (`isReadyForMoreMediaData` never dropped) |
| `NSView.displayLink` keeps ticking after `orderOut` | **no** (+0 ticks) |
| `NSScreen.displayLink` keeps ticking after `orderOut` | yes |
| Layer needs a `controlTimebase` | no — host-PTS-as-is works |
| Source layer while PiP is active | shows the system "playing in picture in picture" placeholder |

Two consequences drive the design: (1) the frame pacer must rebind from the
view-bound link to a screen-bound link while PiP is active, and (2) the
fullscreen stream window and PiP are mutually exclusive — returning to the
stream window must stop PiP.

## Behaviour

**Entering PiP.**

1. *Hotkey* — a new in-stream chord, default **⌃⌥P** (`pipHotkey`,
   configurable in Settings › Shortcuts, same `HotkeyRow` as quit/stats).
   Intercepted before the sys-keys gate like the other chords; never forwarded.
2. *Automatically on switch-away* — when the user Cmd-Tabs away and the
   window's existing debounced resign path confirms a genuine background
   (`backgroundStreamWindow()`), start PiP instead of just hiding. Governed by
   `autoPictureInPicture` (Settings › Streaming, default **on**).
3. *Menu bar* — a "Picture in Picture" item in the menu-bar dropdown while a
   stream is live and PiP is not active.

Both paths do the same thing: run the existing background teardown
(cursor back, `orderOut`, presentation options restored, launcher gets its
"Back to stream" affordance) and then `startPictureInPicture()`.

**While in PiP.**

- Present suppression is **not** engaged (the layer is being watched), so no
  drain-to-newest, no decode gate. `StreamWindow` computes
  `presentSuppressed = isBackgrounded && !isPictureInPictureActive` and only
  emits edges of that value to the decoder.
- The frame pacer is rebound to `NSScreen.displayLink` (the screen the window
  is on, falling back to `NSScreen.main`) so it keeps releasing frames at
  panel cadence with the view off screen. All other pacer machinery (adaptive
  depth, watchdogs, telemetry) is untouched — it only sees a different link.
- `GCController.shouldMonitorBackgroundEvents = true` so gamepad input keeps
  arriving while Glimmer is not frontmost. Restored to its prior value when
  PiP ends.
- PiP's play/pause button maps onto present suppression: pause → suppressed
  (freeze on newest frame, decode gates after 2 s exactly like a hidden
  window), play → un-suppressed (flush + single IDR resync). Live time range
  (`[-∞, +∞]`), `requiresLinearPlayback = true`.

**Leaving PiP.**

- *"Return" button in the PiP window* → `restoreUserInterface…` → same path as
  "Back to stream": activate app, order the stream window front,
  `reengageForeground()`.
- *Close (×) button* → PiP ends, the stream window stays hidden. This is
  exactly the pre-existing Cmd-Tab-away state: present suppression engages,
  decode gates after 2 s, the launcher's "Back to stream" remains available.
  The session is never ended by a PiP gesture.
- *Any return to the stream window* (`resumeWindow()`, Cmd-Tab back → didBecomeKey,
  Dock click → reopen) funnels through `reengageForeground()`, which now stops
  PiP first if it is active. The window is ordered front first, then PiP
  stops, so the system's fly-back animation lands on the visible fullscreen
  layer.
- *Session teardown* (`StreamWindow.close()`) stops PiP and restores the
  controller flag.

**Layer rebuild while PiP is active** (renderer hard-fail self-heal):
`rebuildDisplayLayer()` re-targets the PiP controller at the fresh layer and
restarts PiP if it was active. Rare; correctness over polish.

## Components

### `StreamPictureInPicture` (new, `Glimmer/Stream/StreamPictureInPicture.swift`)

`@MainActor final class`. Owns the `AVPictureInPictureController`, is both its
delegate and its `AVPictureInPictureSampleBufferPlaybackDelegate`.

```
init(layer:)                       // builds controller for this layer
func retarget(layer:)              // rebuild controller; restart if active
var isActive / isPossible: Bool
func start() / func stop()
var onDidStart: (() -> Void)?
var onDidStop: (() -> Void)?       // fires for both × and return
var onRestoreRequested: (() -> Void)?   // "return to app" button
var onPauseChanged: ((Bool) -> Void)?   // play/pause from the PiP controls
```

No knowledge of windows, decoders, or settings — a thin, testable adapter.

### `StreamWindow` (+ new `StreamWindow+PictureInPicture.swift`)

- Owns a `StreamPictureInPicture` built at `init` from `displayLayer`
  (re-targeted in `rebuildDisplayLayer()`).
- New state: `isBackgrounded`, `isPictureInPictureActive`,
  `lastEmittedPresentSuppressed`.
- New callbacks: `onPictureInPictureChanged(Bool)`,
  `onPresentSuppressionChanged(Bool)`. `onBackgroundedChanged(Bool)` keeps its
  current meaning (UI: "Back to stream").
- New provider: `autoPictureInPictureProvider: () -> Bool` (read live at the
  resign edge).
- `enterPictureInPicture()` — public; used by hotkey and menu bar. If the
  window is currently frontmost it runs `backgroundStreamWindow()` first.
- `backgroundStreamWindow()` — after the existing teardown, if the provider
  says yes and PiP is possible, `pip.start()`.
- `reengageForeground()` — stops PiP if active before the existing work.
- `close()` — stops PiP.
- Controller background flag flips in the PiP start/stop handlers.

### `FramePacer` / `VideoDecoder`

- `FramePacer.setDetachedFromView(_:)` (`@MainActor`): stores the flag and
  rebuilds the link. `installLink(on:)` picks `view.displayLink` or
  `(view.window?.screen ?? NSScreen.main).displayLink` off the flag; panel-max
  and screen-signature helpers keep reading the view (its window still reports
  a screen while ordered out).
- `VideoDecoder.setPacingDetachedFromView(_:)`: forwards to the pacer and
  remembers the flag so a pacer re-enable after a give-up honours it.

### Session wiring (`StreamSession+StartSetup.swift`)

- Decoder suppression now listens to `onPresentSuppressionChanged`, not
  `onBackgroundedChanged`.
- `onPictureInPictureChanged` → `dec.setPacingDetachedFromView(active)` and
  the new `.pictureInPicture(Bool)` stream event for the launcher.
- `pipHotkeyProvider` / `autoPictureInPictureProvider` threaded from
  `AppModel` like the existing providers; `InputForwarder.onPiPHotkey` →
  `win.enterPictureInPicture()`.

### `AppModel` / Settings / menu bar

- `pipHotkey: HotkeyChord = .defaultPiP` (⌃⌥P), persisted `"pipHotkey"`.
- `autoPictureInPicture: Bool = true`, persisted `"autoPictureInPicture"`.
- `nativeStreamPictureInPicture: Bool` (observable, from the stream event).
- `enterPictureInPicture()` → `nativeSession?.enterPictureInPicture()`.
- Settings › Shortcuts: `HotkeyRow("Pop the stream out (Picture in Picture)")`.
- Settings › Streaming: `Toggle("Pop out to Picture in Picture when you switch away")`.
- Menu bar: "Picture in Picture" while streaming and not in PiP; "Back to
  stream" while backgrounded (PiP or not).

## Error handling

- `isPictureInPicturePossible == false` (another app owns the single system
  PiP slot, or PiP unsupported): log at notice level, fall back to the plain
  hidden-window behaviour. Never block the switch-away.
- `failedToStartPictureInPictureWithError`: same fallback; the window is
  already hidden and suppression engages via the normal edge because
  `isPictureInPictureActive` never flipped.
- PiP start/stop callbacks that land after `close()` are ignored via the
  existing `didClose` guard.

## Testing

- Unit: `StreamWindow` suppression-edge logic is a pure function of
  (backgrounded, pipActive) — test `presentSuppressedState(...)` truth table
  and edge de-duplication. `HotkeyChord.defaultPiP` doesn't collide with
  quit/stats/bookmark.
- Spike-level: the `pipspike` harness already proves the AVKit behaviours.
- End-to-end on this Mac: pair Glimmer with the local Sunshine (this Mac mini
  runs Sunshine as a Homebrew service), stream "Desktop", trigger PiP via
  hotkey and via Cmd-Tab, verify with `screencapture` that the PiP window
  shows live frames while the stream window is hidden, and that returning via
  Dock click restores fullscreen. Check `~/Library/Logs/Glimmer` for the
  pacer-link rebind lines and no decode-gate engagement while in PiP.
