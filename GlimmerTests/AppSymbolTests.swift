//
//  AppSymbolTests.swift
//
//  The library draws each app as an SF Symbol chosen from its name. A symbol
//  that doesn't exist on the running OS renders as nothing at all - a blank
//  tile, with no error - so every name the mapping can return is asserted to
//  resolve here. This is the test that catches a typo, or a symbol that needs
//  a newer macOS than we target.
//

import AppKit
import Testing
@testable import Glimmer

struct AppSymbolTests {

    /// Names chosen to hit every branch of `LibraryApp.symbol(forName:)`,
    /// plus a few real-world spellings.
    private static let probes = [
        "Desktop", "Low Res Desktop", "Steam", "Steam Big Picture", "SteamVR",
        "Xbox Game Pass", "PlayStation Remote Play", "Epic Games Launcher",
        "GOG Galaxy", "Battle.net", "Ubisoft Connect", "EA App",
        "RetroArch", "Dolphin Emulator", "Plex", "Netflix", "YouTube",
        "Spotify", "Apple Music", "Lightroom", "Google Chrome", "Firefox",
        "Microsoft Edge", "Discord", "Slack", "OBS Studio",
        "Visual Studio Code", "Blender", "Krita", "Photoshop",
        "Microsoft Word", "Excel", "File Explorer", "Control Panel",
        "Terminal", "PowerShell", "Remote Desktop", "Virtual Desktop",
        "Cyberpunk 2077", "Elden Ring", "", "   ", "🎮",
    ]

    @MainActor
    @Test func everySymbolTheMappingCanReturnExistsOnThisOS() {
        var missing: [String] = []
        for name in Self.probes {
            let symbol = LibraryApp.symbol(forName: name)
            if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                missing.append("\(name) -> \(symbol)")
            }
        }
        #expect(missing.isEmpty, "SF Symbols missing on this macOS: \(missing)")
    }

    @Test func theMostSpecificNameWins() {
        // Big Picture before Steam, Low Res before Desktop - otherwise the
        // broader branch would swallow them.
        #expect(LibraryApp.symbol(forName: "Steam Big Picture") == "gamecontroller.fill")
        #expect(LibraryApp.symbol(forName: "Steam") == "gamecontroller.fill")
        // A low-res desktop must not share the full desktop's glyph.
        #expect(LibraryApp.symbol(forName: "Low Res Desktop") == "display")
        #expect(LibraryApp.symbol(forName: "Desktop") == "desktopcomputer")
        #expect(LibraryApp.symbol(forName: "Low Res Desktop")
                != LibraryApp.symbol(forName: "Desktop"))
        #expect(LibraryApp.symbol(forName: "SteamVR") == "visionpro")
    }

    @Test func anUnknownNameFallsBackToAGame() {
        // This is a game-streaming client; an unrecognised app is most likely
        // a game, not a generic "app" placeholder.
        #expect(LibraryApp.symbol(forName: "Elden Ring") == "gamecontroller.fill")
        #expect(LibraryApp.symbol(forName: "") == "gamecontroller.fill")
    }

    @Test func theIconHueIsStableAndInRange() {
        let a = LibraryApp(id: 1, name: "Steam", hdr: false, hidden: false)
        let b = LibraryApp(id: 2, name: "Steam", hdr: false, hidden: false)
        let c = LibraryApp(id: 3, name: "Desktop", hdr: false, hidden: false)
        #expect(a.iconHue == b.iconHue)
        #expect(a.iconHue != c.iconHue)
        #expect((0...1).contains(a.iconHue))
        #expect((0...1).contains(c.iconHue))
    }
}
