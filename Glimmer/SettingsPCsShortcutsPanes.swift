//
//  SettingsPCsShortcutsPanes.swift
//
//  The PCs and Shortcuts settings panes (+ PC tile and hotkey row/badge
//  helpers), split out of SettingsView.swift. Internal so SettingsRoot can
//  compose them across files. (About lives in AboutPane.swift.)
//

import AppKit
import GameController
import os
import ServiceManagement
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showChordCapture = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("In-stream keys") {
                HotkeyRow(label: "Leave the stream", hotkey: $model.quitHotkey)
                    .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                HotkeyRow(label: "Show or hide stream stats", hotkey: $model.statsHotkey)
                    .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                HotkeyRow(label: "Pop out (Picture in Picture)", hotkey: $model.pipHotkey)
                    .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                HotkeyRow(label: "Capture or release the pointer", hotkey: $model.releasePointerHotkey)
                    .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
            }

            SettingsField("macOS keys") {
                Toggle("Use ⌘ shortcuts inside the game", isOn: $model.captureSysKeys)
            }

            SettingsRule()

            SettingsField("Controller quit") {
                Picker("", selection: $model.controllerQuitChord) {
                    ForEach(ControllerQuitChord.allCases, id: \.self) { chord in
                        Text(chord.displayName).tag(chord)
                    }
                }
                .labelsHidden()
                .settingsControl()
                if model.controllerQuitChord == .custom {
                    HStack(spacing: 8) {
                        Text(model.customControllerChord.isEmpty
                             ? "No chord recorded yet"
                             : ControllerButton.describe(model.customControllerChord))
                            .foregroundStyle(model.customControllerChord.isEmpty ? .secondary : .primary)
                        Button("Record…") { showChordCapture = true }
                    }
                }
            }

            if model.controllerConnected || model.rawHIDControllerEnabled {
                SettingsField("DualSense") {
                    RawHIDControl()
                        .settingsControl(maxWidth: SettingsMetrics.wideControlWidth)
                }
            }
        }
        .sheet(isPresented: $showChordCapture) {
            ChordCaptureSheet().environment(model)
        }
    }
}

// MARK: - Controller chord capture (#9)

/// Records a custom controller exit chord by reading live held buttons. The
/// user holds the combo and releases; the set held just before release becomes
/// the chord. Reuses the input-test ControllerMonitor (to engage GameController
/// value updates) + the DualSense raw-HID reader for the center buttons.
private struct ChordCaptureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current: Set<ControllerButton> = []
    /// Sticky union of every button held during this recording - so releasing
    /// the combo one button at a time still captures the whole chord.
    @State private var accumulated: Set<ControllerButton> = []
    @State private var captured: Set<ControllerButton> = []
    @State private var recording = true
    @State private var observers: [NSObjectProtocol] = []
    @State private var hidRetained = false
    // Backstop the event-driven capture in case a release event is missed.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Text("Record exit chord").font(.headline)

            if recording {
                Text("Hold all the buttons for your chord at once, then **release** to capture.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(accumulated.isEmpty ? "Waiting for input…" : ControllerButton.describe(accumulated))
                    .font(.title3.monospaced())
                    .foregroundStyle(accumulated.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(minHeight: 28)
            } else {
                Text("Captured chord").font(.callout).foregroundStyle(.secondary)
                Text(ControllerButton.describe(captured))
                    .font(.title2.weight(.semibold)).foregroundStyle(.tint)
                Button("Record again") { startRecording() }
                    .buttonStyle(.bordered)
            }

            if DualSenseHID.isEnabled == false {
                Text("Tip: turn on Extra DualSense buttons (Settings → Input) to record "
                    + "the Options / Create / Mute buttons.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(captured.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { engage() }
        .onDisappear { disengage() }
        .onReceive(tick) { _ in poll() }
    }

    /// Register input handlers directly (rather than via the input-test
    /// ControllerMonitor) so capture works regardless of stream state, and so
    /// every press/release drives `poll()` - not just the timer.
    private func engage() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery {}
        setGamepadHandlers()
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { setGamepadHandlers() } })
        if DualSenseHID.isEnabled {
            DualSenseHID.shared.onChange = { poll() }
            DualSenseHID.shared.retain()
            hidRetained = true
        }
    }

    private func setGamepadHandlers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { _, _ in
                MainActor.assumeIsolated { poll() }
            }
        }
    }

    private func disengage() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        if hidRetained {
            DualSenseHID.shared.onChange = nil
            DualSenseHID.shared.release()
            hidRetained = false
        }
    }

    private func startRecording() {
        captured = []; accumulated = []; current = []; recording = true
    }

    private func poll() {
        guard recording, let pad = GCController.controllers().first?.extendedGamepad else { return }
        let held = heldControllerButtons(pad: pad)
        current = held
        if !held.isEmpty {
            // Sticky: remember every button touched during the hold, so a
            // staggered release still yields the full chord.
            accumulated.formUnion(held)
        } else if !accumulated.isEmpty {
            // Fully released after a held combo → that's the chord.
            captured = accumulated
            recording = false
        }
    }

    private func save() {
        model.customControllerChord = captured
        model.controllerQuitChord = .custom
        dismiss()
    }
}

struct HotkeyRow: View {
    let label: String
    @Binding var hotkey: HotkeyChord

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyBadge(hotkey: $hotkey)
        }
    }
}

struct HotkeyBadge: View {
    @Binding var hotkey: HotkeyChord
    @State private var isCapturing = false
    @State private var livePreview = ""
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isCapturing { stop() } else { start() }
            } label: {
                Text(displayText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(minWidth: 120, minHeight: 22)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    // Capture state tints the glass with the accent color so it
                    // reads as "live", otherwise it's a neutral glass capsule.
                    .glassEffect(
                        isCapturing
                            ? .regular.interactive().tint(Color.accentColor.opacity(0.22))
                            : .regular.interactive(),
                        in: .capsule
                    )
                    .overlay(
                        Capsule().stroke(
                            isCapturing ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                    )
                    .foregroundStyle(isCapturing ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)

            // Esc-to-cancel hint shown only during capture. Mirrors macOS's
            // own keyboard-shortcut capture UI (System Settings ▸
            // Keyboard ▸ Keyboard Shortcuts).
            if isCapturing {
                Text("Press Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .onDisappear { stop() }
        .animation(.snappy(duration: 0.2), value: isCapturing)
    }

    private var displayText: String {
        if isCapturing {
            return livePreview.isEmpty ? "Press keys…" : livePreview
        }
        return hotkey.displayString
    }

    private func start() {
        isCapturing = true
        livePreview = ""
        // Local event monitor catches keys regardless of first-responder state.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // swallow so Cmd+Q etc. don't activate menu items
        }
    }

    private func stop() {
        isCapturing = false
        livePreview = ""
        if let activeMonitor = monitor {
            NSEvent.removeMonitor(activeMonitor)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Update live modifier preview on flagsChanged
        if event.type == .flagsChanged {
            var parts: [String] = []
            if mods.contains(.control) { parts.append("⌃") }
            if mods.contains(.option) { parts.append("⌥") }
            if mods.contains(.shift) { parts.append("⇧") }
            if mods.contains(.command) { parts.append("⌘") }
            livePreview = parts.isEmpty ? "" : parts.joined() + "…"
            return
        }

        // keyDown: commit the chord if it's a letter or number
        // ESC = cancel
        if event.keyCode == 53 {
            stop()
            return
        }

        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let char = chars.first,
              char.isLetter || char.isNumber else {
            return
        }
        let hk = HotkeyChord(
            ctrl: mods.contains(.control),
            alt: mods.contains(.option),
            shift: mods.contains(.shift),
            cmd: mods.contains(.command),
            keyChar: String(char).lowercased()
        )
        guard hk.ctrl || hk.alt || hk.shift || hk.cmd else { return }
        hotkey = hk
        stop()
    }
}

// About pane: AboutPane.swift.
