//
//  MenuBarBatteryGlyphTests.swift
//
//  The controller battery shown in the menu-bar label. The glyph is a baked
//  asset per level (see MenuBarBatteryGlyph for why it can't be composed at
//  runtime), so the thing worth holding is the mapping: every reading has to
//  name an asset that is ACTUALLY IN THE CATALOG. A name with nothing behind it
//  draws nothing in the menu bar - no error, no fallback, just an icon that
//  quietly isn't there.
//

import AppKit
import GameController
import Testing
@testable import Glimmer

struct MenuBarBatteryGlyphTests {

    // MARK: Every reading resolves to real art

    /// The load-bearing test. Sweeps well past the legal range because both
    /// battery sources can report outside it.
    @Test func everyReadingNamesAnAssetThatExists() {
        for percent in stride(from: -60, through: 160, by: 1) {
            for charging in [false, true] {
                let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging)
                #expect(NSImage(named: name) != nil,
                        "\(percent)% charging=\(charging) -> \(name), which is not in the catalog")
            }
        }
    }

    /// Every pad Steam has a glyph for has its full set: each level, charging,
    /// and the plain glyph for a pad without a battery reading.
    @Test func everyControllerKindHasItsArt() {
        for kind in MenuBarBatteryGlyph.kinds {
            for percent in stride(from: 0, through: 100, by: MenuBarBatteryGlyph.step) {
                for charging in [false, true] {
                    let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging, kind: kind)
                    #expect(NSImage(named: name)?.isTemplate == true, "\(name) missing or not a template")
                }
            }
            let plain = MenuBarBatteryGlyph.glyphName(kind: kind)
            #expect(NSImage(named: plain)?.isTemplate == true, "\(plain) missing or not a template")
        }
        // An unknown kind falls back to the generic pad rather than drawing nothing.
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 50, charging: false, kind: "nope")
                == "ControllerBattery-generic-50")
        #expect(MenuBarBatteryGlyph.glyphName(kind: "nope") == "ControllerGlyph-generic")
    }

    /// GameController's names map to the glyph Steam draws for that pad.
    @Test func controllersMapToSteamsGlyphs() {
        let kind = AppModel.steamControllerKind
        #expect(kind(GCProductCategoryDualSense, "DualSense Wireless Controller") == "ps5")
        #expect(kind(GCProductCategoryDualShock4, "DUALSHOCK 4 Wireless Controller") == "ps4")
        #expect(kind(GCProductCategoryXboxOne, "Xbox Wireless Controller") == "xbox")
        #expect(kind("Switch Pro Controller", "Pro Controller") == "switchpro")
        #expect(kind("Nintendo Switch Joy-Con (L/R)", "Joy-Con (L/R)") == "switchpro")
        #expect(kind(GCProductCategoryHID, "8BitDo Ultimate 2C Wireless") == "8bitdo_ultimate")
        #expect(kind(GCProductCategoryHID, "8BitDo SN30 Pro") == "8bitdo_sn30")
        #expect(kind(GCProductCategoryHID, "8BitDo Pro 2") == "8bitdo_pro")
        #expect(kind(GCProductCategoryHID, "HORIPAD") == "hori")
        #expect(kind(GCProductCategoryHID, "Steam Controller") == "triton")
        #expect(kind(GCProductCategoryMFi, "SteelSeries Nimbus+") == "generic")
        #expect(kind(GCProductCategoryHID, nil) == "generic")
    }

    /// And the art is template art, or the menu bar can't tint it for a dark bar.
    @Test func theArtIsATemplate() {
        for percent in [0, 50, 100] {
            for charging in [false, true] {
                let name = MenuBarBatteryGlyph.assetName(forPercent: percent, charging: charging)
                #expect(NSImage(named: name)?.isTemplate == true, "\(name) is not a template")
            }
        }
    }

    /// Charging is a different asset, not the same one - the bolt has to be
    /// baked in, since nothing can be overlaid onto it later. And it is ONE
    /// asset: the bolt stands in for the level while the pad is plugged in.
    @Test func chargingSelectsOneDifferentAsset() {
        for percent in [0, 30, 70, 100] {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: true)
                    != MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false))
            #expect(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: true)
                    == "ControllerBattery-ps5-Charging")
        }
    }

    // MARK: The rounding

    @Test func exactLevelsMapToThemselves() {
        for level in stride(from: 0, through: 100, by: MenuBarBatteryGlyph.step) {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: level, charging: false)
                    == "ControllerBattery-ps5-\(level)")
        }
    }

    @Test func readingsRoundToTheNearestLevel() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 4, charging: false) == "ControllerBattery-ps5-0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 5, charging: false) == "ControllerBattery-ps5-10")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 74, charging: false) == "ControllerBattery-ps5-70")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 75, charging: false) == "ControllerBattery-ps5-80")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 96, charging: true)
                == "ControllerBattery-ps5-Charging")
    }

    @Test func outOfRangeReadingsClampRatherThanWrap() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: -90, charging: false) == "ControllerBattery-ps5-0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 900, charging: false) == "ControllerBattery-ps5-100")
    }

    /// A dying pad must never be drawn fuller than it is - that's the one
    /// direction of error that matters.
    @Test func theGlyphNeverOverstatesByMoreThanHalfAStep() {
        for percent in 0...100 {
            let shown = Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery-ps5-", with: "")) ?? -1
            #expect(shown - percent <= MenuBarBatteryGlyph.step / 2, "\(percent)% shown as \(shown)%")
        }
    }

    @Test func theMappingIsMonotonic() {
        let shown = (0...100).map { percent -> Int in
            Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery-ps5-", with: "")) ?? -1
        }
        #expect(shown == shown.sorted())
    }
}

struct MenuBarVisibilityTests {
    @Test func hidingTheMenuBarAlwaysKeepsTheAppInTheDock() {
        for mainOpen in [false, true] {
            for streaming in [false, true] {
                #expect(AppDelegate.activationPolicy(mainOpen: mainOpen, streaming: streaming,
                                                     menuBarVisible: false) == .regular)
            }
        }
    }

    @Test func menuBarOnlyModeStillKeepsLiveStreamsAndWindowsInTheDock() {
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: true) == .accessory)
        #expect(AppDelegate.activationPolicy(mainOpen: true, streaming: false,
                                             menuBarVisible: true) == .regular)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: true,
                                             menuBarVisible: true) == .regular)
    }

    @Test func hidingTheMenuBarSurvivesRelaunch() throws {
        let name = "shimmer-menu-bar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MenuBarPreferences.isVisible(in: defaults))
        defaults.set(false, forKey: MenuBarPreferences.visibilityKey)
        let reloaded = try #require(UserDefaults(suiteName: name))
        #expect(!MenuBarPreferences.isVisible(in: reloaded))
    }

    @Test func idleHasNoStatusItemAndKeepsDockAccess() {
        let idle = MenuBarPresentation(warning: false, controller: nil, appGlyph: nil)
        #expect(idle == nil)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: idle != nil) == .regular)
    }

    @Test func steamStatusReturnsAndDisappearsWithoutAFallback() {
        let steam = MenuBarPresentation(warning: false, controller: nil,
                                        appGlyph: .asset("SteamGlyph"))
        #expect(steam?.glyph == .asset("SteamGlyph"))
        #expect(steam?.title == "")
        #expect(steam?.assetHeight == 15)
        #expect(AppDelegate.activationPolicy(mainOpen: false, streaming: false,
                                             menuBarVisible: steam != nil) == .accessory)
        let ended = MenuBarPresentation(warning: false, controller: nil, appGlyph: nil)
        #expect(ended == nil)
    }

    @Test func warningsStillTakePrecedenceOverControllerAndAppStatus() {
        let warning = MenuBarPresentation(warning: true, controller: ("xbox", (75, false)),
                                          appGlyph: .asset("SteamGlyph"))
        #expect(warning?.glyph == .symbol("exclamationmark.triangle.fill"))
        #expect(warning?.title == "")
    }

    @Test func controllerStatusShowsThatPadsGlyphAndBattery() {
        let xbox = MenuBarPresentation(warning: false, controller: ("xbox", (75, false)),
                                       appGlyph: .asset("SteamGlyph"))
        #expect(xbox?.glyph == .asset("ControllerBattery-xbox-80"))
        #expect(xbox?.title == "")
        let charging = MenuBarPresentation(warning: false, controller: ("ps5", (75, true)),
                                           appGlyph: .asset("SteamGlyph"))
        #expect(charging?.glyph == .asset("ControllerBattery-ps5-Charging"))
        // A pad with no battery reading still names itself, without a battery.
        let noBattery = MenuBarPresentation(warning: false, controller: ("switchpro", nil),
                                            appGlyph: .asset("SteamGlyph"))
        #expect(noBattery?.glyph == .asset("ControllerGlyph-switchpro"))
    }
}
