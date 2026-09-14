//
//  SettingsGeneralStreamingPanes.swift
//
//  The App settings pane: login items, the stats overlay, and diagnostics.
//  (Wi-Fi smoothing moved to the Stream tab's Video pane - it tunes the stream.)
//  SettingsRoot composes panes across files, so the types are internal. (Filename keeps
//  its pre-redesign name - renaming means touching the pbxproj for zero
//  behavioural gain; the Stream / Video / Audio panes that replaced the old
//  Quality pane live in their own files.) `LoginItemManager`, the registration
//  plumbing behind the launch toggles, lives in
//  SettingsGeneralStreamingPanes+LoginItem.swift.
//

import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - App

struct AppPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    /// True when macOS has the login item but it is pending the user's approval
    /// in System Settings > Login Items - surfaced inline so the user is not
    /// left with a toggle that silently does nothing at the next reboot.
    @State private var loginItemNeedsApproval = false

    /// Defer the SMAppService register/unregister off the SwiftUI `.onChange`
    /// transaction - running it inline (synchronous, XPC-backed) mid-update
    /// dismissed the window.
    private func scheduleLoginItemRegistration(launchAtLogin: Bool) {
        DispatchQueue.main.async {
            let status = LoginItemManager.apply(launchAtLogin: launchAtLogin)
            loginItemNeedsApproval = (status == .requiresApproval)
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("General") {
                // Login launches come up in the menu bar like every other
                // launch (the helper relaunches the app suppressed).
                Toggle("Be ready at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: on)
                    }
                if loginItemNeedsApproval {
                    SettingsNotice(icon: "exclamationmark.triangle.fill",
                                   message: "macOS needs you to approve Shimmer in Login Items.") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            SettingsRule()

            SettingsField("Stats overlay") {
                Toggle("Show stream health over the picture", isOn: $model.showStreamStats)
            }

            SettingsRule()

            // Deliberately NOT behind the `showDiagnostics` reveal the rest of
            // this group sits behind. This switch is the first thing to flip
            // when a stream misbehaves - it starts the recorder whose output
            // (one JSON object per second, plus GET /snapshot on loopback) is
            // how anyone, human or otherwise, finds out WHY. A troubleshooting
            // switch nobody can find troubleshoots nothing.
            SettingsField("Troubleshooting") {
                Toggle("Record stream health while streaming", isOn: $model.telemetryEnabled)
                if model.telemetryEnabled {
                    Button("Show recordings in Finder") {
                        let dir = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Logs/Shimmer", isDirectory: true)
                        try? FileManager.default.createDirectory(
                            at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }

            if model.showDiagnostics {
                SettingsRule()
                SettingsField("Diagnostics") {
                    DisclosureGroup("Controller input test") {
                        ControllerInputTest().settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                    }
                    .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                    DisclosureGroup("Logs") {
                        LogViewer().frame(maxWidth: 560, alignment: .leading)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
        .onAppear {
            guard launchAtLogin else { loginItemNeedsApproval = false; return }
            let service = SMAppService.loginItem(identifier: LoginItemManager.helperBundleID)
            loginItemNeedsApproval = (service.status == .requiresApproval)
        }
    }
}
