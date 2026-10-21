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
///
/// The streaming hooks exist because the tunnel is only needed while coordinates are
/// actually being written: once the device has accepted a location it keeps it, so a
/// parked spoof needs no connection at all. A sink can use them to open the tunnel
/// for the duration of a movement and close it when the movement ends.
@MainActor
protocol LocationSink: AnyObject {
    var describe: String { get }
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
    func beginStreaming() async
    func endStreaming() async
}

extension LocationSink {
    func beginStreaming() async {}
    func endStreaming() async {}
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
