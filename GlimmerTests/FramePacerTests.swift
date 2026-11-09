//
//  FramePacerTests.swift
//
//  Pacer release decisions that need no display link: the adaptive depth
//  policy, the trim, the due gate and the release-at-submit fast path.
//

import CoreMedia
import Foundation
import os
import QuartzCore
import Testing
@testable import Glimmer

struct FramePacerTests {

    /// Depth follows the published level only: the per-tick decay never grows the buffer,
    /// the 2 s window tick grows it one frame at a time, and decay is rate-limited.
    @Test func adaptiveDepthGrowsOnlyOnTheWindowTick() {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.lock.lock()
        #expect(pacer.justifiedDepthLocked() == 1)
        pacer.adaptiveDepth.reconciledTargetDepth = 4
        #expect(pacer.justifiedDepthLocked() == 4)
        #expect(pacer.decayTargetLocked() == 1)
        pacer.growTargetOneStepLocked()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 2)
        pacer.growTargetOneStepLocked()
        #expect(pacer.adaptiveDepth.adaptiveTargetDepth == 3)
        #expect(pacer.decayTargetLocked() == 3)

        pacer.adaptiveDepth.reconciledTargetDepth = 1
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 0.1
        #expect(pacer.decayTargetLocked() == 3)
        pacer.adaptiveDepth.lastTargetShrinkTime = CFAbsoluteTimeGetCurrent() - 0.3
        #expect(pacer.decayTargetLocked() == 2)
        pacer.lock.unlock()
    }

    /// A frame standing above target for a whole history window is latency, not bunching:
    /// the trim drops it to target, and a dip back to target re-arms the window.
    @Test func standingExtraFrameTrimsAfterHistoryWindow() throws {
        let pacer = try makePacer(fps: 120, queued: 2)
        let start = CFAbsoluteTimeGetCurrent()
        pacer.lock.lock()
        defer { pacer.lock.unlock() }
        #expect(pacer.gapAwareTrimLocked(now: start, effectiveTarget: 1).trimmed.isEmpty)
        #expect(pacer.gapAwareTrimLocked(now: start + 0.3, effectiveTarget: 1).trimmed.isEmpty)
        #expect(pacer.queue.count == 2)
        #expect(pacer.gapAwareTrimLocked(now: start + 0.6, effectiveTarget: 1).trimmed.count == 1)
        #expect(pacer.queue.count == 1)
        #expect(pacer.gapAwareTrimLocked(now: start + 0.7, effectiveTarget: 1).trimmed.isEmpty)
        #expect(pacer.liveness.overTargetSince.isNaN)
        pacer.queue.append(FramePacer.Entry(sampleBuffer: try emptySampleBuffer(), hostPTSSeconds: 1))
        #expect(pacer.gapAwareTrimLocked(now: start + 1.3, effectiveTarget: 1).trimmed.isEmpty)
        #expect(pacer.queue.count == 2)
    }

    /// The post-gap catch-up is exempt: while it plays through, nothing trims to target.
    @Test func standingFrameRuleSparesThePostGapCatchUp() throws {
        let pacer = try makePacer(fps: 120, queued: 3)
        let start = CFAbsoluteTimeGetCurrent()
        pacer.liveness.lastGapRecoveryTime = start
        pacer.lock.lock()
        defer { pacer.lock.unlock() }
        #expect(pacer.gapAwareTrimLocked(now: start, effectiveTarget: 1).inGapRecovery)
        #expect(pacer.gapAwareTrimLocked(now: start + 0.45, effectiveTarget: 1).trimmed.isEmpty)
        #expect(pacer.queue.count == 3)
        #expect(pacer.liveness.overTargetSince.isNaN)
    }

    /// A timer beat before the tick's frame scans out must not hand the
    /// renderer a second frame inside that panel vsync.
    @Test func assistBeatBeforeTickScanoutPresentsOnce() throws {
        let (pacer, presents) = try makeAssistPacer()
        releaseOnHalfRateTick(pacer, linkTimestamp: CACurrentMediaTime())
        pacer.deficitTimerFired()
        #expect(presents.withLock { $0 } == 1)
        #expect(pacer.queue.count == 1)
    }

    /// The tick's target leads by two panel vsyncs, but its frame scans out on
    /// the first; a beat past that lands on a later vsync and still releases.
    @Test func assistBeatAfterFirstPanelVsyncReleases() throws {
        let (pacer, presents) = try makeAssistPacer()
        releaseOnHalfRateTick(pacer, linkTimestamp: CACurrentMediaTime() - 1.5 * panelVsync)
        pacer.deficitTimerFired()
        #expect(presents.withLock { $0 } == 2)
    }

    /// Only a plausible lead counts as a tick's pending scanout; a lead past 1s
    /// is a timebase jump the due gate's clamp must still recover.
    @Test func tickScanoutLeadBounds() {
        #expect(FramePacer.tickOwnsScanout(now: 100, scanout: 100.008))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: 99.99))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: 105))
        #expect(!FramePacer.tickOwnsScanout(now: 100, scanout: .nan))
    }

    /// At rest a due frame reaches the renderer from submit instead of waiting for the next
    /// tick, and claims the vsync it lands on, so the next frame still waits for the gate.
    @Test func restingPacerReleasesADueFrameAtSubmit() throws {
        let (pacer, presents) = try makeRestingPacer()
        let tickTarget = CACurrentMediaTime() + 0.05
        pacer.liveness.lastTickTargetMediaTime = tickTarget
        pacer.lastPresentMediaTime = tickTarget - 1.0 / 120
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        pacer.pacingQueue.sync {}
        #expect(presents.withLock { $0 } == 1)
        #expect(pacer.queue.isEmpty)
        #expect(pacer.lastPresentMediaTime == tickTarget)
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        pacer.pacingQueue.sync {}
        #expect(presents.withLock { $0 } == 1)
        #expect(pacer.queue.count == 1)
    }

    /// A submit release fills the refresh its tick left empty, so that refresh isn't counted
    /// stale; an earlier empty refresh still is.
    @Test func submitReleaseClaimsOnlyItsOwnRefreshFromTheStaleCount() throws {
        let (pacer, presents) = try makeRestingPacer()
        let tickTarget = CACurrentMediaTime() + 0.05
        pacer.liveness.lastTickTargetMediaTime = tickTarget
        pacer.lastPresentMediaTime = tickTarget - 1.0 / 120
        pacer.liveness.staleCandidateTarget = tickTarget - 1.0 / 60
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        pacer.pacingQueue.sync {}
        #expect(presents.withLock { $0 } == 1)
        #expect(pacer.liveness.staleCandidateTarget == tickTarget - 1.0 / 60)

        let (claiming, _) = try makeRestingPacer()
        claiming.liveness.lastTickTargetMediaTime = tickTarget
        claiming.lastPresentMediaTime = tickTarget - 1.0 / 120
        claiming.liveness.staleCandidateTarget = tickTarget
        try claiming.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(claiming.liveness.staleCandidateTarget.isNaN)
    }

    /// A late tick has dequeued frame A and is handing it to the layer when frame B arrives and is
    /// due at once: B is presented after A, never ahead of it.
    @Test func aSubmitReleaseNeverOvertakesATicksFrame() throws {
        let pacer = try makePacer(fps: 120, queued: 1)
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 120
        let frameA = try ObjectIdentifier(#require(pacer.queue.first?.sampleBuffer))
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.willPresent = { buffer in
            let label = ObjectIdentifier(buffer) == frameA ? "A" : "B"
            if label == "A" {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            order.withLock { $0.append(label) }
            return true
        }
        let target = CACurrentMediaTime() - 0.05
        pacer.liveness.lastTickTargetMediaTime = target
        pacer.pacingQueue.async {
            pacer.releaseDueFrame(targetTimestamp: target, vsyncInterval: 1.0 / 120, tickScanout: target)
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        release.signal()
        pacer.pacingQueue.sync {}
        #expect(order.withLock { $0 } == ["A", "B"])
    }

    /// Passthrough stays off while a jitter buffer is wanted and before the first tick,
    /// so the tick path keeps owning those cases.
    @Test func submitReleaseNeedsRestConditions() throws {
        let (pacer, presents) = try makeRestingPacer()
        let tickTarget = CACurrentMediaTime() + 0.05
        pacer.liveness.lastTickTargetMediaTime = tickTarget
        pacer.lastPresentMediaTime = tickTarget - 1.0 / 120
        pacer.adaptiveDepth.adaptiveTargetDepth = 2
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        pacer.pacingQueue.sync {}
        #expect(presents.withLock { $0 } == 0)
        #expect(pacer.queue.count == 1)
        pacer.adaptiveDepth.adaptiveTargetDepth = 1
        pacer.queue.removeAll()
        pacer.liveness.lastTickTargetMediaTime = .nan
        try pacer.submit(emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        pacer.pacingQueue.sync {}
        #expect(presents.withLock { $0 } == 0)
        #expect(pacer.queue.count == 1)
    }

    /// A tick already dispatched when the window hides presents nothing and keeps the newest frame
    /// for the resume, the rule the submit and off-tick paths already follow.
    @Test func aSuppressedTickPresentsNothing() throws {
        let (pacer, presents) = try makeCountingPacer(queued: 1)
        pacer.setPresentSuppressed(true)
        let now = CACurrentMediaTime()
        pacer.releaseDueFrame(targetTimestamp: now + 1, vsyncInterval: 1.0 / 120, tickScanout: now + 1)
        #expect(presents.withLock { $0 } == 0)
        #expect(pacer.queue.count == 1)
    }

    @Test func nextScanoutFollowsTheTickGrid() {
        #expect(FramePacer.nextScanout(now: 10.0, lastTickTarget: 10.004, vsync: 0.004) == 10.004)
        #expect(abs(FramePacer.nextScanout(now: 10.005, lastTickTarget: 10.004, vsync: 0.004) - 10.008) < 1e-9)
        #expect(abs(FramePacer.nextScanout(now: 10.0201, lastTickTarget: 10.004, vsync: 0.004) - 10.024) < 1e-9)
    }

    // MARK: - Helpers

    /// A ticking 120 Hz pacer at rest with nothing queued.
    private func makeRestingPacer() throws -> (FramePacer, OSAllocatedUnfairLock<Int>) {
        let (pacer, presents) = try makeCountingPacer(queued: 0)
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 120
        return (pacer, presents)
    }

    /// A long panel vsync keeps the scanout and target 50-100 ms from `now`, so a
    /// scheduling delay between the test's clock read and the beat's can't flip either test.
    private let panelVsync = 0.1

    /// A tick release as `handleTick` makes it with the link at half the panel's
    /// rate: the target two panel vsyncs out, the scanout on the first.
    private func releaseOnHalfRateTick(_ pacer: FramePacer, linkTimestamp: CFTimeInterval) {
        pacer.releaseDueFrame(
            targetTimestamp: linkTimestamp + 2 * panelVsync, vsyncInterval: panelVsync,
            tickScanout: linkTimestamp + panelVsync)
    }

    private func makeAssistPacer() throws -> (FramePacer, OSAllocatedUnfairLock<Int>) {
        let (pacer, presents) = try makeCountingPacer(queued: 2)
        pacer.tickDeficit.floorAssistActive = true
        return (pacer, presents)
    }

    private func makePacer(fps: Int32, queued: Int) throws -> FramePacer {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: fps)
        pacer.running = true
        for index in 0..<queued {
            pacer.queue.append(FramePacer.Entry(
                sampleBuffer: try emptySampleBuffer(), hostPTSSeconds: Double(index) / Double(fps)))
        }
        return pacer
    }

    private func makeCountingPacer(queued: Int) throws -> (FramePacer, OSAllocatedUnfairLock<Int>) {
        let pacer = try makePacer(fps: 120, queued: queued)
        let presents = OSAllocatedUnfairLock(initialState: 0)
        pacer.willPresent = { _ in
            presents.withLock { $0 += 1 }
            return true
        }
        return (pacer, presents)
    }

    private func emptySampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}
