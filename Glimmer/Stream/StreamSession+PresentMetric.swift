//
//  StreamSession+PresentMetric.swift
//
//  The 2 Hz NOTICE-level present/decode-path instrumentation timer - the
//  diagnostic that pinpoints a present-path freeze from the log alone (pacer
//  tick rate, last-release age, queue depth, decode-output rate). Split out of
//  StreamSession+Watchdog.swift to keep the watchdog file focused on the
//  detect-and-recover logic; the episode/recovery STATE both use lives in
//  StreamSession.swift (main-thread only; stored properties can't live in an
//  extension).
//

import Foundation
import os

extension StreamSession {

    /// Install the two-second session tick: it feeds the env-signal windows, grows
    /// the pacer depth toward the published level, and logs the NOTICE-level
    /// present/decode-path instrumentation - the numbers that would have pinpointed
    /// a freeze instantly: pacer tick rate, last-release age, queue depth,
    /// decode-output rate. NOTICE privacy so it lands in `log show` without --info
    /// and in the in-app log.
    func startPresentMetricTimer() async {
        let dec = videoDecoder
        await MainActor.run {
            self.presentMetricTimer?.invalidate()
            EnvSignalController.shared.beginSession()
            self.prevMetricTotalTicks = 0
            self.prevMetricTotalReleases = 0
            self.prevMetricTime = CFAbsoluteTimeGetCurrent()
            let timer = Timer.scheduledTimer(
                withTimeInterval: 2.0, repeats: true
            ) { [weak self, weak dec] _ in
                MainActor.assumeIsolated {
                    EnvSignalController.shared.observeStreamTick()
                    guard let self, let dec else { return }
                    self.emitPresentMetric(dec: dec)
                }
            }
            timer.tolerance = 0.2
            self.presentMetricTimer = timer
        }
    }

    /// Stop the tick and end the env-signal session. Main actor, from `stop()`.
    @MainActor
    func stopPresentMetricTimer() {
        presentMetricTimer?.invalidate()
        presentMetricTimer = nil
        EnvSignalController.shared.endSession()
    }

    @MainActor
    private func emitPresentMetric(dec: VideoDecoder) {
        let now = CFAbsoluteTimeGetCurrent()
        let decodeIdle = dec.secondsSinceLastDecodedFrame()
        // Only emit once frames have started flowing, so a quiet handshake
        // window doesn't spam the log.
        guard decodeIdle.isFinite else { return }

        // The pacer's only grow step: one frame per window toward the level the env-signal
        // controller published, so depth grows only on sustained evidence.
        dec.pacingGrowDepthTowardTarget()
        // sincePresent is the MODE-AGNOSTIC present clock - meaningful in BOTH
        // paced and direct mode, so the metric line shows how long since a frame
        // reached the screen even when the pacer is down.
        let sincePresent = dec.secondsSinceLastPresentedFrame()
        guard let live = dec.pacingLiveness() else {
            // Direct-enqueue fallback path - report decode + present liveness.
            self.log.notice(
                // swiftlint:disable:next line_length
                "PRESENT METRIC pacer=direct decodeIdle=\(decodeIdle * 1000, format: .fixed(precision: 1), privacy: .public)ms sincePresent=\(sincePresent * 1000, format: .fixed(precision: 1), privacy: .public)ms")
            return
        }
        let dt = max(0.001, now - self.prevMetricTime)
        let ticksPerSec = Double(live.totalTicks &- self.prevMetricTotalTicks) / dt
        let presentsPerSec = Double(live.totalReleases &- self.prevMetricTotalReleases) / dt
        self.prevMetricTotalTicks = live.totalTicks
        self.prevMetricTotalReleases = live.totalReleases
        self.prevMetricTime = now
        self.log.notice(
            // swiftlint:disable:next line_length
            "PRESENT METRIC ticks/s=\(ticksPerSec, format: .fixed(precision: 1), privacy: .public) presents/s=\(presentsPerSec, format: .fixed(precision: 1), privacy: .public) sinceTick=\(live.secondsSinceLastTick * 1000, format: .fixed(precision: 1), privacy: .public)ms sinceRelease=\(live.secondsSinceLastRelease * 1000, format: .fixed(precision: 1), privacy: .public)ms depth=\(live.depth, privacy: .public) targetDepth=\(live.adaptiveTargetDepth, privacy: .public) streamInterval=\(live.streamFrameIntervalSeconds * 1000, format: .fixed(precision: 2), privacy: .public)ms decodeIdle=\(decodeIdle * 1000, format: .fixed(precision: 1), privacy: .public)ms")
    }
}
