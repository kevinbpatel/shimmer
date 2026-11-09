// The coding-agent instructions Settings copies, and the copy button.
import AppKit
import SwiftUI

enum ShimmerCLIAgentInstructions {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func text(hostName: String? = nil, address: String? = nil,
                     bundleURL: URL = Bundle.main.bundleURL) -> String {
        let executable = bundleURL.appendingPathComponent("Contents/Resources/shimmerctl")
        let context = zip(hostName.map { [$0] } ?? [], address.map { [$0] } ?? [])
            .map { "PC name: \($0.0)\nPC address: \($0.1)" }.first
            ?? "Ask which PC to investigate before running host-specific checks."
        let doctor = address.map { "doctor --host \(quote($0))" } ?? "doctor --host <PC-address>"
        return """
        Diagnose Shimmer using its CLI. Find shimmerctl on PATH; otherwise use
        \(quote(executable.path)). Read --help and the bundled CLI.md (the source
        documentation is docs/CLI.md). The CLI requires Python 3; find an existing
        interpreter or explain if it is missing.

        \(context)

        Start with `doctor`: it reports what the running app is doing (screen,
        anything stuck loading, permissions, its background helpers), launchd's view
        of those helpers, the PC's ports, and the commands that fix what it finds.
        Then `fix auto` applies every fix that needs no person and lists the rest.
        `state` prints the app's live state; `logs --last 10m` has the detail. If
        the app doesn't answer, `fix relaunch`. To check a specific PC: \(doctor).
        If no apps appear, check the paired /applist request, hidden apps and
        Sunshine's configuration; the doctor command
        does not by itself verify pairing or the app list.

        Preserve pairing and settings, never request private keys, and do not
        interrupt an active stream. Diagnose first, make targeted fixes where
        authorized, and verify the result in Shimmer.
        """
    }
}

struct CLICopyButton: View {
    let title: String
    let value: () -> String
    @State private var copied = false
    init(_ title: String, value: @escaping () -> String) {
        self.title = title
        self.value = value
    }
    var body: some View {
        Button {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(value(), forType: .string)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                ZStack {
                    Text(title).hidden().accessibilityHidden(true)
                    Text(copied ? "Copied" : title)
                }
            }
        }
    }
}
