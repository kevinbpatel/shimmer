//
//  ContentViewSubviews.swift
//
//  Host-hero presentation pieces split out of ContentView.swift: the app-icon
//  and spec-chip rows, plus the empty-pairing and stream-ended states. Internal
//  so ContentView.swift composes. The three larger pieces that used to live here
//  now have their own files, for length: ContentView+ReadinessChip.swift (the
//  status chip), ContentView+PowerControls.swift (the Luna power cluster), and
//  ContentView+StreamButton.swift (the morphing Stream button and its style).
//

import Accessibility
import AppKit
import SwiftUI

// MARK: - Empty pairing state

struct FirstPCSetup: View {
    let nearby: [HostDiscovery.Discovered]
    @Binding var address: String
    let connect: (String) -> Void
    var error: String? = nil

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 12) {
                        Image("AboutAppIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        VStack(spacing: 4) {
                            Text("Welcome to Shimmer")
                                .font(.system(size: 22, weight: .semibold))
                            // Reuse the subtitle for feedback rather than
                            // leaving an empty alert-sized gap above the field.
                            ZStack {
                                if let error {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.orange)
                                            .accessibilityHidden(true)
                                        Text(error)
                                            .font(.system(size: 13))
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                    .background(Color.orange.opacity(0.055),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .accessibilityElement(children: .combine)
                                } else {
                                    Text("Add your first PC to get started.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 34)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                TextField("PC address or Tailscale IP", text: $address)
                                    .font(.system(size: 14))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                                    .frame(height: FirstPCMetrics.buttonHeight)
                                    .disableAutocorrection(true)
                                    .accessibilityLabel("PC IP address, hostname, or Tailscale address")
                                    .help("Enter the PC’s IP address or hostname, including a Tailscale address")
                                    .onSubmit(submit)
                                Button("Connect", action: submit)
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.roundedRectangle(radius: 5))
                                    .controlSize(.large)
                                    .disabled(trimmedAddress.isEmpty)
                            }
                            .frame(height: FirstPCMetrics.buttonHeight)
                        }
                        if !nearby.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Nearby PCs")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
                                ForEach(nearby) { pc in
                                    HStack(spacing: 10) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22)
                                            .accessibilityHidden(true)
                                        Text(pc.displayName)
                                            .font(.system(size: 14))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Button {
                                            address = pc.host
                                            connect(pc.host)
                                        } label: {
                                            Text("Pair")
                                                .font(.system(size: 13))
                                                .frame(minWidth: 40)
                                        }
                                            .buttonStyle(.bordered)
                                            .buttonBorderShape(.roundedRectangle(radius: 5))
                                            .controlSize(.small)
                                            .help("Pair with \(pc.displayName)")
                                            .accessibilityLabel("Pair with nearby PC \(pc.displayName), \(pc.host)")
                                    }
                                    .padding(.leading, 10)
                                    .padding(.trailing, 4)
                                    .modifier(FirstPCRowStyle())
                                }
                            }
                        }
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: 400)
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func submit() {
        guard !trimmedAddress.isEmpty else { return }
        connect(trimmedAddress)
    }
}

/// Shared, persistent feedback for address and pairing failures.
struct PCConnectionErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

private enum FirstPCMetrics {
    static let rowHeight: CGFloat = 36
    static let buttonHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 8
}

private struct FirstPCRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: FirstPCMetrics.rowHeight)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: FirstPCMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: FirstPCMetrics.cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Stream-ended toast (disconnect beat)

/// Brief "Stream ended" acknowledgement above the launcher content, driven
/// off `AppModel.streamEndedToastVisible`; auto-dismisses after a
/// short hold (the stream window's own fade is missable from a Cmd-Tab).
/// Thin material, no icon, monochrome - Apple's first-party toasts (AirPods
/// connect, volume HUD) are deliberately understated.
struct StreamEndedToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.streamEndedToastVisible {
                VStack(spacing: 2) {
                    Text("Stream ended")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    // Session receipt - one quiet line ("2h 12m · 12 ms
                    // median"), only when the stash kept one (≥5 min sessions).
                    if let line = model.lastSessionReceiptToastLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                // One element, one sentence for assistive tech.
                .accessibilityElement(children: .combine)
                // Keyed on the receipt so a back-to-back end re-arms the hold
                // for the new content; the flag reset in stream() is the other
                // half - the flag actually FALLS between cycles now, so a
                // repeat end gets a fresh task, not a half-spent hold.
                .task(id: model.lastSessionReceipt) {
                    // VoiceOver never reaches a 2-4 s transient by focus
                    // navigation - announce the beat + receipt explicitly.
                    let line = model.lastSessionReceiptToastLine
                    AccessibilityNotification.Announcement(
                        line.map { "Stream ended. \($0)" } ?? "Stream ended"
                    ).post()
                    // Auto-dismiss - 2 s plain, 4 s with the receipt line.
                    let hold: UInt64 = line == nil ? 2_000_000_000 : 4_000_000_000
                    try? await Task.sleep(nanoseconds: hold)
                    if !Task.isCancelled {
                        model.streamEndedToastVisible = false
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.30, extraBounce: 0.1),
                   value: model.streamEndedToastVisible)
    }
}
