//
//  LibraryWindow.swift
//
//  The Computers tab: PCs down the left, the selected PC's apps as a grid of
//  cover art on the right, and the actions along the bottom edge - the shape of
//  Tailscale's Accounts tab, inside the same tabbed window as Settings and
//  About rather than a page of its own.
//
//  Everything underneath is unchanged - `selectHost`, `requestStream`,
//  `PairSheet`, the host context menu and the artwork store are the same calls
//  the old hero card made.
//

import SwiftUI

struct ComputersTab: View {
    @Environment(AppModel.self) private var model

    @State private var showPairSheet = false
    @State private var showUnpairConfirm = false
    @State private var search = ""

    /// Selection is the host ID, not the Host: Host is a value type the store
    /// replaces wholesale on every refresh, so tagging rows with it would drop
    /// the selection on each poll.
    private var hostSelection: Binding<String?> {
        Binding(
            get: { model.selectedHost?.id },
            set: { id in
                guard let id, let host = model.hosts.first(where: { $0.id == id }) else { return }
                model.selectHost(host)
            })
    }

    private var apps: [LibraryApp] {
        guard let host = model.selectedHost else { return [] }
        let visible = host.apps.filter { !$0.hidden }
        guard !search.isEmpty else { return visible }
        return visible.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                // 200pt, measured off the reference app's own window.
                .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(initialAddress: "")
                .presentationBackground(.thinMaterial)
        }
        .confirmationDialog("Remove this PC?", isPresented: $showUnpairConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let host = model.selectedHost { model.unpair(host) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(model.selectedHost?.displayName ?? "This PC") will need to be paired again before you can stream from it.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Hand-rolled rather than a `List`: a sidebar List paints its
            // selection in the ACCENT colour, and the reference app's selected
            // row is a neutral grey plate. No section header either - its
            // account list has none and the tab is already called Computers.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.hosts) { host in
                        HostRow(host: host, selected: host.id == model.selectedHost?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectHost(host) }
                            .hostContextMenu(host)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            // A full-width button on a 39pt bar, like "Add Account…".
            Button {
                showPairSheet = true
            } label: {
                Text("Add PC…").frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        hostHeader(host)
                        if host.apps.count > 8 { searchField.padding(.bottom, 14) }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 84, maximum: 92), spacing: 14, alignment: .top)],
                            alignment: .center, spacing: 24
                        ) {
                            ForEach(apps) { app in
                                AppCoverTile(app: app, host: host)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                }
                .overlay { if model.isStreaming { streamingOverlay(host) } }

                Divider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Remove PC…") { showUnpairConfirm = true }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .task(id: host.id) { model.artwork.prefetch(apps: host.apps, on: host) }
        } else if model.hosts.isEmpty {
            EmptyPairingState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }

    /// The centred identity block the reference app puts at the top of its
    /// detail column: a round glyph, the name under it, then the detail.
    private func hostHeader(_ host: Host) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 56, height: 56)
                Image(systemName: "display")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            Text(host.displayName)
                .font(.system(size: 13, weight: .semibold))
            Text(host.localAddress ?? host.manualAddress ?? host.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
                .frame(width: 170)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    /// Shown over the grid while a session is up, so the window says what is
    /// happening instead of the grid just dimming.
    private func streamingOverlay(_ host: Host) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tint)
            Text("Streaming").font(.headline)
            Text(model.runningAppName ?? model.heroTargetAppName)
                .font(.subheadline).foregroundStyle(.secondary)
            Text(host.displayName)
                .font(.caption).foregroundStyle(.tertiary)
            Button {
                model.resumeStreamWindow()
            } label: {
                Label("Show the stream", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

// MARK: - Sidebar row

/// One PC: a round glyph with a status dot, the name, and the address beneath -
/// the shape of the reference app's account rows (41.5pt plate, 6pt inset).
private struct HostRow: View {
    let host: Host
    let selected: Bool
    @Environment(AppModel.self) private var model

    /// Liveness is only ever polled for the SELECTED host (HostStatusPoller),
    /// so that is the only one this can honestly colour. Every other row gets
    /// the "unknown" grey rather than a guess.
    private var dotColor: Color {
        guard host.id == model.selectedHost?.id else { return .secondary.opacity(0.55) }
        guard let live = model.hostLiveStatus,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            return .secondary.opacity(0.55)
        }
        switch live.state {
        case .asleep: return .red
        case .certMismatch: return .orange
        case .unknown: return .secondary.opacity(0.55)
        case .idle, .streamingApp, .streamingUnknownApp: return .green
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "display")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.accentColor))
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                    .offset(x: 1, y: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(host.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(host.localAddress ?? host.manualAddress ?? host.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // 41.5pt plate, 6pt inset, neutral grey when selected - measured off
        // the reference app.
        .frame(minHeight: 41.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.13) : Color.clear))
    }
}

// MARK: - App tile

/// One launchable app, drawn as a macOS-style icon: a rounded-square plate in
/// a hue derived from the name, with an SF Symbol on it and the title beneath.
///
/// NOT the host's box art. Sunshine serves `/appasset` for every app, but its
/// defaults are generic plates with DESKTOP or STEAM printed on them, which
/// read as cheap cards rather than app icons. Real artwork is still available
/// behind Settings > "Show cover art from the PC" for hosts that have it.
private struct AppCoverTile: View {
    let app: LibraryApp
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    private static let plate: CGFloat = 64

    private var plateColor: Color {
        Color(hue: app.iconHue, saturation: 0.42, brightness: 0.62)
    }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if model.showCoverArt, let image = model.artwork.image(for: app, on: host) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [plateColor.opacity(0.95), plateColor.opacity(0.70)],
                            startPoint: .top, endPoint: .bottom)
                        Image(systemName: app.systemImage)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    }
                }
            }
            .frame(width: Self.plate, height: Self.plate)
            // The macOS app-icon squircle.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if app.name == model.runningAppName { runningBadge }
            }
            .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
            .scaleEffect(hovered ? 1.07 : 1.0)
            .animation(.easeOut(duration: 0.18), value: hovered)

            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .frame(width: 84)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.requestStream(app: app, on: host) }
        .opacity(model.isStreaming ? 0.5 : 1.0)
        .help(model.isStreaming ? "Finish the current stream first" : "Stream \(app.name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Stream \(app.name)")
    }

    private var runningBadge: some View {
        Image(systemName: "figure.run")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .offset(x: 5, y: -5)
            .help("Running on this PC now")
    }
}
