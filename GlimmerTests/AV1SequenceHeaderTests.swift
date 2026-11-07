//
//  AV1SequenceHeaderTests.swift
//
//  Hardware-free coverage for AV1 sequence-header parsing and the coded-size
//  contract: AMD AMF pads AV1 (1920x1080 negotiated → 1920x1082 coded, issue
//  Se7enbrc/glimmer#223), so the format description must describe the coded
//  size and the decoded frames must be cropped back to the negotiated rect.
//  Ported from upstream Glimmer PR #224.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import Glimmer

@MainActor
struct AV1SequenceHeaderTests {

    // MARK: - Parsing

    @Test func parsesSequenceHeaderWithoutDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(Self.sequenceHeader(decoderModel: false))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
    }

    /// decoder_model_info is 5 + 32 + 5 + 5 bits and each operating point's
    /// delays are buffer_delay_length bits wide (AV1 §5.5.4-5.5.5). Reading
    /// them with the wrong widths shifted every later field, including the
    /// coded size the padding fix depends on.
    @Test func parsesSequenceHeaderWithDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(
            Self.sequenceHeader(decoderModel: true, width: 1920, height: 1082))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
        #expect(result?.codedWidth == 1920)
        #expect(result?.codedHeight == 1082)
    }

    @Test func parsesPaddedCodedDimensions() throws {
        // Issue #223 reports 1920x1082 for a negotiated 1920x1080 stream.
        let decoder = VideoDecoder()
        let parsed = try #require(
            decoder.parseAV1SequenceHeader(Self.sequenceHeader(decoderModel: false,
                                                               width: 1920, height: 1082)))
        #expect(parsed.codedWidth == 1920)
        #expect(parsed.codedHeight == 1082)
    }

    // MARK: - Format description geometry

    @Test func parsedPaddingReachesTheFormatDescription() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: 1920, height: 1082)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dims.width == 1920)
        #expect(dims.height == 1082)
        #expect(decoder.av1PaddingBox.withLock { $0?.width } == 1920)
        #expect(decoder.av1PaddingBox.withLock { $0?.height } == 1082)
    }

    @Test func headerCodingLessThanNegotiatedKeepsTheNegotiatedSize() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: 64, height: 64)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dims.width == 1920)
        #expect(dims.height == 1080)
        #expect(decoder.av1PaddingBox.withLock { $0 } == nil)
    }

    @Test(arguments: [(1920, 1082), (1936, 1096), (1920, 1080), (3840, 2160),
                      (65536, 65536), (1920, 1078), (1918, 1082), (1937, 1080)])
    func sequenceGeometryIsBounded(size: (Int, Int)) throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: size.0, height: size.1)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        let accepted = [(1920, 1082), (1936, 1096), (1920, 1080)].contains { $0 == size }
        #expect(dims.width == (accepted ? Int32(size.0) : 1920))
        #expect(dims.height == (accepted ? Int32(size.1) : 1080))
    }

    @Test func unpaddedRebuildClearsStalePadding() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 1920, height: 1082)))
        #expect(decoder.av1PaddingBox.withLock { $0 } != nil)
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 1920, height: 1080)))
        #expect(decoder.av1PaddingBox.withLock { $0 } == nil)
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dims.height == 1080)
    }

    @Test func rebuildWithoutHeaderRetainsGeometry() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: 1920, height: 1082)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let header = try #require(decoder.av1SequenceHeader)
        // A lone temporal-delimiter OBU: no sequence header to parse.
        try #require(decoder.rebuildAV1FormatDescription(obuData: Data([0x12, 0x00])))
        let format = try #require(decoder.formatDescription)
        #expect(CMVideoFormatDescriptionGetDimensions(format).height == 1082)
        #expect(decoder.av1SequenceHeader == header)
        #expect(decoder.av1PaddingBox.withLock { $0?.height } == 1082)
        decoder.teardown()
        #expect(decoder.av1SequenceHeader == nil)
        #expect(decoder.av1PaddingBox.withLock { $0 } == nil)
    }

    @Test func cleanupResetsPaddingState() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 1920, height: 1082)))
        decoder.handleCleanup()
        #expect(decoder.av1SequenceHeader == nil)
        #expect(decoder.av1PaddingBox.withLock { $0 } == nil)
    }

    // MARK: - Clean aperture

    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func cleanApertureKeepsIOSurfaceAndTopLeftDisplayRegion(pixelFormat: OSType) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        decoder.streamWidth = 32
        decoder.streamHeight = 16
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 34, height: 18)))
        var created: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 34, 18, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
        let padded = try #require(created)
        let surface = try #require(CVPixelBufferGetIOSurface(padded)?.takeUnretainedValue())
        CVBufferSetAttachment(padded, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(padded, kCVImageBufferPreferredCleanApertureKey,
            [kCVImageBufferCleanApertureWidthKey: 34, kCVImageBufferCleanApertureHeightKey: 18]
                as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(padded, kCVImageBufferDisplayDimensionsKey,
            [kCVImageBufferDisplayWidthKey: 34, kCVImageBufferDisplayHeightKey: 18]
                as CFDictionary, .shouldPropagate)
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.isStreaming = true
        defer { decoder.teardown() }
        decoder.enqueueDecodedFrame(padded, hostPTS: CMTime(value: 1, timescale: 60))
        #expect(CVPixelBufferGetIOSurface(padded)?.takeUnretainedValue() === surface)
        #expect(CVBufferCopyAttachment(padded, kCVImageBufferPreferredCleanApertureKey, nil) == nil)
        #expect(CVBufferCopyAttachment(padded, kCVImageBufferDisplayDimensionsKey, nil) == nil)
        #expect(CVPixelBufferGetWidth(padded) == 34)
        #expect(CVPixelBufferGetHeight(padded) == 18)
        let description = try #require(decoder.cachedHDRFormatDescription)
        #expect(CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: true)
            == CGRect(x: 0, y: 0, width: 32, height: 16))
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: padded))
        #expect(CMFormatDescriptionGetExtension(description,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    @Test(arguments: [StreamProtocol.VIDEO_FORMAT_H264, StreamProtocol.VIDEO_FORMAT_H265,
                      StreamProtocol.VIDEO_FORMAT_AV1_MAIN8], [(32, 18), (64, 36), (32, 16)])
    func apertureOnlyAppliesToMatchingAV1Padding(codec: Int32, size: (Int, Int)) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = codec
        decoder.streamWidth = 32
        decoder.streamHeight = 16
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 32, height: 18)))
        var created: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, size.0, size.1,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        decoder.applyAV1CleanAperture(to: buffer)
        let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferCleanApertureKey, nil)
        #expect((attachment != nil) == (codec == StreamProtocol.VIDEO_FORMAT_AV1_MAIN8 && size == (32, 18)))
    }

    // MARK: - Fixture

    /// A profile 1, 10-bit sequence header OBU with the given coded maxima.
    static func sequenceHeader(
        decoderModel: Bool, width: Int = 1, height: Int = 1
    ) -> Data {
        var bits = BitFixtureWriter()
        bits.write(1, count: 3)  // seq_profile
        bits.write(0, count: 1)  // still_picture
        bits.write(0, count: 1)  // reduced_still_picture_header
        bits.write(1, count: 1)  // timing_info_present_flag
        bits.write(0, count: 32) // num_units_in_display_tick
        bits.write(0, count: 32) // time_scale
        bits.write(0, count: 1)  // equal_picture_interval
        bits.write(decoderModel ? 1 : 0, count: 1)  // decoder_model_info_present_flag
        if decoderModel {
            bits.write(4, count: 5)  // buffer_delay_length_minus_1
            bits.write(0, count: 32) // num_units_in_decoding_tick
            bits.write(0, count: 5)  // buffer_removal_time_length_minus_1
            bits.write(0, count: 5)  // frame_presentation_time_length_minus_1
        }
        bits.write(0, count: 1)  // initial_display_delay_present_flag
        bits.write(0, count: 5)  // operating_points_cnt_minus_1
        bits.write(0, count: 12) // operating_point_idc[0]
        bits.write(0, count: 5)  // seq_level_idx[0]
        if decoderModel {
            bits.write(1, count: 1)  // decoder_model_present_for_this_op[0]
            bits.write(0, count: 5)  // decoder_buffer_delay
            bits.write(0, count: 5)  // encoder_buffer_delay
            bits.write(0, count: 1)  // low_delay_mode_flag
        }
        // frame_width_bits_minus_1 / max_frame_width_minus_1 pairs sized to
        // the requested coded dimensions (defaults keep the historic 1x1).
        let widthFieldBits = Self.bitWidth(width - 1)
        let heightFieldBits = Self.bitWidth(height - 1)
        bits.write(widthFieldBits - 1, count: 4)
        bits.write(heightFieldBits - 1, count: 4)
        bits.write(width - 1, count: widthFieldBits)
        bits.write(height - 1, count: heightFieldBits)
        bits.write(0, count: 1)  // frame_id_numbers_present_flag
        bits.write(0, count: 1)  // use_128x128_superblock
        bits.write(0, count: 1)  // enable_filter_intra
        bits.write(0, count: 1)  // enable_intra_edge_filter
        bits.write(0, count: 1)  // enable_interintra_compound
        bits.write(0, count: 1)  // enable_masked_compound
        bits.write(0, count: 1)  // enable_warped_motion
        bits.write(0, count: 1)  // enable_dual_filter
        bits.write(0, count: 1)  // enable_order_hint
        bits.write(0, count: 1)  // seq_choose_screen_content_tools
        bits.write(0, count: 1)  // seq_force_screen_content_tools
        bits.write(1, count: 1)  // enable_superres
        bits.write(0, count: 1)  // enable_cdef
        bits.write(0, count: 1)  // enable_restoration
        bits.write(1, count: 1)  // high_bitdepth
        bits.write(0, count: 1)  // color_description_present_flag
        bits.write(0, count: 1)  // color_range
        bits.write(0, count: 1)  // separate_uv_delta_q
        bits.write(0, count: 1)  // film_grain_params_present
        bits.write(0, count: 1)  // padding
        return Data([0x0A, UInt8(bits.bytes.count)] + bits.bytes)
    }

    /// Bits needed to hold `value`, floored at 1 so minus_1 fields stay legal.
    private static func bitWidth(_ value: Int) -> Int {
        var remaining = value
        var bits = 0
        while remaining > 0 {
            bits += 1
            remaining >>= 1
        }
        return max(bits, 1)
    }
}

private struct BitFixtureWriter {
    private(set) var bytes: [UInt8] = []
    private var offset = 0

    mutating func write(_ value: Int, count: Int) {
        for bit in (0..<count).reversed() {
            if offset == 0 { bytes.append(0) }
            if value & (1 << bit) != 0 {
                bytes[bytes.count - 1] |= 1 << (7 - offset)
            }
            offset = (offset + 1) % 8
        }
    }
}
