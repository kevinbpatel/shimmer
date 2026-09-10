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

struct AppIconsRow: View {
    let apps: [LibraryApp]
    let host: Host
    @Environment(AppModel.self) private var model

    /// The tile under the pointer. moonlight-macos-enhanced grows a hovered
    /// cover slightly rather than drawing a border; it reads as the art coming
    /// forward instead of a control lighting up.
    @State private var hoveredAppID: Int?

    /// Most tiles the row will ever show inline. Four 100pt slots span
    /// 4x100 + 3x10 = 430 inside the hero's 472pt content box, so the row stays
    /// one comfortable line at the card's FIXED width. Four rather than the
    /// old five because the tiles now carry real cover art and want the width.
    private static let maxInlineTiles = 4

    /// Apps shown as tiles. At or under the inline cap every app gets one; past
    /// it the last slot is spent on the overflow menu instead of a tile, so the
    /// row is never wider than `maxInlineTiles`.
    private var inlineApps: [LibraryApp] {
        apps.count <= Self.maxInlineTiles
            ? apps
            : Array(apps.prefix(Self.maxInlineTiles - 1))
    }

    private var overflowApps: [LibraryApp] {
        apps.count <= Self.maxInlineTiles
            ? []
            : Array(apps.dropFirst(Self.maxInlineTiles - 1))
    }

    var body: some View {
        // One glass composite for the row - see ReadinessChip's container note.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(inlineApps) { app in
                    appTile(app)
                }
                // Overflow goes in a MENU, not an expanding grid. The launcher
                // window is sized to its content and deliberately not resizable,
                // so anything that grows the card has to grow the window - which
                // is what made the expand-in-place grid untenable. A menu opens
                // OVER the window and costs no layout at all.
                if !overflowApps.isEmpty {
                    overflowMenu
                }
            }
        }
        // Dim the whole row while a session exists (connecting, live,
        // backgrounded) as the visual "parked" cue - .plain buttons don't
        // restyle on disable, so the opacity IS the affordance.
        //
        // The DISABLE, though, is scoped to the launch affordances themselves
        // (each tile, and each item inside the overflow menu) rather than
        // blanket-applied here. A click on one would spawn a SECOND concurrent
        // session - stream()'s re-entrancy guard is the wall, this is the honest
        // signal. But OPENING the menu launches nothing, and disabling the whole
        // row took that with it: mid-session you could not even look at which
        // apps the PC has. Same distinction this file's review of #49 drew for
        // the old expand/collapse controls; it was lost in the revert.
        .opacity(model.isStreaming ? 0.45 : 1.0)
        .animation(.snappy(duration: 0.3), value: model.isStreaming)
        // Pull every app's art at once, including the ones behind the overflow
        // menu, so opening it doesn't start a burst of requests.
        .task(id: host.id) { model.artwork.prefetch(apps: apps, on: host) }
    }

    /// Artwork box: 3:4 portrait, the shape every GameStream host serves
    /// (`/appasset` returns 600x800). 96pt wide is as large as four tiles - art
    /// plus title - can be inside the hero card's fixed 472pt content box, and
    /// large enough that a real cover reads as a cover rather than a chip.
    static let artSize = CGSize(width: 96, height: 128)
    /// Slot width: the art plus a little breathing room for a long title.
    static let slotWidth: CGFloat = 100

    private func appTile(_ app: LibraryApp) -> some View {
        Button {
            model.requestStream(app: app, on: host)
        } label: {
            VStack(spacing: 5) {
                artwork(for: app)
                    .frame(width: Self.artSize.width, height: Self.artSize.height)
                    // 12pt CONTINUOUS, the radius and curve the reference app
                    // uses on its covers - a plain `cornerRadius` corner reads
                    // visibly tighter next to it.
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        // Accent ring for the hero target (resume app, else
                        // default) so the ring always agrees with the hero
                        // button's verb.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                app.name == model.heroTargetAppName ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    }
                    // The badge is a SIBLING of the clipped art, not a subview,
                    // so it can overhang the corner mask the way the reference
                    // app's does.
                    .overlay(alignment: .topTrailing) {
                        if app.name == model.runningAppName { runningBadge }
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .scaleEffect(hoveredAppID == app.id ? 1.06 : 1.0)
                    .animation(.snappy(duration: 0.2), value: hoveredAppID)
                    .onHover { inside in
                        hoveredAppID = inside ? app.id : (hoveredAppID == app.id ? nil : hoveredAppID)
                    }
                Text(app.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // A `.plain` Button only hit-tests its LABEL, so without this the
            // padding around the icon and name was dead space. Fill the declared
            // slot inside the label and claim it as the content shape.
            // (Salvaged from #49, which got this part right.)
            .frame(width: Self.slotWidth, height: Self.artSize.height + 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isStreaming)
        .help(model.isStreaming
            ? "Finish the current stream first" : "Stream \(app.name)")
    }

    /// "This is the app your PC is running right now", straight from the
    /// host's own /serverinfo reading. Same idea as the reference app's blue
    /// runner badge: a filled circle overhanging the artwork's top-right.
    private var runningBadge: some View {
        Image(systemName: "figure.run")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .offset(x: 6, y: -6)
            .help("Running on this PC now")
    }

    /// The host's cover art, or the symbol treatment while it loads / when the
    /// host has none. Deliberately no spinner: art arrives in well under a
    /// second off the disk cache, and a placeholder that flickers into a
    /// picture reads worse than a picture that simply appears.
    @ViewBuilder
    private func artwork(for app: LibraryApp) -> some View {
        if let image = model.artwork.image(for: app, on: host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: app.systemImage)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.artSize.width, height: Self.artSize.height)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        }
    }

    /// The overflow dropdown: every app past the inline cap, in source order.
    /// Reads as one more tile in the row, but opens a native menu over the
    /// window instead of resizing anything.
    private var overflowMenu: some View {
        Menu {
            ForEach(overflowApps) { app in
                Button {
                    model.requestStream(app: app, on: host)
                } label: {
                    Label(app.name, systemImage: app.systemImage)
                }
                // Each ITEM is a launch, so each item parks - the menu itself
                // stays openable so the list is still readable mid-session.
                .disabled(model.isStreaming)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: Self.artSize.width, height: Self.artSize.height)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                Text("\(overflowApps.count) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Self.slotWidth, height: Self.artSize.height + 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 70, height: 70)
        .help(model.isStreaming
            ? "Finish the current stream first"
            : "Show \(overflowApps.count) more app\(overflowApps.count == 1 ? "" : "s")")
        .accessibilityLabel("\(overflowApps.count) more apps")
        .accessibilityHint("Shows the rest of this PC's apps")
    }
}

struct SpecChipsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // One glass composite for the row - see ReadinessChip's container note.
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(model.streamSpecChips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

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
