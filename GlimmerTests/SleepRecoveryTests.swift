import Foundation
import Testing
@testable import Glimmer

struct SleepRecoveryTests {
    @Test @MainActor func aDroppedConnectionNeverShowsTheTriangle() {
        let model = AppModel()
        model.nativeStreamError = "Connection was interrupted."
        model.markStreamInterruption(hostID: "offline-host")
        #expect(!model.menuBarShowsStreamError)
        #expect(model.menuBarSystemImageName == nil)
        #expect(model.nativeStreamError == "Connection was interrupted.")
    }

    @Test @MainActor func aNewerActionableFailureStillShowsTheTriangle() {
        let model = AppModel()
        model.nativeStreamError = "Connection was interrupted."
        model.markStreamInterruption(hostID: "offline-host")
        model.nativeStreamError = "Pair this host again."
        #expect(model.menuBarShowsStreamError)
        #expect(model.menuBarSystemImageName == "exclamationmark.triangle.fill")
        model.nativeStreamError = nil // Dismiss
        #expect(!model.menuBarShowsStreamError)
    }

    @Test @MainActor func hostTerminationsAndStageFailuresAreInterruptions() {
        let model = AppModel()
        let host = Self.host("test-host")
        for code in [StreamSession.recoverableTerminationCode, StreamSession.deadPeerTerminationCode] {
            model.handleNativeEvent(.connectionTerminated(errorCode: code), host: host)
            #expect(model.nativeStreamError != nil)
            #expect(!model.menuBarShowsStreamError)
        }
        model.nativeStreamError = nil
        model.handleNativeEvent(.stageFailed(name: "RTSP handshake", errorCode: -1), host: host)
        #expect(model.nativeStreamError != nil)
        #expect(!model.menuBarShowsStreamError)
    }

    @Test func transientClassificationPreservesErrorsThatNeedAction() {
        #expect(AppModel.isTransientConnectionFailure(StreamError.hostUnreachable("offline")))
        #expect(AppModel.isTransientConnectionFailure(StreamError.sessionFailed(-1)))
        #expect(AppModel.isTransientConnectionFailure(URLError(.networkConnectionLost)))
        #expect(AppModel.isTransientConnectionFailure(POSIXError(.ENETUNREACH)))
        #expect(!AppModel.isTransientConnectionFailure(URLError(.serverCertificateUntrusted)))
        for error in [StreamError.pairingRejected, .pairingFailed("pair it again"),
                      .crypto("bad signature"), .decoderFailed("unsupported codec"),
                      .hostUnreachable("CERT mismatch"), .hostUnreachable("Restart Sunshine")] {
            #expect(!AppModel.isTransientConnectionFailure(error))
        }
    }

    @Test func aLongNapDoesNotExhaustRecovery() {
        let start = Date(timeIntervalSince1970: 1_000)
        var budget = StreamReconnectBudget(now: start, wakeRevision: 0)
        #expect(budget.nextStep(now: start, sleeping: false, wakeRevision: 0) == .attempt(1))
        let later = start.addingTimeInterval(3_600)
        for _ in 0..<10 {
            #expect(budget.nextStep(now: later, sleeping: true, wakeRevision: 0) == .waitingForWake)
        }
        #expect(budget.nextStep(now: later, sleeping: false, wakeRevision: 1) == .attempt(1))
        #expect(budget.nextStep(now: later.addingTimeInterval(1), sleeping: false,
                               wakeRevision: 1) == .attempt(2))
    }

    @Test func recoveryStillStopsOnAnUnavailableNetwork() {
        let start = Date(timeIntervalSince1970: 1_000)
        var budget = StreamReconnectBudget(now: start, wakeRevision: 0)
        for number in 1...StreamSession.reconnectAttemptCap {
            #expect(budget.nextStep(now: start, sleeping: false, wakeRevision: 0) == .attempt(number))
        }
        #expect(budget.nextStep(now: start, sleeping: false, wakeRevision: 0) == .exhausted)
        #expect(budget.nextStep(now: start, sleeping: false, wakeRevision: 1) == .attempt(1))
        #expect(budget.nextStep(now: start.addingTimeInterval(StreamSession.reconnectWindowSeconds),
                               sleeping: false, wakeRevision: 1) == .exhausted)
    }

    @Test func noNetworkAfterWakeDoesNotSpendAttempts() {
        let start = Date(timeIntervalSince1970: 1_000)
        var budget = StreamReconnectBudget(now: start, wakeRevision: 0)
        // Wi-Fi takes 20s to come back: no attempts spent, and the retry window
        // only starts once it's up.
        for second in 0..<20 {
            #expect(budget.nextStep(now: start.addingTimeInterval(Double(second)), sleeping: false,
                                   networkAvailable: false, wakeRevision: 0) == .waitingForNetwork)
        }
        let back = start.addingTimeInterval(20)
        #expect(budget.nextStep(now: back, sleeping: false, wakeRevision: 0) == .attempt(1))
        #expect(budget.nextStep(now: back.addingTimeInterval(StreamSession.reconnectWindowSeconds - 1),
                               sleeping: false, wakeRevision: 0) == .attempt(2))
    }

    @Test func noNetworkAtAllEventuallyGivesUp() {
        let start = Date(timeIntervalSince1970: 1_000)
        var budget = StreamReconnectBudget(now: start, wakeRevision: 0)
        let late = start.addingTimeInterval(StreamReconnectBudget.networkWaitSeconds)
        #expect(budget.nextStep(now: late, sleeping: false, networkAvailable: false,
                               wakeRevision: 0) == .exhausted)
    }

    @Test func anUnansweredProbeIsRefundedButTheWindowStillEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var budget = StreamReconnectBudget(now: start, wakeRevision: 0)
        for _ in 0..<(StreamSession.reconnectAttemptCap * 3) {
            #expect(budget.nextStep(now: start, sleeping: false, wakeRevision: 0) == .attempt(1))
            budget.refundAttempt()
        }
        #expect(budget.nextStep(now: start.addingTimeInterval(StreamSession.reconnectWindowSeconds),
                               sleeping: false, wakeRevision: 0) == .attempt(1))
        #expect(budget.nextStep(now: start.addingTimeInterval(StreamReconnectBudget.networkWaitSeconds),
                               sleeping: false, wakeRevision: 0) == .exhausted)
    }

    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
             apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
             gfeVersion: nil, macAddress: nil)
    }

    @Test @MainActor func verifiedHostRecoveryClearsOnlyTheOldNetworkWarning() async {
        let model = AppModel()
        let host = Self.host("sleep-recovery-test")
        model.selectedHost = host
        model.handleNativeEvent(.connectionTerminated(errorCode: -1), host: host)
        #expect(model.nativeStreamError != nil)
        #expect(model.menuBarSystemImageName == nil)
        let status = HostLiveStatus(hostID: host.id, state: .streamingApp(name: "Steam Big Picture"),
                                    sunshineVersion: "Sunshine", capturedAt: .now)
        await model.publishLiveStatus(status, expectedHostID: host.id)
        #expect(model.nativeStreamError == nil)
        #expect(model.menuBarSystemImageName == nil)

        // An authenticated host response doesn't repair a different stream fault.
        model.handleNativeEvent(.connectionTerminated(errorCode: -1), host: host)
        model.nativeStreamError = "Couldn't start the video decoder."
        await model.publishLiveStatus(status, expectedHostID: host.id)
        #expect(model.nativeStreamError == "Couldn't start the video decoder.")
    }

    @Test @MainActor func unverifiedOrUnrelatedStatusCannotDismissAnInterruption() async {
        let model = AppModel()
        let host = Self.host("sleep-recovery-test")
        model.selectedHost = host
        model.handleNativeEvent(.connectionTerminated(errorCode: -1), host: host)
        let warning = model.nativeStreamError
        var status = HostLiveStatus(hostID: host.id, state: .idle, capturedAt: .now)
        await model.publishLiveStatus(status, expectedHostID: host.id)
        #expect(model.nativeStreamError == warning) // TCP-only fallback
        status.sunshineVersion = "Sunshine"
        status.state = .certMismatch
        await model.publishLiveStatus(status, expectedHostID: host.id)
        #expect(model.nativeStreamError == warning)
        status.state = .idle
        status.capturedAt = .distantPast
        await model.publishLiveStatus(status, expectedHostID: host.id)
        #expect(model.nativeStreamError == warning)
        status.capturedAt = .now
        status.hostID = "other-host"
        model.clearRecoveredInterruption(status)
        #expect(model.nativeStreamError == warning)
        model.handleNativeEvent(.connectionEstablished, host: host)
        #expect(model.nativeStreamError == nil)
    }
}

// MARK: - Session ownership (ported from upstream's SessionLaunchTests)

struct SessionLaunchTests {

    /// A pipeline's events go to the session it started for, whichever is current when they fire,
    /// so a late callback from a timed-out pipeline can't land in the next session (3b8c219a).
    @Test @MainActor func eventsGoToTheSessionTheirPipelineStartedFor() async {
        let session = StreamSession()
        let bridge = StreamBridgeContext(session: session, videoDecoder: VideoDecoder(),
                                         audioDecoder: AudioDecoder(),
                                         inputForwarder: InputForwarder(observeGamepads: false))
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        bridge.eventContinuation = continuation
        let other = StreamBridgeContext(session: StreamSession(), videoDecoder: VideoDecoder(),
                                        audioDecoder: AudioDecoder(),
                                        inputForwarder: InputForwarder(observeGamepads: false))
        let (otherStream, otherContinuation) = AsyncStream<StreamEvent>.makeStream()
        other.eventContinuation = otherContinuation
        let previous = StreamBridgeContext.current
        StreamBridgeContext.current = other
        defer { StreamBridgeContext.current = previous }

        NativeConnectionEvents(bridge: bridge).stageStarting("name resolution")
        continuation.finish()
        otherContinuation.finish()
        var received = 0
        for await _ in stream { received += 1 }
        var strayed = 0
        for await _ in otherStream { strayed += 1 }
        #expect(received == 1)
        #expect(strayed == 0)
    }

    /// Quitting during "Reconnecting…" after an attempt failed: stop still has a client for the PC
    /// it launched on, so a quit sends its /cancel instead of leaving the game running (53e36392).
    @Test func stopCanCancelAfterAFailedReconnectAttempt() async {
        let session = StreamSession()
        await session.loseNetworkAfterReconnect(
            to: ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC"))
        let cleanup = await session.cleanupNetwork
        #expect(await cleanup?.server.uniqueId == "pc")
    }
}

private extension StreamSession {
    func loseNetworkAfterReconnect(to server: ServerInfo) {
        reconnectServer = server
        network = nil
    }
}
