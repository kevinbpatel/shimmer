import AppKit
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct HostIconTests {
    @Test func recognizableNamesSuggestLogosWithoutMatchingFragmentsOrDomains() {
        #expect(HostIcon.suggested(for: "bazzite") == .bazzite)
        #expect(HostIcon.suggested(for: "BAZZITE-Gaming.local") == .bazzite)
        #expect(HostIcon.suggested(for: "my-cachyos-pc") == .cachyOS)
        #expect(HostIcon.suggested(for: "steam-deck") == .steamOS)
        #expect(HostIcon.suggested(for: "Pop!_OS") == .popOS)
        #expect(HostIcon.suggested(for: "Linux Mint") == .mint)
        #expect(HostIcon.suggested(for: "windows-gaming") == .windows)
        #expect(HostIcon.suggested(for: "macos-studio") == .macOS)
        #expect(HostIcon.suggested(for: "Mac") == .macOS)
        #expect(HostIcon.suggested(for: "archer") == .computer)
        #expect(HostIcon.suggested(for: "my-mint-green-pc") == .computer)
        #expect(HostIcon.suggested(for: "desktop.ubuntu.example") == .computer)
        #expect(HostIcon.suggested(for: "192.168.50.44") == .computer)
        #expect(HostIcon.suggested(for: "gaming-pc") == .computer)
        #expect(HostIcon.suggested(for: "ubuntu-windows") == .computer)
        #expect(HostIcon.suggested(for: "steam-pc") == .computer)
        #expect(HostIcon.suggested(for: "pop-osx-pc") == .macOS)
    }

    @Test func advertisedAppleAndWindowsNamesSuggestTheirSystemIcons() {
        for name in ["Kevin’s Mac mini", "Kevins-MacBook-Pro", "MacBookAir", "iMac", "MacStudio"] {
            #expect(HostIcon.suggested(for: name) == .macOS)
        }
        #expect(HostIcon.suggested(for: "Windows11-Gaming") == .windows)
        #expect(HostIcon.suggested(for: "Windows10") == .windows)
        #expect(HostIcon.suggested(for: "macaroni") == .computer)
        #expect(HostIcon.suggested(for: "windowseat") == .computer)
    }

    @Test func explicitChoiceOverridesNamesAndAutomaticUsesTheOriginalServerName() {
        #expect(HostIcon.windows.resolved(serverName: "bazzite") == .windows)
        #expect(HostIcon.computer.resolved(serverName: "bazzite") == .computer)
        #expect(HostIcon.automatic.resolved(serverName: "bazzite") == .bazzite)
    }

    @Test func forgettingOneHostLeavesOtherPreferencesAlone() throws {
        let suite = "HostIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HostIcon.bazzite.rawValue, forKey: HostIcon.storageKey(for: "first"))
        defaults.set(HostIcon.windows.rawValue, forKey: HostIcon.storageKey(for: "second"))
        HostIcon.forget(hostID: "first", defaults: defaults)
        #expect(defaults.object(forKey: HostIcon.storageKey(for: "first")) == nil)
        #expect(defaults.string(forKey: HostIcon.storageKey(for: "second")) == HostIcon.windows.rawValue)
    }

    @Test func everyBundledLogoLoads() {
        for icon in HostIcon.allCases {
            if let name = icon.assetName {
                #expect(NSImage(named: name) != nil, "Missing host logo: \(icon.title)")
            }
        }
        #expect(NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) != nil)
    }
}
