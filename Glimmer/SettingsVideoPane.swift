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
                    .settingsControl()
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
        }
        .onAppear { reloadCodec() }
        .onChange(of: model.selectedHost?.id) { _, _ in reloadCodec() }
    }

    private func reloadCodec() {
        codecPref = model.selectedHost.map { HostCodecPreference.load(for: $0.id) } ?? .auto
    }
}
