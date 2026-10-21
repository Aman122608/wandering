import Foundation

/// Runs the device-initiated pairing that iOS 27 requires.
///
/// The iPhone pairs with a host it discovers on the local network: Settings →
/// Privacy & Security → Developer Mode → "Pair with Wandering". We advertise as that
/// host, iOS asks for a code, this app displays it, and the resulting record is the
/// only one the device will accept — an older record is answered with a reset, which
/// is what connection attempts have been dying on.
@MainActor
final class PairHostBroker: ObservableObject {
    static let shared = PairHostBroker()

    @Published private(set) var isPairing = false
    @Published private(set) var code: String?
    @Published private(set) var message: String?

    /// Called with the finished record; the session connects with it.
    var onPaired: ((PairingStore.Entry) -> Void)?

    private init() {}

    /// The C callback runs on a background thread with no way to touch SwiftUI.
    nonisolated static func show(pin: String) {
        Task { @MainActor in
            shared.code = pin
            shared.message = "Type this code on your iPhone"
            DiagLog.shared.note("pairing: setup code \(pin)")
        }
    }

    func start() {
        guard !isPairing else { return }
        isPairing = true
        code = nil
        message = "Waiting for your iPhone to connect…"
        DiagLog.shared.note("pairing: advertising as a pairable host")

        let destination = PairingStore.newPairingDestination()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [CChar](repeating: 0, count: 256)
            let status = destination.path.withCString { path in
                "Wandering".withCString { name in
                    wd_pair_host(name, path, &buffer, 256)
                }
            }
            let detail = String(cString: buffer)

            Task { @MainActor in
                shared.isPairing = false
                shared.code = nil
                if status == 0, let entry = PairingStore.adopt(destination) {
                    shared.message = "Paired with \(entry.name)"
                    DiagLog.shared.note("pairing: paired, record saved as \(entry.name)")
                    shared.onPaired?(entry)
                } else {
                    shared.message = detail.isEmpty ? "Pairing failed" : detail
                    DiagLog.shared.log("pairing: failed — \(shared.message ?? "")")
                }
            }
        }
    }

    func dismiss() {
        message = nil
        code = nil
    }
}

/// The display callback must have no captures.
private func wdPinDisplayTrampoline(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    PairHostBroker.show(pin: pin.map { String(cString: $0) } ?? "")
}

func installPairableHost() {
    wd_set_pin_display(wdPinDisplayTrampoline, nil)
}
