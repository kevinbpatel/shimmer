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

import Foundation
import Observation
import Testing
import os
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

    @Test @MainActor func aLiveStreamKeepsItsAppDespiteAnOlderHostSnapshot() {
        let model = AppModel()
        let host = Host(id: "active-app-regression", name: "Test PC", customName: nil,
                        localAddress: nil, manualAddress: nil, apps: Self.library,
                        lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                        gfeVersion: nil, macAddress: nil)
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id,
                                             state: .streamingApp(name: "Desktop"),
                                             capturedAt: .now)
        let steam = Self.library[2]
        model.activeStreamApp = steam
        model.isStreaming = true
        model.nativeStreamBackgrounded = true

        #expect(model.heroTargetApp == steam)
        #expect(model.heroTargetAppName == "Steam Big Picture")
        #expect(model.heroTargetApp?.glyph == .asset("SteamGlyph"))
        #expect(model.liveStreamRowTitle == "Back to Steam Big Picture")

        // Snapshot expiry and library/host changes cannot rename a live stream.
        model.hostLiveStatus?.capturedAt = .distantPast
        model.selectedHost = nil
        #expect(model.heroTargetApp == steam)
        #expect(model.liveStreamRowTitle == "Back to Steam Big Picture")

        // Once the session ends, the launcher follows the host again.
        model.isStreaming = false
        model.activeStreamApp = nil
        model.selectedHost = host
        model.hostLiveStatus?.capturedAt = .now
        #expect(model.heroTargetApp?.name == "Desktop")
    }

    @Test @MainActor func theLiveAppGlyphObservesSessionIdentityChanges() {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamApp = Self.library[0]
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.heroTargetApp?.glyph
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.activeStreamApp = Self.library[2]
        #expect(changed.withLock { $0 })
        #expect(model.heroTargetApp?.glyph == .asset("SteamGlyph"))
        model.isStreaming = false
    }

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
        #expect(desktop?.glyph == .symbol("display"))
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

    // MARK: Takeover, or just a resume

    /// The regression that made the dialog useless: asking for the app the host
    /// is ALREADY streaming resumes it, so it must not prompt. That's the
    /// commonest path there is - reconnecting after the stream window closed.
    @Test func resumingTheRunningAppIsNotATakeover() {
        #expect(!AppModel.isTakeover(occupant: "Steam Big Picture",
                                     launching: "Steam Big Picture"))
        #expect(!AppModel.isTakeover(occupant: "Desktop", launching: "Desktop"))
    }

    @Test func launchingOverADifferentAppIsATakeover() {
        #expect(AppModel.isTakeover(occupant: "Steam Big Picture", launching: "Desktop"))
        #expect(AppModel.isTakeover(occupant: "Desktop", launching: "Steam Big Picture"))
        // Names are compared exactly - "Low Res Desktop" really is another app.
        #expect(AppModel.isTakeover(occupant: "Desktop", launching: "Low Res Desktop"))
    }

    /// The host's own `currentgame` names the occupant when the poller has no
    /// fresh snapshot (first seconds after launch): idle is nobody, a known id
    /// is that app, an unknown id is still someone's session.
    @Test func occupantResolvesFromTheHostsCurrentGame() {
        let apps = [
            LibraryApp(id: 881448767, name: "Desktop", hdr: true, hidden: false),
            LibraryApp(id: 1093255277, name: "Steam Big Picture", hdr: true, hidden: false),
        ]
        #expect(AppModel.occupantName(currentGameID: 0, apps: apps) == nil)
        #expect(AppModel.occupantName(currentGameID: 1093255277, apps: apps) == "Steam Big Picture")
        #expect(AppModel.occupantName(currentGameID: 424242, apps: apps) == AppModel.unknownOccupantName)
        // And an unknown occupant is a takeover for any app we could launch.
        #expect(AppModel.isTakeover(occupant: AppModel.unknownOccupantName, launching: "Desktop"))
    }

    @Test func anIdleHostIsNeverATakeover() {
        #expect(!AppModel.isTakeover(occupant: nil, launching: "Desktop"))
        #expect(!AppModel.isTakeover(occupant: "", launching: "Desktop"))
    }
}
