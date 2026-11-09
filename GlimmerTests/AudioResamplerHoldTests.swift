//
//  AudioResamplerHoldTests.swift
//
//  Cushion release judges the drift resampler by its recent drift, not the
//  absolute offset a correctly compensated clock accumulates from wall time.
//  Ported from upstream Glimmer's AudioResamplerHoldTests (the drift-window
//  cases; Shimmer's resampler has no per-device skew memory or setpoint hold).
//

import Foundation
import Testing
@testable import Glimmer

struct AudioResamplerHoldTests {

    /// A decoder whose resampler integral sits at `integralPpm`.
    private func steadyDecoder(targetMs: Double = 100, integralPpm: Double = 0) -> AudioDecoder {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.resamplerIntegralPpm = integralPpm
        decoder.playoutTargetMs = targetMs
        decoder.audioMeterLock.unlock()
        return decoder
    }

    /// A source and output both running 200ppm slow retain constant fill after
    /// 400 seconds, despite 80ms of wall-clock offset. The integral and trough
    /// guards must still hold an unstable or nearly empty cushion.
    @Test(arguments: [(-200.0, 105.0, true), (-501.0, 105.0, false), (-200.0, 5.0, false)])
    func compensatedClockReleasesOnlyAHealthyCushion(ppm: Double, minimumFillMs: Double, releases: Bool) {
        let decoder = steadyDecoder(targetMs: 110, integralPpm: ppm)
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.cushionLinkResolved = true
        decoder.cushionLinkClass = "wired"
        decoder.driftAnchorNanos = now - 400_000_000_000
        decoder.framesScheduled = UInt64(400 * (1 + ppm * 1e-6) * 48_000)
        decoder.framesPlayed = decoder.framesScheduled - 5_280
        decoder.resamplerEpsPpm = ppm
        decoder.lastResamplerUpdateNanos = now
        decoder.playoutTargetMs = 110
        decoder.learnedFloorMs = 105
        decoder.quietWindowMinFillMs = minimumFillMs
        decoder.quietSinceNanos = now - AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.publishAudioState()
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        #expect((decoder.cushionQuietAdjustLocked(now: now) != nil) == releases)
        #expect(decoder.playoutTargetMs == (releases ? 100 : 110))
    }

    @Test func correctedClockStaysStableAcrossLongSessions() {
        var window = AudioDecoder.ResamplerDriftWindow()
        for second in 0...3_600 {
            let stable = window.observe(driftMs: Double(second) * 0.2, now: UInt64(second) * 1_000_000_000)
            #expect(stable)
        }
    }

    @Test func driftExcursionNeedsAWholeCleanWindowBeforeRelease() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        let initial = window.observe(driftMs: 0, now: 0)
        let excursion = window.observe(driftMs: 80, now: 59 * second)
        let failedWindowEnd = window.observe(driftMs: 80, now: 60 * second)
        let recovering = window.observe(driftMs: 80, now: 119 * second)
        let recovered = window.observe(driftMs: 80, now: 120 * second)
        #expect(initial)
        #expect(!excursion)
        #expect(!failedWindowEnd)
        #expect(!recovering)
        #expect(recovered)
    }

    @Test func newPlayoutSegmentDiscardsPriorDriftFailure() {
        let decoder = steadyDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        _ = decoder.resamplerDriftWindow.observe(driftMs: 0, now: now - 2_000_000_000)
        let stable = decoder.resamplerDriftWindow.observe(driftMs: 80, now: now - 1_000_000_000)
        #expect(!stable)
        decoder.meterSampleRate = 48_000
        decoder.cushionLinkResolved = true
        decoder.lastResamplerUpdateNanos = now
        #expect(!decoder.meterRegisterScheduleOrOverrun(frames: 240))
        decoder.publishAudioState()
        #expect(decoder.resamplerSkewConverged)
    }

    @Test func reorderedDriftSamplesCannotPoisonAHealthyWindow() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        _ = window.observe(driftMs: 0, now: 0)
        let rolledOver = window.observe(driftMs: 12, now: 60 * second)
        let older = window.observe(driftMs: 100, now: 59 * second)
        let repeated = window.observe(driftMs: 100, now: 60 * second)
        let next = window.observe(driftMs: 12.2, now: 61 * second)
        #expect(rolledOver)
        #expect(older)
        #expect(repeated)
        #expect(next)
    }

    @Test func reorderedDriftSamplesCannotClearAFailedWindow() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        _ = window.observe(driftMs: 0, now: 0)
        _ = window.observe(driftMs: 80, now: 59 * second)
        let failedWindow = window.observe(driftMs: 80, now: 60 * second)
        let older = window.observe(driftMs: 0, now: 59 * second)
        let repeated = window.observe(driftMs: 0, now: 60 * second)
        let recovering = window.observe(driftMs: 80, now: 119 * second)
        let recovered = window.observe(driftMs: 80, now: 120 * second)
        let delayedFailure = window.observe(driftMs: 160, now: 119 * second)
        #expect(!failedWindow)
        #expect(!older)
        #expect(!repeated)
        #expect(!recovering)
        #expect(recovered)
        #expect(delayedFailure)
    }
}
