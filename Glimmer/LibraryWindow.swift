//
//  LibraryWindow.swift
//
//  The Servers tab: PCs down the left and a launcher on the right. App buttons
//  use the whole detail column, with the server address under its heading.
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
        var visible = host.apps.filter { !$0.hidden }
        let current = model.isStreaming && model.activeStreamHostID == host.id
            ? model.heroTargetApp : nil
        // Keep Cancel / Show stream reachable even if the active app is hidden
        // from the saved library or does not match a subsequent search.
        if let current, !visible.contains(where: { $0.id == current.id }) {
            visible.insert(current, at: 0)
        }
        guard !search.isEmpty else { return visible }
        return visible.filter { $0.id == current?.id || $0.name.localizedCaseInsensitiveContains(search) }
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
                    ServerAppLauncher(host: host, apps: apps, search: $search,
                                      actionForApp: { appAction(for: $0, on: host) }) { app in
                        switch appAction(for: app, on: host) {
                        case .stream: model.requestStream(app: app, on: host)
                        case .cancelConnection: model.cancelConnect()
                        case .showStream: model.resumeStreamWindow()
                        case .unavailable: break
                        }
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Remove PC…") { showUnpairConfirm = true }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        } else if model.hosts.isEmpty {
            EmptyPairingState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }

    private func appAction(for app: LibraryApp, on host: Host) -> ServerAppAction {
        let stage: String?
        if case .connecting(let value) = model.streamPhase { stage = value } else { stage = nil }
        return ServerAppAction(isStreaming: model.isStreaming,
                               isCurrentApp: model.activeStreamHostID == host.id
                                   && model.heroTargetApp?.id == app.id,
                               connectingStage: stage,
                               hasVideo: model.activeStreamHasVideo && model.streamPhase == .streaming)
    }
}

// MARK: - App launcher

/// Keep the live action on its app, as upstream does. In particular a pending
/// handshake must offer Cancel, never another launch or a premature Show stream.
enum ServerAppAction: Equatable {
    case stream, cancelConnection(String), showStream, unavailable

    init(isStreaming: Bool, isCurrentApp: Bool, connectingStage: String?, hasVideo: Bool) {
        if !isStreaming { self = .stream }
        else if !isCurrentApp { self = .unavailable }
        else if let connectingStage { self = .cancelConnection(connectingStage) }
        else if hasVideo { self = .showStream }
        else { self = .unavailable }
    }
}

/// Native controls with enough room for the app's name and its current action.
/// No artwork is invented for Sunshine's desktop entries.
struct ServerAppLauncher: View {
    let host: Host
    let apps: [LibraryApp]
    @Binding var search: String
    let actionForApp: (LibraryApp) -> ServerAppAction
    let launch: (LibraryApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled)
                Text(host.localAddress ?? host.manualAddress ?? host.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Stream an app")
                    .font(.headline)
                if host.apps.filter({ !$0.hidden }).count > 8 { searchField }
                ForEach(apps) { app in
                    ServerAppLaunchButton(app: app, action: actionForApp(app)) { launch(app) }
                }
                if apps.isEmpty {
                    Text(search.isEmpty ? "No apps available." : "No apps match your search.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
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
}

struct ServerAppLaunchButton: View {
    let app: LibraryApp
    let action: ServerAppAction
    let perform: () -> Void

    private var subtitle: String? {
        switch action {
        case .cancelConnection(let stage): stage
        case .showStream: "Show stream"
        case .stream, .unavailable: nil
        }
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                AppGlyphIcon(app: app, size: 24)
                    .font(.system(size: 23))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                switch action {
                case .cancelConnection:
                    ProgressView().controlSize(.small)
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                case .showStream:
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 12, weight: .semibold))
                case .stream, .unavailable:
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(action == .unavailable)
        .help(help)
        .accessibilityLabel(app.name)
        .accessibilityValue(subtitle ?? "")
        .accessibilityHint(help)
    }

    private var help: String {
        switch action {
        case .stream: "Stream \(app.name)"
        case .cancelConnection: "Cancel the connection"
        case .showStream: "Show the current stream"
        case .unavailable: "Finish the current stream first"
        }
    }
}

// MARK: - Sidebar row

/// One PC: a round glyph, the name, and the address beneath -
/// the shape of the reference app's account rows (41.5pt plate, 6pt inset).
private struct HostRow: View {
    let host: Host
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "display")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.accentColor))
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

// MARK: - App glyph

/// An app's icon: a system symbol, or a bundled template mark for the few
/// things SF Symbols has no glyph for. Sized to sit on a button's text line.
///
/// Shared with the menu-bar dropdown, which names the same app on its stream
/// button - the two surfaces have to agree, or the menu says "Stream Steam"
/// beside a gamepad while the library shows the Valve mark.
struct AppGlyphIcon: View {
    let app: LibraryApp
    /// Cap height to match the symbols beside it. The library's rows are
    /// roomier than an NSMenu's, so the dropdown asks for a smaller one.
    var size: CGFloat = 14

    var body: some View {
        switch app.glyph {
        case .symbol(let name):
            Image(systemName: name)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // Matched to the cap height of the symbols beside it, so a
                // bundled mark and an SF Symbol sit on the same line.
                .frame(width: size, height: size)
        }
    }
}
