import Foundation
import Security

/// Which processes may drive the root helper, as a code-signing requirement the
/// OS checks against each XPC peer's audit token (`setCodeSigningRequirement`).
///
/// Derived from the helper's OWN signature, resolved once at launch (`Identity`,
/// in main.swift) because self-inspection reads the file on disk, which an
/// install replaces while the helper keeps running:
/// - Signed with a Team ID (Developer ID): Shimmer's bundle id, Apple-anchored,
///   from the helper's team. Never read from the app on disk, so swapping the
///   bundle can't hand over or downgrade the helper.
/// - Ad hoc (local builds): there is no team to pin, so the peer must be exactly
///   the Shimmer.app this helper ships inside - its designated requirement, which
///   for ad hoc code is its cdhash. Re-read for every connection because each
///   build (and embed-dylibs' re-seal) changes it while an older helper may still
///   be running. Here the app bundle's filesystem permissions are the trust
///   boundary: whoever can rewrite /Applications/Shimmer.app can drive the
///   helper, which only toggles awdl0.
enum HelperClientRequirement {
    static let appIdentifier = "com.kevinbpatel.shimmer"

    /// What the running helper is: its team (nil when ad hoc) and the app it ships in.
    struct Identity: Sendable {
        let teamID: String?
        let enclosingApp: URL?
    }

    /// The requirement for one connection, or nil to refuse it (fail closed).
    static func requirement(teamID: String?, appDesignatedRequirement: String?,
                            identifier: String = appIdentifier) -> String? {
        if let teamID {
            guard teamID.count == 10, teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
                return nil
            }
            return "identifier \"\(identifier)\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"\(teamID)\""
        }
        guard let appDesignatedRequirement, !appDesignatedRequirement.isEmpty else { return nil }
        return "identifier \"\(identifier)\" and (\(appDesignatedRequirement))"
    }

    /// `X.app` for a helper at `X.app/Contents/MacOS/<helper>`; nil anywhere else.
    static func enclosingApp(ofHelperAt executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    /// The running helper's identity. Call once at launch, before the listener
    /// resumes: the file on disk is then still the one launchd validated.
    static func launchIdentity() -> Identity? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        var path: CFURL?
        guard SecCodeCopyPath(staticMe, [], &path) == errSecSuccess, let path else { return nil }
        return Identity(teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                        enclosingApp: enclosingApp(ofHelperAt: path as URL))
    }

    /// The requirement for one connection, given the identity resolved at launch.
    static func requirement(for identity: Identity) -> String? {
        if let team = identity.teamID {
            return requirement(teamID: team, appDesignatedRequirement: nil)
        }
        guard let app = identity.enclosingApp else { return nil }
        return requirement(teamID: nil, appDesignatedRequirement: designatedRequirement(of: app))
    }

    static func designatedRequirement(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}

/// Which connection holds awdl0 down. Only that connection's exit restores it, so
/// a second client that connects and leaves can't cut a stream short; an explicit
/// release from any verified peer still works, so a reconnected app can recover a
/// lease whose reply it lost.
struct HelperLease {
    private(set) var owner: UUID?

    /// Records the claim or release; the caller applies `down` to the interface.
    mutating func set(down: Bool, by peer: UUID) {
        owner = down ? peer : nil
    }

    /// True when `peer` held the lease, which is now cleared and must be released.
    mutating func peerInvalidated(_ peer: UUID) -> Bool {
        guard owner == peer else { return false }
        owner = nil
        return true
    }
}
