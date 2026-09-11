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

extension StreamWindow {

    // MARK: - Entry

    /// Pop the stream out into the system Picture in Picture window. Hides the
    /// fullscreen window first if it is up (same teardown as a Cmd-Tab-away).
    /// No-op when PiP is already up / starting, or when AVKit can't start it.
    public func enterPictureInPicture() {
        guard !didClose, !isPictureInPictureActive, !pictureInPicturePending else { return }
        guard pictureInPicture.isPossible else {
            log.notice("Picture in Picture requested but not possible (another app may own it)")
            return
        }
        // Any resign-debounce teardown in flight is superseded by this
        // explicit hide (same token discipline as the becomeKey observer).
        resignGeneration &+= 1
        hideStreamWindow(forPictureInPicture: true)
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
                    self.exitPiPSourceMode()
                    self.window.orderOut(nil)
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
                self.exitPiPSourceMode()
                self.window.orderOut(nil)
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
        pictureInPicture.onDidStop = { [weak self] _ in
            guard let self, !self.didClose else { return }
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
                self.exitPiPSourceMode()
                self.window.orderOut(nil)
            }
            // × close engages the normal hidden-window suppression; return is a
            // no-op on an unchanged value.
            self.publishPresentSuppression()
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        reengageForeground()
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
        window.contentAspectRatio = .zero
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
                    self.setSourceContent(origin: panel.frame.origin, size: size, display: true)
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
    func exitPiPSourceMode() {
        guard pipSourceMode else { return }
        pipSourceMode = false
        onPictureInPicturePanelChanged?(nil)
        if let obs = pipPanelFrameObserver {
            NotificationCenter.default.removeObserver(obs)
            pipPanelFrameObserver = nil
        }
        window.ignoresMouseEvents = false
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
        window.alphaValue = 1
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
