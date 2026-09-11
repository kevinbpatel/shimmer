//
//  LibraryWindow.swift
//
//  The launcher, as a library rather than a card: PCs down the left, that PC's
//  apps as a grid of cover art filling the window, and the window's own toolbar
//  carrying the host name, add-PC, Settings and a search field.
//
//  This replaces the fixed-size hero card (one PC, a big name, a row of small
//  tiles, one Stream button). The shape is moonlight-macos-enhanced's, which is
//  in turn Moonlight's: the thing you look at is your GAMES, and the PC is a
//  choice in a list rather than the subject of the screen. Streaming is a
//  double-click on a cover, not a separate button.
//
//  Everything underneath is unchanged - `selectHost`, `requestStream`,
//  `PairSheet`, the host context menu, and the artwork store are the same calls
//  the card made.
//

import SwiftUI

struct LibraryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    @State private var showPairSheet = false
    @State private var search = ""

    /// The List's selection is the host id, not the Host: Host is a value type
    /// that the store replaces wholesale on every refresh, so tagging rows with
    /// it would drop the selection each poll.
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
        NavigationSplitView {
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, prompt: "Search apps")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showPairSheet = true
                } label: {
                    Label("Add PC", systemImage: "plus")
                }
                .help("Pair another PC")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(initialAddress: "")
                .presentationBackground(.thinMaterial)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost {
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
                .padding(.vertical, 28)
            }
            .navigationTitle(host.displayName)
            .navigationSubtitle(hostSubtitle(host))
            .overlay { if model.isStreaming { streamingOverlay(host) } }
            .task(id: host.id) { model.artwork.prefetch(apps: host.apps, on: host) }
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }

    private func hostSubtitle(_ host: Host) -> String {
        host.localAddress ?? host.manualAddress ?? host.name
    }

    /// Shown over the grid while a session is up, so the window says what is
    /// happening instead of just dimming. The stream itself lives in its own
    /// window (or Picture in Picture); this is the way back to it.
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
