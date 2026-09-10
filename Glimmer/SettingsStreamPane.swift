//
//  SettingsStreamPane.swift
//
//  The Stream pane: what the next stream asks the host for - resolution,
//  frame rate, bitrate - and how it shows on this Mac (full screen / window,
//  the notch, Picture in Picture). Organised the way moonlight-macos-enhanced
//  lays its Stream pane out, on top of glimmer's preset model: the picker is
//  a VIEW of `qualityPreset` + the Custom numbers (see ResolutionChoice), so
//  nothing new is persisted for the resolution and an existing install reads
//  back exactly what it had. See docs/superpowers/specs/2026-09-10-settings-redesign.md.
//

import SwiftUI

struct StreamPane: View {
    @Environment(AppModel.self) private var model

    /// "Custom…" was picked while the Custom numbers still equal a standard
    /// size; without this the picker would snap back to that size's row and
    /// the fields would never appear. Cleared by any other pick.
    @State private var customResolutionEntry = false
    @State private var customFrameRateEntry = false

    // MARK: Picker bindings (views of the persisted model)

    private var resolutionSelection: Binding<ResolutionChoice> {
        Binding(
            get: {
                // The one row the model can't infer: "Custom…" picked while the
                // typed numbers happen to equal a standard size still has to
                // read as Custom, or the fields would vanish under the user.
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

    // MARK: Row labels

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

    // MARK: Clamps (every commit, focus loss included - see AppModel's init heal)

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
        Form {
            Section {
                Picker("Resolution", selection: resolutionSelection) {
                    ForEach(ResolutionChoice.all, id: \.self) { choice in
                        Text(resolutionLabel(choice)).tag(choice)
                    }
                }
                if resolutionSelection.wrappedValue == .custom {
                    LabeledContent("Size") {
                        HStack(spacing: 6) {
                            TextField("", value: $model.customWidth, format: .number)
                                .frame(width: 70).multilineTextAlignment(.trailing).monospacedDigit()
                                .onChange(of: model.customWidth) { _, _ in clampCustomResolution() }
                            Text("×").foregroundStyle(.secondary)
                            TextField("", value: $model.customHeight, format: .number)
                                .frame(width: 70).multilineTextAlignment(.trailing).monospacedDigit()
                                .onChange(of: model.customHeight) { _, _ in clampCustomResolution() }
                        }
                    }
                }
            } header: {
                Text("Resolution")
            } footer: {
                Text("Match display streams every pixel of this Mac's panel (sharpest; wants a solid network). "
                    + "HiDPI is the panel's default Retina scale - a touch softer, about a quarter of the bits. "
                    + "Your choice is kept until you change it.")
            }

            Section {
                Picker("Frame rate", selection: frameRateSelection) {
                    ForEach(FrameRateChoice.all, id: \.self) { choice in
                        Text(frameRateLabel(choice)).tag(choice)
                    }
                }
                if frameRateSelection.wrappedValue == .custom {
                    LabeledContent("Refresh") {
                        HStack(spacing: 6) {
                            TextField("", value: $model.customFPS, format: .number)
                                .frame(width: 60).multilineTextAlignment(.trailing).monospacedDigit()
                                .onChange(of: model.customFPS) { _, _ in clampCustomFPS() }
                            Text("Hz").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Frame rate")
            } footer: {
                if model.streamDisplayMode == .window {
                    Text("In a window the stream is capped at this display's \(model.currentDisplayMaxHz) Hz - it can't show more.")
                } else {
                    Text("Your display can show up to \(model.currentDisplayMaxHz) Hz. A higher rate than the host can render just costs bandwidth.")
                }
            }

            Section {
                Toggle("Set automatically", isOn: $model.bitrateAuto)
                    .toggleStyle(.switch)
                    .help("Follows the resolution and frame rate: the Moonlight table for the panel presets, "
                        + "anchors measured on real hardware for other sizes.")
                LabeledContent("Bitrate") {
                    Text("\(model.effectiveBitrateKbps / 1000) Mbps")
                        .monospacedDigit()
                        .foregroundStyle(model.bitrateAuto ? .secondary : .primary)
                }
                Slider(value: bitrateSliderIndex,
                       in: 0...Double(BitrateScale.stepsMbps.count - 1), step: 1) {
                    Text("Bitrate")
                } minimumValueLabel: {
                    Text("\(BitrateScale.stepsMbps.first ?? 5)").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("\(BitrateScale.stepsMbps.last ?? 300)").font(.caption).foregroundStyle(.secondary)
                }
                .labelsHidden()
                .disabled(model.bitrateAuto)
            } header: {
                Text("Bitrate")
            } footer: {
                if model.bitrateAuto {
                    Text("Recommended for \(model.effectiveWidth) × \(model.effectiveHeight) at \(model.effectiveFPS) Hz. "
                        + "AV1 and HEVC streams spend about 20% fewer bits for the same picture.")
                } else {
                    Text("Sent to the host as-is. Too high for the link shows as stutter and frame drops, "
                        + "not as a sharper picture.")
                }
            }

            Section {
                Picker("Show the stream", selection: $model.streamDisplayMode) {
                    ForEach(StreamDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Window opens the stream as a normal window you can drag to any size.")
                if model.currentDisplayHasNotch, model.effectiveDisplayMode == .fullScreen {
                    Toggle("Fill the notch", isOn: $model.streamCoversNotch)
                        .toggleStyle(.switch)
                        .help("Covers the whole panel, camera notch included, so a panel-native stream renders 1:1. "
                            + "Off keeps the picture below the notch by using a macOS full-screen space.")
                }
            } header: {
                Text("Display")
            } footer: {
                if model.streamDisplayMode == .window {
                    Text("The pointer belongs to the game while it's over the window - hold Esc or press "
                        + "\(model.releasePointerHotkey.displayString) to get it back. Applies to the next stream.")
                } else if model.currentDisplayHasNotch {
                    Text("A thin strip of the picture hides behind the notch when it's filled. Applies to the next stream.")
                } else {
                    Text("Applies to the next stream.")
                }
            }

            Section {
                Toggle("Pop out to Picture in Picture when you switch away", isOn: $model.autoPictureInPicture)
                    .toggleStyle(.switch)
                    .help("Cmd-Tab away and the stream keeps playing in macOS's floating Picture in Picture window.")
                Toggle("Mouse over the PiP window moves the host pointer", isOn: $model.pipPointerMirror)
                    .toggleStyle(.switch)
                    .help("The host's pointer follows yours across the picture while it's popped out, and a click "
                        + "on the picture clicks there. Dragging the window or its controls never reaches the host.")
            } header: {
                Text("Picture in Picture")
            } footer: {
                Text("The stream keeps playing in a small floating window you can drag to any corner - "
                    + "controllers keep working. \(model.pipHotkey.displayString) pops it out on demand either way.")
            }

            Section("Your next stream") {
                Text(model.streamSpecSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
