//
//  TroubleshootingPane.swift
//
//  Hosts the opt-in raw-HID DualSense control (RawHIDControl), used by
//  Settings → Input. The Troubleshooting PANE that used to live here - the
//  controller input test + the log viewer - folded into the always-visible part
//  of Settings → Diagnostics (one pane instead of two thin ones; the input test
//  and logs stay reachable by everyone, the telemetry/tuning sections reveal via
//  the About option-click). Only this shared control remains here; the file name
//  is kept to avoid an Xcode project-file edit.
//

import AppKit
import SwiftUI

// Module-internal (was private) so Settings → Input can host it alongside the
// mouse + controller-quit settings.
/// Opt-in control for the raw-HID DualSense reader. Off by default; turning it
/// on shows a plain-language explanation BEFORE macOS's "Input Monitoring"
/// prompt, so that scary system dialog is never a surprise.
struct RawHIDControl: View {
    @Environment(AppModel.self) private var model
    @State private var showExplain = false
    /// "Working" = reports are actually arriving. The TCC check
    /// (IOHIDCheckAccess) can read not-granted even while reports flow, which
    /// made this say "waiting for permission" when input was clearly working.
    /// Polled into @State by a timer (NOT a TimelineView wrapping the buttons -
    /// that recreated the Buttons + their accessibility modifiers every second
    /// and triggered a SwiftUI view-graph use-after-free). With @State the
    /// buttons are stable; the view only re-renders when `working` flips.
    @State private var working = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentlyWorking: Bool {
        DualSenseHID.shared.reportCount > 0 || DualSenseHID.accessGranted
    }

    var body: some View {
        if model.rawHIDControllerEnabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Icon AND text carry the state - never colour alone, so the
                    // row still reads for a colourblind user and VoiceOver.
                    Label {
                        Text(working ? "On" : "Needs Input Monitoring")
                    } icon: {
                        Image(systemName: working
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(working ? Color.green : Color.orange)
                    }
                    Spacer()
                    Button("Turn Off") { model.rawHIDControllerEnabled = false }
                }
                if !working { permissionActions }
            }
            .onAppear { working = currentlyWorking }
            .onReceive(poll) { _ in working = currentlyWorking }
        } else {
            Button("Enable…") { showExplain = true }
                .alert("Enable enhanced DualSense buttons?", isPresented: $showExplain) {
                    Button("Enable") { enable() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(AppModel.rawHIDExplanation)
                }
        }
    }

    /// The two steps, as two buttons, in the order they have to happen.
    ///
    /// This replaced a tinted card with a gamecontroller glyph and a paragraph
    /// of instructions. Two reasons. It was the only plate on a page of flat
    /// gutter rows, so it read as something pasted in from a web page; and the
    /// paragraph was telling the user to go and do a thing the app can just do
    /// - macOS applies Input Monitoring only on relaunch, so "Quit & Reopen" is
    /// a button, not a sentence. The button titles ARE the instructions, which
    /// is why there is no explanatory text left here.
    private var permissionActions: some View {
        HStack(spacing: 8) {
            Button("Open Input Monitoring…") { Self.registerAndOpen() }
            Button("Quit & Reopen") { Self.relaunch() }
                // Relaunching mid-session would drop the stream.
                .disabled(model.isStreaming)
                .help(model.isStreaming
                      ? "Finish the current stream first"
                      : "macOS applies Input Monitoring only when the app restarts")
        }
    }

    /// Start a fresh instance, then exit this one. `createsNewApplicationInstance`
    /// is load-bearing: without it LaunchServices just reactivates the running
    /// copy and nothing restarts.
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: config
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func enable() {
        model.rawHIDControllerEnabled = true
        // For a never-asked user this prompts and grants; for a denied/stale
        // entry it no-ops, so the permission card guides them to System Settings.
        if !DualSenseHID.accessGranted { Self.registerAndOpen() }
    }

    /// IOHIDRequestAccess is the ONLY call that adds Glimmer to the Input
    /// Monitoring list (IOHIDCheckAccess never registers it - confirmed via
    /// OpenEmu/Karabiner). It also prompts when state is unknown. We then
    /// deep-link so the user can flip the toggle if it's still off.
    ///
    /// `IOHIDRequestAccess` is SYNCHRONOUS and blocks the calling thread for
    /// ~2s while it presents/resolves the TCC prompt, so we run it off the main
    /// thread and only hop back to main to open System Settings. This is the
    /// ONE sanctioned entry point for the permission request + Settings deep
    /// link - it fires only from this explicit "Open Settings" button, never
    /// automatically on controller connect.
    static func registerAndOpen() {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = DualSenseHID.requestAccess()
            guard !granted else { return } // granted → nothing to open
            DispatchQueue.main.async { openInputMonitoring() }
        }
    }

    @MainActor static func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
