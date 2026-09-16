//
//  SettingsGeneralStreamingPanes+LoginItem.swift
//
//  `LoginItemManager` - the SMAppService login-item lifecycle behind the
//  General pane's two launch toggles, plus the launch-time reconcile
//  AppModel+Lifecycle calls. Split out of SettingsGeneralStreamingPanes.swift
//  to keep that file under the length limit: this is registration plumbing, not
//  a pane, and it has a caller outside Settings.
//

import Foundation
import Security
import ServiceManagement

/// Owns the SMAppService login-item lifecycle, shared by the General toggle
/// and the launch-time reconcile. Registration is keyed by the user's saved
/// intent (UserDefaults `launchAtLogin`) and always goes through the HELPER,
/// which relaunches the main app with the suppressed-window sentinel - the
/// app starts in the menu bar at login exactly as it does on any launch.
enum LoginItemManager {
    static let helperBundleID = "com.kevinbpatel.shimmer.LoginHelper"

    /// The service that backs launch-at-login: always the helper, which
    /// relaunches the app with the suppressed-window sentinel. (An older
    /// build could register the main app directly; `apply` unregisters it.)
    private static var activeService: SMAppService {
        SMAppService.loginItem(identifier: helperBundleID)
    }

    /// Apply the desired state, returning the resulting status so the caller can
    /// prompt for approval. Surfaces failures to the in-app log (the old code
    /// swallowed them into os_log, which is why a broken registration looked
    /// fine until the next reboot never happened).
    /// UserDefaults key: the helper's cdhash at the moment it was last
    /// registered. See `reconcile()`.
    private static let registeredHelperHashKey = "loginItemRegisteredHelperHash"

    @discardableResult
    static func apply(launchAtLogin: Bool) -> SMAppService.Status {
        let helper = activeService
        let mainApp = SMAppService.mainApp
        do {
            guard launchAtLogin else {
                if helper.status == .enabled { try helper.unregister() }
                if mainApp.status == .enabled { try mainApp.unregister() }
                UserDefaults.standard.removeObject(forKey: registeredHelperHashKey)
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            if mainApp.status == .enabled { try mainApp.unregister() }
            try helper.register()
            UserDefaults.standard.set(helperCodeHash(), forKey: registeredHelperHashKey)
            Diag.notice("login item registered (helper) → \(statusLabel(helper.status))", "LoginItem")
            return helper.status
        } catch {
            Diag.error("login item registration FAILED: \(error.localizedDescription)", "LoginItem")
            return .notFound
        }
    }

    /// Re-assert the saved intent at launch so a registration invalidated by an
    /// app update / move self-heals - the root cause of "doesn't start after
    /// reboot". Runs only when the user wants launch-at-login.
    ///
    /// Two distinct drifts are handled:
    ///   * the STATUS drifted from enabled (unregistered / not found) - re-register;
    ///   * the status still reads `.enabled` but the helper BINARY changed since
    ///     it was registered. launchd pins the login item to a lightweight code
    ///     requirement taken at registration; a rebuild (every ad-hoc dev
    ///     `make reinstall`, and each signed update) produces a helper that no
    ///     longer satisfies it, and launchd then refuses to spawn it at login
    ///     (`launchctl print` shows `job state = spawn failed`, `last exit code
    ///     = 78: EX_CONFIG`, `needs LWCR update`) while SMAppService keeps
    ///     reporting `.enabled` and a plain `register()` is a no-op. Only an
    ///     unregister + register makes smd re-submit the job with a fresh
    ///     requirement, so that is done exactly when the helper's cdhash differs
    ///     from the one recorded at the last registration - never on every
    ///     launch, which would re-add the item (and re-notify) each time.
    static func reconcile() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        let helper = activeService
        let status = helper.status
        switch status {
        case .enabled:
            let current = helperCodeHash()
            let registered = UserDefaults.standard.string(forKey: registeredHelperHashKey)
            let hashChanged = current != nil && current != registered
            // Ad-hoc builds are deterministic: an identical rebuild reproduces
            // the SAME cdhash, so "hash unchanged" alone can hide a requirement
            // launchd derived while a stray build-dir copy of the helper was
            // registered. Ask launchd directly; it is the one refusing to spawn.
            let launchdBroken = launchdReportsSpawnFailure()
            if hashChanged || launchdBroken {
                let why = hashChanged
                    ? "helper changed since registration (\(registered ?? "unrecorded") → \(current ?? "?"))"
                    : "launchd reports the login item cannot spawn"
                Diag.notice("login item \(why) - re-registering so launchd refreshes its code requirement", "LoginItem")
                do { try helper.unregister() } catch {
                    Diag.error("login item unregister FAILED: \(error.localizedDescription)", "LoginItem")
                }
                apply(launchAtLogin: true)
            } else {
                Diag.info("login item enabled (helper)", "LoginItem")
            }
        case .requiresApproval:
            Diag.notice("login item needs approval in System Settings ▸ General ▸ Login Items", "LoginItem")
        default:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            apply(launchAtLogin: true)
        }
    }

    /// Whether launchd says the login item job is in a failed state. launchd is
    /// the component that refuses the spawn, and `launchctl print` is the only
    /// public view of its verdict: `job state = spawn failed` / `last exit code
    /// = 78: EX_CONFIG` mean the helper it resolved doesn't satisfy the
    /// requirement it holds. Deliberately NOT keyed on the softer `needs LWCR
    /// update` flag, which launchd shows in healthy states too. Any failure to
    /// run or parse launchctl reads as "not broken" so this can never cause
    /// churn on its own.
    static func launchdReportsSpawnFailure() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(helperBundleID)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return false }
        return out.contains("job state = spawn failed") || out.contains("EX_CONFIG")
    }

    /// The installed helper's cdhash (Security's `kSecCodeInfoUnique`), hex -
    /// the identity launchd's requirement is effectively pinned to for an
    /// ad-hoc build. nil if the helper can't be found or read; callers treat
    /// nil as "don't know, don't churn".
    static func helperCodeHash() -> String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Shimmer Login Helper.app")
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    static func statusLabel(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
