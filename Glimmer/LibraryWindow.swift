//
//  LibraryWindow.swift
//
//  Saved PCs and nearby Bonjour discoveries share the sidebar. The detail
//  pane shows either a saved PC's apps and latency test, or the pairing flow
//  for a PC the user is adding. Saved routes refresh only after pinned TLS verification.
//

import AppKit
import SwiftUI
import Charts
import Network

struct ComputersTab: View {
    @Environment(AppModel.self) private var model

    @Binding var pairingTarget: PCPairingTarget?
    @State private var discovered: [HostDiscovery.Discovered] = []
    @State private var showManualAddress = false
    @State private var pendingManualAddress: String?
    @State private var setupAddress = ""
    @State private var setupError: String?
    @State private var renamingHostID: String?
    @State private var draftHostName = ""
    @FocusState private var hostNameFocused: Bool
    @State private var latencyTest = HostLatencyTest()
    @State private var appRefreshTask: Task<Void, Never>?
    @State private var refreshingApps = false
    @State private var appRefreshFailed = false
    @State private var copiedAgentPrompt = false
    @State private var sidebarProbes: [String: SidebarProbe] = [:]

    private struct SidebarProbe {
        let reachable: Bool
        let capturedAt: Date
    }

    private struct SidebarProbeTarget: Hashable, Sendable {
        let id: String
        let addresses: [String]
        let port: Int
    }

    private var sidebarProbeTargets: [SidebarProbeTarget] {
        guard !model.pairingInFlight, !model.hostPollingPausedForSleep else { return [] }
        return model.hosts.filter {
            $0.id != model.selectedHost?.id && !(model.isStreaming && model.activeStreamHostID == $0.id)
        }.map { host in
            SidebarProbeTarget(id: host.id, addresses: AppModel.candidateAddresses(for: host),
                               port: model.nativeServerInfo(for: host).httpPort)
        }
    }

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
        return host.apps.filter { !$0.hidden }
    }

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                if pairingTarget != nil {
                    detail
                } else {
                    FirstPCSetup(nearby: nearby, address: $setupAddress,
                                 connect: connectFirstPC, error: setupError)
                        .disabled(model.pairingInFlight)
                }
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 200)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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
        .task(id: model.selectedHostRouteAddress) {
            model.refreshHostRoute()
        }
        .task(id: sidebarProbeTargets) {
            let targets = sidebarProbeTargets
            guard !targets.isEmpty else { return }
            while !Task.isCancelled {
                await withTaskGroup(of: (String, Bool).self) { group in
                    for target in targets {
                        group.addTask {
                            for address in target.addresses {
                                guard !Task.isCancelled else { return (target.id, false) }
                                if case .reachable = await HostReachability.measureRTT(host: address, port: target.port) {
                                    return (target.id, true)
                                }
                            }
                            return (target.id, false)
                        }
                    }
                    for await (id, reachable) in group {
                        guard !Task.isCancelled else { continue }
                        sidebarProbes[id] = SidebarProbe(reachable: reachable, capturedAt: .now)
                    }
                }
                do { try await Task.sleep(for: .seconds(AppModel.hostStatusPollSeconds)) }
                catch { return }
            }
        }
        .onChange(of: latencyScope) { latencyTest.reset() }
        .onChange(of: setupAddress) { setupError = nil }
        .onChange(of: model.selectedHost?.id) {
            cancelHostRename()
            resetAppActions()
        }
        .onChange(of: pairingTarget?.id) { cancelHostRename() }
        .onChange(of: hostNameFocused) { _, focused in
            if !focused { saveHostRename() }
        }
        .onDisappear {
            latencyTest.reset()
            resetAppActions()
        }
    }

    private func connectFirstPC(address: String) {
        guard !model.pairingInFlight else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        setupError = nil
        setupAddress = address
        if let host = NearbyPCList.savedPC(at: address, in: model.hosts) {
            model.selectHost(host)
            pairingTarget = nil
            return
        }
        let name = nearby.first { $0.host == address }?.displayName ?? address
        pairingTarget = PCPairingTarget(name: name, address: address, startImmediately: true)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.hosts.isEmpty {
                        ForEach(model.hosts) { host in
                            Button {
                                guard !model.pairingInFlight else { return }
                                pairingTarget = nil
                                model.selectHost(host)
                            } label: {
                                HostRow(host: host, address: model.dialAddress(for: host), selected: pairingTarget == nil && host.id == model.selectedHost?.id,
                                        status: connectionIndicator(for: host), statusText: connectionStatusText(for: host))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.pairingInFlight)
                            .accessibilityLabel("\(host.displayName), \(connectionStatusText(for: host)), \(model.dialAddress(for: host))")
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
            addByAddressButton(expanded: true)
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(.regular)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }

    private func addByAddressButton(expanded: Bool = false) -> some View {
        Button {
            showManualAddress = true
        } label: {
            Text("Add by Address…")
                .frame(maxWidth: expanded ? .infinity : nil)
                .frame(height: 16)
        }
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
            PCPairingPane(target: target, failed: model.hosts.isEmpty ? { address, message in
                guard pairingTarget?.id == target.id else { return }
                setupAddress = address
                setupError = message
                pairingTarget = nil
            } : nil) { id in
                if let host = model.hosts.first(where: { $0.id == id }) {
                    model.selectHost(host)
                    pairingTarget = nil
                }
            }
            .id(target.id)
        } else if let host = model.selectedHost {
            VStack(spacing: 0) {
                VStack(spacing: apps.isEmpty ? 12 : 22) {
                    hostIdentity(for: host)
                    appList(for: host)
                }
                .padding(.top, 20)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                latencySection(for: host)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .hostOptionsMenu(host, onRename: { beginHostRename(host) })
                    .help("PC options")
                    .accessibilityLabel("PC options for \(host.displayName)")
                    .padding(.trailing, 11)
                    .padding(.top, 12)
            }
        } else {
            ContentUnavailableView("No PC selected",
                                   systemImage: "display",
                                   description: Text("Pick one on the left to see its apps."))
        }
    }

    private func hostIdentity(for host: Host) -> some View {
        let address = model.selectedHostRouteAddress ?? model.dialAddress(for: host)
        return VStack(spacing: 6) {
            HostIdentityIcon(host: host, size: 48, status: connectionIndicator(for: host), statusText: connectionStatusText(for: host))
            VStack(spacing: 2) {
                Group {
                    if renamingHostID == host.id {
                        TextField("PC name", text: $draftHostName)
                            .font(.system(size: 16))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                            .focused($hostNameFocused)
                            .onAppear { hostNameFocused = true }
                            .onSubmit { saveHostRename() }
                            .onExitCommand { cancelHostRename() }
                            .accessibilityLabel("PC name")
                    } else {
                        Text(host.displayName)
                            .lineLimit(1)
                            .help(host.displayName)
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)
                Text(address)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(height: 16)
            }
        }
        .frame(maxWidth: .infinity)
        .hostContextMenu(host, onRename: { beginHostRename(host) })
    }

    private func beginHostRename(_ host: Host) {
        draftHostName = host.displayName
        renamingHostID = host.id
    }

    private func connectionIndicator(for host: Host) -> HostStatusIndicator {
        if model.selectedHost?.id == host.id || (model.isStreaming && model.activeStreamHostID == host.id) {
            return model.hostStatusIndicator(for: host.id)
        }
        guard let probe = sidebarProbes[host.id], Date().timeIntervalSince(probe.capturedAt) <= HostLiveStatus.stale else { return .neutral }
        return probe.reachable ? .online : .offline
    }

    private func connectionStatusText(for host: Host) -> String {
        if model.selectedHost?.id == host.id || (model.isStreaming && model.activeStreamHostID == host.id) {
            return model.hostStatusLine(for: host.id)
        }
        guard let probe = sidebarProbes[host.id], Date().timeIntervalSince(probe.capturedAt) <= HostLiveStatus.stale else { return "Checking…" }
        return probe.reachable ? "Online" : "Asleep or offline"
    }

    private func saveHostRename() {
        guard let id = renamingHostID else { return }
        renamingHostID = nil
        hostNameFocused = false
        if let host = model.hosts.first(where: { $0.id == id }) {
            model.renameHost(host, to: draftHostName)
        }
    }

    private func cancelHostRename() {
        renamingHostID = nil
        hostNameFocused = false
    }

    @ViewBuilder
    private func appList(for host: Host) -> some View {
        if apps.isEmpty {
            VStack(spacing: 6) {
                Text("No apps found")
                    .font(.system(size: 13, weight: .medium))
                Text(appRefreshFailed
                     ? "Couldn’t refresh apps. Ask your coding agent to investigate."
                     : "Refresh the list, or ask your coding agent to investigate.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { refreshApps(for: host) } label: {
                        ZStack {
                            Text("Refresh Apps").hidden().accessibilityHidden(true)
                            Text(refreshingApps ? "Refreshing…" : "Refresh Apps")
                        }
                        .frame(height: 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(refreshingApps || model.isStreaming)
                    Button { copyAgentPrompt(for: host) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .frame(width: 12, height: 14)
                            ZStack {
                                Text("Copy Agent Prompt").hidden().accessibilityHidden(true)
                                Text(copiedAgentPrompt ? "Copied" : "Copy Agent Prompt")
                            }
                        }
                        .frame(height: 14)
                    }
                    .help("Copy troubleshooting instructions for Claude Code or another coding agent")
                }
                .font(.system(size: 12))
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
        } else if apps.count > 3 {
            NativeAppListScrollView(rowCount: apps.count) {
                appRows(for: host)
            }
            .frame(height: AppListMetrics.viewportHeight)
            .padding(.trailing, -AppListMetrics.scrollerWidth)
        } else {
            appRows(for: host)
        }
    }

    private func resetAppActions() {
        appRefreshTask?.cancel()
        appRefreshTask = nil
        refreshingApps = false
        appRefreshFailed = false
        copiedAgentPrompt = false
    }

    private func refreshApps(for host: Host) {
        guard !refreshingApps, !model.isStreaming else { return }
        refreshingApps = true
        appRefreshFailed = false
        appRefreshTask = Task { @MainActor in
            do {
                try await model.refreshApps(for: host)
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
                appRefreshFailed = true
            }
            refreshingApps = false
            appRefreshTask = nil
        }
    }

    private func copyAgentPrompt(for host: Host) {
        let prompt = HostAppTroubleshootingPrompt.text(
            hostName: host.displayName,
            address: model.selectedHostRouteAddress ?? model.dialAddress(for: host))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedAgentPrompt = pasteboard.setString(prompt, forType: .string)
    }

    private func appRows(for host: Host) -> some View {
        VStack(spacing: 0) {
            ForEach(apps) { app in
                VStack(spacing: 0) {
                    appRow(app, on: host)
                    if app.id != apps.last?.id {
                        Divider().frame(height: AppListMetrics.dividerHeight).padding(.leading, 43)
                    }
                }
            }
        }
    }

    private func appRow(_ app: LibraryApp, on host: Host) -> some View {
        let active = model.isStreaming && model.activeStreamHostID == host.id
            && model.activeStreamApp?.id == app.id
        let title = model.runningAppName == app.name ? "Resume" : "Stream"
        return HStack(spacing: 11) {
            Button { model.requestStream(app: app, on: host) } label: {
                HStack(spacing: 11) {
                    AppGlyphIcon(app: app, size: 22)
                        .font(.system(size: 22))
                        .frame(width: 27, height: 25)
                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isStreaming)
            .accessibilityLabel("\(title) \(app.name)")
            if active {
                if model.activeStreamHasVideo {
                    Button { model.resumeStreamWindow() } label: {
                        Image(systemName: "pip.exit")
                            .font(.system(size: 15)).foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(app.name) stream")
                    .accessibilityLabel("Show \(app.name) stream")
                }
                if case .connecting(let stage) = model.streamPhase {
                    ProgressView().controlSize(.small).frame(width: 12).help(stage)
                    Button { model.cancelConnect() } label: {
                        AppRowActionLabel(title: "Cancel")
                    }
                    .controlSize(.small)
                } else {
                    Button("End Stream") { model.endStream() }.controlSize(.small)
                        .disabled(model.streamPhase != .streaming)
                }
            } else {
                Button { model.requestStream(app: app, on: host) } label: {
                    AppRowActionLabel(title: title)
                }
                    .controlSize(.small)
                    .disabled(model.isStreaming)
                    .help("\(title) \(app.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: AppListMetrics.rowHeight)
        .opacity(model.isStreaming && !active ? 0.4 : 1)
    }

    private func latencySection(for host: Host) -> some View {
        let streaming = model.isStreaming && model.activeStreamHostID == host.id
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(alignment: .center, spacing: 5) {
                    Text("\(Text("Latency").font(.system(size: 13, weight: .medium)))\(Text(model.macConnectionLabel.map { " over \($0)" } ?? "").foregroundStyle(.secondary))")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize()
                    if model.macConnectionLabel != nil {
                        connectionIcon
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Latency over this Mac’s connection to the PC")
                Spacer(minLength: 0)
                if latencyTest.hasRun {
                    Text(latencyTest.latestDescription)
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                Button {
                    if latencyTest.isRunning { latencyTest.stop() }
                    else { startLatencyTest() }
                } label: {
                    ZStack(alignment: .trailing) {
                        Text("Test latency").hidden().accessibilityHidden(true)
                        Text(latencyTest.isRunning ? "Stop" : "Test latency")
                    }
                    .contentShape(Rectangle())
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(model.isStreaming && !streaming)
            }
            NetworkHistoryGraph(test: latencyTest, streaming: streaming)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var connectionIcon: some View {
        Group {
            if model.macConnectionIsEthernet {
                EthernetPortGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 12)
            } else if let symbol = model.macConnectionSymbol {
                Image(systemName: symbol).font(.system(size: 11))
            }
        }
        .help("This Mac’s connection to the PC: \(model.macConnectionDescription). This does not describe the PC’s network adapter.")
        .accessibilityLabel("This Mac’s connection: \(model.macConnectionDescription)")
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


}

enum HostAppTroubleshootingPrompt {
    static func text(hostName: String, address: String) -> String {
        ShimmerCLIAgentInstructions.text(hostName: hostName, address: address)
    }
}

private enum AppListMetrics {
    static let rowHeight: CGFloat = 39
    static let dividerHeight: CGFloat = 1
    static let viewportHeight = (rowHeight + dividerHeight) * 3
    static var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
    }

    static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * dividerHeight
    }
}

/// Keep the common row action in the same place as its label changes.
private struct AppRowActionLabel: View {
    let title: String

    var body: some View {
        ZStack {
            Text("Resume").hidden().accessibilityHidden(true)
            Text(title)
        }
        .fixedSize()
    }
}

/// A normal macOS scrollbar, visible whenever extra app rows exist.
/// Three-row lists use the regular SwiftUI stack without a scroll view.
private struct NativeAppListScrollView<Content: View>: NSViewRepresentable {
    let rowCount: Int
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState

    private var hostedContent: AnyView {
        AnyView(content().environment(\.colorScheme, colorScheme)
            .environment(\.controlActiveState, activeState))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        // The small native scrollbar sits in the surrounding content margin;
        // it does not take width from the app rows.
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller?.controlSize = .small
        scroll.verticalScrollElasticity = .none
        let document = NSHostingView(rootView: hostedContent)
        document.sizingOptions = []
        document.autoresizingMask = [.width]
        scroll.documentView = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSHostingView<AnyView> else { return }
        document.rootView = hostedContent
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                height: AppListMetrics.contentHeight(rows: rowCount))
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
    private let blue = Color(red: 0.27, green: 0.47, blue: 0.91)

    var body: some View {
        let now = test.sampledAt
        let scale = LatencyGraphScale(maximum: test.history.statistics(at: now)?.maximum)
        let start = max(now.addingTimeInterval(-HostLatencyHistory.duration),
                        min(now.addingTimeInterval(-10), test.history.readings.first?.capturedAt ?? now))
        Chart {
            ForEach(Array(test.history.segments(maxGap: 3.5).enumerated()), id: \.offset) { index, segment in
                ForEach(Array(segment.enumerated()), id: \.offset) { _, reading in
                    LineMark(x: .value("Time", reading.capturedAt),
                             y: .value("Milliseconds", reading.milliseconds),
                             series: .value("Segment", index))
                        .foregroundStyle(blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    PointMark(x: .value("Time", reading.capturedAt),
                              y: .value("Milliseconds", reading.milliseconds))
                        .symbol {
                            Circle()
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay(Circle().strokeBorder(blue, lineWidth: 1.2))
                                .frame(width: 4.5, height: 4.5)
                        }
                }
            }
        }
        .chartXScale(domain: start...now,
                     range: .plotDimension(startPadding: 3, endPadding: 3))
        .chartYScale(domain: 0...scale.upperBound,
                     range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: scale.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.28))
                AxisValueLabel(collisionResolution: .disabled, horizontalSpacing: 8) {
                    if let ms = value.as(Double.self) {
                        Text("\(ms.formatted(.number.precision(.fractionLength(0...1)))) ms")
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plot.clipped() }
        .frame(height: 74)
        .padding(12)
        .overlay {
            if test.hasRun && test.history.readings.isEmpty {
                Text(test.isRunning ? "Waiting for a response…" : "No measurements available")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.18), lineWidth: 1))
        .accessibilityLabel("Latency test history in milliseconds")
        .accessibilityValue(test.hasRun ? test.latestDescription : "No measurements yet")
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
            HostSystemGlyph(icon: HostIcon.suggested(for: pc.displayName))
                .foregroundStyle(.secondary)
                .frame(width: SettingsMetrics.sidebarIconSize, height: SettingsMetrics.sidebarIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(pc.displayName).font(.system(size: 13)).lineLimit(1)
                Text(pc.host).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
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
    let status: HostStatusIndicator
    let statusText: String

    var body: some View {
        HStack(spacing: 8) {
            HostIdentityIcon(host: host, status: status, statusText: statusText)
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
    let size: CGFloat
    let status: HostStatusIndicator?
    let statusText: String?
    @AppStorage private var preference: HostIcon

    init(host: Host, size: CGFloat = SettingsMetrics.sidebarIconSize,
         status: HostStatusIndicator? = nil, statusText: String? = nil) {
        self.host = host
        self.size = size
        self.status = status
        self.statusText = statusText
        _preference = AppStorage(wrappedValue: .automatic, HostIcon.storageKey(for: host.id))
    }

    var body: some View {
        let icon = preference.resolved(serverName: host.name)
        let rgb = icon.backgroundRGB
        let colour = Color(red: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255)
        Group {
            if icon == .bazzite {
                // The colour artwork includes its circular avatar background.
                Image("HostLogo-bazzite")
                    .renderingMode(.original)
                    .resizable().scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(icon == .computer ? Color.accentColor.opacity(0.22) : colour)
                    .frame(width: size, height: size)
                    .overlay {
                        HostSystemGlyph(icon: icon, size: size)
                            .foregroundStyle(icon == .computer ? Color.accentColor : icon == .linux ? .black : .white)
                    }
            }
        }
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    HostConnectionBadge(status: status, size: size >= 48 ? 14 : 12)
                        .help(statusText ?? "PC status")
                        .accessibilityHidden(true)
                }
            }
            .help(statusText.map { "\($0) · Right-click for PC options" }
                  ?? (icon == .computer ? "Server icon · Right-click to choose" : "\(icon.title) icon · Right-click to change"))
            .accessibilityLabel([icon == .computer ? "Server" : "\(icon.title) server icon", statusText].compactMap { $0 }.joined(separator: ", "))
    }
}

struct HostConnectionBadge: View {
    let status: HostStatusIndicator
    let size: CGFloat

    private var diameter: CGFloat {
        size - 4
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .attention, .offline: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }

    var body: some View {
        Circle().fill(color)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
    }
}

/// Shared OS/distro artwork for paired hosts and transient Bonjour rows.
/// The caller supplies the foreground style and surrounding presentation.
private struct HostSystemGlyph: View {
    let icon: HostIcon
    var size: CGFloat = SettingsMetrics.sidebarIconSize
    private var scale: CGFloat { size / SettingsMetrics.sidebarIconSize }

    var body: some View {
        if let asset = icon.assetName {
            Image(asset)
                .renderingMode(icon == .chimeraOS || icon == .bazzite ? .original : .template)
                .resizable().scaledToFit()
                .frame(width: 25 * scale, height: 25 * scale)
        } else {
            Image(systemName: icon == .macOS ? "apple.logo" : "desktopcomputer")
                .font(.system(size: (icon == .macOS ? 23 : 18) * scale))
                .frame(width: 25 * scale, height: 25 * scale)
        }
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
                .symbolRenderingMode(.monochrome)
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
