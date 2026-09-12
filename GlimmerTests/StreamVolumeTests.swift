//
//  StreamVolumeTests.swift
//
//  The menu bar's stream volume + mute. Two things are worth guarding here and
//  neither is the arithmetic: that an absent `streamVolume` key reads as FULL
//  volume rather than silence (`double(forKey:)` answers 0 for a missing key,
//  which would ship every fresh install muted), and that the ladder the Volume
//  submenu draws is the same set of values `isSelectedStreamVolume` will
//  checkmark - the checkmark compares Doubles built by division, so an exact
//  `==` there would silently never match.
//

import AVFAudio
import Testing
@testable import Glimmer

/// Serialized and defaults-restoring for the same reason QualityRestoreTests is:
/// `AppModel()` reads and writes `UserDefaults.standard` under the test host.
@Suite(.serialized)
struct StreamVolumeTests {

    private static let keys = ["streamVolume", "streamMuted"]

    private func withSeededDefaults(_ seed: [String: Any], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        for (key, value) in seed { defaults.set(value, forKey: key) }
        body()
    }

    // MARK: The absent-key trap

    @Test func aFreshInstallStartsAtFullVolume() {
        withSeededDefaults([:]) {
            #expect(AppModel.loadStreamVolume() == 1.0)
        }
    }

    @Test func aSavedLevelIsRestoredAsItself() {
        withSeededDefaults(["streamVolume": 0.4]) {
            #expect(AppModel.loadStreamVolume() == 0.4)
        }
    }

    /// A hand-edited plist or a downgrade shouldn't be able to push the mixer
    /// outside the audible range.
    @Test func anOutOfRangeSavedLevelIsClamped() {
        withSeededDefaults(["streamVolume": 4.2]) { #expect(AppModel.loadStreamVolume() == 1.0) }
        withSeededDefaults(["streamVolume": -1.0]) {
            #expect(AppModel.loadStreamVolume() == AppModel.minStreamVolume)
        }
    }

    // MARK: The ladder

    @Test func theLadderRunsLoudestFirstDownToTheFloor() {
        let levels = AppModel.streamVolumeLevels
        #expect(levels.first == 1.0)
        #expect(levels.last == AppModel.minStreamVolume)
        #expect(levels.count == 10)
        #expect(levels == levels.sorted(by: >))
    }

    /// Silence is Mute's job alone. A 0% rung would be a state the user can't
    /// read their way out of: the menu still offers "Mute", and muting then
    /// unmuting lands back on silence.
    @Test func noRungIsSilent() {
        #expect(AppModel.streamVolumeLevels.allSatisfy { $0 > 0 })
    }

    /// The checkmark's tolerance has to cover the ladder's own division error,
    /// and must not be so wide that two adjacent rungs both match.
    @MainActor
    @Test func exactlyOneRungIsCheckmarkedForEveryRung() {
        withSeededDefaults([:]) {
            let model = AppModel()
            for level in AppModel.streamVolumeLevels {
                model.setStreamVolume(level)
                let matched = AppModel.streamVolumeLevels.filter { model.isSelectedStreamVolume($0) }
                #expect(matched.count == 1)
                #expect(matched.first == level)
            }
        }
    }

    // MARK: Stepping

    /// Louder/Quieter must land back ON the ladder, or the checkmark goes blank
    /// after a few presses (0.7000000000000001 renders as 70% and matches
    /// nothing under an exact compare).
    @MainActor
    @Test func steppingStaysOnTheLadderAndInsideTheRange() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(AppModel.minStreamVolume)
            for _ in 0..<20 {
                model.stepStreamVolume(by: AppModel.streamVolumeStep)
                #expect(AppModel.streamVolumeLevels.contains { model.isSelectedStreamVolume($0) })
            }
            #expect(model.streamVolume == 1.0)
            for _ in 0..<20 { model.stepStreamVolume(by: -AppModel.streamVolumeStep) }
            // Quieter bottoms out on the floor, never on silence.
            #expect(model.streamVolume == AppModel.minStreamVolume)
            #expect(model.effectiveStreamVolume > 0)
        }
    }

    // MARK: Mute

    @MainActor
    @Test func muteWinsOverTheLevelAndTheLevelSurvivesUnderneath() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(0.6)
            model.toggleStreamMute()
            #expect(model.streamMuted)
            #expect(model.effectiveStreamVolume == 0)
            #expect(model.streamVolume == 0.6)   // remembered, not zeroed
            model.toggleStreamMute()
            #expect(model.effectiveStreamVolume == 0.6)
        }
    }

    /// Asking for more volume means it - leaving the mute latched would make
    /// Louder look broken.
    @MainActor
    @Test func raisingTheVolumeUnmutes() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.toggleStreamMute()
            model.stepStreamVolume(by: AppModel.streamVolumeStep)
            #expect(!model.streamMuted)

            model.toggleStreamMute()
            model.setStreamVolume(0.3)
            #expect(!model.streamMuted)
        }
    }

    /// Quieter is NOT an unmute - that's the user asking for less, not for
    /// sound. (Picking a rung IS an unmute; every rung is audible, so choosing
    /// one can only mean "play at this level".)
    @MainActor
    @Test func quieterLeavesTheMuteAlone() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(0.5)
            model.toggleStreamMute()
            model.stepStreamVolume(by: -AppModel.streamVolumeStep)
            #expect(model.streamMuted)
            #expect(model.streamVolume == 0.4)
        }
    }

    // MARK: Persistence

    @MainActor
    @Test func bothSurviveARelaunch() {
        withSeededDefaults([:]) {
            let model = AppModel()
            model.setStreamVolume(0.2)
            model.toggleStreamMute()
            let relaunched = AppModel()
            #expect(relaunched.streamVolume == 0.2)
            #expect(relaunched.streamMuted)
            #expect(relaunched.effectiveStreamVolume == 0)
        }
    }
}

/// The lever itself. Everything above is arithmetic on a Double; this is the
/// one test that checks a volume actually makes the audio quieter.
///
/// It renders the decoder's exact graph - `playerNode -> varispeed ->
/// mainMixer` - offline, so it needs no audio hardware and holds in CI. The
/// thing worth pinning is that `mainMixerNode.outputVolume` scales what comes
/// out of THAT graph: the decoder's own `applyOutputVolumeLocked` writes the
/// mixer rather than `playerNode.volume` (both attenuate correctly here, but
/// the mixer's doesn't depend on how the graph is wired), so a future rewiring
/// that silently broke the setting would show up as this test going flat.
struct StreamVolumeLeverTests {

    /// RMS of a rendered sine through `player -> varispeed -> mainMixer` at the
    /// given mixer output volume, using AVAudioEngine's manual rendering mode
    /// (no audio hardware, so this is safe on any machine and in CI).
    private func renderedRMS(mixerVolume: Float) throws -> Float {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw RenderError.formatUnavailable
        }
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)

        let frames: AVAudioFrameCount = 4_800
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw RenderError.bufferUnavailable
        }
        source.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            guard let samples = source.floatChannelData?[channel] else { throw RenderError.bufferUnavailable }
            for frame in 0..<Int(frames) {
                samples[frame] = sinf(2 * .pi * 440 * Float(frame) / 48_000) * 0.5
            }
        }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        engine.mainMixerNode.outputVolume = mixerVolume
        try engine.start()
        player.scheduleBuffer(source, at: nil, options: [])
        player.play()

        guard let out = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: frames
        ) else { throw RenderError.bufferUnavailable }
        let status = try engine.renderOffline(frames, to: out)
        #expect(status == .success)
        engine.stop()

        guard let rendered = out.floatChannelData?[0] else { throw RenderError.bufferUnavailable }
        var sum: Float = 0
        for frame in 0..<Int(out.frameLength) { sum += rendered[frame] * rendered[frame] }
        return (sum / Float(max(out.frameLength, 1))).squareRoot()
    }

    private enum RenderError: Error { case formatUnavailable, bufferUnavailable }

    @Test func theMixerOutputVolumeActuallyAttenuates() throws {
        let full = try renderedRMS(mixerVolume: 1.0)
        let quarter = try renderedRMS(mixerVolume: 0.25)
        let silent = try renderedRMS(mixerVolume: 0.0)
        // Full scale has to be audible at all, or the harness proves nothing.
        #expect(full > 0.01)
        // A quarter volume is a quarter of the amplitude, so a quarter of the
        // RMS. Generous tolerance - the point is that it scales, not that the
        // renderer is bit-exact.
        #expect(quarter < full * 0.35)
        #expect(quarter > full * 0.15)
        // And 0 is what Mute sends.
        #expect(silent < full * 0.001)
    }
}
