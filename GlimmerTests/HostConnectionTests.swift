import Foundation
import Network
import Testing
@testable import Glimmer

struct HostConnectionTests {
    @Test func discoveryKeepsServicesAdvertisedUnderEitherAlias() {
        var services = DiscoveryServiceSet()
        #expect(services.update(["pc"], for: "gfe") == ["pc"])
        #expect(services.update([], for: "sunshine") == ["pc"])
        #expect(services.update(["pc", "other"], for: "sunshine") == ["pc", "other"])
        #expect(services.update([], for: "gfe") == ["pc", "other"])
        #expect(services.update([], for: "sunshine").isEmpty)
    }

    @Test func discoveryRefreshMatchesUUIDRatherThanNameOrStaleAddress() {
        let host = savedPC(id: "KNOWN", address: "100.64.0.10")
        let moved = HostDiscovery.Discovered(id: "bonjour", displayName: "Renamed", host: "192.168.1.9", port: 47989, serverID: "known")
        #expect(DiscoveredHostRoute.savedHost(for: moved, in: [host]) == host)
        let impostor = HostDiscovery.Discovered(id: "other", displayName: host.name, host: moved.host, port: 47989, serverID: "other")
        #expect(DiscoveredHostRoute.savedHost(for: impostor, in: [host]) == nil)
        let unidentified = HostDiscovery.Discovered(id: "missing", displayName: host.name, host: moved.host, port: 47989)
        #expect(DiscoveredHostRoute.savedHost(for: unidentified, in: [host]) == nil)
        let customPort = HostDiscovery.Discovered(id: "custom", displayName: host.name, host: moved.host, port: 48000, serverID: host.id)
        #expect(DiscoveredHostRoute.savedHost(for: customPort, in: [host]) == nil)
    }

    @Test func routeRefreshRequiresMatchingAuthenticatedUUID() {
        #expect(DiscoveredHostRoute.authenticates("known", hostID: "KNOWN"))
        #expect(!DiscoveredHostRoute.authenticates(nil, hostID: "known"))
        #expect(!DiscoveredHostRoute.authenticates("", hostID: "known"))
        #expect(!DiscoveredHostRoute.authenticates("other", hostID: "known"))
    }

    @Test func aRefreshedLocalRouteKeepsTheManualAddressAsFallback() {
        let host = Glimmer.Host(id: "pc", name: "PC", customName: nil,
            localAddress: "192.168.1.9", manualAddress: "100.64.0.10", apps: [],
            lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
        #expect(AppModel.candidateAddresses(for: host) == ["192.168.1.9", "100.64.0.10"])
    }

    @Test func nearbyPCsExcludeSavedIDsEvenAfterAnAddressChange() {
        let saved = savedPC(id: "KNOWN", address: "192.0.2.1")
        let moved = HostDiscovery.Discovered(id: "bonjour", displayName: "Renamed PC", host: "192.0.2.2", port: 47989, serverID: "known")
        #expect(NearbyPCList.available([moved], saved: [saved]).isEmpty)
    }

    @Test func nearbyPCsMatchCanonicalAddressesAndDeduplicateAliases() {
        let saved = savedPC(id: "saved", address: "2001:db8::1")
        let same = HostDiscovery.Discovered(id: "v6", displayName: "PC", host: "[2001:0DB8:0:0:0:0:0:1]", port: 47989)
        let one = HostDiscovery.Discovered(id: "one", displayName: "Gaming PC", host: "192.0.2.2", port: 47989, serverID: "new")
        let alias = HostDiscovery.Discovered(id: "alias", displayName: "Other service name", host: "192.0.2.3", port: 47989, serverID: "new")
        #expect(NearbyPCList.available([same, one, alias], saved: [saved]).count == 1)
        let duplicates = [one, .init(id: "other-alias", displayName: "Another name", host: one.host, port: one.port)]
        #expect(NearbyPCList.available(duplicates, saved: []).count == 1)
    }

    @Test func aMatchingFriendlyNameDoesNotHideAnUnrelatedNearbyPC() {
        let saved = savedPC(id: "saved", address: "192.0.2.1")
        let other = HostDiscovery.Discovered(id: "new", displayName: saved.name, host: "192.0.2.2", port: 47989, serverID: "different")
        #expect(NearbyPCList.available([other], saved: [saved]) == [other])
    }

    private func savedPC(id: String, address: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: "Gaming PC", customName: nil, localAddress: address, manualAddress: nil,
             apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
    }

    @Test func manuallyEnteringAKnownAddressFindsTheExistingPCWithoutPairingAgain() {
        let host = savedPC(id: "saved", address: "GAMING.local.")
        #expect(NearbyPCList.savedPC(at: "gaming.local", in: [host])?.id == "saved")
        #expect(NearbyPCList.savedPC(at: "other.local", in: [host]) == nil)
    }

    @Test @MainActor func cancellingInlinePairingRejectsALateSuccess() async {
        let flow = PCPairingFlow()
        let gate = LatencySampleGate()
        var selected: String?
        flow.start(pin: "1234", pair: { _ in
            _ = await gate.read()
            return .paired("pc")
        }, completed: { selected = $0 })
        #expect(await eventually { gate.waiting })
        flow.cancel()
        #expect(flow.isCancelling)
        gate.resume(1)
        #expect(await eventually { !flow.isRunning })
        #expect(selected == nil && flow.pin == nil && flow.error == nil)
    }

    @Test @MainActor func replacingInlinePairingCannotSelectThePreviousPC() async {
        let flow = PCPairingFlow()
        let old = LatencySampleGate()
        var selected: [String] = []
        flow.start(pin: "1234", pair: { _ in
            _ = await old.read()
            return .paired("old")
        }, completed: { selected.append($0) })
        #expect(await eventually { old.waiting })
        flow.reset()
        flow.start(pin: "5678", pair: { _ in .paired("new") }, completed: { selected.append($0) })
        #expect(await eventually { selected == ["new"] })
        old.resume(1)
        #expect(await eventually { old.returned })
        #expect(selected == ["new"] && !flow.isRunning)
    }

    @Test @MainActor func retryingInlinePairingClearsThePreviousFailureAndUsesANewPIN() async {
        let flow = PCPairingFlow()
        flow.start(pin: "1234", pair: { _ in .failed("Couldn't reach PC") }, completed: { _ in Issue.record("Unexpected success") })
        #expect(await eventually { flow.error != nil })
        let gate = LatencySampleGate()
        flow.start(pin: "5678", pair: { pin in
            #expect(pin == "5678")
            _ = await gate.read()
            return .failed("New attempt")
        }, completed: { _ in Issue.record("Unexpected success") })
        #expect(flow.pin == "5678" && flow.error == nil)
        #expect(await eventually { gate.waiting })
        flow.cancel()
        gate.resume(nil)
        #expect(await eventually { !flow.isRunning })
    }

    @Test @MainActor func cancellingAControlRequestInterruptsAnActivePINWait() async throws {
        let server = try WaitingControlServer()
        defer { server.stop() }
        #expect(await eventually { server.port != nil })
        guard let port = server.port else { return }
        let request = Task {
            try await ControlTransport.get(host: "127.0.0.1", port: Int(port), target: "/pair", userAgent: "Shimmer test",
                tls: false, credential: .init(clientCertPEM: nil, clientKeyPEM: nil, pinnedCertPEM: nil), timeout: 10)
        }
        #expect(await eventually { server.receivedRequest })
        let started = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled request must not return a successful response")
        } catch { #expect(error is CancellationError) }
        #expect(started.duration(to: .now) < .seconds(1))
    }

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

@MainActor private final class WaitingControlServer {
    let listener: NWListener
    private(set) var port: UInt16?
    private(set) var receivedRequest = false
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state { self.port = self.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                    Task { @MainActor in self?.receivedRequest = data?.isEmpty == false }
                    // Bound a regression's wait so a broken cancellation test
                    // reports a failure instead of hanging the test runner.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { connection.cancel() }
                }
            }
        }
        listener.start(queue: .global())
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}
