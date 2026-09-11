//
//  StreamPictureInPicture.swift
//
//  Thin adapter over AVKit's Picture in Picture for the stream's
//  AVSampleBufferDisplayLayer. The system PiP window (the one Safari /
//  QuickTime use) is fed by the SAME layer the fullscreen stream window
//  paints into: `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)`
//  takes over the layer's renderer output while PiP is active and hands it
//  back on stop. Nothing in the decode / pacing path changes - frames keep
//  landing on `layer.sampleBufferRenderer` exactly as before.
//
//  Verified on macOS 26 (see docs/superpowers/specs/2026-09-10-picture-in-picture-design.md):
//  PiP starts from a borderless window's root layer, while the app is NOT
//  active, and even while the source window is already orderOut'd; it keeps
//  rendering after the window is hidden; no `controlTimebase` is needed for
//  the host-PTS sample buffers we enqueue.
//
//  This class knows nothing about windows, decoders, or settings. It owns
//  the controller, is its delegate, and surfaces edges as MainActor closures:
//    onDidStart / onDidStop         - the PiP window came up / went away
//    onRestoreRequested             - the user hit the "return" button (or a
//                                     programmatic stop asked for restore)
//    onPauseChanged                 - the PiP window's play/pause control
//    onFailedToStart                - AVKit refused (another app owns PiP, ...)
//

import AVFoundation
import AVKit
import CoreMedia
import Foundation
import os

@MainActor
public final class StreamPictureInPicture: NSObject {
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.PiP")

    private var controller: AVPictureInPictureController?
    private var contentSource: AVPictureInPictureController.ContentSource?
    /// The layer the controller is currently built on. Kept so `retarget` can
    /// no-op when handed the same layer twice.
    private weak var layer: AVSampleBufferDisplayLayer?

    /// Set for the duration of a programmatic `stop()` so the restore
    /// callback AVKit fires on every stop (user-initiated OR ours) is only
    /// surfaced as `onRestoreRequested` when the USER asked to come back.
    private var stoppingProgrammatically = false
    /// Latched by the restore callback; read in didStop to tell "return to
    /// app" (restore requested) from "closed with ×" (no restore) apart.
    private var restoreRequested = false
    /// True from willStop (AVKit's, or our own `stop()`) until didStop, so a
    /// second stop request during the ~0.5s dismiss animation is a no-op.
    private var isStopping = false
    /// Armed by `stop()`: AVKit can silently ignore `stopPictureInPicture()`,
    /// and a latched `isStopping` with no willStop/didStop ever coming would
    /// make every later stop a no-op forever - the PiP window then outlives
    /// the stream window's return and mirrors the fullscreen source as a 1:1
    /// crop. If nothing lands within `stopAckTimeout`, ask again, and after
    /// `stopAttempts` unlatch so the state machine stays honest (the user's
    /// own × / return still work). The one KNOWN way to provoke an ignored
    /// stop - asking from inside AVKit's didStart callback - wedges the
    /// controller for retries too (measured: 3 asks over 1.5s, all dropped),
    /// which is why the owner defers that particular stop instead of relying
    /// on this; the watchdog is the backstop for whatever else AVKit drops.
    private var stopWatchdog: DispatchWorkItem?
    private static let stopAckTimeout: TimeInterval = 0.75
    private static let stopAttempts = 3

    /// PiP's play/pause state as the PiP controls last set it. Read by
    /// AVKit's `pictureInPictureControllerIsPlaybackPaused` off the main
    /// thread, so it lives behind a lock rather than on the actor.
    private let pausedState = OSAllocatedUnfairLock(initialState: false)

    public var onDidStart: (@MainActor () -> Void)?
    /// `restoreRequested` is true when the user hit the return-to-app button
    /// (the window should come back), false for the × close button (the
    /// stream stays hidden).
    public var onDidStop: (@MainActor (_ restoreRequested: Bool) -> Void)?
    public var onRestoreRequested: (@MainActor () -> Void)?
    public var onPauseChanged: (@MainActor (Bool) -> Void)?
    public var onFailedToStart: (@MainActor (Error) -> Void)?

    public private(set) var isActive = false

    /// One line of controller + adapter state for the env-gated debug probe
    /// (`--debug-pip-probe`); never read on a normal launch.
    public var debugState: String {
        let ctl = controller
        return "ctl.active=\(ctl?.isPictureInPictureActive ?? false) ctl.possible=\(ctl?.isPictureInPicturePossible ?? false) "
            + "ctl.suspended=\(ctl?.isPictureInPictureSuspended ?? false) isActive=\(isActive) isStopping=\(isStopping) "
            + "stoppingProgrammatically=\(stoppingProgrammatically) restoreRequested=\(restoreRequested)"
    }

    public init(layer: AVSampleBufferDisplayLayer) {
        super.init()
        build(on: layer)
    }

    /// Whether AVKit would let us start right now. False when the system's
    /// single PiP slot is taken by another app, or PiP is unsupported.
    public var isPossible: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
            && (controller?.isPictureInPicturePossible ?? false)
    }

    /// Point the controller at a fresh layer (the renderer hard-fail self-heal
    /// rebuilds the display layer). The old controller's PiP window collapses
    /// with its old layer. Returns whether PiP was active, so the owner can
    /// reconcile its own state - this deliberately does NOT auto-restart PiP:
    /// the system's single PiP slot is still held by the dismissing old window,
    /// so an immediate `start()` would silently fail the `isPossible` guard and
    /// strand the owner's `isPictureInPictureActive` flag true forever (no
    /// callback ever comes because `build` nils the old delegate).
    @discardableResult
    public func retarget(layer newLayer: AVSampleBufferDisplayLayer) -> Bool {
        guard newLayer !== layer else { return false }
        let wasActive = isActive
        if wasActive {
            stoppingProgrammatically = true
            controller?.stopPictureInPicture()
            stoppingProgrammatically = false
            isActive = false
            isStopping = false
            disarmStopWatchdog()
        }
        build(on: newLayer)
        return wasActive
    }

    public func start() {
        guard let controller else { return }
        guard !controller.isPictureInPictureActive else { return }
        guard isPossible else {
            log.notice("Picture in Picture not possible right now (another app may own it) - not starting")
            return
        }
        restoreRequested = false
        pausedState.withLock { $0 = false }
        log.info("Starting Picture in Picture")
        controller.startPictureInPicture()
    }

    public func stop() {
        guard let controller, controller.isPictureInPictureActive, !isStopping else { return }
        log.info("Stopping Picture in Picture")
        stoppingProgrammatically = true
        isStopping = true
        controller.stopPictureInPicture()
        armStopWatchdog(attempt: 1)
    }

    private func armStopWatchdog(attempt: Int) {
        stopWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopWatchdog = nil
            // Acknowledged (willStop/didStop cleared the latch), or PiP is gone
            // by some other route - nothing to do.
            guard self.isStopping, let controller = self.controller,
                  controller.isPictureInPictureActive else { return }
            if attempt >= Self.stopAttempts {
                self.log.error("Picture in Picture stop ignored by AVKit \(attempt) times - giving up; state unlatched")
                self.isStopping = false
                self.stoppingProgrammatically = false
                return
            }
            self.log.error("Picture in Picture stop not acknowledged within \(Self.stopAckTimeout)s - asking again (attempt \(attempt + 1))")
            controller.stopPictureInPicture()
            self.armStopWatchdog(attempt: attempt + 1)
        }
        stopWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopAckTimeout, execute: item)
    }

    private func disarmStopWatchdog() {
        stopWatchdog?.cancel()
        stopWatchdog = nil
    }

    /// Drop the controller without any callbacks - session teardown.
    public func invalidate() {
        onDidStart = nil; onDidStop = nil; onRestoreRequested = nil
        onPauseChanged = nil; onFailedToStart = nil
        if controller?.isPictureInPictureActive == true {
            stoppingProgrammatically = true
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        contentSource = nil
        isActive = false
        isStopping = false
        disarmStopWatchdog()
    }

    private func build(on newLayer: AVSampleBufferDisplayLayer) {
        controller?.delegate = nil
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: newLayer, playbackDelegate: self)
        let ctl = AVPictureInPictureController(contentSource: source)
        ctl.delegate = self
        // A live stream has no timeline to scrub - hide the skip affordances.
        ctl.requiresLinearPlayback = true
        contentSource = source
        controller = ctl
        layer = newLayer
    }

    /// Run `body` on the main actor: inline when AVKit calls us on the main
    /// thread (the delegate contract), otherwise hop.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension StreamPictureInPicture: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            isActive = true
            log.info("Picture in Picture started")
            onDidStart?()
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        onMain { [self] in
            isActive = false
            log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
            onFailedToStart?(error)
        }
    }

    public nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            isStopping = true
            disarmStopWatchdog()
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onMain { [self] in
            isStopping = true
            disarmStopWatchdog()
            // AVKit asks for restore on EVERY stop, including ours. Only a stop
            // we did not initiate is the user asking to come back.
            if !stoppingProgrammatically {
                restoreRequested = true
                onRestoreRequested?()
            }
        }
        // AVKit calls us on the main thread, so the block above ran inline and
        // the window is already coming back by the time we answer. The handler
        // is not Sendable - keep it out of the actor closure.
        completionHandler(true)
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onMain { [self] in
            let restore = restoreRequested
            isActive = false
            isStopping = false
            restoreRequested = false
            stoppingProgrammatically = false
            disarmStopWatchdog()
            log.info("Picture in Picture stopped (restoreRequested=\(restore, privacy: .public))")
            onDidStop?(restore)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension StreamPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Pause is REFUSED. macOS draws the PiP transport in its own agent
    /// process - it is not in our view tree, so the button cannot be hidden -
    /// but a live game has nothing to pause: the host keeps playing, so
    /// "pausing" only freezes the mirror and then jumps on resume. Instead of
    /// honouring it we stay playing and immediately tell AVKit so, which snaps
    /// the button back. Verified by probing the panel: NSApp.windows holds
    /// only `PIPPanel`, whose tree is the display layer and nothing else.
    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        guard !playing else { return }
        pausedState.withLock { $0 = false }
        onMain { [self] in
            self.controller?.invalidatePlaybackState()
            self.log.notice("Picture in Picture pause ignored - a live stream has nothing to pause")
        }
    }

    public nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Live: no seekable timeline.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        pausedState.withLock { $0 }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // The PiP window resized; the renderer scales the sample buffers
        // itself, nothing for us to do.
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        // Live stream - nothing to skip within.
        completionHandler()
    }

    public nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}
