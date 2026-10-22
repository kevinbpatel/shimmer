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
            case .failed(let message): error = message
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
    let paired: (String) -> Void
    @State private var flow = PCPairingFlow()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(target.name).font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(target.address).font(.system(size: 12)).foregroundStyle(.secondary)
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
                    if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if flow.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(flow.isCancelling ? "Cancelling…" : "Waiting for your PC…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Cancel") { flow.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(flow.isCancelling)
                        Spacer()
                        if flow.error != nil {
                            Button("Try Again", action: begin)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.pairingInFlight)
                        }
                    }
                } else {
                    Text("Pair this PC to add it to your saved PCs and stream its apps.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Pair PC", action: begin)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pairingInFlight)
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task { if target.startImmediately { begin() } }
        .onDisappear { flow.reset() }
    }

    private func begin() {
        guard !model.pairingInFlight else { return }
        flow.start(pin: model.generatePairingPIN()) { pin in
            if let id = await model.pair(hostnameOrIP: target.address, pin: pin) {
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
            Text("Enter the IP address or hostname of the PC you want to stream from.")
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
