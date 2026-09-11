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
                    VStack(alignment: .leading, spacing: 12) {
                        // Apps lead: they are what the page is FOR. The PC's
                        // name is not repeated here - the row selected in the
                        // sidebar already says which machine this is.
                        field("Apps") {
                            if host.apps.count > 8 { searchField.padding(.bottom, 2) }
                            ForEach(apps) { app in
                                Button {
                                    model.requestStream(app: app, on: host)
                                } label: {
                                    Label {
                                        Text(app.name)
                                    } icon: {
                                        AppGlyphIcon(app: app)
                                    }
                                    .frame(minWidth: 150, alignment: .leading)
                                }
                                .disabled(model.isStreaming)
                                .help(model.isStreaming
                                      ? "Finish the current stream first" : "Stream \(app.name)")
                            }
                            if apps.isEmpty {
                                Text("No apps to show.").foregroundStyle(.secondary)
                            }
                        }

                        field("Address") {
                            Text(host.localAddress ?? host.manualAddress ?? host.name)
                                .textSelection(.enabled)
                        }
                        field("Status") {
                            HStack(spacing: 7) {
                                Circle().fill(statusColor).frame(width: 9, height: 9)
                                Text(statusText)
                                // The only part of the old streaming card worth
                                // keeping: a way back to a running stream. The
                                // rest of that card - a big "Streaming" plate
                                // naming the app and the PC - said what this
                                // row, the disabled app buttons and their help
                                // text already say, while covering the pane it
                                // was reporting on.
                                if model.isStreaming {
                                    Button("Show the stream") { model.resumeStreamWindow() }
                                        .controlSize(.small)
                                        .padding(.leading, 3)
                                }
                            }
                        }
                        if let played = host.lastPlayedDescription {
                            // The stored string reads "last played 5 hours ago",
                            // which repeats the label in a two-column list.
                            let trimmed = played.hasPrefix("last played ")
                                ? String(played.dropFirst("last played ".count))
                                : played
                            field("Last played") { Text(trimmed).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, 16)
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

    /// One detail row. The reference app right-aligns its labels ~109pt into
    /// the detail column with the values ~20pt beyond - narrower than the
    /// Settings gutter because this column is only 400pt wide.
    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .frame(width: 92, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) { content() }
            Spacer(minLength: 0)
        }
    }

    private var statusColor: Color {
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

    private var statusText: String {
        guard let live = model.hostLiveStatus,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            return "Checking…"
        }
        switch live.state {
        case .idle: return "Online"
        case .streamingApp(let name): return "Streaming \(name)"
        case .streamingUnknownApp: return "Streaming"
        case .asleep: return "Asleep or offline"
        case .certMismatch: return "Trust needed - pair again"
        case .unknown: return "Checking…"
        }
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
