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

struct EmptyPairingState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPair = false

    var body: some View {
        // No leading/trailing Spacers: they centred this state inside a window
        // taller than itself, and the window now sizes to its content, so there
        // is no extra height to centre within - only height they would invent.
        VStack(spacing: 26) {
            ZStack {
                // Floating glass medallion behind the hero symbol -
                // accent-tinted so it picks up the system tint.
                Circle()
                    .frame(width: 144, height: 144)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.18)),
                        in: .circle
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.04)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                Image(systemName: "display.and.arrow.down")
                    .font(.system(size: 60, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: !reduceMotion)
            }

            VStack(spacing: 10) {
                Text("Let's find your gaming PC")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                Text("Shimmer plays games from your gaming PC, on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Button {
                showPair = true
            } label: {
                Label("Pair a PC", systemImage: "plus.circle.fill")
                    .frame(minWidth: 260)
            }
            .buttonStyle(StreamButtonStyle())
            .controlSize(.large)
        }
        .padding(40)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showPair) {
            PairSheet().environment(model)
        }
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
