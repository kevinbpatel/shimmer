// Bundled diagnostics, account-scoped command installation, and its native sheet.
import AppKit
import Darwin
import Foundation
import SwiftUI

struct ShimmerCLIInstallation {
    let bundleURL: URL
    let homeURL: URL
    let shell: String
    private let files = FileManager.default

    init(bundleURL: URL = Bundle.main.bundleURL,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         shell: String? = nil) {
        self.bundleURL = bundleURL
        self.homeURL = homeURL
        self.shell = shell ?? Self.loginShell
    }

    private static var loginShell: String {
        guard let entry = getpwuid(getuid()), let value = entry.pointee.pw_shell else { return "/bin/zsh" }
        return String(cString: value)
    }

    var executableURL: URL { bundleURL.appendingPathComponent("Contents/Resources/shimmerctl") }
    var commandURL: URL { homeURL.appendingPathComponent(".local/bin/shimmerctl") }
    var profileURL: URL {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "bash": homeURL.appendingPathComponent(".bash_profile")
        case "fish": homeURL.appendingPathComponent(".config/fish/conf.d/shimmer-cli.fish")
        default: homeURL.appendingPathComponent(".zshrc")
        }
    }
    var pathBlock: String {
        let command = URL(fileURLWithPath: shell).lastPathComponent == "fish"
            ? "fish_add_path --global \"$HOME/.local/bin\""
            : "case \":$PATH:\" in\n  *\":$HOME/.local/bin:\"*) ;;\n  *) export PATH=\"$HOME/.local/bin:$PATH\" ;;\nesac"
        return "# >>> Shimmer CLI >>>\n\(command)\n# <<< Shimmer CLI <<<\n"
    }
    var isInstalled: Bool {
        guard ownsCommand,
              let text = try? String(contentsOf: profileURL, encoding: .utf8) else { return false }
        return text.contains(pathBlock)
    }
    private var ownsCommand: Bool {
        (try? files.destinationOfSymbolicLink(atPath: commandURL.path)) == executableURL.path
    }

    func install() throws {
        guard ["zsh", "bash", "fish"].contains(URL(fileURLWithPath: shell).lastPathComponent) else {
            throw CLISetupError("Automatic PATH setup supports zsh, bash and fish. You can still use the bundled command directly.")
        }
        guard files.isExecutableFile(atPath: executableURL.path) else {
            throw CLISetupError("The bundled command is missing. Reinstall Shimmer and try again.")
        }
        let linkExists = (try? files.attributesOfItem(atPath: commandURL.path)) != nil
        guard !linkExists || ownsCommand else {
            throw CLISetupError("A different command already exists at ~/.local/bin/shimmerctl. It was left unchanged.")
        }
        let original = try profileContents()
        guard !original.contains("# >>> Shimmer CLI >>>") || original.contains(pathBlock) else {
            throw CLISetupError("The Shimmer block in your shell profile has been edited. It was left unchanged.")
        }
        try files.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !linkExists { try files.createSymbolicLink(at: commandURL, withDestinationURL: executableURL) }
        do {
            if !original.contains(pathBlock) {
                try writeProfile(original + (original.isEmpty || original.hasSuffix("\n") ? "" : "\n") + pathBlock)
            }
        } catch {
            if !linkExists, ownsCommand { try? files.removeItem(at: commandURL) }
            throw error
        }
    }

    func remove() throws {
        let original = try profileContents()
        if original.contains(pathBlock) {
            try writeProfile(original.replacingOccurrences(of: pathBlock, with: ""))
        }
        if ownsCommand { try files.removeItem(at: commandURL) }
    }

    private func profileContents() throws -> String {
        guard files.fileExists(atPath: profileURL.path) else { return "" }
        return try String(contentsOf: profileURL, encoding: .utf8)
    }
    private func writeProfile(_ text: String) throws {
        // Respect dotfile symlinks instead of replacing them with regular files.
        let destination = profileURL.resolvingSymlinksInPath()
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes = try? files.attributesOfItem(atPath: destination.path)
        try Data(text.utf8).write(to: destination, options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
    }
}

private struct CLISetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

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

        Run status, \(doctor), and logs --last 10m. Check the paired /applist request,
        hidden apps and Sunshine’s configuration if no apps appear. The doctor
        command does not by itself verify pairing or the app list.

        Preserve pairing and settings, never request private keys, and do not
        interrupt an active stream. Diagnose first, make targeted fixes where
        authorized, and verify the result in Shimmer.
        """
    }
}

struct CLIIntegrationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var installed = false
    @State private var errorMessage: String?
    private let installation: ShimmerCLIInstallation

    init(installation: ShimmerCLIInstallation = ShimmerCLIInstallation()) {
        self.installation = installation
    }

    private var command: String {
        (installed ? "shimmerctl" : ShimmerCLIAgentInstructions.quote(installation.executableURL.path)) + " status"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Command Line Integration").font(.system(size: 16, weight: .semibold))
            Text("Diagnose Shimmer from Terminal or your coding agent.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("Terminal command").fontWeight(.medium)
                Text(command).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(installed ? "Remove Command" : "Add Command to PATH") { changeInstallation() }
                    Spacer()
                    CLICopyButton("Copy Command") { command }
                }
                SettingsHelp(installed
                             ? "Added for your account. Open a new Terminal window to use it."
                             : "Adds shimmerctl for your account. Python 3 is required.", checkbox: false)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text("Your coding agent").fontWeight(.medium)
                Text("Copy instructions to help your agent find the CLI and investigate this PC.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CLICopyButton("Copy Agent Instructions") {
                    ShimmerCLIAgentInstructions.text(hostName: model.selectedHost?.displayName,
                        address: model.selectedHostRouteAddress)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 520)
        .onAppear { installed = installation.isInstalled }
    }
    private func changeInstallation() {
        do {
            if installed { try installation.remove() } else { try installation.install() }
            installed = installation.isInstalled
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct CLICopyButton: View {
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
