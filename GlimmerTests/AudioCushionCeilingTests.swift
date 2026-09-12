//
//  AudioCushionCeilingTests.swift
//
//  The "Prefer low audio latency" ceiling on the adaptive playout cushion:
//  it lowers the link-aware cap, never raises it, and is absent by default.
//  Pure - no engine.
//

import Testing
@testable import Glimmer

struct AudioCushionCeilingTests {

    @Test func noCeilingLeavesTheLinkCapsAlone() {
        #expect(AudioDecoder.cushionCapMs(forLink: "wired", userCeilingMs: nil) == AudioDecoder.playoutCushionMaxMs)
        #expect(AudioDecoder.cushionCapMs(forLink: "wifi", userCeilingMs: nil) == AudioDecoder.playoutCushionMaxMsWifi)
        #expect(AudioDecoder.cushionCapMs(forLink: "tunnel", userCeilingMs: nil) == AudioDecoder.playoutCushionMaxMsTunnel)
    }

    @Test func ceilingLowersEveryLinkCap() {
        let ceiling = AudioDecoder.lowLatencyCushionCeilingMs
        for link in ["wired", "wifi", "tunnel", "unknown"] {
            #expect(AudioDecoder.cushionCapMs(forLink: link, userCeilingMs: ceiling) == ceiling)
        }
    }

    @Test func ceilingNeverRaisesACap() {
        #expect(AudioDecoder.cushionCapMs(forLink: "wired", userCeilingMs: 1000) == AudioDecoder.playoutCushionMaxMs)
    }

    @Test func theCeilingSitsAboveTheBaseCushion() {
        // A ceiling below the pre-roll base would make the ratchet fight the seed.
        #expect(AudioDecoder.lowLatencyCushionCeilingMs > AudioDecoder.playoutCushionBaseMs)
    }
}
