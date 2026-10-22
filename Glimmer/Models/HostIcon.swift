import Foundation

/// A presentation choice, not an OS fingerprint. GameStream's server-info
/// response does not identify the host's operating system or Linux distro.
enum HostIcon: String, CaseIterable, Identifiable {
    case automatic, computer, windows, macOS, bazzite, steamOS, nobara, cachyOS
    case chimeraOS, garuda, arch, fedora, ubuntu, kubuntu, mint, popOS, debian
    case openSUSE, manjaro, endeavourOS, nixOS, gentoo, linux

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic (server name)"
        case .computer: "Computer"
        case .windows: "Windows"
        case .macOS: "macOS"
        case .bazzite: "Bazzite"
        case .steamOS: "SteamOS"
        case .nobara: "Nobara"
        case .cachyOS: "CachyOS"
        case .chimeraOS: "ChimeraOS"
        case .garuda: "Garuda Linux"
        case .arch: "Arch Linux"
        case .fedora: "Fedora"
        case .ubuntu: "Ubuntu"
        case .kubuntu: "Kubuntu"
        case .mint: "Linux Mint"
        case .popOS: "Pop!_OS"
        case .debian: "Debian"
        case .openSUSE: "openSUSE"
        case .manjaro: "Manjaro"
        case .endeavourOS: "EndeavourOS"
        case .nixOS: "NixOS"
        case .gentoo: "Gentoo"
        case .linux: "Linux (generic)"
        }
    }

    var assetName: String? {
        switch self {
        case .automatic, .computer, .macOS: nil
        default: "HostLogo-\(rawValue)"
        }
    }

    /// Brand-coloured discs keep the different silhouettes on the same
    /// visual footing as the reference app's account avatars.
    var backgroundRGB: UInt32 {
        switch self {
        case .automatic, .computer: 0x397CC2
        case .windows: 0x0078D4
        case .macOS: 0x62666C
        case .bazzite: 0x5939A4
        case .steamOS: 0x193C58
        case .nobara: 0x292D37
        case .cachyOS: 0x008E73
        case .chimeraOS: 0x291B32
        case .garuda: 0x8839EF
        case .arch: 0x1793D1
        case .fedora: 0x3978B6
        case .ubuntu: 0xE95420
        case .kubuntu: 0x0079C1
        case .mint: 0x598D32
        case .popOS: 0x328C98
        case .debian: 0xA81D33
        case .openSUSE: 0x538E28
        case .manjaro: 0x16846C
        case .endeavourOS: 0x6554B7
        case .nixOS: 0x5277C3
        case .gentoo: 0x54487A
        case .linux: 0xFCC624
        }
    }

    func resolved(serverName: String) -> Self {
        self == .automatic ? Self.suggested(for: serverName) : self
    }

    /// Match complete hostname tokens, never an IP, a domain name, the
    /// editable display name, or a substring such as "arch" in "archer".
    static func suggested(for serverName: String) -> Self {
        let hostname = serverName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        let tokens = hostname.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let words = Set(tokens)
        var matches = allCases.filter { icon in
            icon != .linux && !Set(icon.aliases).isDisjoint(with: words)
        }
        // These conventional names contain a separator inside the OS name.
        if tokens.starts(with: ["pop", "os"]), !matches.contains(.popOS) { matches.append(.popOS) }
        if tokens.starts(with: ["linux", "mint"]), !matches.contains(.mint) { matches.append(.mint) }
        if tokens.starts(with: ["steam", "deck"]), !matches.contains(.steamOS) { matches.append(.steamOS) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty, words.contains("linux") { return .linux }
        return .computer
    }

    private var aliases: [String] {
        switch self {
        case .automatic, .computer: []
        case .windows: ["windows", "win10", "win11"]
        case .macOS: ["macos", "osx", "mac"]
        case .bazzite: ["bazzite"]
        case .steamOS: ["steamos", "steamdeck"]
        case .nobara: ["nobara"]
        case .cachyOS: ["cachyos", "cachy"]
        case .chimeraOS: ["chimeraos"]
        case .garuda: ["garuda"]
        case .arch: ["arch", "archlinux"]
        case .fedora: ["fedora", "silverblue", "kinoite"]
        case .ubuntu: ["ubuntu"]
        case .kubuntu: ["kubuntu"]
        case .mint: ["linuxmint"]
        case .popOS: ["popos"]
        case .debian: ["debian"]
        case .openSUSE: ["opensuse"]
        case .manjaro: ["manjaro"]
        case .endeavourOS: ["endeavouros"]
        case .nixOS: ["nixos"]
        case .gentoo: ["gentoo"]
        case .linux: ["linux"]
        }
    }

    static func storageKey(for hostID: String) -> String { "glimmer.hostIcon.\(hostID)" }

    static func forget(hostID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(for: hostID))
    }
}
