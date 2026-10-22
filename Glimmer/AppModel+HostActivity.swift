import Foundation

enum HostStatusIndicator {
    case neutral, online, attention, offline
}

extension AppModel {
    /// One freshness/identity check for the status text and launch target.
    func liveStatus(for hostID: String, at now: Date = .now) -> HostLiveStatus? {
        guard let live = hostLiveStatus, live.hostID == hostID,
              now.timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else { return nil }
        return live
    }

    var selectedHostStatusLine: String {
        guard let id = selectedHost?.id else { return "No PC selected" }
        return hostStatusLine(for: id)
    }

    func hostStatusLine(for hostID: String, at now: Date = .now) -> String {
        if isStreaming, activeStreamHostID == hostID {
            switch streamPhase {
            case .connecting(let stage): return stage
            case .streaming:
                return activeStreamShorthand.map { "Streaming at \($0)" } ?? "Streaming"
            case .idle, .disconnecting: return "Disconnecting…"
            case .error: return "Stream interrupted"
            }
        }
        guard let live = liveStatus(for: hostID, at: now) else { return "Checking…" }
        switch live.state {
        case .idle: return "Online"
        case .reachable: return "Online · status unavailable"
        case .streamingApp: return "Online"
        case .streamingUnknownApp: return "Online"
        case .asleep: return "Asleep or offline"
        case .certMismatch: return "Trust needed - pair again"
        case .unknown: return "Checking…"
        }
    }

    func hostStatusIndicator(for hostID: String, at now: Date = .now) -> HostStatusIndicator {
        if isStreaming, activeStreamHostID == hostID {
            switch streamPhase {
            case .streaming: return .online
            case .connecting, .error: return .attention
            case .idle, .disconnecting: return .neutral
            }
        }
        guard let live = liveStatus(for: hostID, at: now) else { return .neutral }
        switch live.state {
        case .idle, .streamingApp, .streamingUnknownApp: return .online
        case .reachable, .unknown: return .neutral
        case .asleep: return .offline
        case .certMismatch: return .attention
        }
    }

    static func lastStreamedKey(for hostID: String) -> String {
        "glimmer.lastStreamed.\(hostID)"
    }

    func lastStreamedDescription(for host: Host, at now: Date = .now) -> String {
        if isStreaming, activeStreamHostID == host.id, activeStreamHasVideo {
            if streamPhase == .streaming { return "Now" }
            if case .connecting = streamPhase { return "Reconnecting…" }
        }
        return host.lastStreamedDescription(relativeTo: now) ?? "Not recorded"
    }

    func markStreamVideo(for hostID: String) {
        guard isStreaming, activeStreamHostID == hostID else { return }
        switch streamPhase {
        case .connecting, .streaming: activeStreamHasVideo = true
        case .idle, .disconnecting, .error: break
        }
    }

    /// Update persistence AND observable host copies before returning to the
    /// launcher. The old defaults-only write left the UI stale until reload.
    func recordStreamActivity(for hostID: String, endedAt date: Date = .now,
                              defaults: UserDefaults = .standard) {
        guard activeStreamHostID == hostID, activeStreamHasVideo else { return }
        defaults.set(date, forKey: Self.lastStreamedKey(for: hostID))
        defaults.set(date, forKey: "glimmer.lastConnected.\(hostID)")
        if let index = hosts.firstIndex(where: { $0.id == hostID }) {
            hosts[index].lastStreamed = date
            hosts[index].lastConnected = date
            hosts.sort { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        }
        if selectedHost?.id == hostID {
            selectedHost?.lastStreamed = date
            selectedHost?.lastConnected = date
        }
    }
}
