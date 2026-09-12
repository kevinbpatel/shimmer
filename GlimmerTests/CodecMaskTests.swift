//
//  CodecMaskTests.swift
//
//  The two places the advertised video-format set is narrowed: the per-host
//  codec cap (right-click → Codec) and the HDR-off strip. Both must remove
//  whole families, not just the Main profiles - the 4:4:4 profiles carry the
//  same codec and bit-depth bits, and a survivor there lets the host pick AV1
//  under "HEVC", or a 10-bit stream with HDR off. Pure.
//

import Testing
@testable import Glimmer

struct CodecMaskTests {

    /// Everything an Apple Silicon Mac advertises: all three codecs, 8- and
    /// 10-bit, 4:2:0 and 4:4:4.
    private let everything: VideoFormats = [
        .h264, .h264YUV444,
        .hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444,
        .av1, .av1Main10, .av1High8_444, .av1High10_444,
    ]

    @Test func hevcCapRemovesEveryAV1Profile() {
        let capped = HostCodecPreference.hevc.apply(to: everything)
        #expect(capped.isDisjoint(with: [.av1, .av1Main10, .av1High8_444, .av1High10_444]))
        // The floor stays: nothing below the cap is touched.
        #expect(capped.isSuperset(of: [.h264, .h264YUV444, .hevc, .hevcMain10, .hevcRext8_444, .hevcRext10_444]))
    }

    @Test func h264CapRemovesEveryHEVCAndAV1Profile() {
        let capped = HostCodecPreference.h264.apply(to: everything)
        #expect(capped == [.h264, .h264YUV444])
    }

    @Test func autoCapChangesNothing() {
        #expect(HostCodecPreference.auto.apply(to: everything) == everything)
    }

    @Test func hdrOffStripsEveryTenBitProfile() {
        let sdr = AppModel.stripTenBit(from: everything)
        #expect(sdr.isDisjoint(with: [.hevcMain10, .hevcRext10_444, .av1Main10, .av1High10_444]))
        #expect(sdr == [.h264, .h264YUV444, .hevc, .hevcRext8_444, .av1, .av1High8_444])
    }

    @Test func masksAgreeWithTheProtocolConstants() {
        // The families are defined by the wire masks, so a new profile bit
        // lands in the right family without anyone remembering to list it.
        #expect(VideoFormats.av1Family.rawValue == StreamProtocol.VIDEO_FORMAT_MASK_AV1)
        #expect(VideoFormats.hevcFamily.rawValue == StreamProtocol.VIDEO_FORMAT_MASK_H265)
        #expect(VideoFormats.tenBit.rawValue == StreamProtocol.VIDEO_FORMAT_MASK_10BIT)
    }
}
