//
//  StreamChoices.swift
//
//  The value types behind the Stream pane's pickers: the standard resolutions,
//  the resolution / frame-rate choices the pickers bind to (a view of the
//  persisted preset + custom numbers, not a fourth store), and the stepped
//  bitrate scale. Pure values so the rules are unit-testable
//  (GlimmerTests/StreamChoicesTests.swift).
//

import Foundation

/// The standard sizes the Resolution picker offers between "Match display"
/// and "Custom…".
enum CommonResolution: CaseIterable, Hashable {
    case hd720, hd1080, qhd1440, uhd4K

    var width: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .qhd1440: return 2560
        case .uhd4K: return 3840
        }
    }
    var height: Int {
        switch self {
        case .hd720: return 720
        case .hd1080: return 1080
        case .qhd1440: return 1440
        case .uhd4K: return 2160
        }
    }
    var shortLabel: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .uhd4K: return "2160p"
        }
    }

    /// The standard size with exactly these dimensions, if any.
    static func matching(width: Int, height: Int) -> CommonResolution? {
        allCases.first { $0.width == width && $0.height == height }
    }
}

/// What the Resolution picker shows selected. Derived from the persisted
/// preset and Custom dimensions; `custom` is also what a Custom preset with
/// non-standard numbers reads as.
enum ResolutionChoice: Hashable {
    case matchDisplay
    case hidpi
    case standard(CommonResolution)
    case custom

    /// Every row the picker lists, in order.
    static let all: [ResolutionChoice] =
        [.matchDisplay, .hidpi] + CommonResolution.allCases.map { .standard($0) } + [.custom]

    /// The choice a (preset, width, height) triple reads as.
    static func from(preset: QualityPreset, customWidth: Int, customHeight: Int) -> ResolutionChoice {
        switch preset {
        case .matchDisplay: return .matchDisplay
        case .hidpi: return .hidpi
        case .custom:
            if let std = CommonResolution.matching(width: customWidth, height: customHeight) {
                return .standard(std)
            }
            return .custom
        }
    }
}

/// The Frame rate picker's rows. `matchDisplay` is the panel's refresh;
/// `custom` reveals a field.
enum FrameRateChoice: Hashable {
    case matchDisplay
    case fixed(Int)
    case custom

    static let standardRates = [30, 60, 90, 120, 144, 165, 240]
    static let all: [FrameRateChoice] = [.matchDisplay] + standardRates.map { .fixed($0) } + [.custom]

    static func from(matchesDisplay: Bool, customFPS: Int) -> FrameRateChoice {
        if matchesDisplay { return .matchDisplay }
        return standardRates.contains(customFPS) ? .fixed(customFPS) : .custom
    }
}

/// The bitrate slider's stops, in Mbps. Dense where streams actually live,
/// sparse up top; the floor is the engine's 5 Mbps minimum.
enum BitrateScale {
    static let stepsMbps = [5, 6, 7, 8, 9, 10, 12, 15, 18, 20, 25, 30, 35, 40, 45, 50,
                            60, 70, 80, 90, 100, 120, 150, 200, 250, 300]

    /// The slider index whose stop is nearest `mbps`.
    static func nearestIndex(toMbps mbps: Int) -> Int {
        var best = 0
        for (i, step) in stepsMbps.enumerated() where abs(step - mbps) < abs(stepsMbps[best] - mbps) {
            best = i
        }
        return best
    }
}

extension StreamSizeBounds {
    static let bitrateMbps = 5...300
    static func clampBitrateMbps(_ value: Int) -> Int {
        min(max(value, bitrateMbps.lowerBound), bitrateMbps.upperBound)
    }
}

/// The pure resolution rules `persistQualitySettings()` applies, kept free of
/// AppKit so they can be tested directly.
enum QualityResolution {

    /// The refresh a stream asks for. Window mode caps at the panel (it can't
    /// present more); full screen sends the choice verbatim.
    static func frameRate(matchesDisplay: Bool, customFPS: Int, displayHz: Int, windowed: Bool) -> Int {
        if matchesDisplay { return displayHz > 0 ? displayHz : StreamDisplayMode.fallbackDisplayMaxHz }
        return windowed
            ? StreamDisplayMode.windowedRefresh(customFPS: customFPS, displayMaxHz: displayHz)
            : StreamSizeBounds.clampFPS(customFPS)
    }

    /// The bitrate in kbps: the recommendation, or the user's Mbps.
    static func bitrateKbps(auto: Bool, manualMbps: Int, recommendedKbps: Int) -> Int {
        auto ? recommendedKbps : StreamSizeBounds.clampBitrateMbps(manualMbps) * 1000
    }
}
