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

    /// `true` once the user has been sent to System Settings, so the row can
    /// show ONE action at a time. Load-bearing because `IOHIDCheckAccess` is
    /// cached per process: after the user flips the toggle we cannot observe the
    /// grant landing, so "you have been there, now relaunch" is the only signal
    /// available - and it is the right one, since relaunch is genuinely the next
    /// step either way.
    @State private var sentToSettings = false

    var body: some View {
        // A checkbox, like every other row on this page. It replaced an
        // "Enable…" button / "Turn Off" button pair plus a two-button permission
        // card - four controls for one setting, on a page whose grammar is one
        // label and one control. The warning line below borrows the shape the
        // login-item and Wi-Fi helper rows already use for "macOS needs you to
        // approve this": one short orange line, one button.
        Toggle("Use the Options, Create and Mute buttons", isOn: enabledBinding)
            .alert("Enable enhanced DualSense buttons?", isPresented: $showExplain) {
                Button("Enable") { enable() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AppModel.rawHIDExplanation)
            }
        if model.rawHIDControllerEnabled, !working {
            HStack(spacing: 8) {
                // Short enough to stay on ONE line beside the button - a
                // wrapped message leaves the button floating against two lines
                // of text, which is what made this row look assembled rather
                // than designed. The button title carries the detail.
                Label(sentToSettings ? "Relaunch to finish" : "Input Monitoring is off",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                if sentToSettings {
                    Button("Quit & Reopen") { Self.relaunch() }
                        // Relaunching mid-session would drop the stream.
                        .disabled(model.isStreaming)
                        .help(model.isStreaming
                              ? "Finish the current stream first"
                              : "macOS applies Input Monitoring only when the app restarts")
                } else {
                    Button("Open Input Monitoring") {
                        // Only advance to "Relaunch to finish" if we really did
                        // hand the user to System Settings; if the system prompt
                        // came up instead, answering it IS the step.
                        Self.registerAndOpen { sentToSettings = $0 }
                    }
                }
            }
            .onAppear { working = currentlyWorking }
            .onReceive(poll) { _ in working = currentlyWorking }
        }
    }

    /// Turning it ON routes through the explanation alert first - macOS's own
    /// Input Monitoring dialog says "keystrokes", and that is worth defusing
    /// before it appears. Turning it OFF is immediate.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.rawHIDControllerEnabled },
            set: { on in
                if on {
                    showExplain = true
                } else {
                    model.rawHIDControllerEnabled = false
                    sentToSettings = false
                }
            })
    }

    private func enable() {
        model.rawHIDControllerEnabled = true
        // For a never-asked user this prompts and grants; for a denied/stale
        // entry it no-ops, so the warning line guides them to System Settings.
        if !DualSenseHID.accessGranted { Self.registerAndOpen() }
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
    /// - Parameter done: called on the main actor with `true` only if we
    ///   actually sent the user to System Settings.
    static func registerAndOpen(done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        // WHY THIS IS TWO CASES. `IOHIDRequestAccess` presents the system
        // Input Monitoring prompt when TCC has never been asked. Opening System
        // Settings straight afterwards put a full-size window ON TOP of that
        // prompt, so the thing the user had to answer was hidden behind the
        // thing we had just opened - and the reported symptom was "it keeps
        // telling me to enable it" while the prompt sat unanswered underneath.
        //
        // So: if TCC has no answer yet, request and STOP - the prompt is the
        // whole interaction. Only when TCC already has an answer (the request
        // no-ops) is System Settings the right place to send anyone.
        let hasAnAnswer = DualSenseHID.accessGranted || DualSenseHID.accessDenied
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = DualSenseHID.requestAccess()
            DispatchQueue.main.async {
                guard !granted, hasAnAnswer else { done(false); return }
                openInputMonitoring()
                done(true)
            }
        }
    }

    @MainActor static func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
