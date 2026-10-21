import Foundation
import Network

/// Knows whether the phone is on Wi-Fi, so the app can decide on its own whether the
/// cellular setup path is needed.
///
/// `path.usesInterfaceType(.wifi)` is the honest answer: "online" is not the same
/// question. A phone on cellular is online and still needs the Shortcut sequence,
/// which is exactly the case that used to require turning the toggle on by hand.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnWiFi = false
    @Published private(set) var isOnline = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.aman.wandering.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let onWiFi = path.usesInterfaceType(.wifi)
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.isOnWiFi != onWiFi {
                    DiagLog.shared.note("network: wi-fi \(onWiFi ? "connected" : "gone")")
                }
                self.isOnWiFi = onWiFi
                self.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
