# Picture in Picture — manual test & handoff

The AVKit mechanics are validated by a standalone spike (`scratchpad/pipspike`
in the session scratchpad, synthetic frames): PiP starts from the borderless
root layer while the app is inactive and while the window is ordered out; a
screen-bound `CADisplayLink` built *after* the window is ordered out ticks at
panel rate; an ordered-out `NSWindow` still reports its `.screen`. `make app`
and `make test` pass (new `PictureInPictureTests` cover the suppression truth
table + chord uniqueness).

**What was NOT done in-session:** a real end-to-end stream. Editing/restarting
the local Sunshine service was blocked by the tool sandbox, and a throwaway
second Sunshine instance hung at the videotoolbox encoder probe (two instances
contend for the one display's screen capture). So the live checks below need
you to drive Glimmer against your own Sunshine.

## Setup

1. `cd ~/Developer/shimmer && make` (installs to /Applications). Or `make
   open` to build + launch.
2. Pair Glimmer with your Sunshine from Glimmer's "Pair a PC" (enter the PIN in
   the Sunshine web UI). This is the step the sandbox wouldn't let me do for you.
3. Stream "Desktop".

## Checks

1. **Hotkey PiP.** In-stream, press **⌃⌥P**. The fullscreen window should hand
   off to the floating macOS PiP window (draggable to any corner, on top of
   other apps). Video keeps moving.
2. **Latency / pacer binding.** In `~/Library/Logs/Glimmer/glimmer-*.log`, at
   PiP entry you should see `FramePacer link installed ... bound=screen` and NOT
   see `PacerLinkRebuild` or `PacerReenabled` in the following few seconds.
   Those rebuild/give-up lines would mean the screen link isn't ticking and the
   feature is limping along on the direct-enqueue fallback — moving pixels are
   NOT proof on their own. Absence of those lines + `bound=screen` is the proof.
3. **Controller in PiP (the headline claim — verify explicitly).** With the PiP
   window up and another app frontmost, confirm the gamepad still drives the
   game. This relies on `GCController.shouldMonitorBackgroundEvents = true`,
   flipped on in `StreamWindow+PictureInPicture.enableBackgroundControllerEvents`.
   If it doesn't work, that's the first place to look.
4. **Return.** Click the PiP window's return button, the Glimmer Dock icon, or
   the menu-bar "Back to stream" item — all restore fullscreen and stop PiP;
   log shows `bound=view` again. Note **Cmd-Tab back does NOT re-show the
   stream window** — that's pre-existing glimmer behaviour (an ordered-out
   window can't become key, and the reactivation observer gates on
   `isKeyWindow`), not new to PiP.
5. **× close stays hidden.** Close the PiP window with its × button: the stream
   should NOT end; the launcher keeps its "Back to stream" affordance, and after
   ~2s the decoder gates (log: `decode gated`). "Back to stream" resumes it.
6. **Auto-PiP on switch-away.** Settings › Streaming › "Pop out to Picture in
   Picture when you switch away" (default on). Cmd-Tab away mid-stream → the
   stream pops to PiP instead of vanishing. Toggle off → Cmd-Tab away just hides
   it (pre-existing behaviour).
7. **No spurious IDR on entry.** Across a PiP entry, watch the log for a burst of
   `idr_requested` / "ENet IDR frame requested". The detach flag is set at PiP
   *request* time (not on didStart) specifically so the pacer never stalls
   during AVKit's ~200ms startup and provokes a resync IDR. One IDR is expected
   only on the eventual return (the suppression-exit resync); a PiP *entry*
   should provoke none.

## Known limitations (by design)

- **Keyboard/mouse do not reach the host from inside the PiP window.** A system
  PiP window is a passive video surface; only a key window delivers keyDown. So
  the **keyboard** quit chord (⌃⌥Q) can't fire while in PiP. The **controller**
  quit chord (L3+R3) still works via background events. Keyboard-only users
  return via the PiP window button / Dock click, then ⌃⌥Q. This is inherent to
  macOS PiP, not a bug.
- **HDR is not preserved in the PiP window** — the PiP compositor tone-maps to
  SDR. Fine for a corner view; fullscreen is unchanged.
- **One PiP slot system-wide.** If another app (Safari video, etc.) owns PiP,
  entry logs "not possible" and falls back to plain hidden-window behaviour.
- **× vs return button — unverified distinction.** The code treats the PiP
  window's × (close) as "stay hidden" and the return button as "come back to
  fullscreen", keyed on whether AVKit calls
  `restoreUserInterfaceForPictureInPictureStop…`. The spike only exercised
  programmatic stop; if macOS also calls restore for the × button, × will bring
  the window back too (benign, arguably nicer). Worth a glance during testing.
