import Foundation
import Testing
@testable import Glimmer

struct HostConnectionTests {
    @Test func graphScaleAdaptsFromFastLANToSlowerConnections() {
        for (maximum, upper) in [(0.4, 1.0), (1, 1), (1.2, 2), (4, 5),
                                 (9, 10), (26, 50), (99, 100), (101, 200)] {
            let scale = LatencyGraphScale(maximum: maximum)
            #expect(scale.upperBound == upper)
            #expect(scale.ticks == [0, upper / 2, upper])
        }
        #expect(LatencyGraphScale(maximum: 0.4).ticks == [0, 0.5, 1])
    }

    @Test func graphScaleHasAFinitePositiveRangeAndNeverClipsValidMeasurements() {
        for maximum in [0.0, 0.001, 0.999, 1, 2.001, 5, 10.001, 9999, Double(Int.max).nextDown] {
            let scale = LatencyGraphScale(maximum: maximum)
            #expect(scale.upperBound.isFinite && scale.upperBound > 0)
            #expect(scale.upperBound >= maximum)
        }
        for maximum in [nil, .nan, .infinity, -.infinity, -1, Double(Int.max)] as [Double?] {
            #expect(LatencyGraphScale(maximum: maximum).upperBound == 10)
        }
    }

    @Test func failedReadingBreaksTheTraceEvenBetweenCloselySpacedSamples() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        history.record(.init(hostID: "pc", address: "host", milliseconds: 2, capturedAt: now), at: now)
        history.record(nil, at: now.addingTimeInterval(1))
        history.record(.init(hostID: "pc", address: "host", milliseconds: 3,
                             capturedAt: now.addingTimeInterval(2)), at: now.addingTimeInterval(2))
        #expect(history.segments(maxGap: 3.5).map(\.count) == [1, 1])
    }

    @Test @MainActor func diagnosticIsIdleUntilRequestedAndAutomaticallyFinishes() async {
        let test = HostLatencyTest(limit: 3, interval: .zero)
        #expect(!test.hasRun && !test.isRunning && test.attempts == 0)
        var calls = 0
        test.start(hostID: "pc", address: "host") { calls += 1; return Double(calls) }
        #expect(await eventually { test.completed })
        #expect(!test.isRunning && test.hasRun)
        #expect(calls == 3 && test.history.readings.count == 3)
        #expect(test.latestDescription == "3 ms")
    }

    @Test @MainActor func stoppingDiagnosticRejectsALateUncancellableResult() async {
        let test = HostLatencyTest(limit: 1)
        let gate = LatencySampleGate()
        test.start(hostID: "old", address: "old-host") { await gate.read() }
        #expect(await eventually { gate.waiting })
        test.stop()
        gate.resume(50)
        #expect(await eventually { gate.returned })
        #expect(!test.isRunning && test.attempts == 0)
        #expect(test.history.readings.isEmpty && test.latestReading == nil)
    }

    @Test @MainActor func restartingDiagnosticCannotMixResultsFromDifferentHosts() async {
        let test = HostLatencyTest(limit: 1)
        let gate = LatencySampleGate()
        test.start(hostID: "old", address: "old-host") { await gate.read() }
        #expect(await eventually { gate.waiting })
        test.start(hostID: "new", address: "new-host") { 2 }
        #expect(await eventually { test.completed })
        gate.resume(99)
        #expect(await eventually { gate.returned })
        #expect(test.history.readings.count == 1)
        #expect(test.latestReading?.hostID == "new")
        #expect(test.latestDescription == "2 ms")
        test.reset()
        #expect(!test.hasRun && test.history.readings.isEmpty)
    }

    @Test @MainActor func failedDiagnosticDoesNotClaimZeroLatency() async {
        let test = HostLatencyTest(limit: 1)
        test.start(hostID: "pc", address: "host") { nil }
        #expect(await eventually { test.completed })
        #expect(test.attempts == 1 && test.history.readings.isEmpty)
        #expect(test.latestDescription == "Unavailable")
    }

    @Test func tcpProbeRejectsInvalidPortsWithoutTrapping() async {
        for port in [-1, 0, 65536, Int.max] {
            #expect(await HostReachability.measureRTT(host: "unused.invalid", port: port) == .unreachable)
        }
    }

    @Test func cancelledTCPProbeDoesNotBeginNetworkWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await HostReachability.measureRTT(host: "unused.invalid")
        }
        #expect(await task.value == .unreachable)
    }

    @MainActor private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func historySummaryUsesOnlyActualMeasurementsInTheVisibleMinute() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        for (offset, value) in [(-59.0, 100.0), (-30, 2), (-10, 4), (0, 9)] {
            history.record(.init(hostID: "pc", address: "host", milliseconds: value,
                                 capturedAt: now.addingTimeInterval(offset)), at: now)
        }
        let stats = history.statistics(at: now.addingTimeInterval(2))
        #expect(stats?.minimum == 2)
        #expect(stats?.maximum == 9)
        #expect(stats?.average == 5)
        #expect(stats?.count == 3)
        #expect(history.statistics(at: now.addingTimeInterval(61)) == nil)
    }

    @Test func emptyHistoryDoesNotClaimZeroTimingAndSingleSampleIsValid() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = HostLatencyHistory()
        #expect(history.statistics(at: now) == nil)
        history.record(.init(hostID: "pc", address: "host", milliseconds: 0.4, capturedAt: now), at: now)
        let stats = history.statistics(at: now)
        #expect(stats?.minimum == 0.4)
        #expect(stats?.maximum == 0.4)
        #expect(stats?.average == 0.4)
        #expect(stats?.count == 1)
    }

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

@MainActor
private final class LatencySampleGate {
    private var continuation: CheckedContinuation<Double?, Never>?
    var waiting: Bool { continuation != nil }
    private(set) var returned = false
    func read() async -> Double? {
        let value = await withCheckedContinuation { continuation = $0 }
        returned = true
        return value
    }
    func resume(_ value: Double?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
