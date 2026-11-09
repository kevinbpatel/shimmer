//
//  AgentControl.swift
//
//  Lets `shimmerctl` - and so any coding agent - see what the running app is
//  doing and ask it to fix itself, without screenshots or a debugger.
//
//  STATE. The app keeps ~/Library/Application Support/Shimmer/agent-state.json
//  current: what's on screen, the selected PC and whether its status is still
//  loading, the stream phase, the controller, the permissions and both
//  background helpers, plus a list of `issues`, each with the shimmerctl
//  command that fixes it. Rewritten whenever something in it changes (checked
//  every 2 s) and after every command. Local file, owner-only; no network
//  listener.
//
//  COMMANDS. shimmerctl drops `<id>.json` ({"command", "id", "params"}) into
//  ~/Library/Application Support/Shimmer/agent-commands/ (owner-only); the app
//  watches that folder, runs the command and deletes the file. A fixed allowlist
//  of harmless actions - refresh, repair a helper, show a screen, cancel a stuck
//  connect. The result lands in the state file as `last_command`, matched by
//  `id`, which is how shimmerctl knows the app acted.
//
//  A folder rather than a URL scheme: SwiftUI takes over Apple Event URL
//  handling after launch (commands silently stopped arriving), a web page can
//  open a URL but can't write here, and a file works the same from an SSH
//  session, which doesn't share the GUI session's other channels.
//

import AppKit
import IOKit.hid
import ServiceManagement

@MainActor
final class AgentControl: NSObject {
    static let shared = AgentControl()

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shimmer", isDirectory: true)
    }
    static var stateURL: URL { folder.appendingPathComponent("agent-state.json") }
    static var commandsURL: URL { folder.appendingPathComponent("agent-commands", isDirectory: true) }

    /// Everything an agent may ask for. Nothing here starts a stream, unpairs,
    /// quits a game on the PC, or changes a setting.
    enum Command: String, CaseIterable {
        case state, refresh
        case repairWifiHelper = "repair-wifi-helper"
        case repairLoginItem = "repair-login-item"
        case openSettings = "open-settings"
        case openLoginItems = "open-login-items"
        case openInputMonitoring = "open-input-monitoring"
        case cancelConnect = "cancel-connect"
    }

    private weak var model: AppModel?
    private var timer: Timer?
    private var lastContent: Data?
    private var lastCommand: [String: String]?
    private var watcher: DispatchSourceFileSystemObject?
    private let launchedAt = Date()

    func start(model: AppModel) {
        self.model = model
        watchCommands()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { AgentControl.shared.writeState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeState(force: true)
    }

    // MARK: - Commands

    private func watchCommands() {
        let folder = Self.commandsURL
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { AgentControl.shared.drainCommands() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        drainCommands()
    }

    /// Run and delete every queued command file; ignore anything over a minute
    /// old (left from before this launch) or not owned by this user.
    private func drainCommands() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.commandsURL, includingPropertiesForKeys:
            [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == "json" {
            defer { try? fm.removeItem(at: file) }
            let attributes = try? fm.attributesOfItem(atPath: file.path)
            guard (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let modified = attributes?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) < 60,
                  let data = try? Data(contentsOf: file),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = request["command"] as? String else { continue }
            let id = request["id"] as? String ?? ""
            let params = request["params"] as? [String: String] ?? [:]
            run(name, id: id, params: params)
        }
    }

    func run(_ name: String, id: String, params: [String: String]) {
        let query = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let command = Command(rawValue: name) else {
            finish(id: id, name: name, result: "unknown command; known: "
                   + Command.allCases.map(\.rawValue).joined(separator: ", "))
            return
        }
        Diag.notice("agent command: \(command.rawValue)", "Agent")
        switch command {
        case .state:
            finish(id: id, name: name, result: "ok")
        case .refresh:
            AWDLHelperManager.shared.refresh()
            if let model, let host = model.selectedHost {
                Task { @MainActor in
                    await model.pollHostStatusOnce(for: host.id)
                    self.finish(id: id, name: name, result: "ok")
                }
            } else {
                finish(id: id, name: name, result: "ok")
            }
        case .repairWifiHelper:
            AWDLHelperManager.shared.repair()
            // Registration settles asynchronously; report what it settled to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.finish(id: id, name: name, result: "re-registered; wifi_helper shows the outcome")
            }
        case .repairLoginItem:
            LoginItemManager.reconcile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.finish(id: id, name: name, result: "reconciled; login_item shows the outcome")
            }
        case .openSettings:
            let tab = query.first { $0.name == "tab" }?.value.flatMap(SettingsTab.init(rawValue:))
            AppDelegate.openMainWindow?()
            NSApp.activate()
            if let tab { model?.settingsTab = tab }
            finish(id: id, name: name, result: "ok")
        case .openLoginItems:
            SMAppService.openSystemSettingsLoginItems()
            finish(id: id, name: name, result: "opened; the user must switch Shimmer on")
        case .openInputMonitoring:
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            finish(id: id, name: name, result: "opened; the user must switch Shimmer on, then relaunch it")
        case .cancelConnect:
            if case .connecting = model?.streamPhase {
                model?.cancelConnect()
                finish(id: id, name: name, result: "cancelled")
            } else {
                finish(id: id, name: name, result: "nothing was connecting")
            }
        }
    }

    private func finish(id: String, name: String, result: String) {
        lastCommand = ["id": id, "command": name, "result": result,
                       "at": ISO8601DateFormatter().string(from: Date())]
        writeState(force: true)
    }

    // MARK: - State

    func writeState(force: Bool = false) {
        guard let model else { return }
        let snapshot = Self.snapshot(model: model, launchedAt: launchedAt, lastCommand: lastCommand)
        guard let content = try? JSONSerialization.data(
            withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        guard force || content != lastContent else { return }
        lastContent = content
        var stamped = snapshot
        stamped["written_at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(
            withJSONObject: stamped, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = Self.stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func snapshot(model: AppModel, launchedAt: Date,
                         lastCommand: [String: String]?) -> [String: Any] {
        let bundle = Bundle.main
        let mainOpen = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
        let helper = AWDLHelperManager.shared
        let loginStatus = LoginItemManager.currentStatus
        let wantsLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        let inputMonitoring = Self.inputMonitoringStatus()

        var loading: [String] = []
        var issues: [[String: String]] = []
        func issue(_ id: String, _ summary: String, _ fix: String) {
            issues.append(["id": id, "summary": summary, "fix": fix])
        }

        var selected: [String: Any] = [:]
        if let host = model.selectedHost {
            let status = model.selectedHostStatusLine
            selected = ["id": host.id, "name": host.displayName,
                        "local_address": host.localAddress ?? "",
                        "manual_address": host.manualAddress ?? "",
                        "status": status,
                        "running_app": model.runningAppName ?? ""]
            if status == "Checking…" {
                loading.append("PC status for \(host.displayName) is still being checked")
                issue("host_status_loading",
                      "\(host.displayName)'s status has not loaded",
                      "shimmerctl fix refresh; if it persists, shimmerctl doctor (checks the PC's ports)")
            }
        }

        let phase: String
        switch model.streamPhase {
        case .idle: phase = "idle"
        case .connecting(let stage):
            phase = "connecting"
            loading.append("stream connecting: \(stage)")
        case .streaming: phase = "streaming"
        case .disconnecting: phase = "disconnecting"
        case .error(let text): phase = "error: \(text)"
        }
        if model.pairingInFlight { loading.append("pairing with a PC") }
        if let error = model.nativeStreamError {
            issue("stream_error", error, "shimmerctl logs --last 10m")
        }

        let helperState: String
        switch helper.state {
        case .enabled: helperState = "enabled"
        case .notRunning:
            helperState = "approved but macOS can't start it"
            issue("wifi_helper_not_running", "The Wi-Fi helper is approved but launchd can't start it",
                  "shimmerctl fix wifi-helper")
        case .requiresApproval:
            helperState = "waiting for approval"
            issue("wifi_helper_needs_approval", "The Wi-Fi helper is waiting for approval",
                  "shimmerctl fix approve-background (opens Login Items; the user switches Shimmer on)")
        case .notRegistered: helperState = "off"
        case .unavailable(let why): helperState = "unavailable: \(why)"
            issue("wifi_helper_unavailable", why, "shimmerctl fix wifi-helper")
        }

        if wantsLogin {
            if loginStatus == .requiresApproval {
                issue("login_item_needs_approval", "\"Be ready at login\" is waiting for approval",
                      "shimmerctl fix approve-background (opens Login Items; the user switches Shimmer on)")
            } else if loginStatus != .enabled {
                issue("login_item_broken", "\"Be ready at login\" is on but its helper isn't registered",
                      "shimmerctl fix login-item")
            }
        }

        if model.rawHIDControllerEnabled, inputMonitoring != "granted" {
            issue("input_monitoring_off",
                  "Input Monitoring is \(inputMonitoring): the PS, Options, Create and Mute buttons don't reach the PC",
                  "shimmerctl fix input-monitoring (opens the pane; the user switches Shimmer on, then relaunches)")
        }

        return [
            "app": ["version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                    "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
                    "commit": BuildInfo.commit,
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "launched_at": ISO8601DateFormatter().string(from: launchedAt)],
            "ui": ["main_window_visible": mainOpen,
                   "tab": model.settingsTab.rawValue,
                   "in_dock": NSApp.activationPolicy() == .regular,
                   "menu_bar_item_visible": model.hasVisibleMenuBarItem],
            "selected_host": selected,
            "hosts": model.hosts.map { ["id": $0.id, "name": $0.displayName,
                                        "local_address": $0.localAddress ?? "",
                                        "manual_address": $0.manualAddress ?? ""] },
            "stream": ["phase": phase,
                       "picture_in_picture": model.nativeStreamPictureInPicture,
                       "error": model.nativeStreamError ?? ""],
            "controller": ["connected": model.controllerConnected,
                           "kind": model.menuBarControllerKind ?? "",
                           "battery_percent": model.menuBarControllerBattery?.percent ?? -1],
            "permissions": ["input_monitoring": inputMonitoring,
                            "raw_controller_buttons_enabled": model.rawHIDControllerEnabled],
            "wifi_helper": ["state": helperState, "suppressing_awdl": helper.suppressing],
            "login_item": ["wanted": wantsLogin,
                           "status": LoginItemManager.statusLabel(loginStatus)],
            "loading": loading,
            "issues": issues,
            "last_command": lastCommand ?? [:],
            "commands": Command.allCases.map(\.rawValue),
        ]
    }

    static func inputMonitoringStatus() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "not asked yet"
        }
    }
}
