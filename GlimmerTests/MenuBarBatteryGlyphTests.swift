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
    /// baked in, since nothing can be overlaid onto it later.
    @Test func chargingSelectsDifferentArt() {
        for percent in [0, 30, 70, 100] {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: true)
                    != MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false))
        }
    }

    // MARK: The rounding

    @Test func exactLevelsMapToThemselves() {
        for level in stride(from: 0, through: 100, by: MenuBarBatteryGlyph.step) {
            #expect(MenuBarBatteryGlyph.assetName(forPercent: level, charging: false)
                    == "ControllerBattery\(level)")
        }
    }

    @Test func readingsRoundToTheNearestLevel() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 4, charging: false) == "ControllerBattery0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 5, charging: false) == "ControllerBattery10")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 74, charging: false) == "ControllerBattery70")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 75, charging: false) == "ControllerBattery80")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 96, charging: true)
                == "ControllerBattery100Charging")
    }

    @Test func outOfRangeReadingsClampRatherThanWrap() {
        #expect(MenuBarBatteryGlyph.assetName(forPercent: -90, charging: false) == "ControllerBattery0")
        #expect(MenuBarBatteryGlyph.assetName(forPercent: 900, charging: false) == "ControllerBattery100")
    }

    /// A dying pad must never be drawn fuller than it is - that's the one
    /// direction of error that matters.
    @Test func theGlyphNeverOverstatesByMoreThanHalfAStep() {
        for percent in 0...100 {
            let shown = Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery", with: "")) ?? -1
            #expect(shown - percent <= MenuBarBatteryGlyph.step / 2, "\(percent)% shown as \(shown)%")
        }
    }

    @Test func theMappingIsMonotonic() {
        let shown = (0...100).map { percent -> Int in
            Int(MenuBarBatteryGlyph.assetName(forPercent: percent, charging: false)
                .replacingOccurrences(of: "ControllerBattery", with: "")) ?? -1
        }
        #expect(shown == shown.sorted())
    }
}
