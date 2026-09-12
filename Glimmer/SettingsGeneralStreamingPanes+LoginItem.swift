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
    @discardableResult
    static func apply(launchAtLogin: Bool) -> SMAppService.Status {
        let helper = activeService
        let mainApp = SMAppService.mainApp
        do {
            guard launchAtLogin else {
                if helper.status == .enabled { try helper.unregister() }
                if mainApp.status == .enabled { try mainApp.unregister() }
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            if mainApp.status == .enabled { try mainApp.unregister() }
            try helper.register()
            Diag.notice("login item registered (helper) → \(statusLabel(helper.status))", "LoginItem")
            return helper.status
        } catch {
            Diag.error("login item registration FAILED: \(error.localizedDescription)", "LoginItem")
            return .notFound
        }
    }

    /// Re-assert the saved intent at launch so a registration invalidated by an
    /// app update / move self-heals - the root cause of "doesn't start after
    /// reboot". Runs only when the user wants launch-at-login, and only
    /// re-registers when the actual status has drifted from enabled.
    static func reconcile() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        let status = activeService.status
        switch status {
        case .enabled:
            Diag.info("login item enabled (helper)", "LoginItem")
        case .requiresApproval:
            Diag.notice("login item needs approval in System Settings ▸ General ▸ Login Items", "LoginItem")
        default:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            apply(launchAtLogin: true)
        }
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
