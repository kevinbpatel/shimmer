//
//  EnetWireTests.swift
//
//  Round-trip + known-answer coverage for the ByteWriter/ByteReader primitives
//  in EnetWire.swift. These are the byte-exact ENet wire helpers; a regression
//  here silently corrupts every control packet, so the tests pin both the
//  produced bytes and the read-back values, plus the EOF behaviour.
//

import CryptoKit
import Foundation
import Testing
@testable import Glimmer

struct EnetWireTests {

    // MARK: - Writer known-answer (endianness is the whole point)

    @Test func writerU16BEKnownAnswer() {
        var w = ByteWriter()
        w.u16BE(0x1234)
        #expect(w.bytes == [0x12, 0x34])
    }

    @Test func writerU32BEKnownAnswer() {
        var w = ByteWriter()
        w.u32BE(0x1122_3344)
        #expect(w.bytes == [0x11, 0x22, 0x33, 0x44])
    }

    @Test func writerU32LEKnownAnswer() {
        var w = ByteWriter()
        w.u32LE(0x1122_3344)
        #expect(w.bytes == [0x44, 0x33, 0x22, 0x11])
    }

    @Test func writerU32RawIsLittleEndianOnArm() {
        // u32Raw writes native bytes (arm64/x86_64 are little-endian) so the
        // connectID round-trips byte-identically against the VERIFY_CONNECT echo.
        var w = ByteWriter()
        w.u32Raw(0x1122_3344)
        #expect(w.bytes == [0x44, 0x33, 0x22, 0x11])
    }

    @Test func writerU8AndAppend() {
        var w = ByteWriter()
        w.u8(0xAB)
        w.append([0x01, 0x02, 0x03])
        #expect(w.bytes == [0xAB, 0x01, 0x02, 0x03])
    }

    // MARK: - Reader round-trip: write then read back byte-identical

    @Test func roundTripU16BE() {
        for value: UInt16 in [0, 1, 0x1234, 0x00FF, 0xFF00, 0xFFFF] {
            var w = ByteWriter()
            w.u16BE(value)
            var r = ByteReader(w.bytes)
            #expect(r.u16BE() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripU32BE() {
        for value: UInt32 in [0, 1, 0x1122_3344, 0x0000_00FF, 0xFF00_0000, 0xFFFF_FFFF] {
            var w = ByteWriter()
            w.u32BE(value)
            var r = ByteReader(w.bytes)
            #expect(r.u32BE() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripU32Raw() {
        for value: UInt32 in [0, 1, 0x1122_3344, 0xDEAD_BEEF, 0xFFFF_FFFF] {
            var w = ByteWriter()
            w.u32Raw(value)
            var r = ByteReader(w.bytes)
            #expect(r.u32Raw() == value)
            #expect(r.remaining == 0)
        }
    }

    @Test func roundTripMixedSequence() {
        var w = ByteWriter()
        w.u8(0x7F)
        w.u16BE(0xBEEF)
        w.u32BE(0x0102_0304)
        w.u32Raw(0xCAFE_F00D)
        var r = ByteReader(w.bytes)
        #expect(r.u8() == 0x7F)
        #expect(r.u16BE() == 0xBEEF)
        #expect(r.u32BE() == 0x0102_0304)
        #expect(r.u32Raw() == 0xCAFE_F00D)
        #expect(r.remaining == 0)
    }

    @Test func readerTakeReturnsExactSlice() {
        var r = ByteReader([0x10, 0x20, 0x30, 0x40, 0x50], offset: 1)
        #expect(r.take(3) == [0x20, 0x30, 0x40])
        #expect(r.remaining == 1)
        #expect(r.u8() == 0x50)
    }

    // MARK: - Reads past EOF return nil

    @Test func u8PastEOFReturnsNil() {
        var r = ByteReader([0x01])
        #expect(r.u8() == 0x01)
        #expect(r.u8() == nil)
    }

    @Test func u16BEShortBufferReturnsNil() {
        var r = ByteReader([0x01]) // only 1 byte, need 2
        #expect(r.u16BE() == nil)
        #expect(r.remaining == 1) // offset not advanced on failure
    }

    @Test func u32BEShortBufferReturnsNil() {
        var r = ByteReader([0x01, 0x02, 0x03]) // only 3 bytes, need 4
        #expect(r.u32BE() == nil)
        #expect(r.remaining == 3)
    }

    @Test func u32RawShortBufferReturnsNil() {
        var r = ByteReader([0x01, 0x02]) // only 2 bytes, need 4
        #expect(r.u32Raw() == nil)
        #expect(r.remaining == 2)
    }

    @Test func takeBeyondRemainingReturnsNil() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(3) == nil)
        #expect(r.remaining == 2)
    }

    @Test func takeNegativeCountReturnsNil() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(-1) == nil)
    }

    @Test func takeZeroReturnsEmptyArray() {
        var r = ByteReader([0x01, 0x02])
        #expect(r.take(0) == [])
        #expect(r.remaining == 2)
    }

    @Test func emptyReaderReadsReturnNil() {
        var r = ByteReader([])
        #expect(r.remaining == 0)
        #expect(r.u8() == nil)
        #expect(r.u16BE() == nil)
        #expect(r.u32BE() == nil)
        #expect(r.u32Raw() == nil)
    }
}

// MARK: - EnetControlChannel inbound order and recovery requests

/// The control channel driven with no socket: sends drop on the nil connection,
/// and callbacks and stored state expose the results. Ported from upstream's
/// EnetControlChannelTests (286d5382, 920bb644).
struct EnetControlChannelTests {

    static let key: [UInt8] = Array(0..<16).map { UInt8($0) }
    /// SERVER_TERMINATED_CLOSED, a code the host really sends.
    static let hostCode = Int32(bitPattern: 0x8003_0023)

    /// Collects callback values; the parser calls back synchronously.
    final class Events<Value> {
        var values: [Value] = []
    }

    static func makeChannel() throws -> (EnetControlChannel, Events<Int32>) {
        let channel = EnetControlChannel(host: "127.0.0.1", port: 9, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: key))
        let codes = Events<Int32>()
        channel.onTerminated = { codes.values.append($0) }
        return (channel, codes)
    }

    /// One datagram carrying SEND_RELIABLE on `channel`.
    static func reliable(relSeq: UInt16, _ payload: [UInt8], channel: UInt8 = Enet.ctrlChannelGeneric) -> [UInt8] {
        var w = ByteWriter()
        w.u16BE(Enet.headerFlagSentTime)
        w.u16BE(0)
        w.u8(Enet.cmdSendReliable | Enet.flagAcknowledge)
        w.u8(channel)
        w.u16BE(relSeq)
        w.u16BE(UInt16(payload.count))
        w.append(payload)
        return w.bytes
    }

    /// A host-direction ('H') control-V2 envelope sealed with the session key.
    static func sealHost(type: UInt16, payload: [UInt8], seq: UInt32) throws -> [UInt8] {
        var plaintext: [UInt8] = [UInt8(type & 0xFF), UInt8(type >> 8),
                                  UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
        plaintext += payload
        var iv = [UInt8](repeating: 0, count: 12)
        iv[0] = UInt8(seq & 0xFF); iv[1] = UInt8((seq >> 8) & 0xFF)
        iv[2] = UInt8((seq >> 16) & 0xFF); iv[3] = UInt8((seq >> 24) & 0xFF)
        iv[10] = 0x48; iv[11] = 0x43
        let box = try AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: Data(key)),
                                   nonce: try AES.GCM.Nonce(data: Data(iv)))
        let length = UInt16(4 + 16 + box.ciphertext.count)
        let header: [UInt8] = [0x01, 0x00, UInt8(length & 0xFF), UInt8(length >> 8),
                               UInt8(seq & 0xFF), UInt8((seq >> 8) & 0xFF),
                               UInt8((seq >> 16) & 0xFF), UInt8((seq >> 24) & 0xFF)]
        return header + [UInt8](box.tag) + [UInt8](box.ciphertext)
    }

    static func rumble(_ value: UInt16, seq: UInt32) throws -> [UInt8] {
        var payload = ByteWriter()
        payload.u32LE(0)
        payload.append([0, 0, UInt8(truncatingIfNeeded: value), UInt8(value >> 8), 0, 0])
        return try sealHost(type: CtrlV2.rumbleData, payload: payload.bytes, seq: seq)
    }

    static func termination(seq: UInt32) throws -> [UInt8] {
        let code = UInt32(bitPattern: hostCode)
        return try sealHost(type: CtrlV2.termination,
                            payload: [UInt8(code >> 24), UInt8((code >> 16) & 0xFF),
                                      UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)], seq: seq)
    }

    static func rumbleEvents(_ channel: EnetControlChannel) -> Events<UInt16> {
        let events = Events<UInt16>()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        return events
    }

    // MARK: Inbound order

    /// A spoofed packet half the sequence space ahead fails authentication, so it
    /// can't move the cursor and make the PC's genuine messages look stale.
    @Test func forgedReliableDoesNotMakeGenuineMessagesStale() throws {
        let (channel, codes) = try Self.makeChannel()
        let forged: [UInt8] = [0x01, 0x00] + [UInt8](repeating: 0xAB, count: 30)
        channel.onDatagram(Self.reliable(relSeq: 0x7FFF, forged))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 0)))
        #expect(codes.values == [Self.hostCode])
    }

    @Test func forgedExpectedReliableDoesNotAdvanceOrder() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.onDatagram(Self.reliable(relSeq: 1, [1, 0] + [UInt8](repeating: 0xAB, count: 30)))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 1)))
        #expect(codes.values == [Self.hostCode])
    }

    /// A missing reliable holds its successors, and its resend then lands first:
    /// a lost motors-off can't be overtaken (or dropped) by the rumble after it.
    @Test func reliableDeliveryPreservesCrossMessageOrder() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Self.rumbleEvents(channel)
        channel.onRumbleTriggers = { _, left, right in
            #expect(left == 0 && right == 0)
            events.values.append(2)
        }
        let third = try Self.rumble(3, seq: 3)
        let off = try Self.sealHost(type: CtrlV2.rumbleTriggers, payload: [0, 0, 0, 0, 0, 0], seq: 2)
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        channel.onDatagram(Self.reliable(relSeq: 3, third))
        #expect(events.values == [1])
        channel.onDatagram(Self.reliable(relSeq: 2, off))
        channel.onDatagram(Self.reliable(relSeq: 3, third))
        #expect(events.values == [1, 2, 3])
    }

    @Test func channelsKeepIndependentOrder() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Self.rumbleEvents(channel)
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.rumble(2, seq: 2)))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(7, seq: 7), channel: 7))
        #expect(events.values == [7])
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        #expect(events.values == [7, 1, 2])
    }

    /// A Wi-Fi blackout longer than a second, then unrelated traffic, then the PC's
    /// resend of the missing reliable: it still arrives in order instead of being
    /// acknowledged as stale and lost.
    @Test func aGapWaitsThroughABlackoutForTheResend() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Self.rumbleEvents(channel)
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        channel.onDatagram(Self.reliable(relSeq: 3, try Self.rumble(3, seq: 3)))
        Thread.sleep(forTimeInterval: 1.1)
        channel.onDatagram([0, 0])
        #expect(events.values == [1])
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.rumble(2, seq: 2)))
        #expect(events.values == [1, 2, 3])
    }

    @Test func inboundOrderHandlesGapsDuplicatesAndWrap() {
        var order = EnetInboundOrder()
        #expect(order.accept(1, payload: [1]).due == [[1]])
        #expect(order.isDuplicate(1))
        #expect(order.accept(3, payload: [3]).due.isEmpty)
        #expect(order.isDuplicate(3))
        #expect(!order.isDuplicate(2))
        #expect(order.accept(2, payload: [2]).due == [[2], [3]])
        order.next = 0xFFFF
        #expect(order.accept(0, payload: [0]).due.isEmpty)
        #expect(order.accept(0xFFFF, payload: [255]).due == [[255], [0]])
        #expect(order.next == 1)
        #expect(order.isDuplicate(0xFFFF))
    }

    @Test func fullOrderSkipsOnlyTheMissingRange() {
        var order = EnetInboundOrder()
        for seq in 3..<UInt16(EnetInboundOrder.maxHeld + 2) {
            let result = order.accept(seq, payload: [])
            #expect(result.due.isEmpty && result.skipped == 0)
        }
        let result = order.accept(UInt16(EnetInboundOrder.maxHeld + 2), payload: [])
        #expect(result.skipped == 2)
        #expect(result.due == [[UInt8]](repeating: [], count: EnetInboundOrder.maxHeld))
        #expect(order.held.isEmpty)
        #expect(order.next == UInt16(EnetInboundOrder.maxHeld + 3))
    }

    // MARK: Recovery request spacing

    static func urgentRelSeq(_ channel: EnetControlChannel) -> UInt16 {
        channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelUrgent] ?? 0 }
    }

    /// On a slow path a repeat waits for the first request's answer: the spacing
    /// follows the smoothed RTT above the 20 ms floor, and the first request of an
    /// episode still leaves on the next drain.
    @Test func repeatRequestsWaitOutTheRoundTrip() throws {
        #expect(EnetControlChannel.recoverySpacingMs(rttMs: nil) == 20)
        #expect(EnetControlChannel.recoverySpacingMs(rttMs: 4) == 20)
        #expect(EnetControlChannel.recoverySpacingMs(rttMs: 80) == 80)
        #expect(EnetControlChannel.recoverySpacingMs(rttMs: 5000) == 1000)

        let (channel, _) = try Self.makeChannel()
        channel.withState { channel.roundTripTime = 80; channel.hasRttSample = true }
        channel.requestIdrFrame()
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 1)

        channel.requestIdrFrame()
        channel.lastIdrSentMs = channel.serviceTimeMs
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 1)
        #expect(channel.withState { channel.idrPending })

        channel.lastIdrSentMs = channel.serviceTimeMs &- 80
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 2)
        #expect(!channel.withState { channel.idrPending })
    }

    /// RFIs are spaced on their own clock, and an IDR held for spacing still
    /// supersedes any RFI queued behind it.
    @Test func rfiRepeatsWaitAndAHeldIdrSupersedesThem() throws {
        let (channel, _) = try Self.makeChannel()
        channel.invalidateReferenceFrames(from: 10, to: 12)
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 1)

        channel.invalidateReferenceFrames(from: 13, to: 14)
        channel.lastRfiSentMs = channel.serviceTimeMs
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 1)
        #expect(channel.withState { channel.pendingRfi != nil })

        channel.requestIdrFrame()
        channel.lastIdrSentMs = channel.serviceTimeMs
        channel.drainPendingRecoveryRequests()
        #expect(Self.urgentRelSeq(channel) == 1)
        #expect(channel.withState { channel.pendingRfi == nil && channel.idrPending })
    }
}
