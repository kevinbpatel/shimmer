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
        hideStreamWindow()
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
        // window up (~100-300ms). The view-bound link stopped firing the
        // instant the window was ordered out, and a screen link is correct
        // whether or not PiP is up yet - so binding it here keeps frames
        // releasing across the startup gap instead of stalling the pacer FIFO
        // (which, with suppression held off by `pictureInPicturePending`,
        // would otherwise pile up and could trip a resync IDR). Verified: a
        // screen link built while the window is ordered out ticks at panel
        // rate (scratchpad/pipspike --attach-after-orderout).
        onPictureInPictureChanged?(true)
        pictureInPicture.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pictureInPicturePending else { return }
                self.log.error("Picture in Picture start never resolved - clearing pending state")
                self.pictureInPicturePending = false
                // Undo the optimistic request-time detach + UI flip, same as
                // the failure path: the window stays hidden (suppression
                // engages below), the pacer goes back on the view link, and the
                // menu bar stops showing PiP as active.
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
            if !self.isBackgrounded {
                self.log.info("Picture in Picture started after the window returned - stopping it")
                self.pictureInPicture.stop()
                return
            }
            self.enableBackgroundControllerEvents()
            self.publishPresentSuppression()
        }
        pictureInPicture.onFailedToStart = { [weak self] _ in
            guard let self, !self.didClose else { return }
            self.pictureInPicturePending = false
            // We optimistically rebound the pacer to a screen link at request
            // time; PiP didn't come up, so put it back on the view link. The
            // window stays hidden, so the plain hidden-window behaviour
            // (suppression + decode gate) engages through the edge below - the
            // dead view link doesn't matter while decode is gated, and it's the
            // correct binding for the eventual return to the window.
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
            // × close: the window stays hidden and this edge engages the normal
            // hidden-window suppression. Return: reengageForeground() already
            // ran and this is a no-op on an unchanged value.
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
