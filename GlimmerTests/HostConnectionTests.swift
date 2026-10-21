import Foundation
import Testing
@testable import Glimmer

struct HostConnectionTests {
    @Test func historyRecordsEachMeasurementOnceAndExpiresOldSamples() {
        let now = Date(timeIntervalSince1970: 1000)
        let reading = HostLatencyReading(hostID: "pc", address: "host", milliseconds: 2, capturedAt: now)
        var history = HostLatencyHistory()
        history.record(reading, at: now)
        history.record(reading, at: now.addingTimeInterval(1))
        #expect(history.readings.count == 1)
        #expect(history.readings.first?.capturedAt == now)
        history.record(nil, at: now.addingTimeInterval(61))
        #expect(history.readings.isEmpty)
    }

    @Test func historyRejectsInvalidFutureAndOutOfOrderMeasurements() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        for ms in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            history.record(.init(hostID: "pc", address: "host", milliseconds: ms, capturedAt: now), at: now)
        }
        history.record(.init(hostID: "pc", address: "host", milliseconds: 2, capturedAt: now.addingTimeInterval(1)), at: now)
        #expect(history.readings.isEmpty)
        history.record(.init(hostID: "pc", address: "host", milliseconds: 2, capturedAt: now), at: now)
        history.record(.init(hostID: "pc", address: "host", milliseconds: 3, capturedAt: now.addingTimeInterval(-1)), at: now)
        #expect(history.readings.count == 1)
    }

    @Test func historyLeavesAGapWhenMeasurementsAreMissing() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        for offset in [-50.0, -40, -10, 0] {
            history.record(.init(hostID: "pc", address: "host", milliseconds: 2,
                                 capturedAt: now.addingTimeInterval(offset)), at: now)
        }
        #expect(history.segments(maxGap: 22).map(\.count) == [2, 2])
        #expect(history.segments(maxGap: 3).map(\.count) == [1, 1, 1, 1])
    }

    @Test func historyStorageRemainsBoundedForHighFrequencySources() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        for index in 0..<200 {
            history.record(.init(hostID: "pc", address: "host", milliseconds: 2,
                                 capturedAt: now.addingTimeInterval(Double(index) / 100)), at: now.addingTimeInterval(2))
        }
        #expect(history.readings.count == 120)
    }

    @Test func physicalConnectionIsIndependentOfTheTunnelLabel() {
        #expect(HostRouteMonitor.physicalLink(ethernet: true, wifi: false, cellular: false).label == "Ethernet")
        #expect(HostRouteMonitor.physicalLink(ethernet: false, wifi: true, cellular: false).label == "Wi-Fi")
        #expect(HostRouteMonitor.physicalLink(ethernet: false, wifi: false, cellular: true).label == "Cellular")
    }

    @Test func ambiguousOrUnavailablePhysicalLinksAreNotGuessed() {
        #expect(HostRouteMonitor.physicalLink(ethernet: true, wifi: true, cellular: false).label == "Multiple links")
        #expect(HostRouteMonitor.physicalLink(ethernet: true, wifi: false, cellular: true).label == "Multiple links")
        #expect(HostRouteMonitor.physicalLink(ethernet: false, wifi: false, cellular: false).label == "Unavailable")
    }

    private let interfaces = [
        HostRouteMonitor.InterfaceAddress(name: "utun2", address: "100.94.140.12"),
        HostRouteMonitor.InterfaceAddress(name: "utun2", address: "fd7a:115c:a1e0::f635:8c0d"),
        HostRouteMonitor.InterfaceAddress(name: "utun9", address: "100.70.1.2"),
        HostRouteMonitor.InterfaceAddress(name: "en0", address: "192.168.50.10"),
    ]

    @Test func tailscaleIsIdentifiedOnTheSelectedIPv4OrIPv6Interface() {
        for local in ["100.94.140.12", "fd7a:115c:a1e0::f635:8c0d",
                      "FD7A:115C:A1E0:0:0:0:F635:8C0D%utun2"] {
            #expect(HostRouteMonitor.isTailscale(localAddress: local, interfaces: interfaces))
        }
    }

    @Test func anUnrelatedTailscaleInterfaceDoesNotRelabelOtherRoutes() {
        for local in ["100.70.1.2", "192.168.50.10", "100.94.140.13", "", nil] as [String?] {
            #expect(!HostRouteMonitor.isTailscale(localAddress: local, interfaces: interfaces))
        }
    }

    @Test func cgnatAddressesAloneDoNotProveTailscale() {
        #expect(!HostRouteMonitor.isTailscale(localAddress: "100.70.1.2", interfaces: [
            .init(name: "utun9", address: "100.70.1.2"),
            .init(name: "utun9", address: "fd00::1"),
        ]))
    }

    @Test func ambiguousInterfaceOwnershipIsNotLabeledTailscale() {
        let duplicate = interfaces + [.init(name: "utun9", address: "100.94.140.12")]
        #expect(!HostRouteMonitor.isTailscale(localAddress: "100.94.140.12", interfaces: duplicate))
    }

    @Test func latencyRequiresTheSameHostAddressAndUnchangedRoute() {
        let now = Date(timeIntervalSince1970: 1000)
        let reading = HostLatencyReading(hostID: "bazzite", address: "192.168.50.44",
                                         milliseconds: 12, capturedAt: now.addingTimeInterval(-2))
        #expect(reading.text(forHost: "bazzite", address: "192.168.50.44", at: now,
                             notBefore: now.addingTimeInterval(-3), maxAge: 3) == "12 ms")
        #expect(reading.text(forHost: "another-host", address: "192.168.50.44", at: now,
                             notBefore: .distantPast, maxAge: 3) == nil)
        #expect(reading.text(forHost: "bazzite", address: "100.70.1.2", at: now,
                             notBefore: .distantPast, maxAge: 3) == nil)
        #expect(reading.text(forHost: "bazzite", address: "192.168.50.44", at: now,
                             notBefore: now.addingTimeInterval(-1), maxAge: 3) == nil)
    }

    @Test func staleOrFutureLatencyNeverAppears() {
        let now = Date(timeIntervalSince1970: 1000)
        for offset in [-61.0, 1.0] {
            let reading = HostLatencyReading(hostID: "pc", address: "host", milliseconds: 12,
                                             capturedAt: now.addingTimeInterval(offset))
            #expect(reading.text(forHost: "pc", address: "host", at: now,
                                 notBefore: .distantPast, maxAge: 60) == nil)
        }
    }

    @Test func invalidLatencyIsNotRenderedAsANumber() {
        let now = Date(timeIntervalSince1970: 1000)
        for ms in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            let reading = HostLatencyReading(hostID: "pc", address: "host", milliseconds: ms, capturedAt: now)
            #expect(reading.text(forHost: "pc", address: "host", at: now,
                                 notBefore: .distantPast, maxAge: 3) == nil)
        }
    }

    @Test func subMillisecondLatencyIsShownWithoutClaimingAZeroDelay() {
        let now = Date(timeIntervalSince1970: 1000)
        for ms in [0.0, 0.2, 0.9] {
            let reading = HostLatencyReading(hostID: "pc", address: "host", milliseconds: ms, capturedAt: now)
            #expect(reading.text(forHost: "pc", address: "host", at: now,
                                 notBefore: .distantPast, maxAge: 3) == "<1 ms")
        }
    }
}
