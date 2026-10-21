import CoreLocation
import Foundation

/// Location writes through lockdownd's `com.apple.dt.simulatelocation` service.
///
/// This is the pairing-free path: lockdownd answers plain requests over the tunnel and
/// starts the developer service on demand, so nothing here needs a pairing record, a
/// developer disk image, or the remote-pairing handshake that keeps getting reset.
/// Each command opens its own service connection, which is how the service expects to
/// be used — so there is no connection to keep alive between writes.
@MainActor
final class LockdownTransport {
    private let host = "10.7.0.1"
    private let port: UInt16 = 62078

    private(set) var isReady = false
    private(set) var servicePort: UInt16 = 0
    private(set) var status = "not started"

    /// Starts the service once to prove the path works, and reports what happened.
    func prepare() async -> String {
        let (ok, port, message) = await run { ip in
            var servicePort: UInt16 = 0
            var error = [CChar](repeating: 0, count: 256)
            let status = wd_lk_start_simulate(ip, 62078, &servicePort, nil, &error, 256)
            return (status == 0, servicePort, String(cString: error))
        }

        servicePort = port
        isReady = ok
        status = ok
            ? "service ready on port \(port)"
            : (message.isEmpty ? "lockdownd refused the service" : message)
        DiagLog.shared.log("lockdownd: \(status)")
        return status
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        if !isReady {
            let prepared = await prepare()
            guard prepared.hasPrefix("service ready") else {
                throw SinkError.deviceRefused(status)
            }
        }
        let (ok, port, message) = await run { ip in
            var servicePort: UInt16 = 0
            var error = [CChar](repeating: 0, count: 256)
            let status = wd_lk_set_location(ip, 62078, latitude, longitude,
                                            &servicePort, &error, 256)
            return (status == 0, servicePort, String(cString: error))
        }
        if port != 0 { servicePort = port }
        guard ok else {
            isReady = false
            status = message.isEmpty ? "location write refused" : message
            throw SinkError.deviceRefused(status)
        }
    }

    func clearLocation() async throws {
        let (ok, port, message) = await run { ip in
            var servicePort: UInt16 = 0
            var error = [CChar](repeating: 0, count: 256)
            let status = wd_lk_clear_location(ip, 62078, &servicePort, &error, 256)
            return (status == 0, servicePort, String(cString: error))
        }
        if port != 0 { servicePort = port }
        guard ok else {
            throw SinkError.deviceRefused(message.isEmpty ? "clear refused" : message)
        }
    }

    /// Runs a blocking C call off the main thread.
    private func run(_ work: @escaping (UnsafePointer<CChar>) -> (Bool, UInt16, String))
        async -> (Bool, UInt16, String) {
        await withCheckedContinuation { continuation in
            let host = self.host
            DispatchQueue.global(qos: .userInitiated).async {
                let result = host.withCString { work($0) }
                continuation.resume(returning: result)
            }
        }
    }
}
