//
//  StreamChoicesTests.swift
//
//  The Stream pane's picker views of the persisted quality model, and the
//  pure frame-rate / bitrate resolution rules behind persistQualitySettings().
//

import Testing
@testable import Glimmer

struct StreamChoicesTests {

    // MARK: Resolution picker

    @Test func presetsReadAsTheirOwnRows() {
        #expect(ResolutionChoice.from(preset: .matchDisplay, customWidth: 1920, customHeight: 1080) == .matchDisplay)
        #expect(ResolutionChoice.from(preset: .hidpi, customWidth: 1920, customHeight: 1080) == .hidpi)
    }

    @Test func customWithStandardNumbersReadsAsThatStandardRow() {
        #expect(ResolutionChoice.from(preset: .custom, customWidth: 2560, customHeight: 1440) == .standard(.qhd1440))
        #expect(ResolutionChoice.from(preset: .custom, customWidth: 3024, customHeight: 1964) == .custom)
    }

    @Test func pickerListsEveryStandardSizeBetweenMatchAndCustom() {
        #expect(ResolutionChoice.all.first == .matchDisplay)
        #expect(ResolutionChoice.all.last == .custom)
        #expect(ResolutionChoice.all.count == 2 + CommonResolution.allCases.count + 1)
    }

    // MARK: Frame rate picker

    @Test func frameRateRowsFollowTheFlagThenTheNumber() {
        #expect(FrameRateChoice.from(matchesDisplay: true, customFPS: 60) == .matchDisplay)
        #expect(FrameRateChoice.from(matchesDisplay: false, customFPS: 120) == .fixed(120))
        #expect(FrameRateChoice.from(matchesDisplay: false, customFPS: 75) == .custom)
    }

    // MARK: Resolution rules

    @Test func matchingTheDisplayTakesThePanelHz() {
        #expect(QualityResolution.frameRate(matchesDisplay: true, customFPS: 30, displayHz: 120, windowed: false) == 120)
        // A panel that can't say its refresh falls back, never 0.
        #expect(QualityResolution.frameRate(matchesDisplay: true, customFPS: 30, displayHz: 0, windowed: false)
            == StreamDisplayMode.fallbackDisplayMaxHz)
    }

    @Test func aPickedRateIsVerbatimFullScreenAndCappedInAWindow() {
        #expect(QualityResolution.frameRate(matchesDisplay: false, customFPS: 144, displayHz: 60, windowed: false) == 144)
        #expect(QualityResolution.frameRate(matchesDisplay: false, customFPS: 144, displayHz: 60, windowed: true) == 60)
        #expect(QualityResolution.frameRate(matchesDisplay: false, customFPS: 1000, displayHz: 60, windowed: false) == 240)
    }

    @Test func bitrateIsTheRecommendationOrTheUsersNumber() {
        #expect(QualityResolution.bitrateKbps(auto: true, manualMbps: 50, recommendedKbps: 85_000) == 85_000)
        #expect(QualityResolution.bitrateKbps(auto: false, manualMbps: 50, recommendedKbps: 85_000) == 50_000)
        // Out-of-range manual values heal to the engine's floor / ceiling.
        #expect(QualityResolution.bitrateKbps(auto: false, manualMbps: 1, recommendedKbps: 0) == 5_000)
        #expect(QualityResolution.bitrateKbps(auto: false, manualMbps: 9_999, recommendedKbps: 0) == 300_000)
    }

    // MARK: Bitrate slider

    @Test func sliderSnapsToTheNearestStop() {
        #expect(BitrateScale.stepsMbps[BitrateScale.nearestIndex(toMbps: 5)] == 5)
        #expect(BitrateScale.stepsMbps[BitrateScale.nearestIndex(toMbps: 21)] == 20)
        #expect(BitrateScale.stepsMbps[BitrateScale.nearestIndex(toMbps: 86)] == 90)
        // An exact tie keeps the lower stop.
        #expect(BitrateScale.stepsMbps[BitrateScale.nearestIndex(toMbps: 19)] == 18)
        #expect(BitrateScale.stepsMbps[BitrateScale.nearestIndex(toMbps: 1_000)] == 300)
    }

    @Test func stopsAreStrictlyIncreasingWithinBounds() {
        let steps = BitrateScale.stepsMbps
        #expect(steps.first == StreamSizeBounds.bitrateMbps.lowerBound)
        #expect(steps.last == StreamSizeBounds.bitrateMbps.upperBound)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    }
}

/// Launch-time restore of the persisted quality settings.
///
/// Serialized and defer-restored: these construct a real `AppModel`, which
/// reads and writes `UserDefaults.standard` (the app's own domain under the
/// test host).
@Suite(.serialized)
struct QualityRestoreTests {

    private static let keys = [
        "qualityPreset", "customWidth", "customHeight", "customFPS",
        "frameRateMatchesDisplay", "bitrateAuto", "manualBitrateMbps",
    ]

    /// Run `body` with the quality keys set to `seed`, restoring whatever the
    /// user actually had afterwards.
    private func withSeededDefaults(_ seed: [String: Any], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in seed { defaults.set(value, forKey: key) }
        body()
    }

    /// The bug the owner reported: pick a resolution, relaunch, and it was the
    /// display's native size again. `qualityPreset`'s willSet prefill ran
    /// during `init()` (the @Observable macro makes observers fire there) and
    /// persisted the outgoing preset's numbers over the saved ones.
    @MainActor
    @Test func aSavedCustomResolutionSurvivesRelaunch() {
        withSeededDefaults([
            "qualityPreset": "custom", "customWidth": 3840, "customHeight": 2160,
            "customFPS": 60, "frameRateMatchesDisplay": false,
        ]) {
            let model = AppModel()
            #expect(model.qualityPreset == .custom)
            #expect(model.customWidth == 3840)
            #expect(model.customHeight == 2160)
            #expect(model.customFPS == 60)
            // And the restore wrote nothing over what was on record.
            #expect(UserDefaults.standard.integer(forKey: "customWidth") == 3840)
            #expect(UserDefaults.standard.integer(forKey: "customHeight") == 2160)
            #expect(UserDefaults.standard.integer(forKey: "customFPS") == 60)
        }
    }

    /// A manual bitrate is restored as itself, and a restore never seeds the
    /// manual key (only the user turning the switch off does).
    @MainActor
    @Test func aManualBitrateSurvivesRelaunchAndAutoIsNotSeeded() {
        withSeededDefaults([
            "qualityPreset": "matchDisplay", "bitrateAuto": false, "manualBitrateMbps": 45,
        ]) {
            let model = AppModel()
            #expect(model.bitrateAuto == false)
            #expect(model.manualBitrateMbps == 45)
            #expect(UserDefaults.standard.integer(forKey: "manualBitrateMbps") == 45)
        }
    }

    /// The frame-rate flag's migration: absent means "whatever this install was
    /// already getting" - the panel's refresh under a panel preset, the typed
    /// Hz under Custom.
    @MainActor
    @Test func theFrameRateFlagMigratesFromTheOldPreset() {
        withSeededDefaults(["qualityPreset": "custom", "customFPS": 90]) {
            UserDefaults.standard.removeObject(forKey: "frameRateMatchesDisplay")
            let model = AppModel()
            #expect(model.frameRateMatchesDisplay == false)
            #expect(model.customFPS == 90)
        }
        withSeededDefaults(["qualityPreset": "matchDisplay"]) {
            UserDefaults.standard.removeObject(forKey: "frameRateMatchesDisplay")
            #expect(AppModel().frameRateMatchesDisplay == true)
        }
    }
}
