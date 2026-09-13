//
//  SettingsVideoPane.swift
//
//  The Video pane: the codec the selected PC is allowed to send (the same
//  per-host preference the launcher's context menu edits), HDR, and the Wi-Fi
//  smoothing helper (it improves the stream, so it lives on the Stream tab).
//  Size / rate / bitrate belong to the Stream pane. The stats overlay moved to
//  General, next to Troubleshooting - it is a diagnostic, not a picture setting.
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

    /// The privileged AWDL network helper (parks awdl0 during streams).
    @ObservedObject private var awdl = AWDLHelperManager.shared

    /// Defer the register/unregister off the SwiftUI update transaction -
    /// running the XPC-backed call inline mid-update dismissed the window.
    private func scheduleHelperToggle(_ enable: Bool) {
        Task { @MainActor in
            if enable { AWDLHelperManager.shared.enable() } else { AWDLHelperManager.shared.disable() }
        }
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

            SettingsField("Wi-Fi") {
                Toggle("Smooth out Wi-Fi stutter while streaming",
                       isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) }))
                if case .requiresApproval = awdl.state {
                    SettingsNotice(icon: "exclamationmark.triangle.fill",
                                   message: "macOS needs you to approve the Shimmer network helper.") {
                        Button("Open Login Items") { awdl.openSystemSettings() }
                    }
                }
                if case .unavailable(let why) = awdl.state {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Network helper unavailable: \(why)", systemImage: "xmark.octagon")
                            .font(.system(size: 12)).foregroundStyle(.red)
                        if let url = awdl.recoveryDocURL {
                            Link("How to manage login items (Apple Support)", destination: url)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .onAppear { reloadCodec(); awdl.refresh() }
        .onChange(of: model.selectedHost?.id) { _, _ in reloadCodec() }
    }

    private func reloadCodec() {
        codecPref = model.selectedHost.map { HostCodecPreference.load(for: $0.id) } ?? .auto
    }
}
