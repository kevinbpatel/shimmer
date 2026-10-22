// Bonjour discovery for GameStream/Sunshine hosts. Results are transient;
// only a completed pairing writes a PC into the saved-host store.
import Foundation
import Network
import os.log

/// An empty update from one advertised service type must not erase PCs still
/// present under the other GameStream/Sunshine alias.
struct DiscoveryServiceSet {
    private var namesByType: [String: Set<String>] = [:]
    mutating func update(_ names: Set<String>, for type: String) -> Set<String> {
        namesByType[type] = names
        return namesByType.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}

public actor HostDiscovery {
    public static let shared = HostDiscovery()
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Discovery")
    private var browsers: [NWBrowser] = []
    private var resultsContinuation: AsyncStream<[Discovered]>.Continuation?
    private var seen: [String: Discovered] = [:]
    private var resolving: [String: Task<Void, Never>] = [:]
    private var services = DiscoveryServiceSet()
    private var session: UUID?

    public struct Discovered: Sendable, Hashable, Identifiable {
        public let id: String
        public let displayName: String
        public let host: String
        public let port: Int
        /// Informational /serverinfo UUID, used only to avoid duplicate rows.
        /// It never authenticates a server or replaces a certificate pin.
        public let serverID: String?

        public init(id: String, displayName: String, host: String, port: Int,
                    serverID: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.host = host
            self.port = port
            self.serverID = serverID
        }
    }

    public func start() -> AsyncStream<[Discovered]> {
        stop()
        let run = UUID()
        session = run
        return AsyncStream { continuation in
            resultsContinuation = continuation
            continuation.yield([])
            for type in ["_nvstream._tcp", "_nvstream-tcp._tcp"] {
                let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    Task { await self?.handleResults(results, type: type, session: run) }
                }
                let logger = log
                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        logger.error("Bonjour browse failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                browser.start(queue: .global(qos: .utility))
                browsers.append(browser)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop(session: run) }
            }
        }
    }

    private func stop(session run: UUID) {
        guard session == run else { return }
        stop()
    }

    public func stop() {
        session = nil
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        resultsContinuation?.finish()
        resultsContinuation = nil
        seen.removeAll()
        services = DiscoveryServiceSet()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, type: String, session run: UUID) {
        guard session == run else { return }
        let live = services.update(Set(results.compactMap {
            if case let .service(name, _, domain, _) = $0.endpoint { return "\(type)|\(domain)|\(name)" }
            return nil
        }), for: type)
        for result in results {
            if case let .service(name, _, domain, _) = result.endpoint {
                let id = "\(type)|\(domain)|\(name)"
                if seen[id] == nil, resolving[id] == nil {
                    startResolve(id: id, name: name, type: type, domain: domain, session: run)
                }
            }
        }
        for id in Array(resolving.keys) where !live.contains(id) {
            resolving.removeValue(forKey: id)?.cancel()
        }
        seen = seen.filter { live.contains($0.key) }
        publish()
    }

    private func startResolve(id: String, name: String, type: String, domain: String, session run: UUID) {
        resolving[id] = Task {
            let endpoint = await ServiceAddressResolver.resolve(name: name, type: type, domain: domain)
            guard !Task.isCancelled, session == run else { return }
            guard let endpoint else { resolving.removeValue(forKey: id); return }
            // Read-only identification; no client identity, pairing, TLS trust,
            // persistent address changes, or periodic polling is involved here.
            let serverID = await Self.readServerID(host: endpoint.host, port: endpoint.port)
            guard !Task.isCancelled, session == run else { return }
            resolving.removeValue(forKey: id)
            seen[id] = Discovered(id: id, displayName: name, host: endpoint.host,
                                  port: endpoint.port, serverID: serverID)
            publish()
        }
    }

    private static func readServerID(host: String, port: Int) async -> String? {
        guard let response = try? await ControlTransport.get(
            host: host, port: port,
            target: "/serverinfo?uniqueid=\(NetworkClient.wireUniqueID)&uuid=\(UUID().uuidString)",
            userAgent: "Mozilla/5.0 (compatible; Moonlight/Shimmer)",
            tls: false, credential: .init(clientCertPEM: nil, clientKeyPEM: nil, pinnedCertPEM: nil), timeout: 2),
              response.status == 200,
              let xml = try? XMLTreeBuilder.parse(data: response.body),
              let root = xml.firstChild(named: "root"), root.attributes["status_code"] == "200",
              let id = xml.string(forChild: "uniqueid")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    private func publish() {
        resultsContinuation?.yield(seen.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
    }

    static func canonicalHost(_ raw: String, ipv6: Bool) -> String {
        if ipv6 && raw.lowercased().hasPrefix("fe80") { return raw }
        return String(raw.prefix { $0 != "%" })
    }

}

/// Resolve DNS-SD addresses and its advertised port without waiting for a TCP
/// connection to become ready. Delegate callbacks run on the main run loop.
private struct ResolvedService: Sendable {
    let host: String
    let port: Int
}

@MainActor
private final class ServiceAddressResolver: NSObject, @preconcurrency NetServiceDelegate {
    private let service: NetService
    private var continuation: CheckedContinuation<ResolvedService?, Never>?

    private init(name: String, type: String, domain: String) {
        service = NetService(domain: domain, type: type, name: name)
        super.init()
    }

    static func resolve(name: String, type: String, domain: String) async -> ResolvedService? {
        let resolver = ServiceAddressResolver(name: name, type: type, domain: domain)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                resolver.continuation = continuation
                resolver.service.delegate = resolver
                resolver.service.schedule(in: .main, forMode: .common)
                resolver.service.resolve(withTimeout: 3)
            }
        } onCancel: {
            Task { @MainActor in resolver.finish(nil) }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let addresses = (sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count),
                                  &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        // Prefer a numeric LAN IPv4. On IPv6-only networks, a DNS hostname
        // preserves link-local interface scope without inventing a zone suffix.
        let host = addresses.first { IPv4Address($0) != nil }
            ?? sender.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            ?? addresses.first
        guard let host, (1...65535).contains(sender.port) else { finish(nil); return }
        finish(ResolvedService(host: host, port: sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { finish(nil) }

    private func finish(_ result: ResolvedService?) {
        let callback = continuation
        continuation = nil
        service.delegate = nil
        service.stop()
        service.remove(from: .main, forMode: .common)
        callback?.resume(returning: result)
    }
}

/// Identifies candidates; this never treats a Bonjour or HTTP UUID as proof.
/// Non-default control ports are not yet supported by saved-host persistence.
struct DiscoveredHostRoute {
    static func savedHost(for pc: HostDiscovery.Discovered, in hosts: [Host]) -> Host? {
        guard pc.port == 47989, let id = pc.serverID, !id.isEmpty else { return nil }
        return hosts.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func authenticates(_ responseID: String?, hostID: String) -> Bool {
        guard let id = responseID, !id.isEmpty, !hostID.isEmpty else { return false }
        return id.caseInsensitiveCompare(hostID) == .orderedSame
    }
}
