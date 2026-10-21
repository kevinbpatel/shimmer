import Foundation
import Testing
@testable import Glimmer

struct HostActivityTests {
    private static let now = Date(timeIntervalSince1970: 10_000)

    @Test func missingSessionInformationIsNotAnIdleHost() {
        let names = [3: "Steam Big Picture"]
        #expect(HostLiveStatus.reportedState(currentGameID: nil, appNamesByID: names) == .reachable)
        #expect(HostLiveStatus.reportedState(currentGameID: 0, appNamesByID: names) == .idle)
        #expect(HostLiveStatus.reportedState(currentGameID: 3, appNamesByID: names)
                == .streamingApp(name: "Steam Big Picture"))
        #expect(HostLiveStatus.reportedState(currentGameID: 4, appNamesByID: names)
                == .streamingUnknownApp(id: 4))
    }

    private static func host(_ id: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: nil, manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
                     gfeVersion: nil, macAddress: nil)
    }

    @Test @MainActor func staleAndWrongHostSnapshotsCannotClaimAnAppIsRunning() {
        let model = AppModel()
        let host = Self.host("host-activity-a")
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id,
                                             state: .streamingApp(name: "Steam Big Picture"),
                                             capturedAt: Self.now)
        #expect(model.hostStatusLine(for: host.id, at: Self.now) == "Host session: Steam Big Picture")
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .online)
        let expired = Self.now.addingTimeInterval(HostLiveStatus.stale + 1)
        #expect(model.hostStatusLine(for: host.id, at: expired) == "Checking…")
        #expect(model.hostStatusIndicator(for: host.id, at: expired) == .neutral)
        #expect(model.hostStatusLine(for: "other-host", at: Self.now) == "Checking…")
        #expect(model.hostStatusIndicator(for: "other-host", at: Self.now) == .neutral)
        #expect(model.liveStatus(for: "other-host", at: Self.now) == nil)
    }

    @Test @MainActor func transportReachabilityDoesNotClaimAnIdleSession() {
        let model = AppModel()
        let host = Self.host("host-activity-a")
        model.selectedHost = host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id, state: .reachable, capturedAt: Self.now)
        #expect(model.hostStatusLine(for: host.id, at: Self.now) == "Online · session status unavailable")
        #expect(model.hostStatusIndicator(for: host.id, at: Self.now) == .neutral)
        #expect(model.runningAppName == nil)
        #expect(!HostLiveStatus.State.reachable.hasSessionInformation)
        #expect(HostLiveStatus.State.idle.hasSessionInformation)
    }

    @Test @MainActor func connectionProgressIsNotAStreamingClaimAndBelongsToOneHost() {
        let model = AppModel()
        model.isStreaming = true
        model.activeStreamHostID = "host-activity-a"
        model.streamPhase = .connecting(stage: "Connecting to Bazzite…")
        #expect(model.hostStatusLine(for: "host-activity-a") == "Connecting to Bazzite…")
        #expect(model.hostStatusIndicator(for: "host-activity-a") == .attention)
        #expect(model.hostStatusLine(for: "other-host") == "Checking…")
        model.streamPhase = .streaming
        #expect(model.hostStatusLine(for: "host-activity-a") == "Streaming")
        #expect(model.hostStatusIndicator(for: "host-activity-a") == .online)
        model.streamPhase = .connecting(stage: "Reconnecting to Bazzite…")
        #expect(model.hostStatusLine(for: "host-activity-a") == "Reconnecting to Bazzite…")
        model.isStreaming = false
    }

    @Test @MainActor func onlyAStreamWithVideoUpdatesHistoryAndAllHostCopiesImmediately() throws {
        let suite = "shimmer-host-activity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel()
        let host = Self.host("host-activity-a")
        let other = Self.host("host-activity-b")
        model.hosts = [other, host]
        model.selectedHost = host
        model.isStreaming = true
        model.activeStreamHostID = host.id
        model.streamPhase = .connecting(stage: "Connecting…")

        // A failed attempt or handshake alone must not fabricate history.
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) == nil)
        model.handleNativeEvent(.connectionEstablished, host: host)
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) == nil)
        model.markStreamVideo(for: other.id)
        #expect(!model.activeStreamHasVideo)

        model.handleNativeEvent(.firstFrame, host: host)
        #expect(model.lastStreamedDescription(for: host) == "Now")
        model.recordStreamActivity(for: host.id, endedAt: Self.now, defaults: defaults)
        #expect(defaults.object(forKey: AppModel.lastStreamedKey(for: host.id)) as? Date == Self.now)
        #expect(model.selectedHost?.lastStreamed == Self.now)
        #expect(model.hosts.first?.id == host.id)
        #expect(model.hosts.first?.lastStreamed == Self.now)
        #expect(model.hosts.first(where: { $0.id == other.id })?.lastStreamed == nil)
        model.isStreaming = false
    }

    @Test @MainActor func oldAttemptHistoryAndLateFramesCannotBecomeVerifiedHistory() {
        let model = AppModel()
        var host = Self.host("host-activity-a")
        host.lastConnected = Self.now
        model.selectedHost = host
        #expect(model.lastStreamedDescription(for: host, at: Self.now) == "Not recorded")
        model.activeStreamHostID = host.id
        model.isStreaming = true
        model.streamPhase = .idle
        model.markStreamVideo(for: host.id)
        #expect(!model.activeStreamHasVideo)
        model.isStreaming = false
        model.streamPhase = .streaming
        model.markStreamVideo(for: host.id)
        #expect(!model.activeStreamHasVideo)
    }

    @Test func relativeHistoryAgesWithTheClock() {
        var host = Self.host("host-activity-a")
        host.lastStreamed = Self.now
        let near = host.lastStreamedDescription(relativeTo: Self.now.addingTimeInterval(60))
        let later = host.lastStreamedDescription(relativeTo: Self.now.addingTimeInterval(7_200))
        #expect(near != nil)
        #expect(later != near)
    }
}
