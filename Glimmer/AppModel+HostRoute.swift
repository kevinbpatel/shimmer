//
//  AppModel+HostRoute.swift
//
//  Always-on route classification for the SELECTED host - feeds the quiet
//  bolt / Wi-Fi glyph on the launcher's readiness chip ("Ready · 12 ms ⚡").
//
//  DELIBERATELY not the engine's `StreamRouteProbe`: that probe is
//  constructed by the opt-in telemetry exporter (gate-on only) and must stay
//  removable with it - nothing UI-facing may depend on it. This monitor rides
//  pure Network.framework instead: one connected UDP NWConnection to the host
//  (connecting a UDP socket sends NOTHING - it only asks the kernel to bind a
//  route), whose NWPath reports the egress interface class for THAT
//  destination. Path updates are pushed on every route-table event
//  (dock/undock, VPN up, Wi-Fi join), so the glyph flips live with no timers.
//  Idle cost: one parked socket, zero traffic. Unlike the exporter probe we
//  tolerate hostnames here - Network.framework resolves asynchronously off
//  the main thread, and the launcher has no hot path to protect.
//

import Foundation
import Network
import SwiftUI
import Observation
import Darwin

/// Live wired/Wi-Fi classification of the kernel route toward one host.
/// Owned by `AppModel` (see `hostRoute`), re-pointed by the launcher
/// via `refreshHostRoute()` whenever the selected host changes.
@MainActor
@Observable
final class HostRouteMonitor {

    /// The route class the kernel chose toward the monitored host. `tunnel`
    /// (utun/ipsec - Network.framework's `.other`) and `unknown` (no route /
    /// not yet resolved) both render as NO glyph: absent knowledge stays
    /// unlabelled, never guessed.
    enum RouteClass {
        case wired, wifi, cellular, tailscale, tunnel, unknown

        var label: String {
            switch self {
            case .wired: "Ethernet"
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .tailscale: "Tailscale"
            case .tunnel: "VPN"
            case .unknown: "Unknown network"
            }
        }
    }

    enum PhysicalLink {
        case wired, wifi, cellular, multiple, unknown

        var label: String {
            switch self {
            case .wired: "Ethernet"
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .multiple: "Multiple links"
            case .unknown: "Unavailable"
            }
        }
    }

    private(set) var routeClass: RouteClass = .unknown
    private(set) var physicalLink: PhysicalLink = .unknown
    private(set) var address: String?
    private(set) var changedAt = Date.distantPast
    private var routeIdentity = ""

    /// Chip glyph for the current route - bolt for wired, arcs for Wi-Fi,
    /// nothing when the route is a tunnel or unknown.
    var glyphSystemName: String? {
        switch routeClass {
        case .wired: return "bolt.fill"
        case .wifi: return "wifi"
        case .cellular, .tailscale, .tunnel, .unknown: return nil
        }
    }

    /// VoiceOver flavour appended to the chip sentence ("..., over Wi-Fi").
    var accessibilityDescription: String? {
        switch routeClass {
        case .wired: return "over Ethernet"
        case .wifi: return "over Wi-Fi"
        case .cellular: return "over cellular"
        case .tailscale: return "over Tailscale"
        case .tunnel: return "over a VPN"
        case .unknown: return nil
        }
    }

    @ObservationIgnored private var connection: NWConnection?
    /// Bumped on every retarget; stale path callbacks (from a connection we
    /// already cancelled) compare against it and drop their result, so a
    /// quick host switch can't paint the old host's route onto the new chip.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let queue = DispatchQueue(
        label: "io.ugfugl.Glimmer.ui.hostRoute", qos: .utility)

    /// Point the monitor at a new destination (nil tears down to `.unknown`).
    /// Cancels any previous socket first; NWConnection releases its handlers
    /// on cancel, so the retained-handler cycle is broken deterministically.
    func monitor(address: String?) {
        connection?.cancel()
        connection = nil
        generation += 1
        self.address = address
        routeClass = .unknown
        physicalLink = .unknown
        routeIdentity = ""
        changedAt = .now
        guard let address, !address.isEmpty else { return }

        // The port is irrelevant to route selection (only the destination
        // address picks the egress interface) - discard keeps intent obvious.
        let conn = NWConnection(host: NWEndpoint.Host(address), port: 9, using: .udp)
        let gen = generation
        conn.pathUpdateHandler = { [weak self] path in
            // Classify on the monitor queue (cheap enum derivation), publish
            // on the main actor where SwiftUI observes `routeClass`.
            let fresh = Self.classify(path)
            let physical = Self.physicalLink(path)
            let identity = Self.identity(path)
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.publish(fresh, physical: physical, identity: identity)
            }
        }
        // The local endpoint can be absent in the first path callback. Once
        // ready it identifies the exact interface this connection selected.
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            let fresh: RouteClass
            let physical: PhysicalLink
            let identity: String
            switch state {
            case .ready:
                guard let path = conn?.currentPath else { return }
                fresh = Self.classify(path)
                physical = Self.physicalLink(path)
                identity = Self.identity(path)
            case .failed, .waiting, .cancelled:
                fresh = .unknown
                physical = .unknown
                identity = ""
            default: return
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.publish(fresh, physical: physical, identity: identity)
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func publish(_ fresh: RouteClass, physical: PhysicalLink, identity: String) {
        if routeClass != fresh || physicalLink != physical || routeIdentity != identity { changedAt = .now }
        routeClass = fresh
        physicalLink = physical
        routeIdentity = identity
    }

    private nonisolated static func physicalLink(_ path: NWPath) -> PhysicalLink {
        guard path.status == .satisfied else { return .unknown }
        return physicalLink(ethernet: path.usesInterfaceType(.wiredEthernet),
                            wifi: path.usesInterfaceType(.wifi),
                            cellular: path.usesInterfaceType(.cellular))
    }

    /// NWPath can report the physical interface underneath a tunnel as well
    /// as `.other`. If several physical types are eligible, don't guess one.
    nonisolated static func physicalLink(ethernet: Bool, wifi: Bool, cellular: Bool) -> PhysicalLink {
        let count = [ethernet, wifi, cellular].filter { $0 }.count
        if count > 1 { return .multiple }
        if ethernet { return .wired }
        if wifi { return .wifi }
        if cellular { return .cellular }
        return .unknown
    }

    private nonisolated static func identity(_ path: NWPath) -> String {
        path.availableInterfaces.map(\.name).joined(separator: ",")
            + ":" + (localAddress(path) ?? "")
    }

    private nonisolated static func localAddress(_ path: NWPath) -> String? {
        guard case .hostPort(let host, _) = path.localEndpoint else { return nil }
        switch host {
        case .ipv4(let ip): return ip.debugDescription
        case .ipv6(let ip): return ip.debugDescription
        case .name: return nil
        @unknown default: return nil
        }
    }

    /// NWPath → route class. Tunnel is checked FIRST: a host reached through
    /// utun rides `.other`, and the radio underneath is NOT what the kernel
    /// routed to (the same honesty rule the engine's exporter probe follows).
    private nonisolated static func classify(_ path: NWPath) -> RouteClass {
        guard path.status == .satisfied else { return .unknown }
        if path.usesInterfaceType(.other) {
            return isTailscale(localAddress: localAddress(path), interfaces: interfaceAddresses())
                ? .tailscale : .tunnel
        }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .unknown
    }

    struct InterfaceAddress: Sendable {
        let name: String
        let address: String
    }

    /// Positive evidence on the SELECTED interface, not a CGNAT destination or
    /// an unrelated active VPN. Tailscale assigns fd7a:115c:a1e0::/48 locally.
    nonisolated static func isTailscale(localAddress: String?, interfaces: [InterfaceAddress]) -> Bool {
        guard let localAddress, let local = ipBytes(localAddress) else { return false }
        let names = Set(interfaces.filter { ipBytes($0.address) == local }.map(\.name))
        guard names.count == 1, let name = names.first else { return false }
        let prefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        return interfaces.contains {
            $0.name == name && ipBytes($0.address)?.starts(with: prefix) == true
        }
    }

    private nonisolated static func ipBytes(_ value: String) -> Data? {
        let value = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        if let ip = IPv4Address(value) { return ip.rawValue }
        return IPv6Address(value)?.rawValue
    }

    private nonisolated static func interfaceAddresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [InterfaceAddress] = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let item = next {
            next = item.pointee.ifa_next
            guard let address = item.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(InterfaceAddress(name: String(cString: item.pointee.ifa_name),
                                           address: String(cString: buffer)))
        }
        return result
    }
}

struct HostLatencyReading {
    let hostID: String
    let address: String
    let milliseconds: Double
    let capturedAt: Date

    func text(forHost hostID: String, address: String, at now: Date,
              notBefore: Date, maxAge: TimeInterval) -> String? {
        guard self.hostID == hostID, self.address == address,
              capturedAt >= notBefore, capturedAt <= now,
              now.timeIntervalSince(capturedAt) <= maxAge,
              milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(Int.max) else { return nil }
        return milliseconds < 1 ? "<1 ms" : "\(Int(milliseconds.rounded())) ms"
    }
}

extension AppModel {

    var macConnectionDescription: String {
        guard let address = selectedHostRouteAddress, hostRoute.address == address else { return "Checking…" }
        return hostRoute.physicalLink.label
    }

    var hostRouteDescription: String {
        guard let address = selectedHostRouteAddress, hostRoute.address == address else { return "Checking…" }
        switch hostRoute.routeClass {
        case .wired, .wifi, .cellular: return "Direct"
        case .tailscale: return "Tailscale"
        case .tunnel: return "VPN"
        case .unknown: return "Checking…"
        }
    }

    func latencyDescription(liveReading: HostLatencyReading?, at now: Date) -> String {
        guard let host = selectedHost, let address = selectedHostRouteAddress else { return "Unavailable" }
        let reading: HostLatencyReading?
        let maxAge: TimeInterval
        if isStreaming {
            reading = activeStreamHostID == host.id && streamPhase == .streaming ? liveReading : nil
            maxAge = 3
        } else if let status = hostLiveStatus, let ms = status.rttMs,
                  let address = status.probedAddress, let probedAt = status.probedAt {
            reading = HostLatencyReading(hostID: status.hostID, address: address,
                                         milliseconds: Double(ms), capturedAt: probedAt)
            maxAge = HostLiveStatus.stale
        } else {
            reading = nil
            maxAge = 0
        }
        let latency = reading?.text(forHost: host.id, address: address, at: now,
                                    notBefore: hostRoute.changedAt, maxAge: maxAge)
        return latency ?? "Unavailable"
    }

    /// The destination `refreshHostRoute()` monitors for the current
    /// selection - the same fallback chain `nativeServerInfo(for:)` dials, so
    /// the glyph always classifies the address a stream would actually use.
    /// Exposed so the launcher can key its refresh task on the ADDRESS rather
    /// than `selectedHost?.id`: re-pairing a host after a DHCP move rewrites
    /// localaddress/manualaddress under the SAME uuid, so an id-keyed task
    /// never re-fires and the glyph keeps classifying the route to the dead
    /// IP until a host switch or relaunch.
    var selectedHostRouteAddress: String? {
        selectedHost.map { dialAddress(for: $0) }
    }

    /// Re-point the readiness chip's route monitor at the currently selected
    /// host (nil selection tears the parked socket down - see the launcher's
    /// empty-hosts task in MainWindow, which relies on that to release the
    /// socket when the last PC is unpaired). Driven by the launcher
    /// (`.task(id: selectedHostRouteAddress)`) so it follows host switches
    /// AND same-host address changes without the manager needing its own
    /// observer.
    func refreshHostRoute() {
        hostRoute.monitor(address: selectedHostRouteAddress)
    }
}
