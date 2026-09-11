//
//  AppArtworkStore.swift
//
//  Box art for the launcher's app tiles: fetched once from the host over the
//  paired mutual-TLS transport (`/appasset`, see NetworkClient+Endpoints),
//  cached on disk, and handed to SwiftUI as an NSImage.
//
//  Shape of the problem. A view body must answer "what image goes here?"
//  synchronously and may run many times a second, but the answer starts life
//  behind an HTTPS round trip. So `image(for:on:)` is a pure lookup that
//  returns what is already in memory and, on a miss, schedules the fetch as a
//  side effect. Every state a key can be in is tracked (`state`) so a body
//  re-running mid-flight cannot start a second request for the same tile and a
//  host with no art for an app is asked exactly once.
//
//  Disk cache lives in Caches, not Application Support: it is regenerable from
//  the host and macOS is free to evict it. Art is keyed by host AND app id -
//  two PCs can use the same Sunshine app ids for different games.
//

import AppKit
import Observation
import os.log

@MainActor
@Observable
final class AppArtworkStore {

    /// What is known about one host+app's art. `missing` is a terminal state
    /// for the session: a host that answered "no art" is not asked again until
    /// relaunch, which keeps a Desktop entry from re-requesting on every
    /// scroll.
    private enum State: Equatable {
        case loading
        case loaded(NSImage)
        case missing
    }

    @ObservationIgnored private let log = Logger(
        subsystem: "io.ugfugl.Glimmer", category: "Artwork")

    private var states: [String: State] = [:]

    /// Host id + app id → `ServerInfo`, so the store can build its own paired
    /// client without importing AppModel's world. Injected by AppModel.
    @ObservationIgnored var serverInfoProvider: (@MainActor (Host) -> ServerInfo)?

    /// The host's cover art for `app`, or nil while it loads / if the host has
    /// none. Safe to call from a view body: repeated calls for a key already
    /// in flight are free.
    func image(for app: LibraryApp, on host: Host) -> NSImage? {
        let key = Self.key(hostID: host.id, appID: app.id)
        switch states[key] {
        case .loaded(let image): return image
        case .loading, .missing: return nil
        case nil:
            states[key] = .loading
            if let image = Self.readCache(key: key) {
                states[key] = .loaded(image)
                return image
            }
            fetch(app: app, host: host, key: key)
            return nil
        }
    }

    /// Warm the cache for a host's whole app list, so tiles are already drawn
    /// the first time the user looks at them. Idempotent.
    func prefetch(apps: [LibraryApp], on host: Host) {
        for app in apps { _ = image(for: app, on: host) }
    }

    /// Forget everything for one host - its art is refetched on next sight.
    /// Called when a host is unpaired or its app list changes shape.
    func invalidate(hostID: String) {
        let prefix = "\(hostID)/"
        states = states.filter { !$0.key.hasPrefix(prefix) }
        let dir = Self.cacheDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(Self.fileStem(hostID: hostID)) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Fetch

    private func fetch(app: LibraryApp, host: Host, key: String) {
        guard let serverInfoProvider else {
            states[key] = .missing
            return
        }
        let info = serverInfoProvider(host)
        let appID = app.id
        Task { @MainActor in
            let client = NetworkClient(server: info)
            defer { Task { await client.shutdown() } }
            do {
                let data = try await client.appAsset(appID: appID)
                guard let image = NSImage(data: data) else {
                    // 200 with a body we can't decode is a miss, not an error
                    // worth retrying - some hosts answer with an HTML error page.
                    self.log.notice("Box art for app \(appID) did not decode (\(data.count) bytes)")
                    self.states[key] = .missing
                    return
                }
                Self.writeCache(data, key: key)
                self.states[key] = .loaded(image)
            } catch {
                // Expected whenever the host simply has no art for the app, so
                // this is notice-level, not an error.
                self.log.notice("No box art for app \(appID): \(error.localizedDescription, privacy: .public)")
                self.states[key] = .missing
            }
        }
    }

    // MARK: - Disk cache

    private static func key(hostID: String, appID: Int) -> String { "\(hostID)/\(appID)" }

    /// Host ids come from the host itself, so they are sanitised into a
    /// filename rather than trusted: anything outside `[A-Za-z0-9._-]` becomes
    /// `_`, which keeps a hostile id from escaping the cache directory.
    private static func fileStem(hostID: String) -> String {
        let safe = hostID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        }
        return String(safe) + "-"
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Shimmer/BoxArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(key: String) -> URL? {
        let parts = key.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return cacheDirectory.appendingPathComponent(
            "\(fileStem(hostID: String(parts[0])))\(parts[1]).png")
    }

    private static func readCache(key: String) -> NSImage? {
        guard let url = cacheURL(key: key),
              let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private static func writeCache(_ data: Data, key: String) {
        guard let url = cacheURL(key: key) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
