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
                .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(initialAddress: "")
                .presentationBackground(.thinMaterial)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: hostSelection) {
                Section("Computers") {
                    ForEach(model.hosts) { host in
                        HostRow(host: host)
                            .tag(host.id)
                            .hostContextMenu(host)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button("Add PC…") { showPairSheet = true }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost {
            VStack(spacing: 0) {
                header(host)
                Divider()
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: 18, alignment: .top)],
                        alignment: .leading, spacing: 24
                    ) {
                        ForEach(apps) { app in
                            AppCoverTile(app: app, host: host)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay { if model.isStreaming { streamingOverlay(host) } }
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

    private func header(_ host: Host) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(host.localAddress ?? host.manualAddress ?? host.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Shown over the grid while a session is up, so the window says what is
    /// happening instead of the grid just dimming. The stream itself lives in
    /// its own window (or Picture in Picture); this is the way back to it.
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

private struct HostRow: View {
    let host: Host
    @Environment(AppModel.self) private var model

    /// Liveness is only ever polled for the SELECTED host (HostStatusPoller),
    /// so that is the only one this can honestly colour. Every other row gets
    /// the "unknown" grey rather than a guess - a green dot on a PC that has
    /// not been contacted since launch would be a lie.
    private var dotColor: Color {
        guard host.id == model.selectedHost?.id else { return .secondary.opacity(0.5) }
        guard let live = model.hostLiveStatus,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            return .secondary.opacity(0.5)
        }
        switch live.state {
        case .asleep: return .red
        case .certMismatch: return .orange
        case .unknown: return .secondary.opacity(0.5)
        case .idle, .streamingApp, .streamingUnknownApp: return .green
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(host.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.isStreaming, host.id == model.selectedHost?.id {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 4)
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
