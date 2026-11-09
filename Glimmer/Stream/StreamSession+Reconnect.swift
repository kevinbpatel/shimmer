//
//  StreamSession+Reconnect.swift
//
//  Silent reconnect-as-stall. When the host closes a LIVE session with a
//  recoverable code - Sunshine's process restarting across a Windows lock /
//  secure-desktop transition (it returns in ~3s), or a brief network blip -
//  we DON'T bounce to the launcher and DON'T sit through the watchdog's 10s
//  freeze-then-teardown. Instead we hold the frozen last frame on screen and
//  silently re-establish the connection underneath it, resuming in place when
//  video flows again (matching Moonlight's "hang then resume"). Only on
//  give-up (attempts/window exhausted) do we tear down for real.
//
//  This is possible because the frozen frame survives a connection teardown:
//  backend.stopConnection() runs the decoder's sink stop()/cleanup() (which
//  only invalidate the VideoToolbox session + param sets), but NOT
//  VideoDecoder.teardown() or StreamWindow.close() - so the
//  AVSampleBufferDisplayLayer keeps its last image until a fresh setup() +
//  IDR repaints over it. We keep the window, decoder, input forwarder, the
//  retained bridge, StreamBridgeContext.current, and the event stream alive
//  across the rebuild; only the backend connection + NetworkClient are
//  replaced.
//

import Foundation
import Network
import QuartzCore
import SwiftUI
import os

/// Sleep is not a failed retry. A wake starts a fresh bounded recovery window;
/// without this, Date-based deadlines expire while the laptop is in a bag.
/// Likewise no network is not a failed retry: right after a wake Wi-Fi is still
/// rejoining, and every attempt in that gap fails in ~2 ms - five of them used
/// to burn the whole budget before the radio was even back.
struct StreamReconnectBudget {
    enum Step: Equatable {
        case waitingForWake
        case waitingForNetwork
        case attempt(Int)
        case exhausted
    }
    /// How long to hold the frozen frame waiting for ANY network after a wake
    /// (or the drop) before giving up. The retry window starts once one is up.
    static let networkWaitSeconds: TimeInterval = 60
    private var deadline: Date
    private var networkWaitDeadline: Date
    private var wakeRevision: UInt64
    private var attempts = 0
    private var waitedForNetwork = false

    init(now: Date, wakeRevision: UInt64) {
        deadline = now.addingTimeInterval(StreamSession.reconnectWindowSeconds)
        networkWaitDeadline = now.addingTimeInterval(Self.networkWaitSeconds)
        self.wakeRevision = wakeRevision
    }

    mutating func nextStep(now: Date, sleeping: Bool, networkAvailable: Bool = true,
                           wakeRevision: UInt64) -> Step {
        if sleeping { return .waitingForWake }
        if self.wakeRevision != wakeRevision {
            self.wakeRevision = wakeRevision
            attempts = 0
            deadline = now.addingTimeInterval(StreamSession.reconnectWindowSeconds)
            networkWaitDeadline = now.addingTimeInterval(Self.networkWaitSeconds)
        }
        if !networkAvailable {
            guard now < networkWaitDeadline else { return .exhausted }
            waitedForNetwork = true
            return .waitingForNetwork
        }
        if waitedForNetwork {
            // The retry window starts when there's a network to retry on.
            waitedForNetwork = false
            deadline = max(deadline, now.addingTimeInterval(StreamSession.reconnectWindowSeconds))
        }
        guard attempts < StreamSession.reconnectAttemptCap, now < deadline else { return .exhausted }
        attempts += 1
        return .attempt(attempts)
    }

    /// The host didn't answer at any saved address, so no handshake was tried:
    /// hand the attempt back, and keep looking until the network-wait limit -
    /// Tailscale can take 10-20s to come back after a wake.
    mutating func refundAttempt() {
        attempts = max(0, attempts - 1)
        deadline = max(deadline, networkWaitDeadline)
    }
}

extension StreamSession {

    /// Entry point for a host-initiated TERMINATION (routed here from
    /// `NativeBackend.connectionTerminated`). Classifies recoverable-vs-fatal and
    /// either drives a silent reconnect episode or tears down as before.
    func handleHostTerminate(code: Int32) async {
        // The uplink is dead the instant the host closed - pause input so we
        // don't spew sends at a gone backend. It re-arms on the next
        // `.connectionEstablished` (handleConnectionEdge → setReady(true)).
        let inp = input
        // FIFO main-queue hop (NOT Task{}) so this pause can't reorder ahead of the
        // reconnect's setReady(true) - see handleConnectionEdge.
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }

        // Nothing to recover if the user is already tearing down, or we're not
        // (or no longer) the live session.
        guard isStreaming, !stopInProgress else { return }
        // An episode is already being driven - its retry loop owns the outcome.
        // A re-terminate fired by the dead/old backend (or a failed reconnect
        // attempt) must not start a second episode.
        guard !isReconnecting else { return }

        // Recoverable iff we'd already reached a live state AND the cause is one we
        // can resume from: a host terminate in the recoverable set (server restart /
        // graceful), or OUR OWN ENet dead-peer self-terminate (-1, the radio-doze /
        // link-blip case). A terminate before the first live edge is a failed
        // connect, not an interruption - fall through to the honest teardown so the
        // launcher shows the failure. The 10s dead-peer envelope is unchanged; this
        // only chooses silent-reconnect over teardown once it has fired.
        let recoverableCause = Self.recoverableTerminationCodes.contains(code)
            || code == Self.deadPeerTerminationCode
        let recoverable = recoverableCause && reachedLiveState
        guard recoverable else {
            bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
            await stop(cause: code == 0 ? .hostClosedClean : .hostError)
            return
        }

        // Our own dead-peer (-1) says nothing about the PC. A code the PC sent may
        // mean it ended the session on purpose (a quit on the PC, Force Stop, or
        // another device taking over), so ask before relaunching anything.
        if code != Self.deadPeerTerminationCode {
            isReconnecting = true   // the probe owns the outcome; re-entrant terminates wait
            let runningAppID = await probeRunningAppID()
            isReconnecting = false
            guard isStreaming, !stopInProgress else { return }
            if Self.pcEndedSession(runningAppID: runningAppID, appID: reconnectAppID) {
                Diag.notice("The PC ended the session (code 0x\(String(UInt32(bitPattern: code), radix: 16)), "
                    + "now running app \(runningAppID ?? 0)) - ending the stream, not reconnecting.", "Stream")
                await endStreamClosedByPC()
                return
            }
        }
        await runReconnectEpisode(code: code, cause: Self.reconnectCause(code: code))
    }

    /// Whether the PC ended the session on purpose: it answered and no longer
    /// runs our app (0 after a quit on the PC or Force Stop, another id after a
    /// takeover). No answer means Sunshine is restarting, which a reconnect rides out.
    static func pcEndedSession(runningAppID: Int?, appID: Int?) -> Bool {
        guard let runningAppID, let appID else { return false }
        return runningAppID != appID
    }

    /// Whether a reconnect would take the PC over from another app: it now runs
    /// one that isn't ours, which only another device (or the user at the PC)
    /// could have started. Idle (0) is ours to relaunch.
    static func pcMovedOn(runningAppID: Int, appID: Int) -> Bool {
        runningAppID != 0 && runningAppID != appID
    }

    /// One quick /serverinfo over the paired channel: the app the PC runs now,
    /// or nil if it didn't answer in time (or answered without a trustworthy
    /// currentgame). The HTTP leg can't be cancelled, so it is raced, not awaited.
    private func probeRunningAppID() async -> Int? {
        guard let server = reconnectServer else { return nil }
        let net = NetworkClient(server: server)
        let box = FirstResultBox<Int?>()
        let probe = Task {
            let info = try? await net.fetchServerInfo()
            let trusted = info.map { $0.reportsCurrentGame && $0.pairStatus == .paired } ?? false
            await box.offer(.success(trusted ? info?.currentGameID : nil))
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(Self.hostEndProbeSeconds))
            await box.offer(.success(nil))
        }
        let answer = try? await box.value.get()
        probe.cancel()
        timer.cancel()
        return answer ?? nil
    }

    /// The PC ended the session on purpose: end it like a clean close, with no
    /// error banner, no /launch and no /cancel.
    private func endStreamClosedByPC() async {
        pcEndedSession = true
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: 0))
        await stop(cause: .hostClosedClean)
    }

    /// Why the episode's log line says the link went away: -1 is our own link
    /// dropping, not the PC restarting.
    static func reconnectCause(code: Int32) -> String {
        if code == deadPeerTerminationCode { return "our link to the PC dropped (code -1)" }
        return "the PC closed the live stream (code 0x\(String(UInt32(bitPattern: code), radix: 16))), "
            + "likely restarting across a lock or desktop switch"
    }

    /// A reconnect this side chose on a live connection (a bitrate change, a
    /// decoder that never decodes what arrives). Unlike `handleHostTerminate`,
    /// the host has NOT closed anything; the same episode machinery runs, so the
    /// frozen frame holds under the banner and video resumes in place. The first
    /// `reconnectInPlace` brings the live connection down itself
    /// (`teardownConnectionForReconnect` is idempotent), so this only stops
    /// feeding the uplink, exactly as the host-terminate path does.
    func runSelfInitiatedReconnect(cause: String, bannerText: String = "Reconnecting…") async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        let inp = input
        DispatchQueue.main.async { MainActor.assumeIsolated { inp?.setReady(false) } }
        await runReconnectEpisode(code: Self.deadPeerTerminationCode, cause: cause, bannerText: bannerText)
    }

    /// Drive a bounded reconnect episode: hold the frozen frame, retry the
    /// in-place rebuild with a short backoff until it succeeds or we exhaust the
    /// attempt/time budget, then resume (`.reconnected`) or give up (real
    /// teardown). MainActor work happens inside `reconnectInPlace`.
    private func runReconnectEpisode(code: Int32, cause: String, bannerText: String = "Reconnecting…") async {
        isReconnecting = true
        reconnectAttempts = 0
        var budget = StreamReconnectBudget(now: Date(), wakeRevision: reconnectWakeRevision)
        bridge?.eventContinuation?.yield(.reconnecting)
        // Surface the hold over the frozen frame - the launcher's phase chip is
        // occluded by the fullscreen window, so this banner is the only in-stream
        // signal that we're holding rather than dead.
        let winForBanner = window
        await MainActor.run {
            winForBanner?.reconnectBanner.setText(bannerText)
            winForBanner?.reconnectBanner.setVisible(true)
            // VoiceOver can't reach a CALayer banner by focus - announce the
            // reconnect explicitly (the most safety-critical in-stream state).
            AccessibilityNotification.Announcement(bannerText).post()
        }
        Diag.notice("Reconnecting in place, holding the last frame: \(cause).", "Stream")

        startReconnectPathMonitor()
        defer { stopReconnectPathMonitor() }
        var waitingForNetwork = false
        var pcMovedOn = false

        recovery: while isStreaming, !stopInProgress {
            switch budget.nextStep(now: Date(), sleeping: systemSleeping,
                                   networkAvailable: reconnectNetworkAvailable,
                                   wakeRevision: reconnectWakeRevision) {
            case .waitingForWake:
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            case .waitingForNetwork:
                if !waitingForNetwork {
                    waitingForNetwork = true
                    Diag.notice("reconnect: no network yet - waiting before retrying", "Stream")
                    await setReconnectBanner("Waiting for network…")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            case .exhausted: break recovery
            case .attempt(let number): reconnectAttempts = number
            }
            if waitingForNetwork {
                waitingForNetwork = false
                await setReconnectBanner(bannerText)
            }
            let wakeRevision = reconnectWakeRevision
            // Backoff: the host (Sunshine) is mid-restart and its HTTPS endpoint
            // may not answer for ~3s. A short ramp (0.8s, 1.6s, then 2.4s) keeps
            // the first resume snappy; launchWithBusyRecovery's own
            // waitForHostIdle poll absorbs the rest of the host's settle time.
            let delayMs = UInt64(min(reconnectAttempts, 3)) * 800
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            if !isStreaming || stopInProgress { break }
            if systemSleeping || wakeRevision != reconnectWakeRevision { continue }
            // Find the host before spending an attempt on a handshake: home
            // first, then the manual address (Tailscale) for when the laptop
            // woke up somewhere else.
            guard let address = await reachableReconnectAddress() else {
                budget.refundAttempt()
                continue
            }
            if reconnectServer?.address != address {
                Diag.notice("reconnect: host answers at \(address, privacy: .private) - switching to it", "Stream")
                reconnectServer?.address = address
            }
            Diag.notice("reconnect attempt \(reconnectAttempts)/\(Self.reconnectAttemptCap)...", "Stream")
            let outcome = await reconnectInPlace()
            if outcome == .pcMovedOn {
                pcMovedOn = true
                break recovery
            }
            if outcome == .resumed {
                isReconnecting = false
                reconnectAttempts = 0
                // Count the genuine reconnect HERE. The established-edge inference
                // (markEstablishedReportingReconnect) can't: reconnectInPlace re-runs
                // connectBackend → anchorTelemetryConnectStart → p2.reset(), which
                // wipes the established memory before the fresh edge fires, so that
                // path always reads the reconnect as a first connect. This site is
                // the unambiguous "a drop was silently recovered" signal.
                TelemetryCounters.shared.reconnectTotal.increment()
                bridge?.eventContinuation?.yield(.reconnected)
                let winForHide = window
                await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
                Diag.notice("reconnected - stream resumed in place", "Stream")
                // The new connection's decode clock starts here, not at the old
                // connection's last frame (watchdogDecodeIdle floors at the arm),
                // and a later stall logs/recovers fresh.
                await MainActor.run { self.frameWatchdogArmedAt = CACurrentMediaTime() }
                resetStallLatches()
                return
            }
        }

        // Exhausted the budget (or the user quit mid-episode). Give up to a real
        // teardown so the launcher shows the session ended.
        isReconnecting = false
        let winForGiveup = window
        await MainActor.run { winForGiveup?.reconnectBanner.setVisible(false) }
        guard isStreaming, !stopInProgress else { return }
        if pcMovedOn {
            Diag.notice("reconnect: the PC is running another app now - ending the stream, not taking it over.",
                        "Stream")
            await endStreamClosedByPC()
            return
        }
        Diag.error(
            "reconnect exhausted after \(reconnectAttempts) attempt(s) - tearing down",
            "Stream")
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: code))
        await stop(cause: .hostError)
    }

    /// The first saved host address answering on the HTTP port, or nil if none
    /// does yet. The session's current address is the fallback list when the
    /// caller passed none.
    private func reachableReconnectAddress() async -> String? {
        guard let server = reconnectServer else { return nil }
        let candidates = reconnectAddresses.isEmpty ? [server.address] : reconnectAddresses
        for address in candidates {
            if case .reachable = await HostReachability.measureRTT(
                host: address, port: server.httpPort, timeoutMs: 1_500) {
                return address
            }
            if !isStreaming || stopInProgress { return nil }
        }
        return nil
    }

    private func setReconnectBanner(_ text: String) async {
        let win = window
        await MainActor.run { win?.reconnectBanner.setText(text) }
    }

    /// Track whether the Mac has any usable network while an episode runs.
    private func startReconnectPathMonitor() {
        stopReconnectPathMonitor()
        reconnectNetworkAvailable = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.setReconnectNetworkAvailable(available) }
        }
        monitor.start(queue: DispatchQueue(label: "shimmer.reconnect.path"))
        reconnectPathMonitor = monitor
    }

    private func stopReconnectPathMonitor() {
        reconnectPathMonitor?.cancel()
        reconnectPathMonitor = nil
        reconnectNetworkAvailable = true
    }

    private func setReconnectNetworkAvailable(_ available: Bool) {
        guard reconnectPathMonitor != nil else { return }
        reconnectNetworkAvailable = available
    }

    /// One reconnect attempt: tear down ONLY the dead connection, swap in a fresh
    /// backend, re-point input/decoder at it, and re-run the handshake +
    /// /launch + startConnection against the (restarted) host - all while the
    /// window, decoder, frozen frame, bridge, and event stream stay alive.
    /// Says whether the connection is back up, or the PC now runs another app.
    private func reconnectInPlace() async -> ReconnectAttemptOutcome {
        guard isStreaming, !stopInProgress else { return .failed }
        guard let server = reconnectServer,
              let config = reconnectConfig,
              let appID = reconnectAppID,
              let win = window, let inp = input, let dec = videoDecoder else { return .failed }

        // 1. Bring the dead connection fully down (idempotent - onTerminated
        //    already called stopConnection). Keeps the window/decoder/frozen
        //    frame, the bridge + event stream, and StreamBridgeContext.current.
        await teardownConnectionForReconnect()

        // H5: re-check after the teardown await. stop() flips isStreaming/
        // stopInProgress synchronously before its own first await, so a guard
        // evaluated ON the actor between awaits reliably observes a teardown that
        // slipped in. Bail BEFORE building a fresh backend - nothing to clean up.
        guard isStreaming, !stopInProgress else { return .failed }

        // 2. Swap in a fresh backend (NativeBackend is one-shot: its connection
        //    state can't be reused and interrupt() latches permanently). Re-point
        //    input + decoder on the MainActor so uplink + IDR requests go to the
        //    new backend, not the dead one.
        let fresh = NativeBackend()
        self.backend = fresh
        await MainActor.run {
            inp.setBackend(fresh)
            dec.setBackend(fresh)
            // Re-derive the Cruise ceiling: reconnect reuses the forwarder and
            // never re-runs StartSetup, so a mid-session resolution change would
            // otherwise keep a stale gMax.
            inp.cruiseGMax = CruiseTraversal.gMax(forStreamWidth: config.width)
            // Same reasoning for the absolute pointer's reference frame: a
            // reconnect at a new resolution would otherwise keep mapping
            // window points onto the old stream's pixel grid.
            inp.streamPixelSize = CGSize(width: config.width, height: config.height)
            // ...and for the PiP mirror source, which is sized on the stream's
            // aspect line.
            win.streamPixelSize = inp.streamPixelSize
        }

        // 3. Fresh NetworkClient + full handshake against the restarted host.
        let net = NetworkClient(server: server)
        self.network = net
        do {
            let serverInfo = try await net.fetchServerInfo()
            // Another app on the PC means someone took it over (or the user
            // started something at the PC): a reconnect must not /cancel it.
            if serverInfo.reportsCurrentGame,
               Self.pcMovedOn(runningAppID: serverInfo.currentGameID, appID: appID) {
                Diag.notice("reconnect: the PC now runs app \(serverInfo.currentGameID), not ours (\(appID))",
                            "Stream")
                await net.shutdown()
                if self.network === net { self.network = nil }
                return .pcMovedOn
            }
            let launch = try await launchWithBusyRecovery(
                network: net, appID: appID, config: config,
                hintCurrentGame: serverInfo.currentGameID, allowResume: !serverInfo.isRealGFE)
            // Re-probe the path on reconnect: the route may have moved (the
            // tunnel-flap case this whole clamp exists for), so remoteness and
            // the advertised packet size are resolved fresh, never inherited.
            let backendConfig = makeBackendConfig(
                config: config, launch: launch, server: serverInfo)
            // duringReconnect: connectBackend's failure path must NOT run the
            // full stop() (that would blank the frozen frame + bounce to the
            // launcher) - it cancels the failed launch and throws so we retry.
            try await connectBackend(
                serverInfo: serverInfo, launch: launch, backendConfig: backendConfig,
                setup: (win, inp, dec), network: net, duringReconnect: true)
        } catch {
            Diag.notice("reconnect attempt failed: \(error, privacy: .private)", "Stream")
            await net.shutdown()
            self.network = nil
            return .failed
        }

        // H5: a stop() can land at ANY of the awaits above (~0.8-2.4s of handshake
        // per attempt, plus the frozen "Reconnecting..." banner invites a quit).
        // If one did, `fresh` + `net` are now a LIVE ENet/RTP backend on a session
        // with isStreaming=false and no teardown path - a zombie for the process
        // lifetime, with the host holding a "busy" session. interruptConnection()
        // (the permanent latch, drains the receive threads) + drop the client so
        // no live backend/NetworkClient survives the slipped-in stop. The episode
        // loop's own re-checks then exit; the existing stop() torn-down everything
        // else (window/decoder/bridge) already.
        guard isStreaming, !stopInProgress else {
            Diag.notice("reconnect: stop slipped in mid-handshake - "
                + "interrupting the freshly-built backend to kill the zombie connection", "Stream")
            await tearDownSlippedInReconnect(fresh: fresh, net: net)
            return .failed
        }

        // 4. Nudge a keyframe so the fresh VT session repaints over the frozen
        //    frame promptly (Sunshine sends one at start; cheap insurance).
        backend.requestIdrFrame()
        return .resumed
    }

    /// H5 cleanup: a `stop()` slipped in while this attempt was mid-handshake, so
    /// the just-built `fresh` backend + `net` client are live on an already-ended
    /// session. Interrupt the backend (permanent latch; drains the receive threads
    /// so no callback can fire after) and shut the client so the host drops its
    /// session record. Only nil `self.network` if it's still the one we built - a
    /// concurrent stop() may have already nil'd it.
    private func tearDownSlippedInReconnect(fresh: NativeBackend, net: NetworkClient) async {
        fresh.interruptConnection()
        try? await net.cancel()
        await net.shutdown()
        if self.network === net { self.network = nil }
    }

    /// Connection-only teardown for a reconnect: bring the backend connection
    /// down and drop the NetworkClient WITHOUT the things `stop()` does that
    /// would end the session - no event-stream finish, no bridge release, no
    /// `StreamBridgeContext.current` clear, no window close, no decoder teardown,
    /// no power-assertion end, and crucially NO `/cancel` (the host session is
    /// already gone; a /cancel could race the host's freshly-restarted one -
    /// launchWithBusyRecovery does the proper /cancel+/launch on the new client).
    private func teardownConnectionForReconnect() async {
        backend.stopConnection()
        if let net = network { await net.shutdown() }
        network = nil
        if let state = connectFlowState {
            OSSignposter.network.endInterval("ConnectFlow", state, "outcome=reconnect")
            connectFlowState = nil
        }
    }
}

/// How one in-place reconnect attempt ended.
enum ReconnectAttemptOutcome: Equatable {
    case resumed
    case failed
    /// The PC runs another app now; reconnecting would take it over.
    case pcMovedOn
}
