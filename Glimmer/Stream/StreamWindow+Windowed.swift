//
//  StreamWindow+Windowed.swift
//
//  Window mode: the stream as a real titled window (the Custom preset's "Show
//  the stream in a window" toggle), plus the mid-session conversion a Path-B
//  Space exit performs to land here instead of leaving a vanished window
//  (issue #84).
//
//  What is deliberately NOT here: the presentation-options dance, the
//  `mainMenuWindow + 1` level, the resign-key orderOut, the level re-raise on
//  becomeKey. Those are the fullscreen cover's business and stay byte-for-byte
//  in StreamWindow+Show / +Cursor / +Fade behind `displayMode == .fullScreen`
//  gates. A window gets: the shared display observers (pacer rebind), a
//  miniaturize = backgrounded signal, and a cursor that follows pointer
//  capture instead of key status.
//
//  The pointer in a window is GRABBED while it is over the picture - hidden
//  cursor, relative aim - the way a VM window or a game behaves, and given
//  back by a held Esc, the pointer chord, or switching apps. Off the picture
//  it is a normal Mac pointer, mirrored onto the host as absolute positions.
//  InputForwarder owns the engagement and the grab rule (as in full screen it
//  owns capture); it reports each edge through `setPointerCaptured(_:)` and
//  this file keeps VISIBILITY in the single `setCursorHidden` owner - the
//  one-owner rule the cursor latch depends on. The hint that teaches the way
//  out lives in StreamWindow+PointerAffordances.swift.
//

import AppKit

extension StreamWindow {

    /// The frame autosave name. One name for the one stream window: position
    /// and size persist across sessions and launches, and the pixel-mapped
    /// opening size only applies until the user has moved or resized it once.
    static let frameAutosaveName = "GlimmerStreamWindow"

    /// The window-mode bring-up. Mirrors Path A's shape (activate, order
    /// front, install input next runloop, 1.5s key backstop) without the
    /// cover, the cursor hide, or the presentation options.
    func showWindowed() {
        // The Space the green button can enter keeps AppKit's safe-area
        // framing; "Fill the notch" is a full-screen-only choice.
        streamDelegate.coversNotch = false
        streamDelegate.displayMode = .window
        AppDelegate.refreshActivationPolicy()   // a stage of our own, not behind the focused one
        NSApp.activate()
        configureWindowedChrome()
        // Same first-frame fade-in as full screen: an empty display layer
        // renders black, so the window stays invisible until video exists.
        window.alphaValue = 0.0
        awaitingFirstFrameFadeIn = true
        window.makeKeyAndOrderFront(nil)
        installWindowedLifecycleObservers()
        let size = window.contentRect(forFrameRect: window.frame).size
        log.info(
            "Stream window windowed - content \(size.width, privacy: .public)×\(size.height, privacy: .public) pt")
        // No Space animation; install input next runloop (didClose guard like
        // every sibling: a connect that fails first must not re-capture).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose else { return }
            self.onDidBecomeReadyForInput?()
        }
        // Key backstop - same reasoning as Path A's: a window can be on screen
        // and still not key if the app wasn't active at makeKeyAndOrderFront.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.didClose, !self.window.isKeyWindow else { return }
            self.log.error("Window not key 1.5s after show(); retrying activate + makeKeyAndOrderFront + first-responder install")
            NSApp.activate()
            self.window.orderFrontRegardless()   // on top even when activation is refused
            self.window.makeKeyAndOrderFront(nil)
            self.onDidBecomeReadyForInput?()
        }
    }

    /// Title, aspect lock, minimum size, and the opening frame.
    ///
    /// The window ALWAYS opens at the stream's resolution 1:1 - content points
    /// = pixels / backingScale, so a 1080p stream lands on exactly 1920x1080
    /// physical pixels (960x540 pt on a 2x panel), 1440p on 2560x1440, 4K on
    /// 3840x2160: each stream pixel on one screen pixel, no scaling blur,
    /// whatever resolution the stream is set to. The frame-autosave is kept for
    /// POSITION only - the window reopens where the user last put it, but at the
    /// resolution's size, not whatever size they last dragged to (which is what
    /// broke the pixel density before). A 4K request on a smaller panel is
    /// scaled DOWN to fit, preserving aspect.
    private func configureWindowedChrome() {
        window.title = windowTitle
        let aspect = streamPixelSize.width > 0 && streamPixelSize.height > 0
            ? streamPixelSize : CGSize(width: 16, height: 9)
        window.contentAspectRatio = aspect
        window.contentMinSize = StreamWindowGeometry.minimumContentSize(aspect: aspect)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let available = availableContentArea(on: screen)
        let mapped = StreamWindowGeometry.fitted(
            StreamWindowGeometry.pixelMappedContentSize(
                pixelWidth: Int(streamPixelSize.width), pixelHeight: Int(streamPixelSize.height),
                backingScaleFactor: screen?.backingScaleFactor ?? 1),
            within: available)
        window.setContentSize(mapped)
        if let screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        // `setFrameAutosaveName` restores a previously saved frame as a side
        // effect (and returns false if another live window holds the name -
        // close() releases it, so that only happens if a prior window leaked;
        // the window still works, it just doesn't persist its frame).
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            log.error("Stream window frame autosave name already in use - this session's frame won't persist")
        }
        // Position from the restore, size from the resolution: force the
        // content back to the pixel-mapped size, anchored at the restored
        // top-left so the window stays where the user put it. This is what
        // makes every open 1:1 with the stream regardless of the last size the
        // user dragged to. Guarded on a real mapped size (streamPixelSize is
        // set before show(), but a zero would collapse the window).
        if mapped.width > 0, mapped.height > 0 {
            let restored = window.frame
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: mapped)).size
            window.setFrame(NSRect(x: restored.minX, y: restored.maxY - frameSize.height,
                                   width: frameSize.width, height: frameSize.height),
                            display: false)
        }
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        // Seed the FREE-pointer state. The per-view transparent-cursor
        // backstop defaults ON because full screen hides the cursor for the
        // whole session - but a window opens with the pointer the user's own,
        // and without this the arrow would be invisible over the picture from
        // frame zero. It runs before any capture edge can fire (the hover grab
        // needs a first responder, installed a runloop turn later), so a
        // bring-up that DOES land under the pointer still ends captured: this
        // seeds free, the grab then flips it.
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(false)
    }

    /// The visible screen area a window's CONTENT can occupy: the visible
    /// frame (menu bar and Dock excluded) minus this window's own title bar.
    private func availableContentArea(on screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 1920, height: 1080) }
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let titleBar = window.frameRect(forContentRect: probe).height - probe.height
        return CGSize(width: screen.visibleFrame.width,
                      height: max(screen.visibleFrame.height - titleBar, 0))
    }

    /// Save the frame under the autosave name and release the name, so the
    /// next session's window can claim it. Skipped while still in a Space: the
    /// frame at that moment is the screen, not the window the user sized, and
    /// AppKit already saved the real one on the last move/resize.
    func finishWindowedFrameAutosave() {
        if !window.styleMask.contains(.fullScreen) {
            window.saveFrame(usingName: Self.frameAutosaveName)
        }
        window.setFrameAutosaveName("")
    }

    /// The delegate's close request (red button / Cmd-W). Handed to the
    /// session's stop() via `onCloseRequested`; nothing is closed here.
    func handleUserCloseRequest() {
        guard displayMode == .window, !didClose else { return }
        log.info("Stream window close requested by the user - stopping the session")
        onCloseRequested?()
    }

    /// InputForwarder's capture edge in window mode. Visibility stays with the
    /// single `setCursorHidden` owner; the per-view transparent cursor
    /// backstop is switched with it so a free pointer shows the arrow over the
    /// picture and a captured one never can. Entering capture spends one of
    /// the hint's few shows - the only teaching surface left now that the grab
    /// is the pointer being over the window rather than a control to press.
    func setPointerCaptured(_ captured: Bool) {
        guard displayMode == .window, !didClose else { return }
        setCursorHidden(captured)
        (window.contentView as? StreamInputView)?.setTransparentCursorEnabled(captured)
        if captured {
            showCaptureHintIfBudgetAllows()
        } else {
            hideCaptureHint()
        }
        log.info("Pointer \(captured ? "captured" : "released", privacy: .public) (window mode)")
    }

    /// The window-mode observer set: the shared display observers (pacer
    /// rebind + cursor re-assert) and miniaturize/deminiaturize as the
    /// backgrounded signal - a minimized window presents nothing, so the
    /// decoder's present suppression and the launcher's "Back to stream" both
    /// apply. NO key/activation observers: the window stays put when the user
    /// clicks elsewhere, which is the whole point of a window.
    func installWindowedLifecycleObservers() {
        let nc = NotificationCenter.default
        installDisplayObservers(nc: nc)
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.onBackgroundedChanged?(true)
                self.log.info("Stream window miniaturized - present suppressed until it returns")
            }
        })
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose else { return }
                self.onBackgroundedChanged?(false)
            }
        })
    }

    // MARK: - Path B Space exit → window (issue #84)

    /// Registered by the Path-B bring-up. A user-driven exit from the Space
    /// (Mission Control, the Esc gesture) converts this window to window mode
    /// instead of leaving it ordered out: `willExit` disarms the fullscreen
    /// key observers (so the resign-key orderOut can't fire mid-transition)
    /// and flips the mode; `didExit` applies the titled chrome once AppKit has
    /// finished the animation. `close()` sets `didClose` before its own
    /// toggleFullScreen, so a teardown exit never converts.
    func installSpaceExitObservers() {
        let nc = NotificationCenter.default
        spaceExitObservers.append(nc.addObserver(
            forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, self.displayMode == .fullScreen else { return }
                self.beginSpaceExitConversion()
            }
        })
        spaceExitObservers.append(nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.didClose, self.displayMode == .window else { return }
                self.finishSpaceExitConversion()
            }
        })
    }

    /// The transition is under way: make the fullscreen machinery inert
    /// BEFORE anything can fire against it. Removing the key observers and
    /// bumping the resign generation together guarantee that neither a fresh
    /// resign nor one already sitting in its debounce can orderOut the window
    /// - the vanish in #84. The menu bar and cursor come back now, the chrome
    /// waits for didExit.
    private func beginSpaceExitConversion() {
        log.notice("Leaving the fullscreen Space (user-driven) - converting the stream window to window mode")
        resignGeneration &+= 1
        for token in keyObservers { NotificationCenter.default.removeObserver(token) }
        keyObservers.removeAll()
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { wsnc.removeObserver(token) }
        workspaceObservers.removeAll()
        if let saved = previousPresentationOptions {
            NSApp.presentationOptions = saved
            previousPresentationOptions = nil
        }
        displayMode = .window
        streamDelegate.displayMode = .window
        streamDelegate.coversNotch = false
        // Cursor back first, then the forwarder switches to the window pointer
        // model (which releases the association) - the order a resign uses.
        setCursorHidden(false)
        onDisplayModeChanged?(.window)
    }

    /// AppKit has restored the pre-Space frame: dress the window as a real
    /// window (style mask, level, aspect lock, size, autosave), bring it back
    /// key, re-install the input path (the Space exit resets the responder
    /// chain, exactly as the enter did), and arm the windowed observers.
    private func finishSpaceExitConversion() {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        configureWindowedChrome()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        installWindowedLifecycleObservers()
        for token in spaceExitObservers { NotificationCenter.default.removeObserver(token) }
        spaceExitObservers.removeAll()
        onBackgroundedChanged?(false)
        onDidBecomeReadyForInput?()
        Diag.notice("Left the full-screen Space - the stream continues in a window (the pointer is yours again)", "Stream")
    }
}
