//
//  AWDLHelperAuthorizationTests.swift
//
//  The root AWDL helper's client requirement and per-connection lease
//  (helper/HelperAuthorization.swift, compiled into this test target; the helper
//  itself is built by the Makefile). Ported in spirit from upstream Glimmer
//  30d5163e (2026.10.6), adapted so ad hoc builds keep working.
//

import Foundation
import Security
import Testing

struct HelperClientRequirementTests {

    @Test func developerIDPinsTheHelpersOwnTeam() throws {
        let requirement = try #require(HelperClientRequirement.requirement(teamID: "ABCDE12345",
                                                                           appDesignatedRequirement: "cdhash H\"00\""))
        #expect(requirement == "identifier \"com.kevinbpatel.shimmer\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(Self.parses(requirement))
    }

    @Test func malformedTeamIsRefusedRatherThanSpliced() {
        for team in ["", "abcde12345", "ABCDE1234", "ABC\" or true", "ABCDE12345X"] {
            #expect(HelperClientRequirement.requirement(teamID: team, appDesignatedRequirement: "cdhash H\"00\"") == nil)
        }
    }

    @Test func adHocPinsTheEnclosingAppAndFailsClosedWithoutIt() throws {
        let dr = "cdhash H\"2c00e0a51ae65d801e2798b035d7f45d51d185d2\""
        let requirement = try #require(HelperClientRequirement.requirement(teamID: nil, appDesignatedRequirement: dr))
        #expect(requirement == "identifier \"com.kevinbpatel.shimmer\" and (\(dr))")
        #expect(Self.parses(requirement))
        #expect(HelperClientRequirement.requirement(teamID: nil, appDesignatedRequirement: nil) == nil)
        #expect(HelperClientRequirement.requirement(teamID: nil, appDesignatedRequirement: "") == nil)
    }

    /// A requirement built from a signed binary's designated requirement admits that
    /// binary and nothing else, the same check the OS applies to each XPC peer.
    @Test func derivedRequirementAdmitsOnlyTheBinaryItCameFrom() throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        let dr = try #require(HelperClientRequirement.designatedRequirement(of: ls))
        let requirement = try #require(HelperClientRequirement.requirement(teamID: nil, appDesignatedRequirement: dr,
                                                                           identifier: "com.apple.ls"))
        #expect(Self.satisfies(ls, requirement))
        #expect(!Self.satisfies(URL(fileURLWithPath: "/bin/cat"), requirement))
        let shimmerOnly = try #require(HelperClientRequirement.requirement(teamID: nil, appDesignatedRequirement: dr))
        #expect(!Self.satisfies(ls, shimmerOnly))
    }

    /// The launch-time identity decides the branch: a team helper never consults the
    /// app on disk, so a swapped ad hoc bundle can't downgrade it.
    @Test func launchIdentityPicksTheBranch() throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        let team = HelperClientRequirement.Identity(teamID: "ABCDE12345", enclosingApp: ls)
        let teamRequirement = try #require(HelperClientRequirement.requirement(for: team))
        #expect(teamRequirement.contains("leaf[subject.OU] = \"ABCDE12345\""))
        #expect(!teamRequirement.contains("cdhash") && !teamRequirement.contains("com.apple.ls"))

        let adHoc = HelperClientRequirement.Identity(teamID: nil, enclosingApp: ls)
        let lsRequirement = try #require(HelperClientRequirement.designatedRequirement(of: ls))
        #expect(HelperClientRequirement.requirement(for: adHoc)
            == "identifier \"com.kevinbpatel.shimmer\" and (\(lsRequirement))")
        #expect(HelperClientRequirement.requirement(for: .init(teamID: nil, enclosingApp: nil)) == nil)
        let missing = URL(fileURLWithPath: "/nonexistent/Shimmer.app")
        #expect(HelperClientRequirement.requirement(for: .init(teamID: nil, enclosingApp: missing)) == nil)
    }

    @Test func enclosingAppIsFoundOnlyFromContentsMacOS() {
        let helper = URL(fileURLWithPath: "/Applications/Shimmer.app/Contents/MacOS/io.ugfugl.glimmer.helper")
        #expect(HelperClientRequirement.enclosingApp(ofHelperAt: helper)?.path == "/Applications/Shimmer.app")
        for path in ["/usr/local/bin/io.ugfugl.glimmer.helper",
                     "/Applications/Shimmer.app/Contents/Resources/io.ugfugl.glimmer.helper",
                     "/Applications/Shimmer/Contents/MacOS/io.ugfugl.glimmer.helper"] {
            #expect(HelperClientRequirement.enclosingApp(ofHelperAt: URL(fileURLWithPath: path)) == nil)
        }
    }

    private static func parses(_ text: String) -> Bool {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    }

    private static func satisfies(_ url: URL, _ text: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

struct HelperLeaseTests {

    @Test func oldPeerCannotReleaseItsReplacement() {
        var lease = HelperLease()
        let first = UUID()
        let replacement = UUID()
        lease.set(down: true, by: first)
        lease.set(down: true, by: replacement)
        let released1 = lease.peerInvalidated(first)
        #expect(!released1)
        let released2 = lease.peerInvalidated(UUID())
        #expect(!released2)
        #expect(lease.owner == replacement)
        let released3 = lease.peerInvalidated(replacement)
        #expect(released3)
        #expect(lease.owner == nil)
        let released4 = lease.peerInvalidated(replacement)
        #expect(!released4)
    }

    /// A reconnected app can release a lease whose reply it lost, and the old
    /// connection's later exit then changes nothing.
    @Test func replacementPeerCanExplicitlyReleaseTheOldLease() {
        var lease = HelperLease()
        let first = UUID()
        lease.set(down: true, by: first)
        lease.set(down: false, by: UUID())
        #expect(lease.owner == nil)
        let released5 = lease.peerInvalidated(first)
        #expect(!released5)
    }

    /// Status-only connections (ping, currentStatus) never claim, so their exit
    /// can't restore awdl0 under a running stream.
    @Test func nonOwnerExitLeavesTheLeaseAlone() {
        var lease = HelperLease()
        let streaming = UUID()
        lease.set(down: true, by: streaming)
        let released6 = lease.peerInvalidated(UUID())
        #expect(!released6)
        #expect(lease.owner == streaming)
    }
}
