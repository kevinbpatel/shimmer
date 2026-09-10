import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - Settings Root

enum SettingsPane: String, CaseIterable, Identifiable {
    // Organised the way moonlight-macos-enhanced lays Settings out - what the
    // stream asks for, how it's encoded, sound, input - then the PCs and the
    // app itself. Diagnostics keeps the always-visible troubleshooting surface
    // plus the option-click-revealed telemetry wires. Selection is session-only
    // @State; the raw values are free to change with the panes.
    case stream, video, audio, input, pcs, app, diagnostics, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stream: return "Stream"
        case .video: return "Video"
        case .audio: return "Audio"
        case .input: return "Input"
        case .pcs: return "PCs"
        case .app: return "App"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }
    var systemImage: String {
        switch self {
        case .stream: return "airplayvideo"
        case .video: return "video.fill"
        case .audio: return "speaker.wave.2.fill"
        case .input: return "keyboard.fill"
        case .pcs: return "display"
        case .app: return "gearshape.fill"
        case .diagnostics: return "stethoscope"
        // System Settings' About uses `info.circle.fill` - the bare "info"
        // symbol doesn't ship in SF Symbols 6 and falls back to a missing
        // glyph on macOS 26.
        case .about: return "info.circle.fill"
        }
    }
    // System Settings-style colored chip behind each sidebar SF Symbol.
    var chipColor: Color {
        switch self {
        case .stream: return .blue
        case .video: return .orange
        case .audio: return .teal
        case .input: return .indigo
        case .pcs: return .green
        case .app: return .gray
        case .diagnostics: return .pink
        case .about: return .gray
        }
    }
}

struct SettingsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SettingsPane = .stream

    /// Panes shown in the sidebar. All are always present now: Diagnostics holds
    /// the always-visible troubleshooting surface (controller input test + logs),
    /// and its debug/tuning sections stay hidden INSIDE the pane until the
    /// option-click gesture on the About version line flips `showDiagnostics`.
    private var visiblePanes: [SettingsPane] { SettingsPane.allCases }

    var body: some View {
        // NavigationSplitView's master column auto-adopts Liquid Glass
        // sidebar material on macOS 26 (same chrome System Settings uses).
        // We pair it with `.scrollContentBackground(.hidden)` on the List
        // so the sidebar's own opaque list background doesn't paint over
        // the translucent window material the Settings scene provides.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(visiblePanes, selection: $selection) { pane in
                HStack(spacing: 8) {
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            // Subtle top-edge highlight on the colored chip
                            // - matches Tahoe's System Settings chips for
                            // Bluetooth/Network/etc. The gradient lightens
                            // the top ~40% of the chip and falls off to the
                            // base color, giving the glossy "lit from above"
                            // feel without an additional stroke.
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(pane.chipColor)
                                .overlay(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.30),
                                            Color.white.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .blendMode(.plusLighter)
                                    .allowsHitTesting(false)
                                )
                        )
                    Text(pane.title)
                }
                .tag(pane)
            }
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .stream: StreamPane()
                case .video: VideoPane()
                case .audio: AudioPane()
                case .input: ShortcutsPane()
                case .pcs: PCsPane()
                case .app: AppPane()
                case .diagnostics: DiagnosticsPane()
                case .about: AboutPane()
                }
            }
            // The detail pane KEEPS its own opaque form background. Hiding it
            // (paired with a `.thinMaterial` window) let the desktop and, worse,
            // the launcher's purple hero card sitting behind Settings show
            // through the rows - the copy underneath a Section header ended up
            // grey-on-lavender with almost no contrast. Readability of the
            // settings beats translucency of the chrome.
            .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { adoptRequestedPane() }
        .onChange(of: model.requestedSettingsPane) { _, _ in adoptRequestedPane() }
    }

    /// Jump to a pane something else asked for (the debug automation's
    /// screenshot loop; a future deep link). One-shot: consumed on read.
    private func adoptRequestedPane() {
        guard let pane = model.requestedSettingsPane else { return }
        selection = pane
        model.requestedSettingsPane = nil
    }
}
