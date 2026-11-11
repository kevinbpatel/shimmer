//
//  AnnexBToAVCCTests.swift
//
//  Covers VideoDecoder.convertAnnexBToAVCC - the Annex-B start-code -> AVCC
//  4-byte-length-prefix rewrite VideoToolbox H.264/HEVC consume. Pure transform
//  of one AU; reads no decoder state, so it's exercisable off a bare instance.
//

import Foundation
import Testing

@testable import Glimmer

// VideoDecoder.init() is MainActor-isolated; convertAnnexBToAVCC itself is
// nonisolated and pure, so the test just builds the instance on the main actor.
@MainActor
struct AnnexBToAVCCTests {

    /// Read the 4-byte big-endian length prefix at `offset`.
    private func len32(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    @Test func singleNalFourByteStartCode() {
        let decoder = VideoDecoder()
        let input = Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB])
        let out = decoder.convertAnnexBToAVCC(input)
        // 4-byte length prefix (3) + the 3 NAL payload bytes.
        #expect(out.count == 7)
        #expect(len32(out, at: 0) == 3)
        #expect(Array(out[4...]) == [0x65, 0xAA, 0xBB])
    }

    @Test func singleNalThreeByteStartCode() {
        let decoder = VideoDecoder()
        let input = Data([0, 0, 1, 0x41, 0x10])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 6)
        #expect(len32(out, at: 0) == 2)
        #expect(Array(out[4...]) == [0x41, 0x10])
    }

    @Test func multipleNalsMixedStartCodes() {
        let decoder = VideoDecoder()
        // SPS (4-byte SC, 2 bytes) then PPS (3-byte SC, 1 byte).
        let input = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 4 + 2 + 4 + 1)
        #expect(len32(out, at: 0) == 2)
        #expect(Array(out[4..<6]) == [0x67, 0x42])
        #expect(len32(out, at: 6) == 1)
        #expect(Array(out[10...]) == [0x68])
    }

    @Test func emptyNalBetweenStartCodesSkipped() {
        let decoder = VideoDecoder()
        // Back-to-back start codes leave a zero-length unit - it must be dropped
        // so VT never sees a 0-length NAL.
        let input = Data([0, 0, 0, 1, 0, 0, 0, 1, 0x65])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 4 + 1)
        #expect(len32(out, at: 0) == 1)
        #expect(Array(out[4...]) == [0x65])
    }

    @Test func noStartCodePassesNothing() {
        let decoder = VideoDecoder()
        // No leading start code -> nothing is treated as a NAL.
        let input = Data([0x65, 0xAA])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.isEmpty)
    }

    @Test func emptyInputYieldsEmpty() {
        let decoder = VideoDecoder()
        #expect(decoder.convertAnnexBToAVCC(Data()).isEmpty)
    }

    // MARK: - Differential check against the byte-at-a-time scan

    /// The original scanner, kept here as the specification: walk every byte,
    /// prefer the 4-byte start code, emit len32-BE || NAL for each non-empty
    /// unit. The shipping `memchr` scan must produce the same bytes.
    private func referenceConvert(_ bytes: [UInt8]) -> [UInt8] {
        func codeLength(at i: Int) -> Int {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 { return 4 }
            if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { return 3 }
            return 0
        }
        var out: [UInt8] = []
        func emit(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let n = UInt32(range.count)
            out += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += bytes[range]
        }
        var nalStart = -1
        var i = 0
        while i < bytes.count {
            let length = codeLength(at: i)
            if length > 0 {
                if nalStart >= 0 { emit(nalStart..<i) }
                i += length
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0 { emit(nalStart..<bytes.count) }
        return out
    }

    /// Small deterministic generator so a failure reproduces.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Short buffers drawn mostly from {00, 01}: every arrangement of zero
    /// runs, back-to-back codes, codes at either end and truncated codes.
    @Test func matchesReferenceOnStartCodeDenseInput() {
        let decoder = VideoDecoder()
        var rng = SplitMix(state: 0x5348_494D_4D45_52)
        let alphabet: [UInt8] = [0, 0, 0, 0, 1, 1, 1, 2, 0xFF]
        for _ in 0..<40_000 {
            let count = Int.random(in: 0...24, using: &rng)
            let bytes = (0..<count).map { _ in alphabet.randomElement(using: &rng)! }
            let out = [UInt8](decoder.convertAnnexBToAVCC(Data(bytes)))
            if out != referenceConvert(bytes) {
                Issue.record("mismatch for \(bytes)")
                return
            }
        }
    }

    /// Frame-sized buffers of random payload with start codes dropped in, the
    /// shape of a real access unit (a few NALs, long entropy-coded runs).
    @Test func matchesReferenceOnFrameSizedInput() {
        let decoder = VideoDecoder()
        var rng = SplitMix(state: 0x4652_414D_45)
        for _ in 0..<60 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                bytes += Bool.random(using: &rng) ? [0, 0, 0, 1] : [0, 0, 1]
                bytes += (0..<Int.random(in: 0...60_000, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            }
            let out = [UInt8](decoder.convertAnnexBToAVCC(Data(bytes)))
            #expect(out == referenceConvert(bytes))
        }
    }

    /// A slice of a larger Data has a non-zero start index; the scan must work
    /// in the slice's own coordinates.
    @Test func convertsADataSlice() {
        let decoder = VideoDecoder()
        let whole = Data([0xEE, 0xEE, 0, 0, 1, 0x41, 0x10, 0, 0, 0, 1, 0x42])
        let out = [UInt8](decoder.convertAnnexBToAVCC(whole[2...]))
        #expect(out == referenceConvert(Array(whole[2...])))
    }
}
