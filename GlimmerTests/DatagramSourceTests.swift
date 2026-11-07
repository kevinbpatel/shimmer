//
//  DatagramSourceTests.swift
//
//  The video and audio receive loops drop datagrams whose sender is not the
//  PC (UdpPinger.isExpectedPeer). That check is only as good as the sender
//  address the receive call reports: if the batched recvmsg_x shim or the
//  recvfrom fallback ever stopped filling it in, every datagram would fail the
//  check and the stream would go dark. Exercise both real receive paths off a
//  loopback socket. Adapted from upstream Glimmer's DatagramBatchTests (30d5163e).
//

import Darwin
import Foundation
import Testing
@testable import Glimmer

struct DatagramSourceTests {

    /// Each receive path preserves payloads and reports the sender's address independently of its port.
    @Test(arguments: [true, false]) func receivePathsReportTheSender(batched: Bool) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(receiver); close(sender) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(receiver, $0, length) == 0 && getsockname(receiver, $0, &length) == 0
            }
        }
        try #require(bound)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let sizes = [1, 64, 300, 1392, 17]
        for (index, size) in sizes.enumerated() {
            let payload = [UInt8](repeating: UInt8(index + 1), count: size)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, payload, size, 0, $0, length) }
            }
            try #require(sent == size)
        }
        // Loopback delivers on its own thread: wait until all five are queued, or a busy machine
        // hands the one call only the first few.
        try #require(waitForQueuedDatagrams(Int32(sizes.count), on: receiver))

        // The sender's port is ephemeral and != 1: only the address may be pinned.
        let expected = try #require(UdpPinger.makeSockaddr(for: .init("127.0.0.1"), port: 1))
        let other = try #require(UdpPinger.makeSockaddr(for: .init("127.0.0.2"), port: 1))
        let cap = 32
        let stride = 1500
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: cap * stride)
        let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        let sources = UnsafeMutablePointer<sockaddr_storage>.allocate(capacity: cap)
        sources.initialize(repeating: sockaddr_storage(), count: cap)
        let sourceLengths = UnsafeMutablePointer<socklen_t>.allocate(capacity: cap)
        sourceLengths.initialize(repeating: 0, count: cap)
        defer {
            storage.deallocate(); lengths.deallocate()
            sources.deallocate(); sourceLengths.deallocate()
        }

        if batched {
            let received = gl_recvmsg_x_batch(receiver, storage, Int32(stride), Int32(cap), lengths,
                                              sources, sourceLengths)
            #expect(Int(received) == sizes.count)
        }
        for (index, size) in sizes.enumerated() {
            let slot = batched ? index : 0
            let count: Int
            if batched {
                count = Int(lengths[slot])
            } else {
                count = UdpPinger.receive(from: receiver, into: storage, capacity: stride,
                                          source: &sources[0], sourceLength: &sourceLengths[0])
            }
            #expect(count == size)
            #expect(UdpPinger.isExpectedPeer(sources[slot], length: sourceLengths[slot],
                                             expected: expected.0, expectedLength: expected.1))
            #expect(!UdpPinger.isExpectedPeer(sources[slot], length: sourceLengths[slot],
                                              expected: other.0, expectedLength: other.1))
            let bytes = UnsafeBufferPointer(start: storage + slot * stride, count: max(count, 0))
            #expect(bytes.allSatisfy { $0 == UInt8(index + 1) })
        }
    }

    private func waitForQueuedDatagrams(_ count: Int32, on socket: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        var queued: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        while Date() < deadline {
            if getsockopt(socket, SOL_SOCKET, SO_NUMRCVPKT, &queued, &size) == 0, queued >= count { return true }
            usleep(1_000)
        }
        return false
    }
}
