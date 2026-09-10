//
//  SettingsVideoPane.swift
//
//  The Video pane: the codec the selected PC is allowed to send (the same
//  per-host preference the launcher's context menu edits), HDR, and the
//  in-stream stats overlay. The size / rate / bitrate dials are the Stream
//  pane's; this pane is about how the picture is encoded and annotated.
//

import SwiftUI

struct VideoPane: View {
    @Environment(AppModel.self) private var model

    /// Mirror of the selected host's persisted codec preference. Loaded on
    /// appear and whenever the selected host changes; writes go straight
    /// back through `HostCodecPreference.save` and bump the launcher's chip.
    @State private var codecPref: HostCodecPreference = .auto

    private var codecSelection: Binding<HostCodecPreference> {
        Binding(
            get: { codecPref },
            set: { pref in
                codecPref = pref
                guard let host = model.selectedHost else { return }
                HostCodecPreference.save(pref, for: host.id)
                model.displayInfoRevision &+= 1
            })
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if let host = model.selectedHost {
                    Picker("Codec for \(host.displayName)", selection: codecSelection) {
                        ForEach(HostCodecPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                } else {
                    Text("Pair a PC to choose the codec it streams with.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Codec")
            } footer: {
                Text("Automatic negotiates the best both sides support - AV1, then HEVC, then H.264 - "
                    + "and only advertises what this Mac decodes in hardware. Pick a lower one if a PC's "
                    + "encoder misbehaves. Remembered per PC.")
            }

            Section {
                Toggle("HDR (brighter highlights, deeper color)", isOn: $model.customHDR)
                    .toggleStyle(.switch)
            } header: {
                Text("HDR")
            } footer: {
                Text("Needs HDR on the host and an HDR display here. The launcher's HDR badge lights "
                    + "up only once a PQ or HLG stream is actually running.")
            }

            Section {
                Toggle("Watch the stream's health while you play (small overlay over the picture)",
                       isOn: $model.showStreamStats)
                Text("Toggle it any time in-stream with \(model.statsHotkey.displayString).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Overlay position", selection: $model.streamStatsCorner) {
                    ForEach(StatsOverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                Picker("Overlay detail", selection: $model.statsOverlayPreset) {
                    ForEach(StatsOverlayPreset.allCases, id: \.self) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.displayName).fontWeight(.medium)
                            Text(Self.presetSubtitle(preset))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.inline)
                if model.statsOverlayPreset == .custom {
                    StatsCustomRowsPicker()
                }
                DisclosureGroup("When numbers turn yellow or red") {
                    StatsThresholdsEditor()
                }
            } header: {
                Text("Stats overlay")
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadCodec() }
        .onChange(of: model.selectedHost?.id) { _, _ in reloadCodec() }
    }

    private func reloadCodec() {
        codecPref = model.selectedHost.map { HostCodecPreference.load(for: $0.id) } ?? .auto
    }

    /// Per-preset hint. Counts derive from the row-set constants so the copy
    /// can't drift when a preset gains a row.
    static func presetSubtitle(_ preset: StatsOverlayPreset) -> String {
        switch preset {
        case .minimal:
            return "\(StatsOverlayDefaults.minimalRows.count) metrics - render FPS, latency, bitrate"
        case .micro:
            return "\(StatsOverlayDefaults.microRows.count) metrics - framerate, network, bitrate"
        case .extended: return "All stream metrics (not audio or Mac vitals)"
        case .custom: return "Pick rows individually below"
        }
    }
}
