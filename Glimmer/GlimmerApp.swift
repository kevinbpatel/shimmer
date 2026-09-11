import AppKit
import ServiceManagement
import SwiftUI

/// Captures SwiftUI's `openWindow` action and parks it on AppDelegate so the
/// AppKit reopen handler can spawn the main window when SwiftUI's `Window`
/// scene has destroyed its instance after an X-close. Hosted on the
/// `MenuBarExtra` content (NOT the main window) so the captured closure's
/// SwiftUI environment outlives the launcher window - closing the launcher
/// leaves the menu bar item alive, so this view stays alive, so the closure
/// stays callable.
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.openMainWindow = { openWindow(id: "main") }
            }
    }
}

/// Sentinel arg passed by Glimmer Login Helper when it relaunches the main
/// app at login. Read once at App.init and used to gate `.defaultLaunchBehavior`
/// so the main window stays suppressed on login launches but auto-shows on
/// every user-initiated launch (Spotlight / Finder / Dock). No heuristics -
/// we control both sides of the launch.
private let launchedAtLogin = ProcessInfo.processInfo.arguments.contains("--launched-at-login")

@main
struct GlimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // FIRST: carry a glimmer install's pairings + preferences forward into
        // shimmer's bundle id / support directory (one-shot; see the file).
        // Precedes ContainerMigration so its copied sentinel is honoured.
        BundleIDMigration.runIfNeeded()
        // MUST precede AppModel(): its init reads ~20 UserDefaults keys,
        // which the unsandbox-flip orphaned in the old container until this runs.
        ContainerMigration.runIfNeeded()
        // Also MUST precede AppModel(), for the same reason: a registered
        // default only answers reads that come AFTER the registration, and
        // AppModel's init (and its property initializers) read these keys
        // immediately. This block used to live in
        // applicationWillFinishLaunching, which runs after this initializer -
        // so every key AppModel reads was already past its chance to see a
        // registered default.
        Self.registerDefaults()
        let mgr = AppModel()
        _model = State(wrappedValue: mgr)
        AppDelegate.boundManager = mgr
    }

    /// Defaults for prefs whose readers use bare `UserDefaults.bool(forKey:)`.
    /// REGISTERED, never written - a registration sits under the persistent
    /// domain, so a user's own choice still wins and toggling back to the
    /// default doesn't leave a stray key behind.
    ///
    /// Every value here must equal what the code effectively falls back to
    /// today (`bool(forKey:)` on an absent key is false), so adding a key
    /// changes nothing now. The point is that the default becomes a stated,
    /// changeable fact in ONE place: flipping one of these to `true` later
    /// reaches EXISTING users, where a hard-coded `false` fallback only ever
    /// reached fresh installs.
    @MainActor
    private static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Default-ON prefs. disableMouseAccelWhileStreaming linearizes the
            // system pointer acceleration while the stream window is focused so
            // forwarded mouse deltas are raw 1:1; the non-UI gate reads it via
            // UserDefaults.bool, which needs the registered default to read
            // `true` before first toggle.
            MouseAccelerationControl.enabledDefaultsKey: true,
            // Cruise: resolution-aware fast-flick traversal boost. DEFAULT OFF
            // as of 2026-07-19: at 4K, combat aim snaps and traversal flicks
            // occupy the same velocity AND distance range (field histograms:
            // aim snaps 1100-1800 counts/s, flicks p99 ~1770, distances
            // overlap), so any velocity-gated boost eventually boosts aim -
            // two "crazy sensitivity" incidents in one day. Raw everywhere
            // wins until a discriminator that can't misfire exists. The
            // machinery + hidden knobs stay for opt-in experimentation.
            CruiseTraversal.enabledDefaultsKey: false,
            // Fire the present tick on a private high-QoS run loop (not .main)
            // so a busy main thread can't starve the CADisplayLink callback.
            // Flip false for an instant fallback to the main-runloop tick.
            FramePacer.tickOffMainDefaultsKey: true,
            // Give that tick thread Mach time-constraint (real-time) scheduling
            // so the CPU can't preempt it under load. Flip false to fall back to
            // plain userInteractive (the pre-realtime behavior) without a rebuild.
            PacerTickThread.realtimeDefaultsKey: true,
            // AppModel's own bare-bool reads. All OFF today - the Mac keeps its
            // volume during a stream, raw HID stays behind its explicit opt-in
            // (it needs Input Monitoring), the auto-offer hasn't been answered,
            // and the Diagnostics pane and its telemetry stay hidden until a
            // power user reveals them from About.
            "rawHIDControllerEnabled": false,
            "rawHIDPromptAnswered": false,
            "showDiagnostics": false,
            "telemetryEnabled": false,
            // "Show the stream": full screen unless the user picks Window. The
            // registered value keeps the raw read and AppModel's declared
            // default in agreement (see StreamDisplayMode.defaultMode).
            StreamDisplayMode.defaultsKey: StreamDisplayMode.defaultMode.rawValue
        ])
    }

    var body: some Scene {
        // `Window` (single-instance) over `WindowGroup` - `openWindow(id:)`
        // brings the existing one to front instead of spawning a duplicate.
        Window("Shimmer", id: "main") {
            MainWindow()
                .environment(model)
                // 520pt card + 80pt margins per side = 680. This MUST equal the
                // connect surface's real width (ConnectSurface's .horizontal
                // padding): a floor BELOW it leaves the window that much range
                // to be dragged through, and it opens at the bottom of the range
                // with the margins squeezed flat - which is exactly what a stale
                // 584 here did. A floor equal to the content leaves nothing to
                // drag.
                // OPAQUE, not a material. A translucent window picks up the
                // desktop behind it - which is why this window's background
                // colour changed between two screenshots taken over different
                // wallpaper - and the app this is modelled on is flat.
                .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        }
        // The title bar is VISIBLE now: the library puts the selected PC's name
        // and address there (navigationTitle / navigationSubtitle) and hangs
        // add-PC, Settings and the search field off the toolbar, the way the
        // reference app does. Hiding it took all of that with it.
        // Resizable, with a floor. The window is a library now - a grid that
        // reflows and a sidebar - so bigger genuinely shows more, which is
        // exactly the opposite of the fixed hero card this replaced (it could
        // only ever have gained empty space, which is why it was pinned).
        // The content states an exact size per tab and the window takes it;
        // the reference app's window cannot be dragged bigger either.
        .windowResizability(.contentSize)
        // Opt OUT of window state restoration so a previously-X-closed
        // launcher always re-spawns fresh next launch (the bug that made
        // first Dock click do nothing pre-restoration-fix).
        .restorationBehavior(.disabled)
        // Suppress the auto-shown window when we were launched by the
        // login helper. User-initiated launches don't carry the sentinel
        // arg, so the Window scene spawns normally.
        .defaultLaunchBehavior(launchedAtLogin ? .suppressed : .automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            #if canImport(Sparkle)
            // Standard macOS "Check for Updates..." under the app menu (after the
            // About item). Sparkle drives the rest: a check on every open
            // (applicationDidFinishLaunching) plus a daily background check and
            // the update panels. Mirrored in the menu-bar dropdown for the
            // accessory (no-window) case - see MenuBarContent.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: UpdaterController.shared.updater)
            }
            // The `Settings` scene used to supply this item (and its ⌘,) for
            // free. Settings is a page in the main window now, so the command
            // is ours: bring the window forward, then show the page.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppDelegate.openMainWindow?()
                    NSApp.activate()
                    model.settingsTab = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            #endif
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .background(OpenWindowCapture())
        } label: {
            // Precedence, worst news first:
            //   error        -> the warning triangle alone (nothing else matters)
            //   pad connected-> the controller's own glyph + its battery percentage
            //   streaming    -> play.fill
            //   idle         -> the Eclipse mark (Assets.xcassets/MenuBarIcon)
            //
            // The pad outranks `play.fill` deliberately: a live stream is
            // already obvious from the screen in front of you, whereas the
            // percentage is the one number you want mid-session and the one
            // you'd have to open a menu to see. See `menuBarControllerGlyph`
            // for why a PlayStation pad gets a bundled DualSense mark and
            // everything else gets Apple's generic controller symbol.
            if model.nativeStreamError != nil, let symbol = model.menuBarSystemImageName {
                Image(systemName: symbol)
            } else if let battery = model.menuBarControllerBattery {
                // An HStack, NOT a `Label`: MenuBarExtra renders its label view
                // into the status item and a Label arrives icon-only there - the
                // title is silently dropped (measured, 2026-09-11: the same view
                // as a Label drew the glyph and no percentage). Spelling out the
                // Image + Text is what actually puts the number in the menu bar.
                // The pad AND its charge, as one baked image - the status item
                // button has a single image slot, so this cannot be composed
                // here. See MenuBarBatteryGlyph for what was probed. A bar reads
                // without being parsed and is the shape every other battery on
                // this Mac uses; the exact percentage stays in the dropdown.
                //
                // Only a PlayStation pad has this art. Anything else keeps the
                // generic controller symbol and the number.
                if model.menuBarControllerGlyph == .playStation {
                    Image(MenuBarBatteryGlyph.assetName(
                        forPercent: battery.percent, charging: battery.charging))
                } else {
                    HStack(spacing: 3) {
                        model.menuBarControllerGlyph.image()
                        Text("\(battery.percent)%")
                    }
                }
            } else if let symbol = model.menuBarSystemImageName {
                Image(systemName: symbol)
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hand-off slot set by `GlimmerApp.init` so AppDelegate can reach the
    /// manager before any SwiftUI view body runs.
    nonisolated(unsafe) static var boundManager: AppModel?

    /// Captured SwiftUI `openWindow(id: "main")` invocation. Set by
    /// `OpenWindowCapture` the first time MainWindow appears; used by
    /// applicationShouldHandleReopen when the X-closed Window scene needs
    /// to be respawned (NSApp.windows no longer contains it, but SwiftUI
    /// will rebuild from the WindowGroup on openWindow).
    nonisolated(unsafe) static var openMainWindow: (@MainActor () -> Void)?

    weak var model: AppModel?

    /// NSWindow open/close observers wired in applicationWillFinishLaunching
    /// to toggle `NSApp.activationPolicy` between `.regular` (Dock icon
    /// visible) when the main window is open and `.accessory` (no Dock
    /// icon) when only the menu bar is alive. Tracked so deinit can detach.
    private var windowVisibilityObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Version + build + commit on the FIRST log line, so any pasted log
        // (bug report, telemetry session) identifies the exact build with no
        // back-and-forth - the issue template asks; the log now answers.
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Diag.notice("app launching - Shimmer \(version) (\(build)) commit \(BuildInfo.commit) "
            + "built \(BuildInfo.date) (launchedAtLogin=\(launchedAtLogin))", "Launch")

        // Defaults registration deliberately does NOT happen here: it has to run
        // before AppModel reads its keys, which is GlimmerApp.init() - one
        // initializer earlier than this delegate callback. See
        // `GlimmerApp.registerDefaults()`.
        //
        // Crash recovery: if a prior session died mid-stream with the pointer
        // acceleration linearized, restore the user's saved value now (no-op in
        // the clean case). Runs before any window/stream can re-engage capture.
        MouseAccelerationControl.restoreOrphanedOverride()

        if let mgr = Self.boundManager {
            self.model = mgr
            mgr.attach(appDelegate: self)
            Task { await mgr.bootstrap() }
        }

        // Login-launched? Start as `.accessory` so the Dock icon never
        // appears alongside an invisible window. didBecomeKey on a
        // subsequent user-triggered window open flips us back to
        // `.regular` via the recheck observer.
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
            Diag.info("login launch → activation policy .accessory (menu-bar only)", "Launch")
        }

        let nc = NotificationCenter.default
        // Re-evaluate activation policy on any becomeKey / willClose. We
        // don't read `note.object` because Swift 6 strict concurrency
        // refuses to send the non-Sendable Notification across the
        // assumeIsolated boundary; instead we look up the main window's
        // current visibility from NSApp.windows on each tick.
        let recheck: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                // willClose fires while the window is still in NSApp.windows,
                // so defer one runloop tick to see the post-close state.
                DispatchQueue.main.async {
                    let mainOpen = NSApp.windows.contains {
                        $0.identifier?.rawValue == "main" && $0.isVisible
                    }
                    NSApp.setActivationPolicy(mainOpen ? .regular : .accessory)
                }
            }
        }
        windowVisibilityObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { _ in recheck() })
        windowVisibilityObservers.append(nc.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { _ in recheck() })
    }

    #if canImport(Sparkle)
    /// Check for updates on every user-initiated open, in addition to Sparkle's
    /// daily scheduled check - a cold start should surface a newer release right
    /// away instead of waiting up to a day. `checkForUpdatesInBackground` is
    /// silent unless an update is actually available. Skipped on login launches
    /// (the user didn't open it; the daily scheduled check covers that session).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launchedAtLogin else { return }
        UpdaterController.shared.updater.checkForUpdatesInBackground()
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the menu bar item alive when all windows close.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        // Cmd-Q / menu Quit mid-stream skips the session's stop()/exitCapturedMode(),
        // so the SYSTEM-WIDE pointer-acceleration override would survive process exit.
        // Restore it synchronously (idempotent; no-op when nothing is overridden).
        MouseAccelerationControl.restoreOrphanedOverride()
        // A live (or connecting) session must reach the host's /cancel before
        // the process exits. Returning .terminateNow after kicking off an async
        // stop let the process die first and left Sunshine holding a phantom
        // session that blocked the next /launch (issue #84). Defer the quit,
        // run the stop bounded (a hung host can't pin Cmd-Q past the bound),
        // then reply. No session object yet (the stream Task hasn't spun up)
        // means nothing has been asked of the host - quit now.
        guard let model, TerminationGate.reply(isStreaming: model.isStreaming) == .terminateLater,
              let session = model.nativeSession else {
            return .terminateNow
        }
        Task { @MainActor in
            let bound = TerminationGate.stopBoundSeconds
            let finished = await TerminationGate.runBounded(seconds: bound) { await session.stop() }
            Diag.notice(finished
                ? "Quit: stream stopped and the host session cancelled"
                : "Quit: host didn't acknowledge /cancel within \(Int(bound))s - exiting anyway", "Stream")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Dock-click handler. Fires on Dock-icon click, `open -a Glimmer`, and
    /// Launchpad reopen - NOT on every app activation (Cmd-Tab, in-app
    /// window clicks).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if model?.isStreaming == true {
            model?.resumeStreamWindow()
            return false
        }
        NSApp.activate()
        // 1. Hidden-but-alive window: orderFront it (covers the launchMinimized
        //    path where we orderOut'd a still-living window object).
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // 2. Destroyed window (X-close): respawn via the captured SwiftUI
        //    openWindow action. AppKit's default reopen doesn't reliably
        //    rebuild SwiftUI Window scenes.
        if let opener = Self.openMainWindow {
            opener()
            return false
        }
        return true
    }
}
