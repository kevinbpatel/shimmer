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

    @Test func frameRateRowIsJustTheNumber() {
        #expect(FrameRateChoice.from(customFPS: 120) == .fixed(120))
        #expect(FrameRateChoice.from(customFPS: 75) == .custom)
        #expect(!FrameRateChoice.all.isEmpty)
    }

    /// "Match display" left the picker, so an install that was on it has to
    /// land on the rate it was ALREADY streaming at - the panel's refresh -
    /// not on whatever `customFPS` happened to hold.
    @Test func matchDisplayMigratesToThePanelsOwnRate() {
        #expect(FrameRateChoice.migratedRate(displayHz: 120) == 120)
        #expect(FrameRateChoice.migratedRate(displayHz: 75) == 75)
        // A panel that can't say its refresh falls back, never 0.
        #expect(FrameRateChoice.migratedRate(displayHz: 0) == 60)
        // And an absurd reading is clamped like any other rate.
        #expect(FrameRateChoice.migratedRate(displayHz: 1000) == 240)
    }

    /// A migrated 75Hz panel reads back as Custom showing 75 - the honest row,
    /// since 75 isn't one of the standard offers.
    @Test func aNonStandardMigratedRateReadsAsCustom() {
        #expect(FrameRateChoice.from(customFPS: FrameRateChoice.migratedRate(displayHz: 75)) == .custom)
    }

    // MARK: Resolution rules

    @Test func aPickedRateIsVerbatimFullScreenAndCappedInAWindow() {
        #expect(QualityResolution.frameRate(customFPS: 144, displayHz: 60, windowed: false) == 144)
        #expect(QualityResolution.frameRate(customFPS: 144, displayHz: 60, windowed: true) == 60)
        #expect(QualityResolution.frameRate(customFPS: 1000, displayHz: 60, windowed: false) == 240)
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
        "customHDR", "didWidenHDRToAllPresets",
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

    /// The write half of the resolution picker, which is the half the bug
    /// lived in: picking a row must read back as that row, and still read back
    /// as that row after a relaunch. `.custom` is excluded because it is
    /// deliberately ambiguous (typed numbers equal to a standard size read as
    /// that size; the pane holds the "user asked for Custom" bit).
    @MainActor
    @Test func everyResolutionChoiceRoundTripsAndSurvivesRelaunch() {
        withSeededDefaults(["qualityPreset": "matchDisplay"]) {
            let model = AppModel()
            for choice in ResolutionChoice.all where choice != .custom {
                model.apply(choice)
                #expect(model.resolutionChoice == choice)
                #expect(AppModel().resolutionChoice == choice)
            }
            // Custom keeps the numbers on record rather than re-deriving them.
            model.apply(.standard(.qhd1440))
            // Spelled out: both choice enums have a `.custom`.
            model.apply(ResolutionChoice.custom)
            #expect(model.qualityPreset == .custom)
            #expect(model.customWidth == 2560)
            #expect(AppModel().customWidth == 2560)
        }
    }

    /// Same for the frame-rate picker.
    @MainActor
    @Test func everyFrameRateChoiceRoundTripsAndSurvivesRelaunch() {
        withSeededDefaults(["qualityPreset": "matchDisplay"]) {
            let model = AppModel()
            for choice in FrameRateChoice.all where choice != .custom {
                model.apply(choice)
                #expect(model.frameRateChoice == choice)
                #expect(AppModel().frameRateChoice == choice)
            }
        }
    }

    /// Changing the resolution must not disturb a frame rate the user picked.
    @MainActor
    @Test func pickingAResolutionLeavesTheChosenFrameRateAlone() {
        withSeededDefaults(["qualityPreset": "matchDisplay"]) {
            let model = AppModel()
            model.apply(.fixed(60))
            model.apply(.standard(.uhd4K))
            #expect(model.customFPS == 60)
            #expect(model.customWidth == 3840)
        }
    }

    /// HDR used to be forced on under the panel presets and only asked under
    /// Custom. Widening it to every preset must not silently drop HDR for an
    /// install that had turned it off under Custom and gone back.
    @MainActor
    @Test func widenedHDRCarriesPanelPresetUsersForward() {
        withSeededDefaults(["qualityPreset": "matchDisplay", "customHDR": false]) {
            UserDefaults.standard.removeObject(forKey: "didWidenHDRToAllPresets")
            #expect(AppModel().customHDR == true)
        }
        // Someone actually streaming Custom without HDR keeps it off.
        withSeededDefaults(["qualityPreset": "custom", "customHDR": false]) {
            UserDefaults.standard.removeObject(forKey: "didWidenHDRToAllPresets")
            #expect(AppModel().customHDR == false)
        }
    }

    /// Dropping "Match display" must not change anyone's stream. An install
    /// that had a typed rate keeps it verbatim; one that was matching the
    /// display adopts that panel's refresh as a fixed number, and the old key
    /// is cleared so the conversion can never re-fire over a later choice.
    @MainActor
    @Test func matchDisplayInstallsConvertToAFixedRateOnce() {
        withSeededDefaults(["qualityPreset": "custom", "customFPS": 90,
                            "frameRateMatchesDisplay": false]) {
            UserDefaults.standard.removeObject(forKey: "didDropMatchDisplayFrameRate")
            let model = AppModel()
            #expect(model.customFPS == 90)
            #expect(UserDefaults.standard.object(forKey: "frameRateMatchesDisplay") == nil)
        }
        withSeededDefaults(["qualityPreset": "matchDisplay", "customFPS": 30,
                            "frameRateMatchesDisplay": true]) {
            UserDefaults.standard.removeObject(forKey: "didDropMatchDisplayFrameRate")
            let model = AppModel()
            // Whatever this machine's panel reports - never the stale 30.
            #expect(model.customFPS == FrameRateChoice.migratedRate(
                displayHz: model.currentDisplayMaxHz))
            #expect(UserDefaults.standard.object(forKey: "frameRateMatchesDisplay") == nil)
        }
        // Key absent + a panel preset means the install was matching the
        // display back when the flag defaulted that way.
        withSeededDefaults(["qualityPreset": "matchDisplay", "customFPS": 30]) {
            UserDefaults.standard.removeObject(forKey: "frameRateMatchesDisplay")
            UserDefaults.standard.removeObject(forKey: "didDropMatchDisplayFrameRate")
            #expect(AppModel().customFPS != 30)
        }

        // And it is genuinely ONE shot: a second launch leaves a later choice
        // alone rather than re-stamping the panel rate over it.
        withSeededDefaults(["qualityPreset": "matchDisplay", "customFPS": 30]) {
            UserDefaults.standard.removeObject(forKey: "didDropMatchDisplayFrameRate")
            _ = AppModel()
            UserDefaults.standard.set(30, forKey: "customFPS")
            #expect(AppModel().customFPS == 30)
        }
    }
}
