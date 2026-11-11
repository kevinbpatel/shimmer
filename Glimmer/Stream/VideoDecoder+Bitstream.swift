//
//  VideoDecoder+Bitstream.swift
//
//  Bitstream parsing and CMVideoFormatDescription / CMSampleBuffer construction
//  for H.264, HEVC, and AV1. Lives separate from the decoder lifecycle so the
//  per-codec parameter-set assembly + Annex-B ↔ AVCC plumbing reads in one
//  place.

import CoreMedia
import Foundation
import VideoToolbox

extension VideoDecoder {

    // MARK: - Format description builders

    nonisolated func rebuildH264FormatDescription() -> Bool {
        guard let sps = spsData, let pps = ppsData else { return false }
        return sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return false
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                var newFormat: CMVideoFormatDescription?
                let status = pointers.withUnsafeBufferPointer { ptrs -> OSStatus in
                    sizes.withUnsafeBufferPointer { szs -> OSStatus in
                        guard let ptrsBase = ptrs.baseAddress, let szsBase = szs.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBase,
                            parameterSetSizes: szsBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormat)
                    }
                }
                if status != noErr {
                    log.error("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(status)")
                    return false
                }
                self.formatDescription = newFormat
                self.cachedHDRFormatDescription = nil
                self.tearDownDecompressionSession()
                return true
            }
        }
    }

    nonisolated func rebuildHEVCFormatDescription() -> Bool {
        guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return false }
        return vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard
                        let vpsBase = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else {
                        return false
                    }
                    let pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    var newFormat: CMVideoFormatDescription?
                    let status = pointers.withUnsafeBufferPointer { ptrs -> OSStatus in
                        sizes.withUnsafeBufferPointer { szs -> OSStatus in
                            guard let ptrsBase = ptrs.baseAddress, let szsBase = szs.baseAddress else {
                                return kCMFormatDescriptionError_InvalidParameter
                            }
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrsBase,
                                parameterSetSizes: szsBase,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &newFormat)
                        }
                    }
                    if status != noErr {
                        log.error("CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: \(status)")
                        return false
                    }
                    self.formatDescription = newFormat
                    self.cachedHDRFormatDescription = nil
                    self.tearDownDecompressionSession()
                    return true
                }
            }
        }
    }

    nonisolated func rebuildAV1FormatDescription(obuData: Data) -> Bool {
        // For AV1 we need a CMFormatDescription with the AV1C extension
        // (av1C box per ISO/IEC 23091-2). VideoToolbox surfaces this via
        // CMVideoFormatDescriptionCreate with a kCMFormatDescriptionExtension
        // for sample-description-extension-atoms.
        //
        // The av1C config record encodes (per the AV1 ISO Base Media File
        // Format spec) seq_profile / seq_level / seq_tier / high_bitdepth /
        // twelve_bit / monochrome / chroma_subsampling_x / _y. These come
        // from the AV1 sequence header OBU's `color_config` block (AV1 spec
        // §5.5.1, §5.5.2). We parse them out of the first SEQUENCE_HEADER_OBU
        // in the bitstream so 4:4:4 (HIGH8_444 / HIGH10_444) streams describe
        // themselves correctly to VT - hardcoding 4:2:0 here silently breaks
        // any future 4:4:4 path.
        //
        // Parser is intentionally minimal: it walks OBU headers (with optional
        // extension byte + leb128 size), finds the SEQUENCE_HEADER_OBU
        // (type=1), and bit-reads enough of §5.5.1 to recover the eight
        // av1C-relevant fields. If parsing fails we fall back to the
        // negotiated-format hint (Main8/Main10, 4:2:0) - VT's HW AV1 decoder
        // re-derives the truth from the OBU at decode time, so a mis-tagged
        // av1C is recoverable for Main; the parser fail-safe just keeps the
        // pre-fix behavior on edge-case bitstreams.
        //
        // Headerless rebuilds (e.g. a stall-recreate IDR without a sequence
        // header OBU) retain the active configuration, including any encoder
        // padding; only a cold start falls back to the negotiated hints.
        guard !obuData.isEmpty else { return false }

        let parsed = parseAV1SequenceHeader(obuData) ?? av1SequenceHeader
        if let parsed {
            log.info(
                """
                AV1 seq configuration: profile=\(parsed.seqProfile, privacy: .public) \
                bitDepth=\(parsed.bitDepth, privacy: .public) \
                mono=\(parsed.monochrome, privacy: .public) \
                ssx=\(parsed.subsamplingX, privacy: .public) \
                ssy=\(parsed.subsamplingY, privacy: .public)
                """
            )
        } else {
            log.warning("AV1 seq header parse failed; falling back to Main 4:2:0 av1C")
        }

        let isMain10Hint = (streamVideoFormat & StreamProtocol.VIDEO_FORMAT_AV1_MAIN10) != 0
        let seqProfile: UInt8 = parsed?.seqProfile ?? 0
        let bitDepth: UInt8 = parsed?.bitDepth ?? (isMain10Hint ? 10 : 8)
        let monochrome: UInt8 = parsed?.monochrome ?? 0
        let subsamplingX: UInt8 = parsed?.subsamplingX ?? 1
        let subsamplingY: UInt8 = parsed?.subsamplingY ?? 1
        let seqTier: UInt8 = parsed?.seqTier ?? 0
        let level: UInt8 = 0  // 2.0; auto-negotiated by the decoder anyway

        // Decode at the coded size. AMD AMF pads AV1 to its block size (e.g.
        // 1920x1082 for a negotiated 1920x1080, issue #223); a format
        // description at the negotiated size makes VT fail with -12909.
        // Sequence maxima are not necessarily the current frame size, so only
        // accept small padding around the negotiated rect.
        var codedWidth = Int(streamWidth)
        var codedHeight = Int(streamHeight)
        if let parsed, acceptsAV1Padding(width: parsed.codedWidth, height: parsed.codedHeight) {
            codedWidth = parsed.codedWidth
            codedHeight = parsed.codedHeight
        } else if let parsed, parsed.codedWidth != codedWidth || parsed.codedHeight != codedHeight {
            log.warning("AV1 sequence dimensions outside padding bounds; keeping negotiated geometry")
        }

        var av1cBytes: [UInt8] = []
        // Marker bit + version (1), then seq_profile(3) + seq_level_idx_0(5)
        av1cBytes.append(0x81)  // marker=1, version=1
        av1cBytes.append((seqProfile << 5) | (level & 0x1F))
        // seq_tier_0(1) + high_bitdepth(1) + twelve_bit(1) + monochrome(1)
        // + chroma_subsampling_x(1) + chroma_subsampling_y(1)
        // + chroma_sample_position(2)
        let highBitDepth: UInt8 = (bitDepth >= 10) ? 1 : 0
        let twelveBit: UInt8 = (bitDepth >= 12) ? 1 : 0
        av1cBytes.append(
            (seqTier << 7) | (highBitDepth << 6) | (twelveBit << 5) | (monochrome << 4)
                | (subsamplingX << 3) | (subsamplingY << 2))
        // initial_presentation_delay_present(1) + reserved(7)
        av1cBytes.append(0x00)

        let av1cData = Data(av1cBytes) as CFData

        let av1CKey = "av1C" as CFString
        // Wrap atoms in a dict keyed by FourCC, matching VT's "sample
        // description extension atoms" contract.
        let atomsDict = [av1CKey: av1cData] as CFDictionary
        let extKey =
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        let extensions = [extKey: atomsDict] as CFDictionary

        var newFormat: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: Int32(codedWidth),
            height: Int32(codedHeight),
            extensions: extensions,
            formatDescriptionOut: &newFormat)
        if status != noErr {
            log.error("CMVideoFormatDescriptionCreate (AV1) failed: \(status)")
            return false
        }
        // Retire the old session (and its output callbacks) before publishing
        // the new geometry, so a stale callback never sees a mismatched box.
        self.tearDownDecompressionSession()
        self.formatDescription = newFormat
        self.av1SequenceHeader = parsed
        let padded = codedWidth != Int(streamWidth) || codedHeight != Int(streamHeight)
        self.av1PaddingBox.withLock { [codedWidth, codedHeight] in
            $0 = padded ? (codedWidth, codedHeight) : nil
        }
        self.cachedHDRFormatDescription = nil
        return true
    }

    // MARK: - Annex-B / AVCC conversion

    /// Strip a leading Annex-B start code (00 00 00 01 or 00 00 01) so what
    /// remains is a bare NAL unit suitable for use as a parameter set.
    nonisolated func stripStartCode(_ data: Data) -> Data {
        if data.count >= 4, data[0] == 0, data[1] == 0, data[2] == 0, data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        }
        if data.count >= 3, data[0] == 0, data[1] == 0, data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    /// Replace each Annex-B start code with a 4-byte big-endian length prefix
    /// (AVCC / HVCC, the form VideoToolbox consumes). Scan-then-write over
    /// `withUnsafeBytes` avoids a `Data -> [UInt8] -> Data` copy per frame.
    nonisolated func convertAnnexBToAVCC(_ data: Data) -> Data {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Data()
            }
            let count = raw.count

            // First pass: collect NAL spans and the exact output length.
            //
            // Every start code ends in 0x01, so the scan jumps from one 0x01
            // byte to the next with `memchr` (vectorised) and only then looks
            // back for the two or three zero bytes. Entropy-coded video has a
            // 0x01 about once in 256 bytes, so this touches a small fraction
            // of what a byte-at-a-time walk did - that walk was the largest
            // user-space cost of a high-bitrate stream (13% of a core at
            // ~190 Mbps). The spans it finds are identical: a code is the
            // 4-byte form when a third zero precedes the 0x01 and that zero
            // wasn't already consumed, the 3-byte form otherwise.
            var nals: [(start: Int, length: Int)] = []
            var outSize = 0
            var nalStart = -1
            var consumed = 0 // first byte not part of an earlier start code
            var search = 0
            while search < count,
                  let hit = memchr(base + search, 0x01, count - search) {
                let one = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                search = one + 1
                guard one >= consumed + 2, base[one - 1] == 0, base[one - 2] == 0 else { continue }
                let codeStart = (one >= consumed + 3 && base[one - 3] == 0) ? one - 3 : one - 2
                if nalStart >= 0, codeStart > nalStart {
                    nals.append((nalStart, codeStart - nalStart))
                    outSize += 4 + (codeStart - nalStart)
                }
                nalStart = one + 1
                consumed = one + 1
            }
            if nalStart >= 0, count > nalStart {
                nals.append((nalStart, count - nalStart))
                outSize += 4 + (count - nalStart)
            }

            // Second pass: one pre-sized write of len32-BE || NAL per unit.
            var out = Data(count: outSize)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.baseAddress else { return }
                var offset = 0
                for nal in nals {
                    let lenBE = UInt32(nal.length).bigEndian
                    withUnsafeBytes(of: lenBE) { lenBytes in
                        // A 4-byte fixed-width value always has a base address;
                        // the guard states that instead of trapping on it.
                        guard let lenBase = lenBytes.baseAddress else { return }
                        dstBase.advanced(by: offset).copyMemory(from: lenBase, byteCount: 4)
                    }
                    offset += 4
                    dstBase.advanced(by: offset)
                        .copyMemory(from: base.advanced(by: nal.start), byteCount: nal.length)
                    offset += nal.length
                }
            }
            return out
        }
    }

    // MARK: - Sample buffer construction (for VT input)

    nonisolated func makeSampleBuffer(
        rawData: Data, rtpTimestamp: UInt32 = 0
    ) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { return nil }

        // Wrap rawData in a CMBlockBuffer. We copy because moonlight will
        // reuse its buffers after submitDecodeUnit returns; sharing memory
        // here would be a use-after-free hazard.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: rawData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: rawData.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            log.error("CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return nil
        }

        status = CMBlockBufferAssureBlockMemory(bb)
        guard status == kCMBlockBufferNoErr else {
            log.error("CMBlockBufferAssureBlockMemory failed: \(status)")
            return nil
        }

        status = rawData.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: rawData.count)
        }
        guard status == kCMBlockBufferNoErr else {
            log.error("CMBlockBufferReplaceDataBytes failed: \(status)")
            return nil
        }

        // Attach the host's rtpTimestamp (90kHz units, per H.264/HEVC/AV1
        // RTP standard - see DECODE_UNIT.rtpTimestamp in Limelight.h, and
        // the spec note that CMTimeMake((int64_t)du->rtpTimestamp, 90000)
        // is the canonical conversion). VT propagates this onto the output
        // callback's presentationTimeStamp argument so the downstream
        // enqueue path can stamp the output CMSampleBuffer in the host's
        // capture clock rather than our local "now-receive" clock.
        //
        // Why this matters: AVSampleBufferDisplayLayer / VideoRenderer uses
        // the PTS to make drop decisions when frames bunch up. A local
        // mach_absolute_time PTS would be monotonically increasing in
        // *our* clock and give the layer no signal to detect a stale frame
        // post-stutter; host-clock PTS lets it drop stale frames cleanly.
        let timingInfo: CMSampleTimingInfo
        if rtpTimestamp != 0 {
            timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTimeMake(value: Int64(rtpTimestamp), timescale: 90_000),
                decodeTimeStamp: .invalid)
        } else {
            // No host PTS available (older Sunshine builds, defensive path).
            timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid)
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleSize = rawData.count
        status = withUnsafePointer(to: timingInfo) { timingPtr in
            var sampleSizeLocal = sampleSize
            return CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: timingPtr,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizeLocal,
                sampleBufferOut: &sampleBuffer)
        }
        if status != noErr {
            log.error("CMSampleBufferCreateReady failed: \(status)")
            return nil
        }
        return sampleBuffer
    }
}
