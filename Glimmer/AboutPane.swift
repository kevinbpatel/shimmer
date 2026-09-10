//
//  AboutPane.swift
//
//  Settings → About. App identity, the credo, version (with the option-click
//  Diagnostics reveal), credits, license, and the upstream support link. Split
//  out of SettingsPCsShortcutsPanes.swift to keep that file under the 600-line bar.
//

import AppKit
import SwiftUI

/// Single source of truth for the About pane's outbound links. Strings (not
/// force-unwrapped URLs) so the pane renders link rows with a lint-clean
/// `if let`; a malformed constant degrades to "row missing", never a crash.
private enum AboutLink {
    static let repo = "https://github.com/kevinbpatel/shimmer"
    static let credits = "https://github.com/kevinbpatel/shimmer/blob/main/CREDITS.md"
    static let upstream = "https://github.com/Se7enbrc/glimmer"
    static let license = "https://www.gnu.org/licenses/gpl-3.0.html"
    static let sunshine = "https://github.com/LizardByte/Sunshine"
    static let moonlight = "https://github.com/moonlight-stream"
    /// glimmer's author's GitHub Sponsors - shimmer's engine is theirs, so the
    /// one ask in this pane goes upstream.
    static let donate = "https://github.com/sponsors/Se7enbrc"
}

struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // First-party utility tone - see System Settings ▸ About, Disk
        // Utility ▸ About, Activity Monitor ▸ About: app name + plain
        // description + version + credits. No marketing voice, no
        // exclamation marks, no comparisons to other products. The credo
        // is the one allowed line of soul.
        Form {
            Section {
                HStack(spacing: 18) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
                    } else {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .frame(width: 96, height: 96)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shimmer")
                            .font(.system(size: 28, weight: .bold))
                            .tracking(-0.4)
                        Text("Stream your gaming PC to this Mac - and pop it out.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        // The credo, inherited from glimmer. One line, no
                        // elaboration - it is the project's bar, not a slogan.
                        Text("Highest fidelity. Lowest resources. Rock stable.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                        Text("Version \(versionString)")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            // Hidden reveal for the telemetry/tuning sections
                            // inside Settings → Diagnostics. Option-clicking the
                            // version line toggles `showDiagnostics` - a
                            // deliberate, undiscoverable gesture so normal users
                            // never trip it, but a power user (or a bug report)
                            // can surface them.
                            .gesture(
                                TapGesture()
                                    .modifiers(.option)
                                    .onEnded { model.showDiagnostics.toggle() }
                            )
                            .help(model.showDiagnostics
                                  ? "Option-click to hide the developer tools"
                                  : "")
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            Section("A fork of glimmer") {
                Text("Shimmer is a fork of glimmer by Se7enbrc that adds macOS Picture in "
                    + "Picture. The streaming engine - decoder, pacing, audio, input - is "
                    + "glimmer's work; the pop-out and its macOS workarounds are Shimmer's.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.repo) {
                    Link("github.com/kevinbpatel/shimmer", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.upstream) {
                    Link("github.com/Se7enbrc/glimmer (upstream)", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.donate) {
                    Link("Support glimmer's author", destination: url)
                        .font(.footnote)
                }
            }
            Section("License") {
                Text("Shimmer is free software under the GNU General Public License v3, the "
                    + "same license as glimmer. You may run, study, share, and modify it; "
                    + "there is no warranty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.license) {
                    Link("GNU GPL v3", destination: url)
                        .font(.footnote)
                }
            }
            Section("Projects we like") {
                Text("Built for Sunshine, the open-source game-streaming host. Shimmer "
                    + "speaks the Moonlight protocol - itself carrying NVIDIA GameStream "
                    + "forward - and the transport is ported from moonlight-common-c, "
                    + "with respect. Full credits in CREDITS.md.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.sunshine) {
                    Link("github.com/LizardByte/Sunshine", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.moonlight) {
                    Link("github.com/moonlight-stream", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.credits) {
                    Link("Credits", destination: url)
                        .font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "1.2.3 (45)" - short marketing version + build number, matching
    /// what System Settings ▸ General ▸ About shows for first-party apps.
    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
