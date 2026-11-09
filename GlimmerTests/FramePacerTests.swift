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

    // MARK: - Helpers

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
