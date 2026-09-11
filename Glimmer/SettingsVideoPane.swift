//
//  SettingsVideoPane.swift
//
//  The Video pane: the codec the selected PC is allowed to send (the same
//  per-host preference the launcher's context menu edits), HDR, and the
//  in-stream stats overlay. Size / rate / bitrate belong to the Stream pane;
//  this one is about how the picture is encoded and annotated.
//

import SwiftUI

struct VideoPane: View {
    @Environment(AppModel.self) private var model

    /// Mirror of the selected host's persisted codec preference. Loaded on
    /// appear and whenever the selected host changes; writes go straight back
    /// through `HostCodecPreference.save` and bump the launcher's chip.
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
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("Codec") {
                if let host = model.selectedHost {
                    Picker("", selection: codecSelection) {
                        ForEach(HostCodecPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                } else {
                    Text("Pair a PC to choose the codec it streams with.")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsField("HDR") {
                Toggle("Brighter highlights, deeper colour", isOn: $model.customHDR)
            }

            SettingsRule()

            SettingsField("Stats overlay") {
                Toggle("Show stream health over the picture", isOn: $model.showStreamStats)
            }

            SettingsField("Position") {
                Picker("", selection: $model.streamStatsCorner) {
                    ForEach(StatsOverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            SettingsField("Detail") {
                Picker("", selection: $model.statsOverlayPreset) {
                    ForEach(StatsOverlayPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                if model.statsOverlayPreset == .custom {
                    StatsCustomRowsPicker()
                        .frame(maxWidth: 460, alignment: .leading)
                }
                DisclosureGroup("When numbers turn yellow or red") {
                    StatsThresholdsEditor()
                        .frame(maxWidth: 460, alignment: .leading)
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
        }
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
            return "\(StatsOverlayDefaults.minimalRows.count) metrics - render FPS, latency, bitrate."
        case .micro:
            return "\(StatsOverlayDefaults.microRows.count) metrics - framerate, network, bitrate."
        case .extended: return "All stream metrics (not audio or Mac vitals)."
        case .custom: return "Pick rows individually below."
        }
    }
}
