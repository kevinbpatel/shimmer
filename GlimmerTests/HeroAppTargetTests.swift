//
//  HeroAppTargetTests.swift
//
//  The menu bar's stream button names an app, draws that app's icon, and
//  launches it. All three read `resolveHeroApp`, and the reason they have to
//  is the bug this replaced: the label was built from `defaultAppName` while
//  the action resolved the last-played target, so the item could say
//  "Stream Desktop" and start Steam.
//
//  What's pinned here is the LOOKUP, which is the part that can silently
//  disagree. The name → glyph mapping is AppSymbolTests' job.
//

import Testing
@testable import Glimmer

struct HeroAppTargetTests {

    private static func app(_ name: String, id: Int = 0) -> LibraryApp {
        LibraryApp(id: id, name: name, hdr: false, hidden: false)
    }

    private static let library = [
        app("Desktop", id: 1), app("Low Res Desktop", id: 2),
        app("Steam Big Picture", id: 3), app("Elden Ring", id: 4),
    ]

    // MARK: The lookup

    @Test func theLastPlayedAppWins() {
        for name in ["Steam Big Picture", "Low Res Desktop", "Elden Ring", "Desktop"] {
            #expect(AppModel.resolveHeroApp(in: Self.library, named: name)?.name == name)
        }
    }

    /// A name that isn't in the applist any more - the game was uninstalled on
    /// the host, or the list hasn't been refreshed since pairing.
    @Test func anUnknownNameFallsBackToDesktop() {
        #expect(AppModel.resolveHeroApp(in: Self.library, named: "Half-Life 3")?.name == "Desktop")
    }

    /// Some hosts publish no entry called exactly "Desktop".
    @Test func withoutADesktopEntryTheFirstAppIsUsed() {
        let apps = [Self.app("Steam Big Picture", id: 3), Self.app("Elden Ring", id: 4)]
        #expect(AppModel.resolveHeroApp(in: apps, named: "Half-Life 3")?.name == "Steam Big Picture")
    }

    @Test func anEmptyLibraryResolvesToNothing() {
        #expect(AppModel.resolveHeroApp(in: [], named: "Desktop") == nil)
    }

    // MARK: The thing the lookup is for

    /// The whole point: whatever the button says, the icon beside it belongs to
    /// the SAME app, because both come out of this one call. A regression here
    /// is a Steam mark over the word "Desktop".
    @Test func theResolvedAppCarriesItsOwnGlyph() {
        let steam = AppModel.resolveHeroApp(in: Self.library, named: "Steam Big Picture")
        #expect(steam?.glyph == .asset("SteamGlyph"))
        let desktop = AppModel.resolveHeroApp(in: Self.library, named: "Low Res Desktop")
        #expect(desktop?.glyph == .symbol("desktopcomputer"))
        let game = AppModel.resolveHeroApp(in: Self.library, named: "Elden Ring")
        #expect(game?.glyph == .symbol("gamecontroller.fill"))
    }

    /// A name that fell back resolves to a DIFFERENT app, and the label has to
    /// follow the resolution rather than the request - otherwise the button
    /// says "Stream Half-Life 3" and launches the desktop.
    @Test func theLabelFollowsTheResolutionNotTheRequest() {
        let resolved = AppModel.resolveHeroApp(in: Self.library, named: "Half-Life 3")
        #expect(resolved?.name != "Half-Life 3")
        #expect(resolved?.name == "Desktop")
    }
}
