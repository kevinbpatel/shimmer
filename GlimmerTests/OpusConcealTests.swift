//
//  OpusConcealTests.swift
//
//  A packet libopus rejects is concealed like a lost one, so playback stays
//  continuous. Real 5 ms CELT packets at Sunshine's settings, with a distinct
//  -12 dBFS tone per channel (upstream Glimmer's OpusDecoderTests fixtures).
//

import Foundation
import Testing
@testable import Glimmer

struct OpusConcealTests {

    private static let stereo = [
        "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58abc93cb740be2bcd584efccd910bf0cff90084",
        "ecc8b89010be17d51a2b34d6852b3ac4d7c33ace08a21eff5aae3eacff7a34b6cea490b94b28ab226da7e91382d7128dc6f75c34000febc11f8a4b13",
        "ecc85e2a7260a98bd240544742674e73cd84b9044ca02a89b1192dcead05793df85afd62dd245bb923c409023199c4d690ba5136aaff474cc44d5312",
        "ecc8a90053eb7363cf9cb521719ab8d1788db26fb0e031265ccd726e45328df4bc90fe98addf0cedd7194fbba2b8b569425c90fb53d0b5d2514d0712",
        "ecc839e66ceabdc6e046c54aca71bbc4d5f381392fdbfc66cb1c45609162df8849385700a2c44561eb939851a40b578a91696969e9450b0fcddf6b12"
    ]

    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// Each packet's frames out and per-channel RMS, through the decode path's
    /// conceal-on-failure step, plus whether it concealed a rejected packet.
    private static func run(_ packets: [String]) -> [(frames: Int32, rms: [Float], concealed: Bool)]? {
        var err: Int32 = 0
        let mapping: [UInt8] = [0, 1]
        guard let decoder = opus_multistream_decoder_create(48_000, 2, 1, 1, mapping, &err),
              err == OPUS_OK else { return nil }
        defer { opus_multistream_decoder_destroy(decoder) }
        var pcm = [Float](repeating: 0, count: 240 * 2)
        return packets.map { hex in
            let packet = bytes(hex)
            let (frames, rejected) = packet.withUnsafeBufferPointer { input in
                pcm.withUnsafeMutableBufferPointer { out in
                    AudioDecoder.decodeOrConceal(decoder, input: input.baseAddress, length: Int32(input.count),
                                                 into: out.baseAddress!, frameSize: 240, decodeFec: 0)
                }
            }
            let rms = (0..<2).map { channel -> Float in
                guard frames > 0 else { return 0 }
                var sum: Float = 0
                for frame in 0..<Int(frames) { sum += pcm[frame * 2 + channel] * pcm[frame * 2 + channel] }
                return (sum / Float(frames)).squareRoot()
            }
            return (frames, rms, rejected != nil)
        }
    }

    /// A packet that won't decode used to schedule nothing, a 5 ms hole the meter read as an under-run.
    @Test func undecodablePacketIsConcealedAndTheStreamRecovers() throws {
        let malformed = "ed01"   // two equal frames can't share one byte
        let out = try #require(Self.run([Self.stereo[0], Self.stereo[1], Self.stereo[2], malformed,
                                         Self.stereo[3], Self.stereo[4]]))
        #expect(out.map(\.frames) == [240, 240, 240, 240, 240, 240])
        #expect(out.map(\.concealed) == [false, false, false, true, false, false])
        #expect(out[3].rms.allSatisfy { $0 > 0.05 }, "concealed \(out[3].rms)")
        for packet in out.suffix(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "recovered \(packet.rms)") }
    }
}
