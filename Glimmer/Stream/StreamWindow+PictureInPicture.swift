//
//  StreamWindow+PictureInPicture.swift
//
//  Picture in Picture orchestration for the stream window: entering (hotkey /
//  menu bar / automatically on switch-away), the AVKit edge handlers, the
//  return path, and the present-suppression state the decoder is told about.
//
//  Model
//  -----
//  The system PiP window is fed by the SAME AVSampleBufferDisplayLayer the
//  fullscreen window paints into (AVKit takes over the layer's output; the
//  fullscreen window shows a placeholder while PiP is up). So the two are
//  mutually exclusive, and PiP is only ever entered from the HIDDEN state:
//
//      visible ──hide──▶ hidden ──start──▶ PiP ──stop(return)──▶ visible
//                          ▲                 │
//                          └──stop(×)────────┘
//
//  Present suppression - the decoder's "nobody is looking, stop presenting
//  and after 2s stop decoding" signal - used to be a synonym for "hidden".
//  With PiP it is a function of four bits (see `presentSuppressedState`):
//  hidden AND not in/entering PiP, OR paused from the PiP controls. Only
//  edges of that value reach the decoder.
//
//  While PiP is up:
//    * the frame pacer is rebound to a screen link (a view-bound link stops
//      firing off screen) - the owner does that from `onPictureInPictureChanged`;
//    * `GCController.shouldMonitorBackgroundEvents` is on so the gamepad keeps
//      reaching the host while another app is frontmost. Keyboard/mouse stay
//      with the frontmost app by construction (our window isn't key).
//

import AppKit
import GameController
import os.log

/// Debug-only file trace for the PiP hide / return paths, gated on the
/// `--debug-pip-probe` knob (never on for a normal launch). The unified log
/// can be unavailable on a test machine; this appends one line per decision
/// to /tmp/shimmer-pip-trace.log so a sequence can be reconstructed exactly.
enum PiPTrace {
    static let enabled: Bool = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--debug-pip-probe") }
        || ProcessInfo.processInfo.environment["GLIMMER_DEBUG_PIP_PROBE"] != nil
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    @MainActor static func log(_ what: String, _ w: NSWindow? = nil) {
        guard enabled else { return }
        var line = "\(fmt.string(from: Date())) \(what) active=\(NSApp.isActive)"
        if let w { line += " key=\(w.isKeyWindow) visible=\(w.isVisible) alpha=\(w.alphaValue) level=\(w.level.rawValue) frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(Int(w.frame.width))x\(Int(w.frame.height))" }
        line += "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/shimmer-pip-trace.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { FileManager.default.createFile(atPath: "/tmp/shimmer-pip-trace.log", contents: line.data(using: .utf8)) }
    }
}

extension StreamWindow {

    // MARK: - Entry

    /// Pop the stream out into the system Picture in Picture window. Hides the
    /// fullscreen window first if it is up (same teardown as a Cmd-Tab-away).
    /// No-op when PiP is already up / starting, or when AVKit can't start it.
    public func enterPictureInPicture() {
        PiPTrace.log("enterPictureInPicture backgrounded=\(isBackgrounded) active=\(isPictureInPictureActive) pending=\(pictureInPicturePending) possible=\(pictureInPicture.isPossible)", window)
        guard !didClose, !isPictureInPictureActive, !pictureInPicturePending else { return }
        guard pictureInPicture.isPossible else {
            log.notice("Picture in Picture requested but not possible (another app may own it)")
            return
        }
        // Any resign-debounce teardown in flight is superseded by this
        // explicit hide (same token discipline as the becomeKey observer).
        resignGeneration &+= 1
        if isBackgrounded {
            // Already hidden - a × close of an earlier PiP, or a switch-away
            // without auto-PiP - so the window is ordered OUT, and
            // hideStreamWindow would be a no-op: PiP would then start on an
            // off-screen fullscreen layer and mirror it 1:1 as the bottom-left
            // crop. Enter mirror-source mode directly (alpha 0, click-through,
            // pre-shrunk) and put the window back on screen without any of
            // the foreground re-engage - it stays invisible and non-key.
            // Order in FIRST, on the window's normal chrome and frame - the
            // same call the return path makes - and only then mutate it. An
            // order-in standardizes the frame against the window's aspect /
            // resize increments; doing that after source mode had touched them
            // trapped inside AppKit on macOS 26.6 (window mode). Alpha 0 goes
            // on before the order-in so nothing flashes.
            window.alphaValue = 0
            window.orderFront(nil)
            enterPiPSourceMode()
            log.info("Picture in Picture from the hidden window - source put back on screen at alpha 0")
        } else {
            hideStreamWindow(forPictureInPicture: true)
        }
        startPictureInPictureNow()
        publishPresentSuppression()
    }

    /// Ask AVKit to start. `pictureInPicturePending` keeps present suppression
    /// off for the ~100ms until didStart / failedToStart resolves it; a
    /// backstop clears it if AVKit never answers (never observed, but a stuck
    /// pending would leave a hidden window decoding forever).
    func startPictureInPictureNow() {
        guard !isPictureInPictureActive, !pictureInPicturePending else { return }
        guard pictureInPicture.isPossible else {
            log.notice("Picture in Picture not possible - staying hidden")
            return
        }
        pictureInPicturePending = true
        // Rebind the pacer to a screen link NOW, before AVKit brings the PiP
        // window up (~100-300ms). Binding it here keeps frames releasing across
        // the startup gap instead of stalling the pacer FIFO (which, with
        // suppression held off by `pictureInPicturePending`, would otherwise
        // pile up and could trip a resync IDR). A screen link ticks regardless
        // of the source window's size/visibility.
        onPictureInPictureChanged?(true)
        pictureInPicture.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pictureInPicturePending else { return }
                self.log.error("Picture in Picture start never resolved - clearing pending state")
                self.pictureInPicturePending = false
                // Fall back to a clean hidden state, same as the failure path.
                if self.pipSourceMode {
                    self.window.orderOut(nil)
                    self.exitPiPSourceMode(restoreAlpha: false)
                }
                self.onPictureInPictureChanged?(false)
                self.publishPresentSuppression()
            }
        }
    }

    // MARK: - AVKit edges

    func installPictureInPictureHandlers() {
        pictureInPicture.onDidStart = { [weak self] in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePending = false
            self.setPictureInPictureActive(true)
            // Came back to the window while PiP was still starting - the
            // window wins; collapse the PiP that just appeared. The pacer is
            // still screen-bound here (reengageForeground doesn't rebind it;
            // the view rebind lands in onDidStop below), which is harmless -
            // a screen link ticks whether the window is visible or not.
            //
            // NOT synchronously: we are inside AVKit's didStart callback, and
            // a stopPictureInPicture() issued from there is silently dropped -
            // and so is every later one (measured on macOS 26: three retries
            // over 1.5s, all ignored). The PiP window then outlives the
            // window's return, mirroring the restored fullscreen source as
            // the 1:1 bottom-left crop. One run-loop turn later it is honoured.
            if !self.isBackgrounded {
                self.log.info("Picture in Picture started after the window returned - stopping it")
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.didClose, !self.isBackgrounded else { return }
                    self.pictureInPicture.stop()
                }
                return
            }
            self.enableBackgroundControllerEvents()
            // Size the (alpha-0, on-screen) source window to the PiP window so
            // AVKit's 1:1 pixel mirror shows the WHOLE frame, not the bottom-
            // left crop. This is the fix for the documented macOS sample-buffer
            // PiP scaling bug (see matchSourceWindowToPiPPanel).
            self.matchSourceWindowToPiPPanel()
            self.publishPresentSuppression()
        }
        pictureInPicture.onFailedToStart = { [weak self] _ in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePending = false
            // PiP didn't come up. Fall back to the plain hidden-window state:
            // leave mirror-source mode (restore the fullscreen frame) and order
            // the window out. Put the pacer back on the view link.
            if self.pipSourceMode {
                self.window.orderOut(nil)
                self.exitPiPSourceMode(restoreAlpha: false)
            }
            self.onPictureInPictureChanged?(false)
            self.publishPresentSuppression()
        }
        pictureInPicture.onRestoreRequested = { [weak self] in
            // The user hit the PiP window's return button: bring the stream
            // window back. reengageForeground() also asks PiP to stop, which
            // is a no-op here because AVKit is already stopping it.
            self?.returnFromPictureInPicture()
        }
        pictureInPicture.onDidStop = { [weak self] restoreRequested in
            guard let self, !self.didClose else { return }
            PiPTrace.log("onDidStop restoreRequested=\(restoreRequested) backgrounded=\(self.isBackgrounded) inFlight=\(self.pipReturnInFlight)", self.window)
            self.setPictureInPictureActive(false)
            self.pictureInPicturePaused = false
            self.restoreBackgroundControllerEvents()
            self.onPictureInPictureChanged?(false)
            // × close (not the return button): the window is still the alpha-0
            // shrunk mirror source and stays hidden. Restore its fullscreen
            // frame and order it out cleanly so "Back to stream" resumes it
            // full size. (On the return path reengageForeground already left
            // source mode and isBackgrounded is false, so this is skipped.)
            if self.isBackgrounded {
                // ORDER OUT FIRST, while the source is still alpha 0, then restore
                // its frame / chrome / alpha off screen. The other order let a
                // composited frame of the full-size window - AVKit's placeholder
                // ("This video is playing in picture in picture") - flash for an
                // instant between alpha 1 and the order-out, especially now that
                // source mode also swaps the window's level and collection
                // behaviour (each a window-server round trip).
                self.window.orderOut(nil)
                self.exitPiPSourceMode(restoreAlpha: false)
            }
            // × close engages the normal hidden-window suppression; return is a
            // no-op on an unchanged value.
            self.publishPresentSuppression()
            // Return: presentation is owned by awaitActivationThenPresent (window
            // mode) / the immediate path (fullscreen); nothing to do here.
        }
        pictureInPicture.onPauseChanged = { [weak self] paused in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePaused = paused
            self.publishPresentSuppression()
        }
    }

    /// Bring the fullscreen window back from PiP - identical to the launcher's
    /// "Back to stream" (`StreamSession.resumeWindow()`): activate, order
    /// front, then the shared foreground re-engage (which stops PiP).
    func returnFromPictureInPicture() {
        guard !didClose else { return }
        PiPTrace.log("returnFromPictureInPicture backgrounded=\(isBackgrounded) sourceMode=\(pipSourceMode)", window)
        pipReturnInFlight = true
        // Backstop: a stop that never reports must not pin the flag forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            MainActor.assumeIsolated { self?.pipReturnInFlight = false }
        }
        if displayMode == .window {
            // Sequencing, measured on macOS 27 with real HID clicks on the
            // panel's return control: the `NSApp.activate()` issued while
            // AVKit's PiP panel is still alive / closing is dropped - the app
            // is still inactive seconds later, its window on screen but not
            // key, and Stage Manager files an inactive app's window into the
            // strip on the next interaction. Activation only sticks when
            // re-requested after the panel is gone (~0.9 s after the click).
            // Therefore: restore the frame + alpha now (AVKit's fly-back needs
            // a visible target) but KEEP the floating / transient panel shape,
            // which Stage Manager never stages; keep asking for activation
            // until it is real; only then restore the normal shape and make
            // the window key + front, so it lands on the now-active app's
            // own stage.
            exitPiPSourceMode(restoreShape: false)
            // The return has begun: the window is on screen at alpha 1 and is
            // no longer "parked". Say so NOW - onDidStop treats a still-
            // backgrounded window as the × close and orders it out (measured:
            // that emptied the stage and starved activation for 3 s). The rest
            // of the foreground re-engage (cursor, level, presentation) runs in
            // presentReturnedWindow once the app is genuinely active.
            isBackgrounded = false
            publishPresentSuppression()
            onBackgroundedChanged?(false)
            NSApp.activate()
            awaitActivationThenPresent(attempt: 0)
            return
        }
        // Fullscreen cover: level above the menu bar, stationary - Stage
        // Manager doesn't manage it, the immediate path has always worked.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        reengageForeground()
    }

    /// Poll for genuine activation (up to ~3 s, re-requesting every 400 ms -
    /// early requests are refused while the panel winds down), then present.
    /// On timeout present anyway: an on-screen window the user can click
    /// beats one that never comes back.
    func awaitActivationThenPresent(attempt: Int) {
        guard !didClose else { return }
        if NSApp.isActive || attempt >= 30 {
            PiPTrace.log("awaitActivation done attempt=\(attempt)", window)
            presentReturnedWindow()
            return
        }
        if attempt % 4 == 0 { NSApp.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.awaitActivationThenPresent(attempt: attempt + 1) }
        }
    }

    /// Put the window's level + collection behaviour back to what they were
    /// before source mode reshaped it as a floating, unmanaged panel. No-op
    /// when already restored.
    func restorePiPSourceShape() {
        guard let shape = savedShapeBeforePiP else { return }
        window.collectionBehavior = shape.behavior
        window.level = shape.level
        savedShapeBeforePiP = nil
    }

    /// The second half of a window-mode return: back to the normal window
    /// shape, key + front, foreground re-engaged. Idempotent.
    /// The second half of a window-mode return: back to the normal window
    /// shape, key + front, foreground re-engaged. Idempotent. Runs only once
    /// the app is genuinely active (or the wait timed out), so the primary
    /// window lands on the now-active app's own Stage Manager stage instead
    /// of being filed into the strip.
    func presentReturnedWindow() {
        guard !didClose else { return }
        restorePiPSourceShape()
        resignGeneration &+= 1
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reengageForeground()
        PiPTrace.log("presentReturnedWindow: presented", window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.pipReturnInFlight = false }
        }
    }

    /// The renderer hard-fail self-heal rebuilt the display layer while PiP was
    /// up (or starting). `retarget` already collapsed the old PiP window and
    /// deliberately did not relaunch (its slot is still held by the dismissing
    /// window). Clear our PiP state, put the pacer back on the view link, and
    /// bring the recovering stream back to the foreground so the user is never
    /// stranded on a hidden window with no PiP.
    func handleLayerRebuildDuringPiP() {
        log.notice("Display layer rebuilt during Picture in Picture - exiting PiP and returning to the stream window")
        pictureInPicturePending = false
        setPictureInPictureActive(false)
        pictureInPicturePaused = false
        restoreBackgroundControllerEvents()
        onPictureInPictureChanged?(false)
        returnFromPictureInPicture()
    }

    /// PiP teardown for `close()`: drop the controller silently and put the
    /// controller-background flag back.
    func tearDownPictureInPicture() {
        pictureInPicturePending = false
        pictureInPicture.invalidate()
        setPictureInPictureActive(false)
        restoreBackgroundControllerEvents()
        exitPiPSourceMode()
    }

    // MARK: - PiP mirror-source window (the macOS 1:1-crop workaround)
    //
    // macOS's sample-buffer Picture in Picture (unlike iOS, and unlike
    // AVPlayerLayer PiP) mirrors the source AVSampleBufferDisplayLayer into the
    // PiP window at 1:1 PIXELS with no scaling transform - so a fullscreen
    // source layer shows only its bottom-left corner in the PiP window
    // (Apple bug, FB22411168; reproduced and confirmed on macOS 26). The
    // working fix: keep the source window ON SCREEN (PiP can't mirror an
    // ordered-out window) but invisible (alpha 0, click-through), and size it
    // to the PiP window's content so 1:1 == the whole frame. Track PiP resizes
    // to stay matched.
    //
    // "Matched" is on the stream's aspect line, not the panel's integer size:
    // the panel is whole pixels and almost never exactly 16:9, and a source
    // layer sized to it would leave `.resizeAspect` a sub-pixel pillarbox that
    // the 1:1 mirror paints as a white hairline down one edge (see
    // `StreamWindowGeometry.pipSourceSize`). So the display VIEW takes the
    // exact-aspect (fractional) size and the window rounds up around it.

    /// Enter mirror-source mode: hide the fullscreen content (alpha 0) but keep
    /// the window on screen and pass-through. Called from the PiP hide path
    /// BEFORE PiP starts; the exact size is applied on didStart once the PiP
    /// window exists.
    func enterPiPSourceMode() {
        guard !pipSourceMode else { return }
        pipSourceMode = true
        // Make the invisible source look like a floating tool panel to the
        // window manager, not an app window. Stage Manager tiles every
        // on-screen window it MANAGES - and it does so whether the app is
        // .regular or .accessory (measured: the ghost tile survived the
        // accessory flip). What it leaves alone are floating-level,
        // stationary / transient windows (palettes, panels) - the shape the
        // borderless fullscreen cover already has (.canJoinAllSpaces +
        // .stationary at a high level). Window mode's titled window is a
        // plain managed window, so reshape it for the duration of source
        // mode and restore on exit.
        savedShapeBeforePiP = (window.level, window.collectionBehavior)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .ignoresCycle]
        window.level = .floating
        savedFrameBeforePiP = window.frame
        // Window mode (upstream's titled stream window) locks the content
        // aspect, enforces a minimum size, and autosaves the frame - all three
        // fight the mirror-source sizing below (the aspect lock would shrink
        // the content inside the title-bar-reduced height and letterbox the
        // PiP picture; autosave would persist the 480×270 source as the
        // user's window). Suspend them for the duration; the borderless
        // fullscreen cover has none of these set, so this is a no-op there.
        savedChromeBeforePiP = (window.contentAspectRatio, window.contentMinSize,
                                window.frameAutosaveName)
        // Aspect ratio and resize increments share one slot in NSWindow: an
        // aspect lock stores increments of (0,0), and `contentAspectRatio =
        // .zero` LEAVES them at zero - an aspect-less window that AppKit's
        // order-in frame standardization then divides by (a trap on macOS
        // 26.6). Increments of (1,1) is the documented way to clear the lock.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.contentMinSize = .zero
        if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // Pre-shrink to a typical PiP size so the first ~200ms (before
        // matchSourceWindowToPiPPanel runs on didStart) don't mirror the
        // fullscreen source 1:1 - which would flash the bottom-left crop. The
        // exact size is applied the moment the PiP window exists. AVKit takes
        // the PiP window's aspect from the layer it starts on, so this goes
        // through the same aspect conformance as every later size.
        setSourceContent(origin: window.frame.origin, size: NSSize(width: 480, height: 270), display: false)
    }

    /// Place the mirror source so the display layer covers a `size` panel at
    /// `origin`. The layer (via `displayView`) takes the smallest rect on the
    /// stream's exact aspect that covers `size` - fractional on one axis - and
    /// the window's content is that rounded up to whole points so the view
    /// stays inside it. For the borderless fullscreen cover the content rect
    /// is the frame; for a titled window (window mode) the frame is taller by
    /// the title bar, and sizing the frame instead would leave the content -
    /// and so the 1:1 mirror - short by that much.
    func setSourceContent(origin: NSPoint, size: NSSize, display: Bool) {
        let exact = StreamWindowGeometry.pipSourceSize(covering: size, aspect: streamPixelSize)
        let content = NSSize(width: ceil(exact.width), height: ceil(exact.height))
        window.setFrame(window.frameRect(forContentRect: NSRect(origin: origin, size: content)),
                        display: display)
        // After the window's autoresizing pass, so it is the final word.
        displayView.frame = NSRect(origin: .zero, size: exact)
    }

    /// Size the alpha-0 source window to the system PiP window's content, and
    /// keep it matched as the user resizes PiP. Falls back to a sensible small
    /// size if the private PiP panel can't be located (a future macOS could
    /// rename it) - the fallback shows the whole frame at a fixed size rather
    /// than reverting to the bottom-left crop.
    func matchSourceWindowToPiPPanel() {
        guard pipSourceMode, !didClose else { return }
        // A short delay lets AVKit finish creating the PiP panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pipSourceMode, !self.didClose else { return }
                guard let panel = NSApp.windows.first(where: {
                    String(describing: type(of: $0)).contains("PIPPanel")
                }), let content = panel.contentView else {
                    self.log.error("PiP: could not locate the PIPPanel window - using a fallback source size (frame will still be whole, size approximate)")
                    self.setSourceContent(origin: self.window.frame.origin,
                                          size: NSSize(width: 640, height: 360), display: true)
                    return
                }
                let apply: @MainActor () -> Void = { [weak self] in
                    guard let self, self.pipSourceMode, !self.didClose else { return }
                    let size = content.bounds.size
                    guard size.width > 1, size.height > 1 else { return }
                    // Pin the (invisible) source window to its ORIGINAL origin,
                    // not the PiP panel's. The 1:1 mirror depends only on the
                    // source layer's SIZE covering the panel's content; where the
                    // source window sits on screen is irrelevant to what AVKit
                    // captures. Parking it at the panel's origin used to physically
                    // move the window across the screen, so on return it travelled
                    // back to its saved frame - the "drifts to the panel's spot,
                    // then snaps to the left" glitch under Stage Manager. Keeping
                    // the origin fixed means only the size ever changes.
                    self.setSourceContent(origin: self.savedFrameBeforePiP?.origin ?? self.window.frame.origin,
                                          size: size, display: true)
                    // Part B of the workaround: AVKit draws an empty black
                    // overlay (AVPictureInPictureCALayerHostView) on top of the
                    // correctly-scaled content layer - the big black box. Hide
                    // it (never its parent CALayerHost, which carries the real
                    // content). Re-applied on every resize because AVKit can
                    // re-show it.
                    self.hidePiPBlackOverlay(in: content)
                }
                apply()
                self.onPictureInPicturePanelChanged?(panel)
                content.postsFrameChangedNotifications = true
                self.pipPanelFrameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: content, queue: .main
                ) { _ in MainActor.assumeIsolated(apply) }
                self.log.info("PiP: source window matched to PiP panel content \(Int(content.bounds.width))x\(Int(content.bounds.height))")
            }
        }
    }

    /// Walk the PiP panel's view tree and hide AVKit's empty black overlay
    /// (`AVPictureInPictureCALayerHostView`) - the fixed black box drawn on top
    /// of the correctly-scaled content. NEVER hide its parent `CALayerHost`,
    /// which carries the real mirrored content. Safe/no-op if the class isn't
    /// present (future macOS rename): the black box simply remains.
    func hidePiPBlackOverlay(in root: NSView) {
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "AVPictureInPictureCALayerHostView" {
                if !v.isHidden { v.isHidden = true }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
    }

    /// Leave mirror-source mode: stop tracking, restore the fullscreen frame,
    /// alpha, and event handling. Idempotent. Does NOT decide visibility - the
    /// caller orders the window front (return) or out (× close). The frame is
    /// restored with display:false so a hide path never flashes the fullscreen
    /// content before ordering out.
    /// `restoreAlpha: false` is for the HIDE paths (× close, start failed, start
    /// timeout): they order the window out first, and AppKit batches window-
    /// server updates per run-loop turn - an `alphaValue = 1` issued in the
    /// same turn as the order-out can be composited before the order-out
    /// lands, flashing the empty full-size window for a frame (measured on
    /// the mini: one blank white frame at the × moment). A window at alpha 0
    /// cannot paint whatever else changes, so those callers keep alpha 0 here
    /// and restore it on the NEXT turn, once the order-out is committed.
    func exitPiPSourceMode(restoreAlpha: Bool = true, restoreShape: Bool = true) {
        PiPTrace.log("exitPiPSourceMode restoreAlpha=\(restoreAlpha) restoreShape=\(restoreShape) sourceMode=\(pipSourceMode)", window)
        guard pipSourceMode else { return }
        pipSourceMode = false
        onPictureInPicturePanelChanged?(nil)
        if let obs = pipPanelFrameObserver {
            NotificationCenter.default.removeObserver(obs)
            pipPanelFrameObserver = nil
        }
        window.ignoresMouseEvents = false
        if restoreShape { restorePiPSourceShape() }
        if let chrome = savedChromeBeforePiP {
            window.contentAspectRatio = chrome.aspect
            window.contentMinSize = chrome.minSize
            // Re-claiming the autosave name restores the LAST SAVED frame as a
            // side effect - the pre-PiP one, since saving was off meanwhile -
            // and the explicit restore below wins regardless.
            if !chrome.autosaveName.isEmpty { window.setFrameAutosaveName(chrome.autosaveName) }
            savedChromeBeforePiP = nil
        }
        if let saved = savedFrameBeforePiP {
            window.setFrame(saved, display: false)
            savedFrameBeforePiP = nil
        }
        // Autoresizing carries the source mode's fractional margin through the
        // frame restore (a 0.4pt-short layer at the top of the screen); pin the
        // view back to its superview.
        if let superview = displayView.superview { displayView.frame = superview.bounds }
        if restoreAlpha {
            window.alphaValue = 1
        } else {
            DispatchQueue.main.async { [weak self] in self?.window.alphaValue = 1 }
        }
    }

    // MARK: - Debug probe

    /// Everything the PiP state machine depends on, one line, for the
    /// env-gated `--debug-pip-probe` timer in DebugAutomation.
    public func debugPiPState() -> String {
        let panelVisible = NSApp.windows.contains {
            String(describing: type(of: $0)).contains("PIPPanel") && $0.isVisible
        }
        return "\(pictureInPicture.debugState) win.active=\(isPictureInPictureActive) pending=\(pictureInPicturePending) "
            + "sourceMode=\(pipSourceMode) backgrounded=\(isBackgrounded) alpha=\(window.alphaValue) "
            + "frame=\(Int(window.frame.width))x\(Int(window.frame.height)) visible=\(window.isVisible) key=\(window.isKeyWindow) "
            + "appActive=\(NSApp.isActive) panelVisible=\(panelVisible)"
    }

    // MARK: - Present suppression

    /// The decoder's suppression state as a pure function of the window's
    /// PiP bits, so the truth table is unit-testable without AppKit:
    ///  * hidden and nothing is (about to be) showing the layer → suppressed;
    ///  * PiP up or starting → NOT suppressed (someone is watching);
    ///  * paused from the PiP controls → suppressed (freeze + decode gate),
    ///    regardless of the rest.
    nonisolated static func presentSuppressedState(
        backgrounded: Bool, pipActive: Bool, pipPending: Bool, pipPaused: Bool
    ) -> Bool {
        if pipPaused { return true }
        return backgrounded && !pipActive && !pipPending
    }

    /// Recompute and forward the suppression state, edge-triggered.
    func publishPresentSuppression() {
        let suppressed = Self.presentSuppressedState(
            backgrounded: isBackgrounded,
            pipActive: isPictureInPictureActive,
            pipPending: pictureInPicturePending,
            pipPaused: pictureInPicturePaused)
        guard suppressed != lastEmittedPresentSuppressed else { return }
        lastEmittedPresentSuppressed = suppressed
        onPresentSuppressionChanged?(suppressed)
    }

    // MARK: - Controller in the background

    /// GameController only delivers pad input to the frontmost app unless told
    /// otherwise. While PiP is up Glimmer is by definition NOT frontmost, and
    /// "keep playing with the pad from the corner" is the whole point.
    private func enableBackgroundControllerEvents() {
        guard savedControllerBackgroundFlag == nil else { return }
        savedControllerBackgroundFlag = GCController.shouldMonitorBackgroundEvents
        GCController.shouldMonitorBackgroundEvents = true
        log.info("Controller background events enabled for Picture in Picture")
    }

    private func restoreBackgroundControllerEvents() {
        guard let saved = savedControllerBackgroundFlag else { return }
        GCController.shouldMonitorBackgroundEvents = saved
        savedControllerBackgroundFlag = nil
    }
}
