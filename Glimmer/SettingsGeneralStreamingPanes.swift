//
//  SettingsGeneralStreamingPanes.swift
//
//  The App settings pane (login items, default action, the Wi-Fi helper) and
//  the stats-overlay custom-rows picker the Video pane embeds. SettingsRoot
//  composes panes across files, so the types are internal. (Filename keeps
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
    @AppStorage("launchMinimized") private var launchMinimized: Bool = false

    /// True when macOS has the login item but it is pending the user's approval
    /// in System Settings > Login Items - surfaced inline so the user is not
    /// left with a toggle that silently does nothing at the next reboot.
    @State private var loginItemNeedsApproval = false

    /// The privileged AWDL network helper (parks awdl0 during streams).
    @ObservedObject private var awdl = AWDLHelperManager.shared

    /// Defer the SMAppService register/unregister off the SwiftUI `.onChange`
    /// transaction - running it inline (synchronous, XPC-backed) mid-update
    /// dismissed the window.
    private func scheduleLoginItemRegistration(launchAtLogin: Bool, minimized: Bool) {
        DispatchQueue.main.async {
            let status = LoginItemManager.apply(launchAtLogin: launchAtLogin, minimized: minimized)
            loginItemNeedsApproval = (status == .requiresApproval)
        }
    }

    private func scheduleHelperToggle(_ enable: Bool) {
        Task { @MainActor in
            if enable { AWDLHelperManager.shared.enable() } else { AWDLHelperManager.shared.disable() }
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("General") {
                Toggle("Be ready at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: on, minimized: launchMinimized)
                    }
                Toggle("Stay hidden at login (menu bar only)", isOn: $launchMinimized)
                    .onChange(of: launchMinimized) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: launchAtLogin, minimized: on)
                    }
                    .disabled(!launchAtLogin)
                if loginItemNeedsApproval {
                    HStack(spacing: 8) {
                        Label("macOS needs you to approve Shimmer in Login Items.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            SettingsRule()

            SettingsField("Wi-Fi") {
                Toggle("Smooth out Wi-Fi stutter while streaming",
                       isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) }))
                if case .requiresApproval = awdl.state {
                    HStack(spacing: 8) {
                        Label("macOS needs you to approve the Shimmer network helper.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
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

            if model.showDiagnostics {
                SettingsRule()
                SettingsField("Diagnostics") {
                    Toggle("Performance telemetry", isOn: $model.telemetryEnabled)
                    DisclosureGroup("Controller input test") {
                        ControllerInputTest().frame(maxWidth: 460, alignment: .leading)
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    DisclosureGroup("Logs") {
                        LogViewer().frame(maxWidth: 560, alignment: .leading)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
        .onAppear {
            awdl.refresh()
            guard launchAtLogin else { loginItemNeedsApproval = false; return }
            let service = launchMinimized
                ? SMAppService.loginItem(identifier: LoginItemManager.helperBundleID)
                : SMAppService.mainApp
            loginItemNeedsApproval = (service.status == .requiresApproval)
        }
    }
}

// MARK: - Stats custom rows picker
//
// Standalone view (not inlined in the QualityPane) because the
// Section{} body in SwiftUI's Form has tight rules about what counts as
// a single row vs. a multi-row group, and a grouped checkbox grid sits
// most cleanly as its own view. Reads + writes the manager directly via
// @Environment; no separate binding plumbing.
struct StatsCustomRowsPicker: View {
    @Environment(AppModel.self) private var model

    /// Row catalogue grouped by section for display. The order here
    /// matches the rendering order in StreamStatsSnapshot.rows() - the
    /// user sees the same top-to-bottom shape in the checkbox list as
    /// in the overlay. Audio sits at the bottom and is unchecked by
    /// default; users opt in via Custom.
    private static let sections: [(title: String, rows: [(StatsRow.Kind, String)])] = [
        ("Frame rates", [
            (.hostFps, "Host FPS"),
            (.networkFps, "Network FPS"),
            (.decodeFps, "Decode FPS"),
            (.renderFps, "Render FPS")
        ]),
        ("Network", [
            (.latency, "Latency"),
            (.jitter, "Jitter"),
            (.networkDrops, "Network drop rate")
        ]),
        ("Pipeline", [
            (.decoderDrops, "Decoder drops"),
            (.smoothness, "Smoothness"),
            (.decodeTime, "Decode time"),
            (.bitrate, "Bitrate"),
            (.hostProcessing, "Host encode latency")
        ]),
        ("Mac", [
            (.macCpu, "Mac CPU"),
            (.macRam, "Mac RAM"),
            (.macBattery, "Mac battery"),
            (.controllerBattery, "Controller battery")
        ]),
        ("Config", [
            (.audio, "Audio configuration")
        ])
    ]

    init() {
        // Exhaustiveness tripwire: every StatsRow.Kind must appear in the
        // hand-maintained catalogue above, or that row silently becomes
        // un-toggleable in Custom (how .smoothness went missing - added
        // to the enum and Extended, never to this list). Debug-only;
        // assert() compiles out of release builds.
        assert(
            Set(Self.sections.flatMap { $0.rows.map(\.0) }) == Set(StatsRow.Kind.allCases),
            "Custom-rows catalogue is out of sync with StatsRow.Kind.allCases")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(section.rows, id: \.0) { row in
                        Toggle(row.1, isOn: rowBinding(for: row.0))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    /// Two-way binding for one row's membership in the custom-rows set.
    /// Set-mutation goes through the property's didSet so the
    /// UserDefaults persistence kicks in on every toggle.
    private func rowBinding(for kind: StatsRow.Kind) -> Binding<Bool> {
        Binding(
            get: { model.statsOverlayCustomRows.contains(kind) },
            set: { isOn in
                if isOn {
                    model.statsOverlayCustomRows.insert(kind)
                } else {
                    model.statsOverlayCustomRows.remove(kind)
                }
            }
        )
    }
}
