import SwiftUI
import AppKit

// MARK: - Main Window

/// Hands the title bar to the content. macOS 26 pins a SwiftUI `Window`'s
/// title to the LEADING edge (removing the toolbar does not change it), while
/// the app this is modelled on centres it. So the system title is hidden, the
/// bar is made transparent and the content is extended under it; `AppShell`
/// draws the centred title itself. Zero sized and non-interactive - it exists
/// only to reach the NSWindow.
private struct WindowChromeTweak: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            Self.apply(to: view.window)
            Self.applyLate(to: view.window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }
    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Not resizable, and no zoom or minimise - the reference app's window
        // shows those two buttons greyed out.
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.miniaturizable)
        window.isMovableByWindowBackground = true
    }

    /// SwiftUI finishes configuring the window AFTER the first layout pass and
    /// puts `.fullSizeContentView` back, which left a 32pt reserved title bar
    /// and pushed the centred title below the traffic lights. Re-assert once
    /// the run loop has settled.
    static func applyLate(to window: NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { apply(to: window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { apply(to: window) }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showAWDLPrompt = false
    @State private var awdlPromptChecked = false

    var body: some View {
        @Bindable var model = model
        return Group {
            AppShell()
                .background(WindowChromeTweak().frame(width: 0, height: 0))
        }
        // One-time proactive offer when a DualSense is connected (see
        // maybeOfferRawHID) - explains the feature before macOS's Input
        // Monitoring prompt; declining never re-asks.
        .alert("Enable enhanced DualSense buttons?", isPresented: $model.showRawHIDPrompt) {
            Button("Enable") { model.enableRawHIDFromPrompt() }
            // "Not Now" just dismisses - no permanent flag - so a future
            // DualSense connect offers again. Only "Don't Ask Again" answers
            // for good (matches AWDLEnablePrompt's Not Now / Don't ask again
            // split). declineRawHIDPrompt() already sets the permanent flag.
            Button("Not Now", role: .cancel) { model.showRawHIDPrompt = false }
            Button("Don't Ask Again") { model.declineRawHIDPrompt() }
        } message: {
            Text(AppModel.rawHIDExplanation)
        }
        // One-time launch nudge to enable Wi-Fi stutter protection. Only for
        // users who've paired a PC (skips first-run onboarding), never while the
        // rawHID prompt is up; "Don't ask again" inside silences it for good.
        .sheet(isPresented: $showAWDLPrompt) {
            AWDLEnablePrompt(manager: AWDLHelperManager.shared)
        }
        .task {
            guard !awdlPromptChecked else { return }
            awdlPromptChecked = true
            // Let hosts load + the window settle before deciding - checking
            // hosts.isEmpty immediately on appear raced the async host load,
            // so the prompt never fired.
            try? await Task.sleep(for: .seconds(1.0))
            AWDLHelperManager.shared.refresh()
            // Parking awdl0 only smooths Wi-Fi; on a confirmed wired route it's
            // a privileged-helper install for nothing. Suppress ONLY on .wired -
            // Wi-Fi / tunnel / still-resolving unknown still prompt.
            guard !model.hosts.isEmpty,
                  !model.showRawHIDPrompt,
                  model.hostRoute.routeClass != .wired,
                  AWDLHelperManager.shared.shouldPromptToEnable else { return }
            showAWDLPrompt = true
        }
        // No .frame: forcing either axis to .infinity gives the window an
        // unbounded box to fill, and the only thing available to fill it with is
        // nothing. The content states its own size; the window follows it.
        .overlay(alignment: .top) {
            // Disconnect-beat toast - a brief, calm acknowledgement after a
            // stream ends instead of the launcher just snapping back.
            StreamEndedToast()
                .padding(.top, 16)
        }
        // Takeover confirmation: launching over a host that's already streaming
        // someone else's session boots them out, so confirm before we /launch.
        .confirmationDialog(
            "Take over the stream?",
            isPresented: Binding(
                get: { model.pendingTakeover != nil },
                set: { if !$0 { model.pendingTakeover = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingTakeover
        ) { _ in
            Button("Take over", role: .destructive) { model.confirmPendingTakeover() }
            Button("Cancel", role: .cancel) { model.pendingTakeover = nil }
        } message: { pending in
            Text("\(pending.host.displayName) is already streaming \(pending.occupantApp). Starting your stream will end that session.")
        }
        .background {
            // ⌘1-⌘9 host switching (multi-PC households only) - invisible,
            // window-scoped. See HostSwitchShortcuts for why hidden buttons
            // beat toolbar-menu shortcuts or app-level .commands here.
            HostSwitchShortcuts()
        }
        // Unpairing the LAST PC swaps ConnectSurface out for the empty state,
        // which merely CANCELS its route-monitor task - cancellation never
        // runs monitor(nil), leaving the parked UDP socket watching the
        // forgotten host's route until quit. Key on emptiness; release it
        // (selectedHost is nil here → monitor(address: nil), the teardown).
        .task(id: model.hosts.isEmpty) {
            if model.hosts.isEmpty { model.refreshHostRoute() }
        }
    }
}

/// Invisible ⌘1-⌘9 host-switch shortcuts, mounted behind the launcher when
/// more than one PC is paired. Zero-size transparent buttons are the reliable
/// window-scoped registration here: toolbar-Menu items only exist while the
/// menu is open (shortcuts never register), and app-level `.commands` would
/// also fire from Settings. Capped at nine - ⌘0 reads as "reset".
private struct HostSwitchShortcuts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hosts.count > 1 {
            ForEach(Array(model.hosts.prefix(9).enumerated()), id: \.element.id) { index, host in
                Button("") { model.selectHost(host) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Three-stop accent gradient shared by the hero card (ContentView) and the
/// Stream button (ContentViewSubviews) - internal, not file-private - so the
/// two surfaces read as a matched pair. Top-left lifts toward white,
/// bottom-right deepens toward black; opacities stay low so the Liquid Glass
/// material dominates and the accent reads as a tint rather than a fill.
@MainActor
var accentSurfaceGradient: LinearGradient {
    LinearGradient(
        stops: [
            // Saturation matched to the Eclipse app icon (the old
            // 0.16-0.30 opacities read dull next to it).
            .init(color: Color.accentColor.mix(with: .white, by: 0.12).opacity(0.55), location: 0),
            .init(color: Color.accentColor.opacity(0.38), location: 0.55),
            .init(color: Color.accentColor.mix(with: .black, by: 0.25).opacity(0.45), location: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// NOTE: the readiness chip's composite-status model now lives with
// `ReadinessChip` in ContentView+ReadinessChip.swift, the menu-bar dropdown and
// the shared per-host right-click menu in ContentView+Menus.swift, and the
// morphing hero button in ContentView+StreamButton.swift (pointers kept on
// purpose).
