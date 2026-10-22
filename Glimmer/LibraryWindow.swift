//
//  LibraryWindow.swift
//
//  Saved PCs and nearby Bonjour discoveries share the sidebar. The detail
//  pane shows either a saved PC's apps and latency test, or the pairing flow
//  for a PC the user is adding. Saved routes refresh only after pinned TLS verification.
//

import SwiftUI
import Charts
import Network

struct ComputersTab: View {
    @Environment(AppModel.self) private var model

    @State private var pairingTarget: PCPairingTarget?
    @State private var discovered: [HostDiscovery.Discovered] = []
    @State private var showManualAddress = false
    @State private var pendingManualAddress: String?
    @State private var showUnpairConfirm = false
    @State private var search = ""
    @State private var latencyTest = HostLatencyTest()

    private struct DiscoveryRouteScope: Hashable {
        let discoveries: [HostDiscovery.Discovered]
        let paused: Bool
    }

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

    private var nearby: [HostDiscovery.Discovered] {
        NearbyPCList.available(discovered, saved: model.hosts)
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
        .task(id: model.pairingInFlight) {
            // Each task owns its browser. Cancelling an older task can never
            // stop the browser belonging to a newly opened Servers tab.
            guard !model.pairingInFlight else { return }
            let browser = HostDiscovery()
            for await results in await browser.start() {
                guard !Task.isCancelled else { break }
                discovered = results
            }
            await browser.stop()
        }
        .task(id: DiscoveryRouteScope(discoveries: discovered, paused: model.pairingInFlight || model.isStreaming)) {
            await model.refreshDiscoveredHostAddresses(discovered)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.hosts.isEmpty {
                        sidebarHeading("Saved PCs")
                        ForEach(model.hosts) { host in
                            Button {
                                guard !model.pairingInFlight else { return }
                                pairingTarget = nil
                                model.selectHost(host)
                            } label: {
                                HostRow(host: host, address: model.dialAddress(for: host), selected: pairingTarget == nil && host.id == model.selectedHost?.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .accessibilityLabel("\(host.displayName), saved PC, \(model.dialAddress(for: host))")
                            .hostContextMenu(host)
                        }
                    }
                    if !nearby.isEmpty {
                        sidebarHeading("Nearby PCs")
                            .padding(.top, model.hosts.isEmpty ? 0 : 10)
                        ForEach(nearby) { pc in
                            Button {
                                latencyTest.reset()
                                pairingTarget = PCPairingTarget(name: pc.displayName, address: pc.host)
                            } label: {
                                NearbyPCRow(pc: pc, selected: pairingTarget?.address == pc.host)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .help("Pair with \(pc.displayName) to add this PC")
                            .accessibilityLabel("\(pc.displayName), nearby PC, not added, \(pc.host)")
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Button {
                showManualAddress = true
            } label: {
                Text("Add by Address…")
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(.regular)
            .disabled(model.pairingInFlight)
            .help("Add a PC using an IP address or hostname")
            .popover(isPresented: $showManualAddress,
                     attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                ManualAddressPopover(cancel: { showManualAddress = false }) { address in
                    pendingManualAddress = address
                    showManualAddress = false
                }
                .onDisappear {
                    guard let address = pendingManualAddress else { return }
                    pendingManualAddress = nil
                    latencyTest.reset()
                    if let host = NearbyPCList.savedPC(at: address, in: model.hosts) {
                        pairingTarget = nil
                        model.selectHost(host)
                    } else {
                        pairingTarget = PCPairingTarget(name: "Add PC", address: address, startImmediately: true)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let target = pairingTarget {
            PCPairingPane(target: target) { id in
                if let host = model.hosts.first(where: { $0.id == id }) {
                    model.selectHost(host)
                    pairingTarget = nil
                }
            }
            .id(target.id)
        } else if let host = model.selectedHost {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Apps lead: they are what the page is FOR. The PC's
                        // name is not repeated here - the row selected in the
                        // sidebar already says which machine this is.
                        field("Apps") {
                            if host.apps.count > 8 { searchField.padding(.bottom, 2) }
                            ForEach(apps) { app in
                                let canShowStream = model.isStreaming
                                    && model.activeStreamHostID == host.id
                                    && model.activeStreamApp?.id == app.id
                                    && model.activeStreamHasVideo
                                HStack(spacing: 6) {
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
                                    .fixedSize(horizontal: true, vertical: false)
                                    .disabled(model.isStreaming)
                                    .help(model.isStreaming
                                          ? "Finish the current stream first" : "Stream \(app.name)")

                                    if canShowStream {
                                        Button {
                                            model.resumeStreamWindow()
                                        } label: {
                                            Label("Show stream", systemImage: "pip.exit")
                                                .labelStyle(.iconOnly)
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 24, height: 24)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Show \(app.name) stream")
                                        .accessibilityLabel("Show \(app.name) stream")
                                    }
                                }
                            }
                            if apps.isEmpty {
                                Text("No apps to show.").foregroundStyle(.secondary)
                            }
                            if model.isStreaming, model.activeStreamHostID == host.id,
                               case .connecting(let stage) = model.streamPhase {
                                Text(stage).foregroundStyle(.secondary)
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

                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                latencySection(for: host)
                    .padding(16)

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

    private func latencySection(for host: Host) -> some View {
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

/// A readable zero-based scale for the measurements currently in view. Keep
/// clean tick values without imposing a 10 ms floor on fast connections.
struct LatencyGraphScale {
    let upperBound: Double
    var ticks: [Double] { [0, upperBound / 2, upperBound] }

    init(maximum: Double?) {
        guard let maximum, maximum.isFinite, maximum >= 0,
              maximum < Double(Int.max) else {
            upperBound = 10
            return
        }
        let value = max(1, maximum)
        let magnitude = pow(10, floor(log10(value)))
        let step = [1.0, 2, 5, 10].first { $0 * magnitude >= value } ?? 10
        upperBound = max(value, step * magnitude)
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
        let scale = LatencyGraphScale(maximum: test.history.statistics(at: now)?.maximum)
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
                .chartYScale(domain: 0...scale.upperBound,
                             range: .plotDimension(startPadding: 8, endPadding: 8))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: scale.ticks) { value in
                        AxisValueLabel(collisionResolution: .disabled, horizontalSpacing: 8) {
                            if let ms = value.as(Double.self) {
                                Text("\(ms.formatted(.number.precision(.fractionLength(0...1))))ms")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                    .frame(minWidth: 36, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartPlotStyle { plot in plot.clipped() }
                .frame(height: 80)
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

/// Discovery is transient and untrusted. Match stable server IDs or exact
/// saved addresses; a friendly name alone must never hide another user's PC.
struct NearbyPCList {
    static func savedPC(at address: String, in saved: [Host]) -> Host? {
        let key = addressKey(address)
        return saved.first { host in
            [host.localAddress, host.manualAddress].compactMap { $0 }.contains { addressKey($0) == key }
        }
    }

    static func available(_ found: [HostDiscovery.Discovered], saved: [Host]) -> [HostDiscovery.Discovered] {
        let ids = Set(saved.map { $0.id.lowercased() })
        let addresses = Set(saved.flatMap { [$0.localAddress, $0.manualAddress].compactMap { $0 }.map(addressKey) })
        var seenIDs = Set<String>()
        var seenAddresses = Set<String>()
        return found.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.id < $1.id
        }.filter { pc in
            let address = addressKey(pc.host)
            if let id = pc.serverID, ids.contains(id.lowercased()) { return false }
            guard !addresses.contains(address) else { return false }
            let endpoint = "\(address):\(pc.port)"
            let duplicateAddress = !seenAddresses.insert(endpoint).inserted
            let duplicateID = pc.serverID.map { !seenIDs.insert($0.lowercased()).inserted } ?? false
            return !duplicateAddress && !duplicateID
        }
    }

    private static func addressKey(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let pieces = value.split(separator: "%", maxSplits: 1)
        let plain = pieces.first.map(String.init) ?? value
        if let ip = IPv4Address(plain) { return "v4:" + ip.rawValue.base64EncodedString() }
        if let ip = IPv6Address(plain) {
            let bytes = Array(ip.rawValue)
            let zone = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && pieces.count == 2 ? "%" + pieces[1] : ""
            return "v6:" + ip.rawValue.base64EncodedString() + zone
        }
        return value.hasSuffix(".") ? String(value.dropLast()) : value
    }
}

private struct NearbyPCRow: View {
    let pc: HostDiscovery.Discovered
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: SettingsMetrics.sidebarIconSize, height: SettingsMetrics.sidebarIconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(pc.displayName).font(.system(size: 13)).lineLimit(1)
                Text(pc.host).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.sidebarRowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar row

/// One PC: a round glyph, the name, and the address beneath -
/// the shape of the reference app's account rows (48pt plate, 6pt inset).
private struct HostRow: View {
    let host: Host
    let address: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HostIdentityIcon(host: host)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(address)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.sidebarRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.13) : Color.clear))
    }
}

/// The icon preference is keyed by stable host ID, independently of the
/// replaceable Host snapshots. AppStorage updates both the row and menu.
struct HostIdentityIcon: View {
    let host: Host
    @AppStorage private var preference: HostIcon

    init(host: Host) {
        self.host = host
        _preference = AppStorage(wrappedValue: .automatic, HostIcon.storageKey(for: host.id))
    }

    var body: some View {
        let icon = preference.resolved(serverName: host.name)
        let rgb = icon.backgroundRGB
        let colour = Color(red: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255)
        Circle()
            .fill(icon == .computer ? Color.accentColor.opacity(0.22) : colour)
            .frame(width: SettingsMetrics.sidebarIconSize, height: SettingsMetrics.sidebarIconSize)
            .overlay {
                if let asset = icon.assetName {
                    Image(asset)
                        .renderingMode(icon == .chimeraOS ? .original : .template)
                        .resizable().scaledToFit()
                        .foregroundStyle(icon == .linux ? Color.black : .white)
                        .frame(width: 25, height: 25)
                } else {
                    Image(systemName: icon == .macOS ? "apple.logo" : "display")
                        .font(.system(size: icon == .macOS ? 23 : 18))
                        .foregroundStyle(icon == .computer ? Color.accentColor : .white)
                }
            }
            .help(icon == .computer ? "Server icon · Right-click to choose" : "\(icon.title) icon · Right-click to change")
            .accessibilityLabel(icon == .computer ? "Server" : "\(icon.title) server icon")
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
