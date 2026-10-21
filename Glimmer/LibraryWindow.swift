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
import Charts

struct ComputersTab: View {
    @Environment(AppModel.self) private var model

    @State private var showPairSheet = false
    @State private var showUnpairConfirm = false
    @State private var search = ""
    @State private var liveLatency: HostLatencyReading?
    @State private var latencyHistory = HostLatencyHistory()

    private struct LatencyScope: Equatable {
        let hostID: String?
        let address: String?
        let routeChangedAt: Date
        let streaming: Bool
        let streamHostID: String?
    }

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
        .task(id: LatencyScope(hostID: model.selectedHost?.id,
                              address: model.selectedHostRouteAddress,
                              routeChangedAt: model.hostRoute.changedAt,
                              streaming: model.isStreaming,
                              streamHostID: model.activeStreamHostID)) {
            await sampleLatencyHistory()
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
                            if model.isStreaming, model.activeStreamHostID == host.id,
                               case .connecting(let stage) = model.streamPhase {
                                Text(stage).foregroundStyle(.secondary)
                            }
                            if model.isStreaming, model.activeStreamHostID == host.id,
                               model.activeStreamHasVideo {
                                Button("Show the stream") { model.resumeStreamWindow() }
                            }
                        }

                        field("Address") {
                            Text(model.selectedHostRouteAddress ?? host.name)
                                .textSelection(.enabled)
                        }

                        field("Connection") {
                            HStack(spacing: 6) {
                                if model.macConnectionIsEthernet {
                                    EthernetPortGlyph()
                                        .stroke(.secondary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                                        .frame(width: 16, height: 14)
                                        .accessibilityHidden(true)
                                } else if let symbol = model.macConnectionSymbol {
                                    Image(systemName: symbol).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                Text(model.macConnectionDescription)
                            }
                                .help("The physical interface macOS reports for this Mac’s route to the server, including underneath a VPN. This does not describe the host PC’s interface. Multiple links means macOS reports more than one eligible physical interface.")
                        }

                        NetworkHistoryGraph(history: latencyHistory, streaming: model.isStreaming,
                                            currentValue: { model.latencyDescription(liveReading: liveLatency, at: $0) })
                            .padding(.top, 18)
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

    private func sampleLatencyHistory() async {
        liveLatency = nil
        latencyHistory = HostLatencyHistory()
        guard let hostID = model.selectedHost?.id,
              let address = model.selectedHostRouteAddress else { return }
        let routeChangedAt = model.hostRoute.changedAt
        let streaming = model.isStreaming
        while !Task.isCancelled {
            let value = streaming && model.activeStreamHostID == hostID && model.streamPhase == .streaming
                ? await model.nativeSession?.networkRoundTripMilliseconds() : nil
            guard !Task.isCancelled, model.isStreaming == streaming,
                  model.selectedHost?.id == hostID, model.hostRoute.changedAt == routeChangedAt,
                  model.selectedHostRouteAddress == address else { return }
            liveLatency = value.map {
                HostLatencyReading(hostID: hostID, address: address, milliseconds: $0, capturedAt: .now)
            }
            let now = Date.now
            latencyHistory.record(model.currentLatencyReading(liveReading: liveLatency, at: now), at: now)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
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

/// One plot, with Activity Monitor's cyan trace and pale fill. It belongs to
/// the detail content, sharing its margins, rather than a separate footer.
private struct NetworkHistoryGraph: View {
    let history: HostLatencyHistory
    let streaming: Bool
    let currentValue: (Date) -> String

    private let cyan = Color(red: 0, green: 0.73, blue: 0.90)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let stats = history.statistics(at: timeline.date)
            let ceiling = max(10, ceil((stats?.maximum ?? 0) * 1.15 / 5) * 5)
            VStack(spacing: 7) {
                ZStack {
                    Text(streaming ? "ROUND-TRIP" : "RESPONSE TIME")
                        .font(.system(size: 11, weight: .semibold))
                    HStack {
                        Spacer()
                        Text(currentValue(timeline.date))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(cyan)
                    }
                }
                Divider()
                Chart {
                    RuleMark(y: .value("Baseline", 0))
                        .foregroundStyle(cyan.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                    ForEach(Array(history.segments(maxGap: streaming ? 3 : AppModel.hostStatusPollSeconds * 2 + 2).enumerated()), id: \.offset) { index, segment in
                        ForEach(Array(segment.enumerated()), id: \.offset) { _, reading in
                            AreaMark(x: .value("Time", reading.capturedAt),
                                     yStart: .value("Milliseconds", 0),
                                     yEnd: .value("Milliseconds", reading.milliseconds),
                                     series: .value("Segment", index))
                                .foregroundStyle(cyan.opacity(0.20))
                                .interpolationMethod(.linear)
                            LineMark(x: .value("Time", reading.capturedAt),
                                     y: .value("Milliseconds", reading.milliseconds),
                                     series: .value("Segment", index))
                                .foregroundStyle(cyan)
                                .lineStyle(StrokeStyle(lineWidth: 1.2))
                                .interpolationMethod(.linear)
                            if segment.count == 1 {
                                PointMark(x: .value("Time", reading.capturedAt),
                                          y: .value("Milliseconds", reading.milliseconds))
                                    .foregroundStyle(cyan).symbolSize(7)
                            }
                        }
                    }
                }
                .chartXScale(domain: timeline.date.addingTimeInterval(-HostLatencyHistory.duration)...timeline.date)
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartPlotStyle { plot in plot.clipped() }
                .overlay(alignment: .topLeading) {
                    if stats == nil {
                        Text("Waiting for measurements")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.top, 5)
                    }
                }
                .accessibilityLabel("Last minute of network timing")
                HStack {
                    Text("60 sec")
                    Spacer()
                    Text("0–\(ceiling.formatted(.number.precision(.fractionLength(0)))) ms")
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(height: 132)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.22), lineWidth: 1))
        }
        .help(streaming
              ? "Network round-trip time from the stream transport over this view’s last minute. Missing readings leave gaps. Excludes game, capture, encoding, decoding, and display delay."
              : "TCP connection setup time to the server, including DNS if needed. Shows this view’s last minute of actual checks, about 10 seconds apart. Missing readings leave gaps. History resets when the host, path, or measurement type changes.")
    }
}

/// A small RJ45 socket: the stepped opening and six contacts read as Ethernet
/// at text size, without depending on a plug-shaped SF Symbol.
private struct EthernetPortGlyph: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let outline: [CGPoint] = [CGPoint(x: 2, y: 2), CGPoint(x: 14, y: 2),
                                  CGPoint(x: 14, y: 10), CGPoint(x: 11, y: 10),
                                  CGPoint(x: 11, y: 12), CGPoint(x: 5, y: 12),
                                  CGPoint(x: 5, y: 10), CGPoint(x: 2, y: 10)]
        path.addLines(outline)
        path.closeSubpath()
        for x in stride(from: 4.0, through: 12.0, by: 1.6) {
            path.move(to: CGPoint(x: x, y: 3.5))
            path.addLine(to: CGPoint(x: x, y: 6.5))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 14)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
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
