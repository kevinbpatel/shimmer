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
                Toggle("Show status in menu bar", isOn: $model.showMenuBarItem)
                    .help("Shows the active app, controller battery, or a warning. Hidden when idle; Shimmer stays available in the Dock.")
                SettingsHelp("Hidden when idle. Shimmer stays available in the Dock.")
                // The login helper suppresses the window; Dock access remains
                // available whenever there is no useful menu-bar status.
                // Waiting for approval it isn't on, so no tick: a red dot stands
                // in the checkbox's place until the user allows Shimmer.
                if loginItemNeedsApproval {
                    SettingsNotice(message: "Be ready at login") {
                        Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .help("Turn on Shimmer under Allow in the Background. Starts quietly when you sign in.")
                } else {
                    Toggle("Be ready at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            scheduleLoginItemRegistration(launchAtLogin: on)
                        }
                    SettingsHelp("Starts quietly when you sign in.")
                }
            }

            // Deliberately NOT behind the `showDiagnostics` reveal the rest of
            // this group sits behind. This switch is the first thing to flip
            // when a stream misbehaves - it starts the recorder whose output
            // (one JSON object per second, plus GET /snapshot on loopback) is
            // how anyone, human or otherwise, finds out WHY. A troubleshooting
            // switch nobody can find troubleshoots nothing.
            SettingsField("Stream health") {
                Toggle("Show over the picture", isOn: $model.showStreamStats)
                Toggle("Record while streaming", isOn: $model.telemetryEnabled)
                    .settingsStackedToggle()
                SettingsHelp("Saves local recordings for diagnosing stream issues.")
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

            // The agent finds the bundled shimmerctl itself (the instructions
            // carry its path), so there's nothing to install or type here.
            SettingsField("Coding agents") {
                HStack {
                    Text("Let an agent check and fix Shimmer.")
                    Spacer(minLength: 8)
                    CLICopyButton("Copy Instructions") {
                        ShimmerCLIAgentInstructions.text(hostName: model.selectedHost?.displayName,
                            address: model.selectedHostRouteAddress)
                    }
                    .settingsTrailingButton()
                }
            }

            if model.showDiagnostics {
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
        .onAppear { refreshLoginApproval() }
        // Approval happens in System Settings; re-check on the way back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginApproval()
        }
    }

    private func refreshLoginApproval() {
        guard launchAtLogin else { loginItemNeedsApproval = false; return }
        let service = SMAppService.loginItem(identifier: LoginItemManager.helperBundleID)
        loginItemNeedsApproval = (service.status == .requiresApproval)
    }
}
