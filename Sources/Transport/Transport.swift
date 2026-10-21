import CoreLocation
import Foundation

/// Coordinates the device side: find the tunnel, hand the pairing file and the
/// endpoint to the developer client, and expose a tiny set/clear surface.
///
/// Everything is serialised through `IdeviceClient` (an actor). The developer call
/// itself has no timeout, so every public entry point here is bounded.
@MainActor
final class Transport {
    static let shared = Transport()

    private(set) var dialedAddress: String?
    private(set) var endpoint: TunnelEndpoint?
    private var connected = false

    private init() {}

    func bringUp(session: DeviceSession) async throws {
        if connected { return }

        guard let pairing = PairingStore.current else {
            throw SinkError.notConnected("no pairing file imported")
        }

        guard let endpoint = TunnelProbe.discover() else {
            throw SinkError.notConnected(
                "no tunnel on port \(TunnelProbe.developerPort) — is LocalDevVPN connected?"
            )
        }
        self.endpoint = endpoint
        dialedAddress = "\(endpoint.address):\(endpoint.port)"

        try await IdeviceClient.shared.connect(endpoint: endpoint, pairingFile: pairing)

        let status = try await IdeviceClient.shared.prepareDeveloperServices()
        session.developerModeEnabled = status.developerMode
        session.diskImageMounted = status.diskImageMounted
        connected = true
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        guard connected else { throw SinkError.notConnected("tunnel closed") }
        try await IdeviceClient.shared.setLocation(latitude: latitude, longitude: longitude)
    }

    func clearLocation() async throws {
        guard connected else { return }
        try await IdeviceClient.shared.clearLocation()
    }

    func shutDown() {
        connected = false
        dialedAddress = nil
        endpoint = nil
        Task { await IdeviceClient.shared.disconnect() }
    }
}
