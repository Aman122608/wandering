import Foundation

/// Carries the pairing code from the UI to the handshake.
///
/// The handshake runs on the blocking FFI thread and stops inside a C callback asking
/// for the six digits shown on the device. That thread cannot touch SwiftUI, so the
/// callback only flips a flag here; this object publishes it, the UI collects the code,
/// and `wd_submit_pin` wakes the blocked thread.
@MainActor
final class PinBroker: ObservableObject {
    static let shared = PinBroker()

    @Published var isWaiting = false

    private init() {}

    /// rppairing pair-setup uses a fixed code (000000) rather than one the device
    /// displays, so answering automatically is correct and avoids blocking the
    /// handshake for three minutes behind a sheet nobody needs to fill in.
    nonisolated static func request() {
        DiagLog.shared.log("pairing: pair-setup asked for the code — answering 000000")
        "000000".withCString { _ = wd_submit_pin($0) }
    }

    func submit(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trimmed.withCString { _ = wd_submit_pin($0) }
        isWaiting = false
        DiagLog.shared.note("pairing: code submitted (\(trimmed.count) digits)")
    }

    func cancel() {
        wd_cancel_pin()
        isWaiting = false
        DiagLog.shared.log("pairing: code prompt cancelled")
    }
}

/// The C callback must be a plain function with no captures.
private func wdPinRequestTrampoline(_ context: UnsafeMutableRawPointer?) {
    PinBroker.request()
}

/// Installs the callback once, at launch, before any connect attempt.
func installPinProvider() {
    wd_set_pin_provider(wdPinRequestTrampoline, nil)
}
