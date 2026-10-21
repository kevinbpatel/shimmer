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
    @State private var latencyTest = HostLatencyTest()

    private struct LatencyScope: Equatable {
        let hostID: String?
        let address: String?
        let routeChangedAt: Date
        let streaming: Bool
        let streamHostID: String?
    }

    private var latencyScope: LatencyScope {
        LatencyScope(hostID: model.selectedHost?.id, address: model.selectedHostRouteAddress,
                     routeChangedAt: model.hostRoute.changedAt, streaming: model.isStreaming,
                     streamHostID: model.activeStreamHostID)
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
        .onChange(of: latencyScope) { latencyTest.reset() }
        .onDisappear { latencyTest.reset() }
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

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Latency").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if latencyTest.hasRun {
                                    Button(latencyTest.isRunning ? "Stop" : "Test latency") {
                                        if latencyTest.isRunning { latencyTest.stop() }
                                        else { startLatencyTest() }
                                    }
                                    .buttonStyle(.link)
                                    .disabled(model.isStreaming && model.activeStreamHostID != host.id)
                                }
                            }
                            NetworkHistoryGraph(test: latencyTest, streaming: model.isStreaming,
                                                canStart: !model.isStreaming || model.activeStreamHostID == host.id,
                                                startTest: startLatencyTest)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func startLatencyTest() {
        guard let host = model.selectedHost,
              let address = model.selectedHostRouteAddress else { return }
        let scope = latencyScope
        let port = model.nativeServerInfo(for: host).httpPort
        latencyTest.start(hostID: host.id, address: address) {
            guard latencyScope == scope else { return nil }
            if scope.streaming {
                guard model.activeStreamHostID == host.id, model.streamPhase == .streaming else { return nil }
                return await model.nativeSession?.networkRoundTripMilliseconds()
            }
            switch await HostReachability.measureRTT(host: address, port: port) {
            case .reachable(let ms): return Double(ms)
            case .unreachable: return nil
            }
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

/// An opt-in Tailscale-style diagnostic: a quiet result header, blue trace,
/// and readable millisecond labels on the right. Completed results are frozen.
private struct NetworkHistoryGraph: View {
    let test: HostLatencyTest
    let streaming: Bool
    let canStart: Bool
    let startTest: () -> Void
    private let blue = Color(red: 0.27, green: 0.47, blue: 0.91)

    var body: some View {
        let now = test.sampledAt
        let maximum = test.history.statistics(at: now)?.maximum ?? 0
        let ceiling = max(10, ceil(maximum * 1.15 / 10) * 10)
        let start = max(now.addingTimeInterval(-HostLatencyHistory.duration),
                        min(now.addingTimeInterval(-10), test.history.readings.first?.capturedAt ?? now))
        VStack(alignment: .leading, spacing: 7) {
            VStack(spacing: 0) {
                Group {
                    if test.hasRun {
                        HStack {
                            Text(streaming ? "Stream round-trip" : "TCP response time")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(test.latestDescription)
                                .fontWeight(.semibold).monospacedDigit()
                        }
                    } else {
                        Text("Test connection latency")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                Chart {
                    if !test.hasRun {
                        RuleMark(y: .value("Baseline", 0))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    ForEach(Array(test.history.segments(maxGap: 3.5).enumerated()), id: \.offset) { index, segment in
                        ForEach(Array(segment.enumerated()), id: \.offset) { _, reading in
                            LineMark(x: .value("Time", reading.capturedAt),
                                     y: .value("Milliseconds", reading.milliseconds),
                                     series: .value("Segment", index))
                                .foregroundStyle(blue)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                .interpolationMethod(.monotone)
                            if segment.count == 1 {
                                PointMark(x: .value("Time", reading.capturedAt),
                                          y: .value("Milliseconds", reading.milliseconds))
                                    .foregroundStyle(blue).symbolSize(10)
                            }
                        }
                    }
                }
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...ceiling)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let ms = value.as(Double.self) {
                                Text("\(ms.formatted(.number.precision(.fractionLength(0))))ms")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartPlotStyle { plot in plot.clipped() }
                .frame(height: 100)
                .opacity(test.hasRun ? 1 : 0.4)
                .overlay(alignment: .center) {
                    if !test.hasRun {
                        Button("Test latency", action: startTest)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(!canStart)
                    } else if test.history.readings.isEmpty {
                        Text(test.isRunning ? "Waiting for a response…" : "No measurements available")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Latency test history in milliseconds")
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.22), lineWidth: 1))
        }
        .help(streaming
              ? "Network round-trip time from the current stream. Reads the existing transport estimator without extra probes. Excludes game, capture, encoding, decoding, and display delay."
              : "Measures TCP connection setup time to this server, including DNS if needed. Runs only when started, for up to 30 readings. Stop cancels the test. This is not ICMP ping or end-to-end input latency.")
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
