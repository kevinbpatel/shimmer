# Settings redesign: Stream / Video / Audio / Input / App

Date: 2026-09-10. Status: implemented in this branch.

## Why

Three complaints from real use of the fork, plus a request to organise
Settings the way skyhua0224/moonlight-macos-enhanced does:

1. "It doesn't remember the last resolution." The default preset (Native
   Retina) re-derives from the panel every launch, and choosing any other
   resolution meant first switching a radio to *Custom* and then typing or
   picking numbers inside that card. The choice *was* persisted, but the
   model read as "it went back to native".
2. "It's hard to adjust the bitrate." Upstream removed the bitrate control
   entirely (derived from resolution and refresh). The owner wants to see and
   set it.
3. The panes were General / Quality / PCs / Input / Diagnostics / About, with
   the Wi-Fi helper and the stats overlay living under *Quality*.

## What changes

### Sidebar

`Stream · Video · Audio · Input · PCs · App · Diagnostics · About`, same
coloured-chip rows as before (the app already renders System-Settings-style
chips; only the set and colours change). Selection still opens on the first
pane.

### Quality model (AppModel + QualityCalculator)

The three presets stay as the **resolution source** (`qualityPreset`:
matchDisplay / hidpi / custom) so persisted values and the migration path are
untouched. Everything else stops being "Custom-only":

| Setting | Property / key | Default | Applies to |
|---|---|---|---|
| Resolution | `qualityPreset` + `customWidth`/`customHeight` | Match display | – |
| Frame rate | `frameRateMatchesDisplay` (new) + `customFPS` | match display | every preset |
| Bitrate | `bitrateAuto` (new) + `manualBitrateMbps` (new, 5…300) | auto | every preset |
| HDR | `customHDR` (existing key) | on | every preset (was hard-coded on for the two panel presets) |
| Show the stream | `streamDisplayMode` | full screen | every preset (was Custom-only) |
| Audio channels | `audioLayout` (new): auto / stereo / 5.1 / 7.1 | auto | – |

Migration: `frameRateMatchesDisplay` absent → `qualityPreset != .custom`
(so an existing Custom user keeps their typed Hz; preset users keep the
panel's). `bitrateAuto` absent → true.

`persistQualitySettings()` resolves, in order: size from the preset; fps =
matches-display ? panel Hz : clamped `customFPS`, capped to the panel in
window mode (upstream rule); bitrate = auto ? the preset's formula (Moonlight
table for the two panel presets, measured anchors for Custom, as before) :
`manualBitrateMbps × 1000`; hdr = `customHDR`. A manual bitrate is sent
verbatim (no codec discount), like Custom's recommendation already was.

### Stream pane

- **Resolution** picker: `Match display (W×H)`, `HiDPI (W/2×H/2)`, 1280×720,
  1920×1080, 2560×1440, 3840×2160, `Custom…` (reveals width × height fields).
  Selecting a standard size sets the Custom preset's numbers; "Custom…" keeps
  whatever was last used (the preset's own `willSet` prefill).
- **Frame rate** picker: `Match display (N Hz)`, 30, 60, 90, 120, 144, 165,
  240, `Custom…`.
- **Bitrate**: "Set automatically" switch plus an always-visible stepped
  slider and Mbps readout; disabled (showing the recommendation) while auto.
- **Display**: Full screen / Window; Fill the notch (notched panels, full
  screen only).
- **Picture in Picture**: pop out on switch-away; mouse over the PiP window.
- **Your next stream** summary line (unchanged).

### Video pane

Codec (per selected PC, the same `HostCodecPreference` the context menu
edits), HDR, and the stats overlay (position, detail, custom rows,
thresholds).

### Audio pane

Channels (auto / stereo / 5.1 / 7.1), Mute this Mac while streaming.

### Input pane

Unchanged content (shortcuts, controller quit, DualSense raw HID, ⌘ keys,
raw mouse).

### App pane

Login items, default action on connect, the Wi-Fi helper (moved from
Quality).

## Fork divergences (expect these to conflict on the next upstream merge)

- `StreamDisplayMode.effective(chosen:preset:)` is now the identity: upstream
  forces `.fullScreen` unless the preset is `.custom`, on the reasoning that
  the panel-native presets *are* full screen. Here the preset only decides the
  size, so Window is honoured under all three. `GlimmerTests/
  StreamDisplayModeTests.swift`'s `windowOnlyAppliesUnderCustom` was inverted
  to match (`theChoiceAppliesUnderEveryPreset`). The `preset` parameter is
  kept, unused, so upstream's call sites still compile.
- `persistQualitySettings()` / `effectiveValuesForPreset(_:)` no longer
  hard-code `hdr = true` for the panel presets, and read frame rate and
  bitrate from the new properties instead of the preset. Upstream's version is
  a `switch` over the preset that resolves all four values.
- `QualityPane` is gone, split into `StreamPane` / `VideoPane` / `AudioPane`
  (new files) with the Wi-Fi section moved to `AppPane` (the renamed
  `GeneralPane`, still in `SettingsGeneralStreamingPanes.swift`).
- `AppModel.isRestoringDefaults`: upstream's `init()` comment asserts property
  observers are suppressed there. They are not - `@Observable` rewrites the
  stored properties into computed ones - and upstream's `qualityPreset`
  willSet prefill overwrites a saved Custom resolution at every launch because
  of it. Any upstream change to `init()` or to those observers needs this
  latch preserved.

## Out of scope

Per-host settings profiles (mme has them; glimmer keys only the codec per
host), an in-stream resolution menu, and any of mme's Metal/EQ machinery.
