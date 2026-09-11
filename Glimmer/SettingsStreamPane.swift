//
//  SettingsStreamPane.swift
//
//  The Stream pane: what the next stream asks the host for - resolution, frame
//  rate, bitrate - and how it shows on this Mac (full screen / window, the
//  notch, Picture in Picture). Laid out with the Tailscale-style gutter rows in
//  SettingsChrome.swift.
//
//  The resolution and frame-rate pickers are VIEWS of `qualityPreset` + the
//  Custom numbers (see Models/StreamChoices.swift), so nothing new is persisted
//  for them and an existing install reads back exactly what it had. The write
//  half lives on AppModel (`apply(_:)`) and is round-tripped in
//  GlimmerTests/StreamChoicesTests.swift.
//

import SwiftUI

struct StreamPane: View {
    @Environment(AppModel.self) private var model

    /// "Custom…" was picked while the Custom numbers still equal a standard
    /// size; without this the picker would snap back to that size's row and the
    /// fields would never appear. Cleared by any other pick.
    @State private var customResolutionEntry = false
    @State private var customFrameRateEntry = false

    // MARK: Picker bindings

    private var resolutionSelection: Binding<ResolutionChoice> {
        Binding(
            get: {
                if customResolutionEntry, model.qualityPreset == .custom { return .custom }
                return model.resolutionChoice
            },
            set: { choice in
                customResolutionEntry = (choice == .custom)
                model.apply(choice)
            })
    }

    private var frameRateSelection: Binding<FrameRateChoice> {
        Binding(
            get: {
                if customFrameRateEntry, !model.frameRateMatchesDisplay { return .custom }
                return model.frameRateChoice
            },
            set: { choice in
                customFrameRateEntry = (choice == .custom)
                model.apply(choice)
            })
    }

    /// The slider rides the stepped scale; while automatic it rests on the
    /// recommendation (disabled), so turning automatic off starts there.
    private var bitrateSliderIndex: Binding<Double> {
        Binding(
            get: { Double(BitrateScale.nearestIndex(toMbps: model.effectiveBitrateKbps / 1000)) },
            set: { model.manualBitrateMbps = BitrateScale.stepsMbps[Int($0.rounded())] })
    }

    // MARK: Labels

    private func resolutionLabel(_ choice: ResolutionChoice) -> String {
        _ = model.displayInfoRevision
        switch choice {
        case .matchDisplay:
            let d = model.smartDefaultsForCurrentDisplay()
            return "Match display (\(d.width) × \(d.height))"
        case .hidpi:
            let d = model.hidpiDefaultsForCurrentDisplay()
            return "HiDPI (\(d.width) × \(d.height))"
        case .standard(let size):
            return "\(size.width) × \(size.height) · \(size.shortLabel)"
        case .custom:
            return "Custom…"
        }
    }

    private func frameRateLabel(_ choice: FrameRateChoice) -> String {
        switch choice {
        case .matchDisplay: return "Match display (\(model.currentDisplayMaxHz) Hz)"
        case .fixed(let hz): return "\(hz) Hz"
        case .custom: return "Custom…"
        }
    }

    // MARK: Clamps (run on EVERY commit, focus loss included)

    private func clampCustomResolution() {
        let width = StreamSizeBounds.clampWidth(model.customWidth)
        if width != model.customWidth { model.customWidth = width }
        let height = StreamSizeBounds.clampHeight(model.customHeight)
        if height != model.customHeight { model.customHeight = height }
    }

    private func clampCustomFPS() {
        let fps = StreamSizeBounds.clampFPS(model.customFPS)
        if fps != model.customFPS { model.customFPS = fps }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("Resolution") {
                Picker("", selection: resolutionSelection) {
                    ForEach(ResolutionChoice.all, id: \.self) { choice in
                        Text(resolutionLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                if resolutionSelection.wrappedValue == .custom {
                    HStack(spacing: 6) {
                        TextField("", value: $model.customWidth, format: .number)
                            .frame(width: 72).multilineTextAlignment(.trailing).monospacedDigit()
                            .onChange(of: model.customWidth) { _, _ in clampCustomResolution() }
                        Text("×").foregroundStyle(.secondary)
                        TextField("", value: $model.customHeight, format: .number)
                            .frame(width: 72).multilineTextAlignment(.trailing).monospacedDigit()
                            .onChange(of: model.customHeight) { _, _ in clampCustomResolution() }
                    }
                }
                SettingsNote("Match display sends every pixel of this Mac's panel - sharpest, and it wants "
                    + "a solid network. HiDPI is the panel's default Retina scale: a touch softer for about "
                    + "a quarter of the bits. Your choice is kept until you change it.")
            }

            SettingsField("Frame rate") {
                Picker("", selection: frameRateSelection) {
                    ForEach(FrameRateChoice.all, id: \.self) { choice in
                        Text(frameRateLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                if frameRateSelection.wrappedValue == .custom {
                    HStack(spacing: 6) {
                        TextField("", value: $model.customFPS, format: .number)
                            .frame(width: 72).multilineTextAlignment(.trailing).monospacedDigit()
                            .onChange(of: model.customFPS) { _, _ in clampCustomFPS() }
                        Text("Hz").foregroundStyle(.secondary)
                    }
                }
                if model.streamDisplayMode == .window {
                    SettingsNote("In a window the stream is capped at this display's \(model.currentDisplayMaxHz) Hz - it can't show more.")
                } else {
                    SettingsNote("Your display can show up to \(model.currentDisplayMaxHz) Hz. Asking for more than the host can render just costs bandwidth.")
                }
            }

            SettingsField("Bitrate") {
                Toggle("Set automatically", isOn: $model.bitrateAuto)
                HStack(spacing: 10) {
                    Slider(value: bitrateSliderIndex,
                           in: 0...Double(BitrateScale.stepsMbps.count - 1), step: 1)
                        .frame(width: 260)
                        .disabled(model.bitrateAuto)
                    Text("\(model.effectiveBitrateKbps / 1000) Mbps")
                        .monospacedDigit()
                        .foregroundStyle(model.bitrateAuto ? .secondary : .primary)
                }
                if model.bitrateAuto {
                    SettingsNote("Recommended for \(model.effectiveWidth) × \(model.effectiveHeight) at \(model.effectiveFPS) Hz. "
                        + "AV1 and HEVC spend about 20% fewer bits for the same picture.")
                } else {
                    SettingsNote("Sent to the host as-is. Too high for the link shows up as stutter and dropped "
                        + "frames, not as a sharper picture.")
                }
            }

            SettingsField("Show the stream") {
                Picker("", selection: $model.streamDisplayMode) {
                    ForEach(StreamDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                if model.streamDisplayMode == .window {
                    SettingsNote("The pointer belongs to the game while it's over the window - hold Esc or press "
                        + "\(model.releasePointerHotkey.displayString) to get it back. Applies to the next stream.")
                } else {
                    SettingsNote("Applies to the next stream.")
                }
            }

            SettingsField("Picture in Picture") {
                Toggle("Pop out when you switch away", isOn: $model.autoPictureInPicture)
                SettingsNote("The stream keeps playing in a small floating window you can drag to any corner, "
                    + "controllers keep working, and the mouse over that window moves the host's pointer. "
                    + "\(model.pipHotkey.displayString) pops it out on demand either way.")
            }

        }
    }
}
