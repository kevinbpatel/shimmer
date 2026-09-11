//
//  AppModel+Streaming+Config.swift
//
//  The derived, read-only half of AppModel+Streaming.swift: the codec-aware
//  wire bitrate, the state-aware hero verb, and the Host → engine bridge (`nativeStreamConfig` / `nativeServerInfo` and
//  the authoritative TLS-pin resolution behind it). Split out of
//  AppModel+Streaming.swift to keep each file under the length limit; the
//  session lifecycle - stream(), its teardown, engine events, connect cancel -
//  stays there and in AppModel+Streaming+Events.swift.
//

import Foundation
import AppKit
import os.log

extension AppModel {

    /// The H.264-anchored quality dial (`effectiveBitrateKbps`) scaled by the
    /// negotiated codec's efficiency - AV1 and HEVC spend ~20% fewer bits for
    /// the same picture, so the budget is discounted to match. Custom is
    /// verbatim, and so is a bitrate the user set by hand: they asked for that
    /// number.
    func wireBitrateKbps(forFormats formats: VideoFormats) -> Int {
        if case .custom = qualityPreset { return effectiveBitrateKbps }
        if !bitrateAuto { return effectiveBitrateKbps }
        let mult = Self.codecBudgetMultiplier(for: formats)
        return max(5_000, Int((Double(effectiveBitrateKbps) * mult).rounded()))
    }

    // MARK: Streaming

    /// The fallback target when nothing better is known. There is no "default
    /// app" setting any more: the library shows a button per app, so picking
    /// one in Settings as well was a second answer to a question the user
    /// answers by clicking. Desktop is the one entry every host publishes.
    var defaultAppName: String {
        guard let host = selectedHost else { return "Desktop" }
        if host.apps.contains(where: { $0.name == "Desktop" }) { return "Desktop" }
        return host.apps.first?.name ?? "Desktop"
    }

    func streamDefaultApp() {
        guard let host = selectedHost, let app = heroTargetApp else { return }
        requestStream(app: app, on: host)
    }

    // MARK: - Hero verb (state-aware primary action)

    /// UserDefaults key for the NAME of the last app launched on a host.
    /// Distinct from `glimmer.lastConnected.<id>` (a DATE, stamped at stream
    /// END): "what did I play here" is true from the moment a launch begins,
    /// so the name stamps at START - see the write in `stream(app:on:)`.
    static func lastPlayedAppKey(for hostId: String) -> String {
        "glimmer.lastPlayedApp.\(hostId)"
    }

    /// The app the HOST says is running right now, if the reading is fresh.
    ///
    /// Deliberately narrower than `resumableAppName`: no last-played fallback.
    /// This drives the badge on the app tile, and a badge that claims a game is
    /// running because it ran yesterday is a lie, whereas the hero button
    /// falling back to "the thing you last played" is a reasonable guess.
    var runningAppName: String? {
        guard let host = selectedHost,
              let live = hostLiveStatus,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale,
              case .streamingApp(let name) = live.state,
              host.apps.contains(where: { $0.name == name })
        else { return nil }
        return name
    }

    /// The app the hero button can meaningfully resume on the selected host.
    /// Host-reported truth wins: a fresh /serverinfo snapshot naming an
    /// in-flight session (aged out on the same `HostLiveStatus.stale` horizon
    /// the readiness chip uses; the host-id guard in `publishLiveStatus`
    /// already scopes the snapshot to this host). Otherwise the name stamped
    /// at the last stream start, as long as it's still in the applist. nil
    /// when neither is known - the button falls back to "Connect".
    var resumableAppName: String? {
        guard let host = selectedHost else { return nil }
        if let live = hostLiveStatus,
           Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale,
           case .streamingApp(let name) = live.state,
           host.apps.contains(where: { $0.name == name }) {
            return name
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastPlayedAppKey(for: host.id)),
           host.apps.contains(where: { $0.name == last }) {
            return last
        }
        return nil
    }

    /// What the hero button actually launches - the resume target when known,
    /// else the configured default app. The AppIconsRow accent ring follows
    /// this so the ring can never disagree with the button's verb.
    var heroTargetAppName: String {
        resumableAppName ?? defaultAppName
    }

    /// The same target as a library entry, so a surface naming it can also draw
    /// its icon. Resolved through the SAME fallback chain `streamDefaultApp()`
    /// uses - name match, then Desktop, then whatever the host published first
    /// - because a button whose icon and verb come from different lookups will
    /// eventually show one app and launch another. nil only when the host has
    /// no apps at all, which is the case the caller draws a bare play arrow for.
    var heroTargetApp: LibraryApp? {
        guard let host = selectedHost else { return nil }
        return Self.resolveHeroApp(in: host.apps, named: heroTargetAppName)
    }

    /// The lookup itself, pure so the invariant "the verb, the icon and the
    /// launch all name one app" is checkable without an AppModel.
    nonisolated static func resolveHeroApp(in apps: [LibraryApp], named name: String) -> LibraryApp? {
        apps.first(where: { $0.name == name })
            ?? apps.first(where: { $0.name == "Desktop" })
            ?? apps.first
    }

    /// Primary-button copy. Always "Stream <app>" - this button only shows on the
    /// launcher (never mid-stream), so "Resume" read as confusing. The verb is the
    /// same whether we resume the host's running session or launch fresh;
    /// `streamHeroApp()` still picks /resume vs /launch under the hood.
    ///
    /// Named off the RESOLVED app rather than `heroTargetAppName`, so the two
    /// can't disagree: the name is a guess that may not be in the applist (a
    /// game uninstalled on the host, or a brand-new pairing), and in that case
    /// the button falls back to a real app and has to say which.
    var heroActionLabel: String {
        "Stream \(heroTargetApp?.name ?? defaultAppName)"
    }

    /// Launch the hero target (the primary click / Return-key action).
    func streamHeroApp() {
        guard let host = selectedHost else { return }
        if let name = resumableAppName,
           let app = host.apps.first(where: { $0.name == name }) {
            requestStream(app: app, on: host)
        } else {
            streamDefaultApp()
        }
    }

    /// Bridge our published quality settings into the engine's StreamConfig.
    /// The codec set is the probed client capability capped by the host's
    /// override (right-click → Codec; Automatic by default, which negotiates
    /// AV1 → HEVC → H.264 against what the host can actually encode).
    func nativeStreamConfig(for host: Host) -> StreamConfig {
        persistQualitySettings()
        var cfg = StreamConfig(width: effectiveWidth, height: effectiveHeight,
                               fps: effectiveFPS, bitrateKbps: effectiveBitrateKbps)
        // HDR only when the display can actually show it. Asking for it on an
        // SDR panel cannot improve anything and actively hurts: the host
        // switches to 10-bit and advertises BT.2020, and that wide-gamut tag on
        // Rec.709 content is what over-saturates the picture (see
        // derivedColorSpaceKey). NSScreen reports 1.0 of EDR headroom on a
        // panel with no HDR at all.
        let displayCanShowHDR = (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
        cfg.hdr = effectiveHDR && displayCanShowHDR
        if effectiveHDR && !displayCanShowHDR {
            Diag.info("HDR requested but this display has no headroom (EDR 1.0) - streaming SDR", "Stream")
        }
        // Always the richest layout this Mac's default output can take.
        cfg.audio = .bestForCurrentOutput()
        cfg.captureSysKeys = captureSysKeys
        // The notch choice only means something on a notched panel; elsewhere
        // the session always takes the borderless cover (see
        // effectiveStreamCoversNotch for the issue this closes).
        cfg.coversNotch = effectiveStreamCoversNotch
        cfg.displayMode = effectiveDisplayMode
        let codecPref = HostCodecPreference.load(for: host.id)
        var formats = codecPref.apply(to: .probedSupported)
        // Don't advertise 10-bit profiles when we're not asking for HDR. The
        // host picks the best format we offer, so offering Main10 got us a
        // 10-bit stream tagged BT.2020 for SDR content - the over-saturation
        // fixed in derivedColorSpaceKey. Not offering it removes the mis-tag at
        // the source instead of compensating for it, and 10-bit buys nothing
        // on an SDR pipeline. moonlight-qt masks the same way.
        if !cfg.hdr {
            formats = formats.subtracting([.hevcMain10, .av1Main10])
        }
        cfg.videoFormats = formats
        // Codec-aware wire budget (see wireBitrateKbps): the H.264-anchored dial
        // scaled by the negotiated codec's efficiency. The spec chip reads the same
        // path so what's shown matches what's sent.
        cfg.bitrateKbps = wireBitrateKbps(forFormats: cfg.videoFormats)
        return cfg
    }

    /// Title for the Window-mode stream window: the PC's name, then the app
    /// when one is known - "Tower - Desktop". Static and pure so the shape is
    /// trivially checkable.
    static func streamWindowTitle(hostName: String, appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespaces)
        return app.isEmpty ? hostName : "\(hostName) - \(app)"
    }

    /// Convert a paired Host into the engine's ServerInfo. The
    /// serverCertPEM seeds TLS pinning so we don't have to re-discover it
    /// over HTTP first. We prefer Glimmer's own persisted pin (written by
    /// `PairingClient.runPairingFlow` after the RSA-verified handshake) over
    /// the moonlight-qt migrated copy. Both are equivalent pairing outputs,
    /// but only the Glimmer-side pin has been validated by our pairing flow
    /// in this app's lifetime. Internal so HostStatusPoller.swift can call it.
    func nativeServerInfo(for host: Host) -> ServerInfo {
        var info = ServerInfo(
            address: host.localAddress ?? host.manualAddress ?? host.name,
            uniqueId: host.id,
            serverName: host.displayName
        )
        // H1: the mode-0600 file store is the ONLY authoritative pin source.
        // `host.serverCertPEM` lives in same-UID-writable UserDefaults
        // (hosts.N.srvcert) - an attacker can swap it for a MITM cert via
        // cfprefsd, so we treat it as an untrusted HINT, never a direct pin.
        info.serverCertPEM = authoritativePin(for: host)
        info.appVersion = host.appVersion
        info.gfeVersion = host.gfeVersion
        info.pairStatus = .paired      // host is in our local list → already paired
        return info
    }

    /// Resolve the host's TLS pin from the authoritative file store, honoring
    /// the legacy UserDefaults hint (`host.serverCertPEM`) only as a one-way
    /// migration source. File ALWAYS wins; a file-vs-hint mismatch is a hard
    /// error (refuse + force re-pair), never a silent fallback. Returns nil
    /// when no trustworthy pin exists - the pairStatus gate then forces a
    /// re-pair rather than pinning a writable value.
    private func authoritativePin(for host: Host) -> String? {
        let filePin = PinnedCertStore.load(forHostID: host.id)
        let hint = host.serverCertPEM.flatMap { $0.isEmpty ? nil : $0 }

        if let filePin {
            // File wins. If the writable hint disagrees, someone moved one of
            // them - refuse to stream and force a re-pair rather than guess.
            if let hint, hint != filePin {
                log.error(
                    """
                    Pinned cert for host id=\(host.id, privacy: .public) DISAGREES with the \
                    UserDefaults hint - refusing to stream and forcing re-pair (possible MITM).
                    """
                )
                return nil
            }
            return filePin
        }

        // No file pin. Migrate the untrusted hint into the file store ONCE,
        // then read it back from the file store so every later read is
        // file-only. If the migration write fails, refuse rather than pin a
        // same-UID-writable value.
        if let hint {
            do {
                try PinnedCertStore.store(pem: hint, forHostID: host.id)
                return PinnedCertStore.load(forHostID: host.id)
            } catch {
                log.error(
                    """
                    Failed to migrate the UserDefaults cert hint into the file store for host \
                    id=\(host.id, privacy: .public): \(error.localizedDescription, privacy: .public) - \
                    forcing re-pair instead of pinning a writable value.
                    """
                )
                return nil
            }
        }

        // Neither store has a pin: stream falls to a forced re-pair (the
        // pairStatus gate handles it), not TOFU on a writable cert.
        log.error(
            """
            No pinned cert for host id=\(host.id, privacy: .public) - forcing re-pair. \
            Check that host.id matches server.uniqueId (the host's `<uniqueid>` from /serverinfo).
            """
        )
        return nil
    }
}
