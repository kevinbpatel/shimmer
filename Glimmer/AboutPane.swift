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
        ScrollView {
            VStack(spacing: 14) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                } else {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.tint)
                }

                VStack(spacing: 4) {
                    Text("Shimmer for macOS")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Version \(versionString)")
                        .foregroundStyle(.secondary)
                        // Hidden reveal for the telemetry/tuning sections in
                        // App: option-clicking the version line toggles
                        // `showDiagnostics` - deliberately undiscoverable, so a
                        // normal user never trips it but a bug report can.
                        .gesture(
                            TapGesture()
                                .modifiers(.option)
                                .onEnded { model.showDiagnostics.toggle() })
                    Text("A fork of glimmer that pops the game out into Picture in Picture")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 6) {
                    if let url = URL(string: AboutLink.repo) { Link("shimmer on GitHub", destination: url) }
                    if let url = URL(string: AboutLink.upstream) { Link("glimmer, the upstream project", destination: url) }
                    if let url = URL(string: AboutLink.credits) { Link("Credits", destination: url) }
                    if let url = URL(string: AboutLink.license) { Link("GNU GPL v3", destination: url) }
                }

                Divider().frame(maxWidth: 420).padding(.vertical, 6)

                VStack(spacing: 6) {
                    Text("GPLv3. shimmer's engine is glimmer's, Copyright © 2026 ugfugl.io; shimmer's "
                        + "additions are Copyright © 2026 Kevin Patel.")
                    Text("The transport is ported from moonlight-common-c and moonlight-qt.")
                    if let url = URL(string: AboutLink.donate) {
                        Link("Sponsor glimmer's author", destination: url).padding(.top, 2)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .padding(.horizontal, 24)
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
