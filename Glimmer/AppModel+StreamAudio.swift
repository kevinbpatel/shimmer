//
//  AppModel+StreamAudio.swift
//
//  The stream's own volume + mute: the level ladder the menu-bar dropdown
//  offers, and the plumbing that pushes a change onto the live session's audio
//  player node. The stored properties live in AppModel.swift (they have to);
//  everything about WHEN a volume applies lives here, and everything about HOW
//  it applies lives in AudioDecoder+Engine.swift.
//
//  Why a ladder and not a slider: the menu-bar dropdown is a `.menu`-style
//  MenuBarExtra, which is a real system NSMenu. NSMenu has no slider item - only
//  the Sound menu extra gets one, via a private view-backed item - so a SwiftUI
//  `Slider` there renders as nothing at all. Discrete 10% steps plus
//  Louder/Quieter is the native-looking shape that actually draws.
//

import Foundation

extension AppModel {
    /// Step for the menu bar's Louder / Quieter items, and the spacing of the
    /// Volume submenu's ladder. 10% is fine enough to dial a stream in against
    /// Discord/music and coarse enough that the whole range is one short menu.
    nonisolated static let streamVolumeStep = 0.1

    /// The quietest rung the ladder offers. Silence belongs to Mute alone: a 0%
    /// rung makes a dead state the user can't read their way out of - the menu
    /// still says "Mute", and muting then unmuting lands back on silence. With a
    /// floor here, unmuting always restores something audible.
    nonisolated static let minStreamVolume = 0.1

    /// The Volume submenu's ladder, loudest first (the way the Sound menu and
    /// every other descending macOS level list reads), down to the floor.
    nonisolated static let streamVolumeLevels: [Double] =
        stride(from: 10, through: 1, by: -1).map { Double($0) / 10.0 }

    /// Seed for `streamVolume`. `UserDefaults.double(forKey:)` answers 0 for an
    /// absent key, which would start every fresh install silent - so probe for
    /// the object first and only then trust the number.
    nonisolated static func loadStreamVolume() -> Double {
        guard let stored = UserDefaults.standard.object(forKey: "streamVolume") as? Double else {
            return 1.0
        }
        return min(max(stored, minStreamVolume), 1)
    }

    /// What the player node should be at right now. Mute wins over the level,
    /// and the level survives underneath it so unmuting restores what the user
    /// had rather than snapping to full.
    var effectiveStreamVolume: Double { streamMuted ? 0 : streamVolume }

    /// Whole-percent form for the menu title ("Volume: 70%").
    var streamVolumePercent: Int { Int((streamVolume * 100).rounded()) }

    /// Push the current volume onto the live session. A no-op when nothing is
    /// streaming, and that's fine: `AudioDecoder` re-reads the stored value
    /// every time it builds its graph, and `startStream` pushes it once more at
    /// session start, so the next stream opens at the right level either way.
    func applyStreamVolume() {
        nativeSession?.audioDecoder.setOutputVolume(Float(effectiveStreamVolume))
    }

    /// Menu-bar Louder / Quieter. Raising from silence also unmutes: a user who
    /// asks for more volume means it, and leaving the mute latched would make
    /// the item look broken.
    func stepStreamVolume(by delta: Double) {
        let target = min(max(streamVolume + delta, Self.minStreamVolume), 1)
        // Snap back onto the step grid so repeated presses can't drift on
        // floating-point error (0.7000000000000001 renders as 70% but fails the
        // checkmark's equality test against the ladder's 0.7).
        streamVolume = (target / Self.streamVolumeStep).rounded() * Self.streamVolumeStep
        if delta > 0, streamMuted { streamMuted = false }
    }

    /// Jump straight to a rung of the ladder. Picking one unmutes: every rung is
    /// audible by construction, so choosing a level while muted can only mean
    /// "play at this level".
    func setStreamVolume(_ level: Double) {
        streamVolume = min(max(level, Self.minStreamVolume), 1)
        if streamMuted { streamMuted = false }
    }

    func toggleStreamMute() { streamMuted.toggle() }

    /// True when `level` is the rung currently selected, for the submenu's
    /// checkmark. Compared with a tolerance because the ladder is built by
    /// division and the stored value round-trips through UserDefaults.
    func isSelectedStreamVolume(_ level: Double) -> Bool {
        abs(level - streamVolume) < Self.streamVolumeStep / 2
    }
}
