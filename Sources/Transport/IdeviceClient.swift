import Foundation

/// Thin async wrapper around the developer tunnel.
///
/// The implementation is generated against the idevice FFI (see
/// `Sources/Transport/IdeviceFFI.swift`). This file keeps the shape stable so the
/// rest of the app never sees C pointers or blocking calls.
actor IdeviceClient {
    static let shared = IdeviceClient()

    struct DeveloperStatus {
        var developerMode: Bool
        var diskImageMounted: Bool
    }

    private var isConnected = false

    func connect(endpoint: TunnelEndpoint, pairingFile: URL) async throws {
        // Implemented in IdeviceFFI.swift.
        try await FFIBackend.shared.connect(endpoint: endpoint, pairingFile: pairingFile)
        isConnected = true
    }

    func prepareDeveloperServices() async throws -> DeveloperStatus {
        guard isConnected else { throw SinkError.notConnected("call connect first") }
        return try await FFIBackend.shared.prepareDeveloperServices()
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        guard isConnected else { throw SinkError.notConnected("call connect first") }
        try await FFIBackend.shared.setLocation(latitude: latitude, longitude: longitude)
    }

    func clearLocation() async throws {
        guard isConnected else { return }
        try await FFIBackend.shared.clearLocation()
    }

    func disconnect() {
        guard isConnected else { return }
        isConnected = false
        FFIBackend.shared.disconnect()
    }
}

/// Placeholder until the FFI layer lands; every call fails with a clear message
/// instead of trapping, so the app is usable as a planner before it can inject.
final class FFIBackend {
    static let shared = FFIBackend()
    private init() {}

    func connect(endpoint: TunnelEndpoint, pairingFile: URL) async throws {
        throw SinkError.notConnected("developer transport not linked yet")
    }

    func prepareDeveloperServices() async throws -> IdeviceClient.DeveloperStatus {
        throw SinkError.notConnected("developer transport not linked yet")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        throw SinkError.notConnected("developer transport not linked yet")
    }

    func clearLocation() async throws {}

    func disconnect() {}
}
