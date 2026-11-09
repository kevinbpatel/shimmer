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

    // MARK: - Helpers

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
