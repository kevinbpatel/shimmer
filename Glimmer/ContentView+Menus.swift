//
//  ContentView+Menus.swift
//
//  The launcher's two menu surfaces: the MenuBarExtra dropdown (open / stream /
//  switch PC / controller charm / Settings / updates / quit) and the shared
//  per-host right-click menu (Rename / Codec / Unpair) that both the hero card
//  and Settings' PCTile mount via `.hostContextMenu(host)`. Split out of
//  ContentView.swift to keep each file under the length limit; the window,
//  connect surface, and hero live there.
//

import AppKit
import SwiftUI

extension AppModel.ControllerGlyph {
    /// The mark itself. The PlayStation body is bundled template art (see
    /// `AppModel.menuBarControllerGlyph` for why it isn't an SF Symbol); it is
    /// authored at 20x14pt, which is the menu bar's size, so the dropdown asks
    /// for a smaller frame to sit level with the SF Symbols around it.
    func image(height: CGFloat? = nil) -> some View {
        Group {
            switch self {
            case .playStation:
                if let height {
                    Image("DualSenseGlyph").resizable().scaledToFit()
                        .frame(height: height)
                } else {
                    Image("DualSenseGlyph")
                }
            case .generic:
                Image(systemName: "gamecontroller.fill")
            }
        }
    }
}

// MARK: - Menu bar content

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Icon-forward, sectioned layout within `.menu`-style MenuBarExtra
            // constraints (system NSMenu: Labels show their SF Symbol,
            // Sections render titled groups, custom materials are NOT
            // honoured - lean on iconography + structure, not glass). Item
            // order: navigational ("Open Shimmer") FIRST, then stream actions,
            // then app-wide (Settings / Quit) - Apple's first-party agent
            // pattern (Time Machine, Bluetooth).
            Button {
                openWindow(id: "main")
                activate()
            } label: {
                Label("Open Shimmer", systemImage: "macwindow")
            }

            if let host = model.selectedHost {
                // "Connected to" only when actually streaming this host - the
                // selected host is not necessarily the connected one.
                Section(model.isStreaming ? "Connected to \(host.displayName)" : host.displayName) {
                    if model.isStreaming {
                        // ONE row for the live session, named and iconed off the
                        // app: "Streaming X" (status, disabled) while the window
                        // is up, "Back to X" (the way back) whenever it is hidden
                        // - a plain Cmd-Tab-away OR showing in PiP. It used to be
                        // a greyed-out "Stream X" plus a separate "Back to stream".
                        Button {
                            model.resumeStreamWindow()
                        } label: {
                            Label {
                                Text(model.liveStreamRowTitle)
                            } icon: {
                                if let app = model.heroTargetApp {
                                    AppGlyphIcon(app: app, size: 12)
                                } else {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                }
                            }
                        }
                        .disabled(!model.nativeStreamBackgrounded)
                        // "Picture in Picture" whenever it isn't already popped out.
                        if !model.nativeStreamPictureInPicture {
                            Button {
                                model.enterPictureInPicture()
                            } label: {
                                Label("Picture in Picture", systemImage: "pip.enter")
                            }
                        }
                    } else {
                        // Named AND iconed off the app this actually launches -
                        // the one you streamed here last, not a fixed "Desktop".
                        // The label used to read `defaultAppName` while the
                        // action resolved the last-played target, so the item
                        // could say "Stream Desktop" and launch Steam.
                        //
                        // Two forms of the launch: show the stream, or pop it
                        // straight out into Picture in Picture (the window never
                        // shows, the picture lands in the corner, the app you
                        // were in stays in front). Settings picks which one the
                        // row is; holding ⌥ gives the other.
                        let popOutFirst = model.menuBarStreamsPopOut
                        launchRow(popOut: popOutFirst)
                            .modifierKeyAlternate(.option) {
                                launchRow(popOut: !popOutFirst)
                            }
                    }

                    if model.hosts.count > 1 {
                        Menu {
                            ForEach(model.hosts) { host in
                                Button {
                                    model.selectHost(host)
                                } label: {
                                    if host.id == model.selectedHost?.id {
                                        Label(host.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(host.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label("Switch PC", systemImage: "desktopcomputer")
                        }
                    }
                }
            } else {
                Section {
                    Label("No PC paired", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                }
            }

            // Stream audio - the stream's own level, not the Mac's.
            //
            // No slider: this dropdown is a real system NSMenu, which has no
            // slider item (the Sound extra's is a private view-backed one), so a
            // SwiftUI `Slider` here draws nothing at all. A ladder of 10% steps
            // plus Louder / Quieter is the shape that renders AND reads native.
            //
            // Shown whether or not a stream is live, because mute persists: a
            // control that disappears with the session is one the user can't
            // undo before starting the next one.
            Section("Stream Audio") {
                Button {
                    model.toggleStreamMute()
                } label: {
                    Label(model.streamMuted ? "Unmute" : "Mute",
                          systemImage: model.streamMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Menu {
                    Button {
                        model.stepStreamVolume(by: AppModel.streamVolumeStep)
                    } label: {
                        Label("Louder", systemImage: "speaker.plus")
                    }
                    .disabled(model.streamVolume >= 1)
                    Button {
                        model.stepStreamVolume(by: -AppModel.streamVolumeStep)
                    } label: {
                        Label("Quieter", systemImage: "speaker.minus")
                    }
                    .disabled(model.streamVolume <= AppModel.minStreamVolume)
                    Section {
                        ForEach(AppModel.streamVolumeLevels, id: \.self) { level in
                            Button {
                                model.setStreamVolume(level)
                            } label: {
                                // Checkmark by hand: an NSMenu item's state is
                                // not something SwiftUI exposes here, so the
                                // selected rung carries the glyph itself - the
                                // same trick the "Switch PC" list above uses.
                                if model.isSelectedStreamVolume(level) {
                                    Label("\(Int((level * 100).rounded()))%", systemImage: "checkmark")
                                } else {
                                    Text("\(Int((level * 100).rounded()))%")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Volume: \(model.streamVolumePercent)%",
                          systemImage: model.streamMuted ? "speaker.slash" : "speaker.wave.2")
                }
            }

            // Controller battery charm - shown whenever a pad reporting battery
            // is connected to the Mac (sampled on menu open). The glyph matches
            // the one in the menu-bar label so the two read as one thing.
            if let battery = model.menuBarControllerBattery {
                Section("Controller") {
                    Label {
                        Text("\(battery.percent)% battery\(battery.charging ? " · charging" : "")")
                    } icon: {
                        if battery.charging {
                            Image(systemName: "battery.100.bolt")
                        } else {
                            model.menuBarControllerGlyph.image(height: 11)
                        }
                    }
                }
            }

            Divider()

            Button {
                AppDelegate.openMainWindow?()
                NSApp.activate()
                model.settingsTab = .settings
                activate()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            // No "Check for Updates…" here, by request. Sparkle still checks on
            // its own (`checkForUpdatesInBackground` at launch), and the manual
            // command stays in the app menu under Shimmer - so the only case
            // this costs is checking by hand while running with no window open.

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Shimmer", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }

    /// The menu bar's launch row in one of its two forms. `activate()` only
    /// for the shown-window form: a pop-out launch hands activation back to
    /// the app the user was in once PiP is up, so bringing Shimmer forward
    /// here would only be undone.
    @ViewBuilder
    private func launchRow(popOut: Bool) -> some View {
        Button {
            model.streamDefaultApp(inPictureInPicture: popOut)
            if !popOut { activate() }
        } label: {
            Label {
                Text(popOut ? model.heroPictureInPictureLabel : model.heroActionLabel)
            } icon: {
                if popOut {
                    Image(systemName: "pip.enter")
                } else if let app = model.heroTargetApp {
                    AppGlyphIcon(app: app, size: 12)
                } else {
                    Image(systemName: "play.fill")
                }
            }
        }
    }

    private func activate() {
        // NSApp.activate() is the macOS 14+ replacement for
        // activate(ignoringOtherApps:) - the OS decides foreground policy
        // system-side now, so the "ignoringOtherApps: true" knob is gone.
        NSApp.activate()
    }
}

// MARK: - Shared per-host right-click menu

/// Right-click actions for a paired host (Rename / Codec / Unpair),
/// shared by the launcher hero and the Settings PCTile. Right-click is the
/// canonical affordance (no visible button). Carries its own confirmation
/// dialogs + rename alert; apply via `.hostContextMenu(host)` with the
/// AppModel in the environment.
private struct HostContextMenu: ViewModifier {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var showUnpairConfirm = false
    @State private var showRename = false
    @State private var draftName = ""
    @State private var codecPref: HostCodecPreference

    init(host: Host) {
        self.host = host
        _codecPref = State(initialValue: HostCodecPreference.load(for: host.id))
    }

    func body(content: Content) -> some View {
        content
            // Make the WHOLE frame (incl. padding) right-clickable; keep the
            // secondary click out of any interactive-glass press underneath.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    draftName = host.customName ?? ""
                    showRename = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                // Per-host codec cap. Automatic negotiates AV1 → HEVC → H.264
                // against what this host's encoder supports, so the override
                // exists only for the host whose preferred codec misbehaves -
                // hence a submenu here, not a Quality-pane item.
                Picker(selection: $codecPref) {
                    ForEach(HostCodecPreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                } label: {
                    Label("Codec", systemImage: "film.stack")
                }
                .pickerStyle(.menu)
                // Two surfaces mount this menu; reload at present-time so a
                // change on one is reflected in the other's checkmark.
                .onAppear { codecPref = HostCodecPreference.load(for: host.id) }
                .onChange(of: codecPref) { _, newValue in
                    HostCodecPreference.save(newValue, for: host.id)
                    // Spec chip/summary read the codec via UserDefaults; bump
                    // the observable sentinel so SwiftUI recomputes the Mbps.
                    model.displayInfoRevision &+= 1
                }
                Divider()
                Button(role: .destructive) {
                    showUnpairConfirm = true
                } label: {
                    Label("Unpair…", systemImage: "minus.circle")
                }
            }
            .alert("Rename \(host.displayName)", isPresented: $showRename) {
                TextField("Display name", text: $draftName)
                Button("Save") { model.renameHost(host, to: draftName) }
                // Not destructive - it just clears the custom name back to the
                // PC's own hostname, so no red styling.
                Button("Use default name") {
                    model.renameHost(host, to: "")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Shown in the launcher and PC list. Leave empty (or 'Use default name') to show the PC's own hostname.")
            }
            .confirmationDialog(
                "Unpair \(host.displayName)?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair(host) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Shimmer will forget this PC and leave a clean state. You can pair again at any time.")
            }
    }
}

extension View {
    /// Attach the shared per-host right-click menu (Rename / Codec / Unpair).
    func hostContextMenu(_ host: Host) -> some View {
        modifier(HostContextMenu(host: host))
    }
}
