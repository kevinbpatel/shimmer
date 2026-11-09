//
//  AudioCushionDeadAirTests.swift
//
//  How the adaptive audio cushion walks back down: a quiet window releases a
//  learned floor on every link class, but never straight back to a level that
//  just under-ran.
//

import Foundation
import Testing
@testable import Glimmer

// Same serialized suite as the stall tests: drains bump the shared under-run
// counter that suite's evidence-gate pair brackets.
extension AudioPlayoutStallTests {

    /// A target one step above its learned floor, at the end of a quiet window whose trough
    /// stayed `minFillMs` above empty. Only wired links used to release the floor here; the
    /// rest waited ~10 min a step, holding Wi-Fi targets near 105 ms over 75 ms troughs.
    @Test(arguments: [("wifi", 25.0, true), ("tunnel", 25.0, true), ("unknown", 25.0, true),
                      ("wired", 15.0, true), ("wifi", 15.0, false)])
    func quietWindowReleasesTheFloor(link: String, minFillMs: Double, releases: Bool) {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = link
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 110
        decoder.learnedFloorMs = 105
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = minFillMs
        #expect((decoder.cushionQuietAdjustLocked(now: now) != nil) == releases)
        #expect(decoder.playoutTargetMs == (releases ? 100 : 110))
        #expect(decoder.learnedFloorMs == (releases ? 95 : 105))
    }

    /// For the recent-failure hold after an under-run, a quiet window won't walk the target back
    /// below a step above the level that failed; once the hold passes, it may.
    @Test func walkDownHoldsAboveARecentFailure() {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = "wifi"
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 54
        decoder.learnedFloorMs = 50
        decoder.lastFailedTargetMs = 44
        decoder.lastUnderrunNanos = now &- 60_000_000_000
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = 25
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 54)

        decoder.lastUnderrunNanos = now &- AudioDecoder.cushionFloorDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) != nil)
        #expect(decoder.playoutTargetMs == 44)
    }

    /// The ordinary walk-down, far above the floor, holds a step above a recent failure too: a grow
    /// that never taught the floor must not walk straight back to the level that under-ran.
    @Test func ordinaryWalkDownHoldsAboveARecentFailure() {
        let decoder = AudioDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        decoder.cushionLinkClass = "wifi"
        decoder.resamplerSkewConverged = true
        decoder.playoutTargetMs = 70
        decoder.learnedFloorMs = 45
        decoder.lastFailedTargetMs = 60
        decoder.lastUnderrunNanos = now &- 60_000_000_000
        decoder.quietSinceNanos = now &- AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.quietWindowMinFillMs = 25
        #expect(decoder.cushionQuietAdjustLocked(now: now) == nil)
        #expect(decoder.playoutTargetMs == 70)

        decoder.lastUnderrunNanos = now &- AudioDecoder.cushionFloorDecayQuietNanos
        #expect(decoder.cushionQuietAdjustLocked(now: now) != nil)
        #expect(decoder.playoutTargetMs == 60)
    }
}
