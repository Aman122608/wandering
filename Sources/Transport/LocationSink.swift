import Foundation

enum SinkError: LocalizedError {
    case notConnected(String)
    case timedOut(String)
    case deviceRefused(String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let d): return "Not connected: \(d)"
        case .timedOut(let d): return "Timed out: \(d)"
        case .deviceRefused(let d): return "Device refused: \(d)"
        case .internalFailure(let d): return "Internal error: \(d)"
        }
    }
}

/// Anything that can move the device's reported location.
/// The player only knows this protocol, so the transport can be swapped
/// (developer tunnel today, something else later) without touching the engine.
@MainActor
protocol LocationSink: AnyObject {
    var describe: String { get }
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
}

/// Records writes without a device. Used by the engine tests and the preview.
@MainActor
final class DryRunSink: LocationSink {
    private(set) var writes: [(Double, Double)] = []
    var describe: String { "dry-run" }

    func setLocation(latitude: Double, longitude: Double) async throws {
        writes.append((latitude, longitude))
    }

    func clearLocation() async throws {
        writes.removeAll()
    }
}
