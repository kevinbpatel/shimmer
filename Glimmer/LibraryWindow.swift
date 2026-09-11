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
            // No section header: the reference app's account list has none, and
            // the tab is already called Computers.
            List(selection: hostSelection) {
                ForEach(model.hosts) { host in
                    HostRow(host: host)
                        .tag(host.id)
                        .hostContextMenu(host)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 42)

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
                            columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: 18, alignment: .top)],
                            alignment: .center, spacing: 24
                        ) {
                            ForEach(apps) { app in
                                AppCoverTile(app: app, host: host)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
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
        .padding(.vertical, 5)
    }
}

// MARK: - Cover tile

private struct AppCoverTile: View {
    let app: LibraryApp
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    /// 3:4, the shape every GameStream host serves (`/appasset` answers
    /// 600x800). 128pt wide is close to the reference app's default tile.
    private static let art = CGSize(width: 128, height: 171)

    var body: some View {
        VStack(spacing: 8) {
            cover
                .frame(width: Self.art.width, height: Self.art.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if app.name == model.runningAppName { runningBadge }
                }
                .shadow(color: .black.opacity(0.35), radius: 5, y: 5)
                .scaleEffect(hovered ? 1.06 : 1.0)
                .animation(.easeOut(duration: 0.2), value: hovered)
            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
        .frame(width: Self.art.width)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.requestStream(app: app, on: host) }
        .opacity(model.isStreaming ? 0.5 : 1.0)
        .help(model.isStreaming ? "Finish the current stream first" : "Stream \(app.name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Stream \(app.name)")
    }

    @ViewBuilder
    private var cover: some View {
        if let image = model.artwork.image(for: app, on: host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            // The host has no art (or it is still arriving): a flat plate with
            // the app's symbol, rather than a spinner that flickers into a
            // picture a moment later.
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: app.systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runningBadge: some View {
        Image(systemName: "figure.run")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            .offset(x: 6, y: -6)
            .help("Running on this PC now")
    }
}
