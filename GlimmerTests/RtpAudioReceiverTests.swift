//
//  RtpAudioReceiverTests.swift
//
//  The audio receiver's datagram path and the FEC queue behind it, driven
//  without a socket: reordering, FEC layout tolerance and queue bounds.
//  Ported from upstream Glimmer's RtspClientTests audio cases.
//

import Foundation
import Testing
@testable import Glimmer

struct RtpAudioReceiverTests {

    final class NullAudioSink: NativeAudioSink {
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: [UInt8]) {}
        func decodeAndPlayPLC() {}
        func cleanup() {}
    }

    final class RecordingAudioSink: NativeAudioSink, @unchecked Sendable {
        // Packets are appended on the caller's thread; the lock keeps reads coherent.
        private let lock = NSLock()
        private var packets: [[UInt8]] = []

        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: [UInt8]) { lock.lock(); packets.append(opus); lock.unlock() }
        func decodeAndPlayPLC() {}
        func cleanup() {}
        func recordedPackets() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return packets }
    }

    static func audioReceiver(sink: NativeAudioSink) -> RtpAudioReceiver {
        // A Sunshine-shaped version, so the queue starts with FEC on.
        RtpAudioReceiver(
            host: "127.0.0.1", audioPort: 48000, pingPayload: [], appVersionQuad: [7, 1, 431, -1],
            audioPacketDuration: 5, opusConfig: RtspHandshakeResult.defaultOpusConfig, audioConfig: 0,
            audioEncryption: false, aesKey: [], aesIvId: [], sink: sink)
    }

    static func audioDatagram(type: UInt8, sequence: UInt16, timestamp: UInt32,
                              payload: [UInt8]) -> [UInt8] {
        [0x80, type, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
         UInt8(timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
         UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp),
         0, 0, 0, 1] + payload
    }

    /// A parity datagram whose AUDIO_FEC_HEADER names `base` as its block's first sequence number.
    static func parityDatagram(sequence: UInt16, base: UInt16) -> [UInt8] {
        audioDatagram(type: RtpAudioQueue.payloadTypeFec, sequence: sequence, timestamp: 0,
                      payload: [0, RtpAudioQueue.payloadTypeAudio, UInt8(base >> 8), UInt8(truncatingIfNeeded: base),
                                0, 0, 0, 0, 0, 0, 0, 1])
    }

    static func feed(_ receiver: RtpAudioReceiver, dataSequences: [UInt16]) {
        for sequence in dataSequences {
            let payload = [UInt8](repeating: UInt8(truncatingIfNeeded: sequence), count: 8)
            let packet = audioDatagram(type: RtpAudioQueue.payloadTypeAudio, sequence: sequence,
                                       timestamp: UInt32(sequence) * 5, payload: payload)
            receiver.handleDatagram(packet, count: packet.count)
        }
    }

    /// The packet that fills a reorder gap takes the in-order fast path; the packet queued
    /// behind it used to wait for the next datagram.
    @Test func filledAudioReorderGapDrainsReadyPackets() {
        let sink = RecordingAudioSink()
        let receiver = Self.audioReceiver(sink: sink)
        let fec = Self.parityDatagram(sequence: 0, base: 0)
        receiver.handleDatagram(fec, count: fec.count)
        Self.feed(receiver, dataSequences: [4, 6, 5])
        #expect(sink.recordedPackets() == [
            [UInt8](repeating: 4, count: 8), [UInt8](repeating: 5, count: 8),
            [UInt8](repeating: 6, count: 8)
        ])
    }

    /// One stray misaligned parity packet used to turn audio FEC, and with it reordering, off for the session.
    @Test func oneMisalignedParityPacketLeavesAudioFecOn() {
        let sink = RecordingAudioSink()
        let receiver = Self.audioReceiver(sink: sink)
        for parity in [Self.parityDatagram(sequence: 0, base: 0), Self.parityDatagram(sequence: 1, base: 6)] {
            receiver.handleDatagram(parity, count: parity.count)
        }
        Self.feed(receiver, dataSequences: [4, 6, 5])
        #expect(!receiver.queue.incompatibleServer)
        #expect(sink.recordedPackets().map(\.first) == [4, 5, 6])
    }

    @Test func aStreakOfMisalignedParityTurnsAudioFecOff() {
        let receiver = Self.audioReceiver(sink: NullAudioSink())
        let sync = Self.parityDatagram(sequence: 0, base: 0)
        receiver.handleDatagram(sync, count: sync.count)
        for index in 1...RtpAudioQueue.layoutMismatchStreakLimit {
            #expect(!receiver.queue.incompatibleServer)
            let parity = Self.parityDatagram(sequence: UInt16(index), base: 6)
            receiver.handleDatagram(parity, count: parity.count)
        }
        #expect(receiver.queue.incompatibleServer)
    }
}
