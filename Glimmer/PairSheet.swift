//
//  PairSheet.swift
//
//  The "Pair a new PC" flow. Extracted from SettingsView (which was at its
//  file-length limit) and given a discover-first UX: the sheet opens to a live
//  mDNS list of PCs on the network (the Discovery actor, previously unwired),
//  the user picks one, and pairing then
//  auto-starts so the displayed PIN is immediately enterable on the host.
//
//  Also hosts PINTiles + FloatingWindowLevel, both used only here.
//

import AppKit
import Network
import SwiftUI

struct PairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hostnameOrIP: String
    @State private var pin: String = ""
    /// nil = still choosing a host; non-nil = a host was picked/entered and we
    /// move to the PIN/handshake step.
    @State private var chosen: Bool

    /// Latched when a handshake THIS sheet started reports success.
    ///
    /// Deliberately not read straight off `model.pairingPhase`: that phase is
    /// app-wide state that outlives the sheet, and a body gated on it meant that
    /// after one successful pairing every later open of the sheet short-
    /// circuited to the "Paired" screen - with an empty host name, and no route
    /// back to the chooser short of relaunching the app. A local latch starts
    /// false on every presentation, so a stale phase can no longer speak for a
    /// sheet that has paired nothing. It is only ever set with a non-empty host
    /// name in hand, which is what keeps `successBody` from rendering "  is
    /// ready to stream."
    @State private var paired = false

    /// Optional pre-fill, used by the "re-pair" recovery path so the user
    /// doesn't retype the host's address - that path jumps straight to the PIN
    /// step. The normal "Pair a new PC" entry starts on the discovery chooser.
    init(initialAddress: String = "") {
        _hostnameOrIP = State(initialValue: initialAddress)
        _chosen = State(initialValue: !initialAddress.isEmpty)
    }

    /// The host we're pairing with, whitespace-trimmed. Empty means the user
    /// hasn't picked or typed one yet.
    private var trimmedHost: String {
        hostnameOrIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(titleText)
                .font(.title2.bold())
                .contentTransition(.opacity)

            if paired {
                successBody
            } else if !chosen {
                HostChooser(selected: { addr in
                    hostnameOrIP = addr
                    chosen = true
                })
            } else {
                pinBody
            }

            footer
        }
        .padding(28)
        .frame(width: 480)
        // Float above all other Glimmer windows so the PIN being read off isn't
        // hidden behind the launcher or Settings. Reverts on dismiss.
        .background(FloatingWindowLevel())
        // Success is taken as a TRANSITION seen while this sheet is on screen
        // and has a host in hand - never as a standing value, which is how a
        // previous pairing's result used to leak into a fresh sheet.
        .onChange(of: model.pairingPhase) { _, phase in
            guard case .success = phase, chosen, !trimmedHost.isEmpty else { return }
            paired = true
        }
        .onDisappear {
            // The phase is per-attempt state. Leaving it latched at
            // .success/.failure carried the last attempt's banner - and its
            // success screen - into the next open of the sheet. `pair()` clears
            // it at the start of an attempt too; this covers the dismissals
            // where no new attempt ever follows.
            model.pairingPhase = .idle
        }
    }

    private var titleText: String {
        if paired { return "Paired" }
        return chosen ? "Pair a new PC" : "Choose a PC"
    }

    @ViewBuilder private var successBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: paired)
            Text("\(trimmedHost) is ready to stream.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .sensoryFeedback(.success, trigger: paired)
        // Auto-close after a brief beat so the check + haptic register; select
        // the freshly-paired host so the launcher lands on it.
        .task(id: paired) {
            guard paired else { return }
            // No auto-dismiss: the success screen shows Done / "Stream now" buttons,
            // and a 900ms auto-close made them unclickable. The user dismisses it.
            selectPairedHost()
        }
    }

    @ViewBuilder private var pinBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On \(hostnameOrIP), enter this code")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            PINTiles(pin: pin)
                .onAppear {
                    if pin.isEmpty { pin = model.generatePairingPIN() }
                    // Showing the code IS the start of pairing - the handshake
                    // must be open on the host for the typed PIN to land.
                    startPairing()
                }
            Text("Open your PC's pairing page and type these four digits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let msg = model.pairingMessage, !paired {
            HStack(spacing: 8) {
                if model.pairingInFlight {
                    ProgressView().controlSize(.small)
                } else if msg.lowercased().contains("fail")
                            || msg.lowercased().contains("couldn't")
                            || msg.lowercased().contains("invalid") {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                }
                Text(msg).font(.callout)
                Spacer()
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if paired {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stream now") {
                    selectPairedHost()
                    model.streamDefaultApp()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(StreamButtonStyle())
            } else if !chosen {
                Spacer()
                Button("Cancel") { dismiss() }
            } else {
                Spacer()
                Button("Back") {
                    chosen = false
                    pin = ""
                }
                Button("Cancel") { dismiss() }
                // Manual retry - pairing normally auto-starts with the code.
                Button("Retry") { startPairing() }
                    .buttonStyle(StreamButtonStyle())
                    .disabled(model.pairingInFlight)
            }
        }
    }

    private func startPairing() {
        guard !model.pairingInFlight, !paired, !trimmedHost.isEmpty else { return }
        if pin.count != 4 { pin = model.generatePairingPIN() }
        Task { await model.pair(hostnameOrIP: hostnameOrIP, pin: pin) }
    }

    private func selectPairedHost() {
        let typed = trimmedHost
        if let host = model.hosts.first(where: {
            [$0.name, $0.displayName, $0.localAddress, $0.manualAddress]
                .compactMap { $0 }
                .contains { $0.caseInsensitiveCompare(typed) == .orderedSame }
        }) {
            model.selectHost(host)
        }
    }
}

// MARK: - Discover-first host chooser

/// Live mDNS list of PCs. Manual addresses are entered from the separate
/// dropdown beside Add PC in the Servers sidebar.
private struct HostChooser: View {
    let selected: (String) -> Void
    @State private var found: [HostDiscovery.Discovered] = []
    /// Stop showing an indefinite spinner on Bonjour-hostile networks.
    @State private var discoveryStalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Up-front explanation for macOS's Local Network prompt, in the same
            // spirit as the raw-HID one on the launcher: the `.task` below
            // starts mDNS the moment this view renders, so the system dialog can
            // land within a second of the sheet opening. Rendered FIRST, in the
            // same body pass that arms discovery, so the reason is already on
            // screen when the prompt arrives - not somewhere behind it.
            Text("Shimmer looks for PCs running Sunshine on your local network; "
                + "macOS will ask to allow that.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if found.isEmpty && !discoveryStalled {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for PCs on your network…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            if found.isEmpty && discoveryStalled {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("No PCs found yet. To enter an address, cancel and use the arrow beside Add PC.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            if !found.isEmpty {
                VStack(spacing: 8) {
                    ForEach(found) { host in
                        Button {
                            selected(host.host)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.displayName).fontWeight(.medium)
                                    Text(host.host).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            // Stream discovered hosts until the view goes away. HostDiscovery
            // is an actor; start() is actor-isolated so we await it, then
            // consume the AsyncStream it returns.
            let stream = await HostDiscovery.shared.start()
            for await hosts in stream {
                found = hosts
            }
            await HostDiscovery.shared.stop()
        }
        // Explain how to use the separate address entry if discovery stalls.
        .task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled, found.isEmpty {
                discoveryStalled = true
            }
        }
    }
}

// MARK: - Manual address popover

struct ManualAddressPopover: View {
    let cancel: () -> Void
    let add: (String) -> Void
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    init(initialAddress: String = "", cancel: @escaping () -> Void,
         add: @escaping (String) -> Void) {
        self.cancel = cancel
        self.add = add
        _address = State(initialValue: initialAddress)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add PC Using an Address")
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
            Text("Enter the IP address or hostname of the PC you want to stream from.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.10 or pc.local", text: $address)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .focused($addressFocused)
                .onSubmit(submit)
                .accessibilityLabel("PC IP address or hostname")
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) {
                    Text("Add PC…").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedAddress.isEmpty)
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 360)
        .onAppear { addressFocused = true }
    }

    private func submit() {
        guard !trimmedAddress.isEmpty else { return }
        add(trimmedAddress)
    }
}

// MARK: - Window level

/// Raises its hosting NSWindow to `.floating` while present so the pairing
/// sheet stays above the launcher + Settings windows.
private struct FloatingWindowLevel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = .floating }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.level = .floating }
    }
}

// MARK: - PIN tiles

/// Display-only tiles showing the four-digit PIN the user types on the HOST.
/// Static labels, not input fields - the digits are generated by Glimmer and
/// read off by the user, not typed here.
private struct PINTiles: View {
    let pin: String
    var body: some View {
        let digits = pin.padding(toLength: 4, withPad: " ", startingAt: 0)
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(digits.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch).trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .glassEffect(
                            .regular.tint(Color.accentColor.opacity(0.12)),
                            in: .rect(cornerRadius: 14)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code")
        .accessibilityValue(pin.map(String.init).joined(separator: " "))
    }
}
