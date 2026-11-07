// Inline PC pairing and the address-entry popover used by the Servers tab.
import Foundation
import SwiftUI
import Observation

struct PCPairingTarget: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    var startImmediately = false
}

/// Owns one attempt. A cancelled or replaced attempt cannot select a saved
/// PC later, even if its network operation completes after cancellation.
@MainActor @Observable
final class PCPairingFlow {
    enum Result { case paired(String), failed(String) }
    private(set) var pin: String?
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func start(pin: String, pair: @escaping @MainActor (String) async -> Result,
               completed: @escaping @MainActor (String) -> Void) {
        guard !isRunning else { return }
        generation += 1
        let run = generation
        self.pin = pin
        error = nil
        isRunning = true
        isCancelling = false
        task = Task { [weak self] in
            let result = await pair(pin)
            guard let self, generation == run else { return }
            isRunning = false
            isCancelling = false
            task = nil
            guard !Task.isCancelled else {
                self.pin = nil
                error = nil
                return
            }
            switch result {
            case .paired(let id): completed(id)
            case .failed(let message):
                self.pin = nil
                error = message
            }
        }
    }

    func cancel() {
        guard isRunning else { reset(); return }
        isCancelling = true
        task?.cancel()
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        pin = nil
        error = nil
        isRunning = false
        isCancelling = false
    }
}

struct PCPairingPane: View {
    @Environment(AppModel.self) private var model
    let target: PCPairingTarget
    let failed: ((String, String) -> Void)?
    let paired: (String) -> Void
    @State private var flow = PCPairingFlow()
    @State private var address: String

    init(target: PCPairingTarget, failed: ((String, String) -> Void)? = nil,
         paired: @escaping (String) -> Void) {
        self.target = target
        self.failed = failed
        self.paired = paired
        _address = State(initialValue: target.address)
    }

    var body: some View {
        Group {
            if let error = flow.error {
                recoveryForm(error: error)
            } else {
                pairingBody
            }
        }
        .task { if target.startImmediately { begin() } }
        .onChange(of: flow.error) { _, error in
            if let error { failed?(address, error) }
        }
        .onDisappear { flow.reset() }
    }

    private var pairingBody: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, 4)
                        Text(address == target.address ? target.name : address)
                            .font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(address).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let pin = flow.pin {
                        Text("Enter this code in the pairing prompt on your PC.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pin)
                            .id(pin)
                            .font(.system(size: 34, weight: .medium, design: .monospaced))
                            .tracking(8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        if flow.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(flow.isCancelling ? "Cancelling…" : "Waiting for your PC…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel") { flow.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(flow.isCancelling)
                    } else {
                        VStack(spacing: 16) {
                            Text("Pair with this PC to stream its apps to your Mac.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Pair PC", action: begin)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.pairingInFlight)
                        }
                    }
                }
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func recoveryForm(error: String) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        Text(target.name)
                            .font(.system(size: 18, weight: .semibold))
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        PCConnectionErrorBanner(message: error)
                        HStack(spacing: 10) {
                            TextField("IP address or hostname", text: $address)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .disableAutocorrection(true)
                                .accessibilityLabel("PC IP address or hostname")
                                .onSubmit(begin)
                            Button("Try Again", action: begin)
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.roundedRectangle(radius: 5))
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.pairingInFlight || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: 400)
                .padding(.horizontal, 28)
                .padding(.top, 68)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func begin() {
        guard !model.pairingInFlight else { return }
        let pairingAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairingAddress.isEmpty else { return }
        address = pairingAddress
        flow.start(pin: model.generatePairingPIN()) { pin in
            if let id = await model.pair(hostnameOrIP: pairingAddress, pin: pin) {
                if model.hosts.contains(where: { $0.id == id }) { return .paired(id) }
                return .failed("Pairing finished, but this PC couldn't be added. Try again.")
            }
            return .failed(model.pairingMessage ?? "Couldn't pair this PC. Try again.")
        } completed: { id in paired(id) }
    }
}

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
            Text("Add PC by Address")
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
            Text("Enter the PC’s IP address or hostname.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.10 or pc.local", text: $address)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .focused($addressFocused)
                .onSubmit(submit)
                .accessibilityLabel("PC IP address or hostname")
            HStack(spacing: 24) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button(action: submit) {
                    Text("Pair PC…").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedAddress.isEmpty)
                .frame(maxWidth: .infinity)
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
