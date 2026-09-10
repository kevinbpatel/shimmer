//
//  BundleIDMigration.swift
//
//  One-shot carry-forward from the glimmer identity to the shimmer identity.
//
//  shimmer is a fork of glimmer that changed the bundle identifier
//  (io.ugfugl.Glimmer → com.kevinbpatel.shimmer) and the per-user data
//  directory (Application Support/Glimmer → Application Support/Shimmer). Both
//  of those are where a user's pairings live: the host list + every preference
//  is keyed by the bundle id in UserDefaults, and the client identity + pinned
//  host certificates are files under the support directory. Without this a
//  user upgrading a glimmer install to shimmer would come up unpaired with
//  factory settings and have to redo the PIN handshake on every PC.
//
//  Runs FIRST in `GlimmerApp.init()`, before `ContainerMigration` and before
//  `AppModel` reads a single key, and it copies rather than moves so the
//  glimmer install (if one is kept side by side) is untouched. Guarded by a
//  sentinel in the NEW domain so it runs exactly once; the defaults copy is
//  additionally skipped when the new domain already holds a host list, so a
//  shimmer that has been paired on its own never has its state overwritten.
//

import Foundation
import os.log

enum BundleIDMigration {
    static let didMigrateKey = "didMigrateFromGlimmerBundleID"
    private static let legacyBundleID = "io.ugfugl.Glimmer"
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kevinbpatel.shimmer",
        category: "BundleIDMigration")

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didMigrateKey) else { return }

        // 1. Preferences: the whole legacy persistent domain (hosts.N.*, quality,
        //    hotkeys, the pinned-cert legacy keys, migration sentinels - all of
        //    it) into the new domain, only when the new domain has no host list
        //    of its own yet.
        let legacy = defaults.persistentDomain(forName: legacyBundleID) ?? [:]
        if !legacy.isEmpty, defaults.object(forKey: "hosts.size") == nil {
            for (key, value) in legacy { defaults.set(value, forKey: key) }
            log.notice("copied \(legacy.count, privacy: .public) preference key(s) from \(legacyBundleID, privacy: .public)")
        }

        // 2. Files: client identity + pinned host certs. copyTree skips files
        //    that already exist at the destination and preserves the 0600 mode
        //    the identity/cert loaders verify.
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true) {
            let src = appSupport.appendingPathComponent("Glimmer", isDirectory: true)
            let dst = appSupport.appendingPathComponent("Shimmer", isDirectory: true)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                let copied = ContainerMigration.copyTree(from: src, to: dst)
                log.notice("copied \(copied, privacy: .public) item(s) from Application Support/Glimmer to Shimmer")
            }
        }

        defaults.set(true, forKey: didMigrateKey)
    }
}
