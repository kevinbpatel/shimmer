//
//  DebugAutomation.swift
//
//  Env-var-gated automation for headless iteration during development. INERT
//  unless the GLIMMER_DEBUG_* variables are set, so it never affects a normal
//  launch. Lets a script drive: pick a host, start a stream, enter Picture in
//  Picture after N seconds, and quit after M seconds - so a capture/inspect/fix
//  loop needs no GUI clicking.
//
//    GLIMMER_DEBUG_STREAM=<substr>   select the first host whose name/address
//                                    contains <substr> (case-insensitive) and
//                                    stream its default app.
//    GLIMMER_DEBUG_PIP_AFTER=<sec>   once streaming, wait <sec> then ⌃⌥P.
//    GLIMMER_DEBUG_QUIT_AFTER=<sec>  quit the app <sec> after streaming starts.
//
//  The same knobs are accepted as command-line arguments
//  (`--debug-stream=<substr> --debug-pip-after=<sec> ...`) because a GUI app
//  launched through LaunchServices (`open -n App.app --args ...`) lives in the
//  gui/<uid> launchd domain and never sees a shell's environment - not even
//  one exported with `launchctl setenv`, which lands in user/<uid> when the
//  shell is an SSH session. Launching via `open` matters: it's what gets the
//  Local Network privacy grant attributed to the app rather than sshd.
//

import AppKit
import Foundation

extension AppModel {

    /// `GLIMMER_DEBUG_<NAME>` from the environment, else `--debug-<name>=value`
    /// from the command line. Only used to decide whether automation is armed;
    /// nothing here runs on a normal launch.
    private static func debugKnob(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["GLIMMER_DEBUG_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"],
           !v.isEmpty { return v }
        let prefix = "--debug-\(name)="
        return ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// First loaded host whose name or address contains `match`.
    func debugHost(matching match: String) -> Host? {
        let host = hosts.first {
            $0.name.localizedCaseInsensitiveContains(match)
                || ($0.customName?.localizedCaseInsensitiveContains(match) ?? false)
                || ($0.localAddress?.localizedCaseInsensitiveContains(match) ?? false)
                || ($0.manualAddress?.localizedCaseInsensitiveContains(match) ?? false)
        }
        if host == nil {
            log.error("DEBUG automation: no host matching '\(match, privacy: .public)' among \(self.hosts.map(\.name), privacy: .public)")
        }
        return host
    }

    func runDebugAutomationIfRequested() {
        // `--debug-open-settings=<pane>[,<pane>...]`: open the Settings window
        // on each pane in turn, 3s apart (a screenshot loop for UI work), then
        // quit after --debug-quit-after seconds if given.
        if let panes = Self.debugKnob("open-settings") {
            let list = panes.split(separator: ",").compactMap { SettingsTab(rawValue: String($0)) }
            log.notice("DEBUG automation: opening Settings on \(list.map(\.rawValue), privacy: .public)")
            for (i, pane) in list.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 3.0) { [weak self] in
                    NSApp.activate()
                    self?.settingsTab = pane
                    self?.showSettings = true
                }
            }
            if let quitAfter = Self.debugKnob("quit-after").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { NSApp.terminate(nil) }
            }
            return
        }
        // `--debug-fetch-artwork=<host substr>`: pull every app's box art from
        // that host and drop it in /tmp, logging sizes. Proves the /appasset
        // endpoint against a real Sunshine before any UI is built on it.
        if let hostMatch = Self.debugKnob("fetch-artwork") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let host = self.debugHost(matching: hostMatch) else { return }
                Task { @MainActor in
                    let info = self.nativeServerInfo(for: host)
                    let client = NetworkClient(server: info)
                    for app in host.apps {
                        do {
                            let data = try await client.appAsset(appID: app.id)
                            let path = "/tmp/shimmer-art-\(app.id).png"
                            try? data.write(to: URL(fileURLWithPath: path))
                            let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined()
                            self.log.notice("ARTWORK \(app.name, privacy: .public): \(data.count) bytes magic=\(magic, privacy: .public) -> \(path, privacy: .public)")
                        } catch {
                            self.log.error("ARTWORK \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    await client.shutdown()
                    NSApp.terminate(nil)
                }
            }
            return
        }
        guard let hostMatch = Self.debugKnob("stream") else { return }
        let pipAfter = Self.debugKnob("pip-after").flatMap(Double.init)
        let quitAfter = Self.debugKnob("quit-after").flatMap(Double.init)
        let returnAfter = Self.debugKnob("return-after").flatMap(Double.init)
        log.notice("DEBUG automation armed: stream host~=\(hostMatch, privacy: .public) pipAfter=\(pipAfter ?? -1) quitAfter=\(quitAfter ?? -1)")

        // Give discovery/host-load a beat, then select + stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard let host = self.hosts.first(where: {
                $0.name.localizedCaseInsensitiveContains(hostMatch)
                    || ($0.customName?.localizedCaseInsensitiveContains(hostMatch) ?? false)
                    || ($0.localAddress?.localizedCaseInsensitiveContains(hostMatch) ?? false)
                    || ($0.manualAddress?.localizedCaseInsensitiveContains(hostMatch) ?? false)
            }) else {
                self.log.error("DEBUG automation: no host matching '\(hostMatch, privacy: .public)' among \(self.hosts.map(\.name), privacy: .public)")
                return
            }
            self.log.notice("DEBUG automation: selecting \(host.name, privacy: .public) (\(host.apps.count) apps) and streaming default")
            self.selectHost(host)
            self.streamDefaultApp()
            self.armDebugPiPAndQuit(pipAfter: pipAfter, returnAfter: returnAfter, quitAfter: quitAfter)
        }
    }

    /// Poll for the stream to go live, then schedule the PiP + return + quit
    /// actions relative to that moment (connect time is variable).
    private func armDebugPiPAndQuit(pipAfter: Double?, returnAfter: Double?, quitAfter: Double?) {
        var fired = false
        let start = Date()
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Give up after 30s of not reaching streaming.
            if Date().timeIntervalSince(start) > 30 {
                self.log.error("DEBUG automation: stream never reached .streaming within 30s (phase=\(String(describing: self.streamPhase), privacy: .public))")
                t.invalidate(); return
            }
            guard self.streamPhase == .streaming, !fired else { return }
            fired = true
            t.invalidate()
            self.log.notice("DEBUG automation: stream is live")
            if let pipAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter) { [weak self] in
                    self?.log.notice("DEBUG automation: entering Picture in Picture")
                    self?.enterPictureInPicture()
                }
                if let returnAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pipAfter + returnAfter) { [weak self] in
                        self?.log.notice("DEBUG automation: returning from Picture in Picture")
                        self?.resumeStreamWindow()
                    }
                }
            }
            if let quitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
                    NSApp.terminate(nil)
                }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
    }
}
