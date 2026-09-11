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

/// The app's appearance. macOS follows the system by default, but a streaming
/// client is often used in a dark room next to a TV while the Mac itself is in
/// light mode - so it is worth being able to pin, the way the reference app
/// (moonlight-macos-enhanced) does.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means "inherit", which is what an unset `NSApp.appearance` does.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies to every window the app owns, including ones already on screen.
    @MainActor func apply() { NSApp.appearance = nsAppearance }
}

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

    /// Default-launch options - the host applist with "Desktop" pinned first.
    private var launchAppOptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in ["Desktop"] + (model.selectedHost?.apps.map(\.name) ?? [])
        where seen.insert(name).inserted {
            out.append(name)
        }
        let current = model.defaultLaunchApp
        if !current.isEmpty, seen.insert(current).inserted { out.append(current) }
        return out
    }

    /// A stored app that is not on the selected host (set on another PC) is
    /// annotated so the picker does not imply it will launch here.
    private func launchOptionLabel(_ name: String) -> String {
        guard name != "Desktop",
              let host = model.selectedHost,
              !host.apps.contains(where: { $0.name == name }) else { return name }
        return "\(name) (not on \(host.displayName))"
    }

    var body: some View {
        @Bindable var model = model
        SettingsPageBody {
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
                SettingsNote("When hidden, Shimmer launches into the menu bar at login without showing the "
                    + "window. Manual launches via Spotlight, Finder or the Dock always open it.")
                if loginItemNeedsApproval {
                    HStack(spacing: 8) {
                        Label("macOS needs you to approve Shimmer in Login Items.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            SettingsField("Appearance") {
                Picker("", selection: $model.appAppearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            SettingsField("On connect, launch") {
                Picker("", selection: $model.defaultLaunchApp) {
                    ForEach(launchAppOptions, id: \.self) { name in
                        Text(launchOptionLabel(name)).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                SettingsNote("Right-click a PC in the library to pick a different app per connection.")
            }

            SettingsRule()

            SettingsField("Wi-Fi") {
                Toggle("Smooth out Wi-Fi stutter while streaming",
                       isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) }))
                SettingsNote("Parks AirDrop's radio (AWDL) for the length of a stream so it can't grab the "
                    + "Wi-Fi channel and cause multi-second freezes. Restored the instant you stop. Installs a "
                    + "small helper that needs a one-time approval.")
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
                    SettingsNote("Local only - writes per-frame traces under ~/Library/Logs/Shimmer. "
                        + "Nothing leaves this Mac.")
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
