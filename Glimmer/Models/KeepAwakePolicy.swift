//
//  KeepAwakePolicy.swift
//
//  Whether a live stream keeps the Mac and its display from sleeping. A game
//  stream is video the user is watching, but to the OS there is no local
//  input - a controller doesn't reset the idle timer - so without an
//  assertion the screen dims and sleeps minutes into a pad-only session.
//  That was always on; this makes it a choice, because a stream parked in a
//  corner while you read is not a reason to hold the display open all night.
//

import Foundation

public enum KeepAwakePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Hold the assertion for the whole session - every build before this one.
    case always
    /// Hold it only while the stream window is up. Hidden (a Cmd-Tab-away) or
    /// parked in Picture in Picture, the Mac's own sleep rules apply.
    case whileShowing
    /// Never hold it; the Mac sleeps exactly as it would without a stream.
    case never

    public var id: String { rawValue }

    /// A fresh install keeps the Mac awake - the safe stance for a stream
    /// someone is actually playing.
    public static let defaultPolicy: KeepAwakePolicy = .always

    /// UserDefaults key. Registered (never written) with `defaultPolicy` in
    /// GlimmerApp so the raw read agrees with the declared default.
    public static let defaultsKey = "keepAwakePolicy"

    public var displayName: String {
        switch self {
        case .always: return "Always"
        case .whileShowing: return "Only while showing"
        case .never: return "Never"
        }
    }

    /// Resolve a persisted raw value. Absent or unrecognised lands on the
    /// default rather than guessing.
    public static func persisted(rawValue: String?) -> KeepAwakePolicy {
        rawValue.flatMap(KeepAwakePolicy.init(rawValue:)) ?? defaultPolicy
    }

    /// Whether the sleep assertion is held right now, given whether the
    /// stream window is showing (not backgrounded: neither hidden nor in
    /// Picture in Picture). Pure, so the truth table is unit-tested.
    public func holdsSleepAssertion(windowShowing: Bool) -> Bool {
        switch self {
        case .always: return true
        case .whileShowing: return windowShowing
        case .never: return false
        }
    }
}
