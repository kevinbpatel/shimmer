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

// About pane: AboutPane.swift.
