import Foundation

/// Async wrapper over the C shim.
///
/// Every shim call blocks on a socket round-trip to the device, so they all run
/// on one dedicated serial queue. Serial is not a style choice: the developer
/// service refuses a second write while one is outstanding, and the Rust layer's
/// handles are not thread safe.
actor IdeviceClient {
    static let shared = IdeviceClient()

    struct DeveloperStatus {
        var developerMode: Bool
        var diskImageMounted: Bool
        var productVersion: String
    }

    private let queue = DispatchQueue(label: "com.aman.wandering.iddevice", qos: .userInitiated)
    private var device: OpaquePointer?
    private var connected = false
    private var mounted = false

    // MARK: - Connection

    func connect(endpoint: TunnelEndpoint, pairingFile: URL) async throws {
        if connected { return }
        let handle = try await onQueue { () -> OpaquePointer in
            guard let handle = wd_create() else {
                throw SinkError.internalFailure("could not allocate device handle")
            }
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_connect(handle, endpoint.address, endpoint.port,
                                    pairingFile.path, &err, err.count)
            guard status == 0 else {
                wd_free(handle)
                throw SinkError.deviceRefused(Self.string(err))
            }
            return handle
        }
        device = handle
        connected = true
        DiagLog.shared.log("ffi: tunnel open to \(endpoint.address):\(endpoint.port)")
    }

    func prepareDeveloperServices() async throws -> DeveloperStatus {
        guard let device, connected else {
            throw SinkError.notConnected("tunnel not open")
        }

        let version: String = try await onQueue { () -> String in
            var out = [CChar](repeating: 0, count: 64)
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_product_version(device, &out, out.count, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
            return Self.string(out)
        }

        var enabled: Int32 = 0
        try await onQueue {
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_developer_mode(device, &enabled, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
        }
        DiagLog.shared.log("ffi: developer mode \(enabled == 1 ? "on" : "off") · iOS \(version)")

        guard enabled == 1 else {
            throw SinkError.notConnected("Developer Mode is off — enable it in Settings → Privacy & Security")
        }

        if !mounted {
            DiagLog.shared.log("ffi: mounting personalised disk image")
            let assets = try await DeveloperDiskImage.assets(for: version) { name, fraction in
                DiagLog.shared.log("ddi: \(name) \(Int(fraction * 100))%")
            }
            let chipID: UInt64 = try await onQueue {
                var value: UInt64 = 0
                var err = [CChar](repeating: 0, count: 512)
                let status = wd_unique_chip_id(device, &value, &err, err.count)
                guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
                return value
            }
            DiagLog.shared.log("ffi: UniqueChipID \(chipID)")

            try await onQueue {
                var err = [CChar](repeating: 0, count: 512)
                let status = assets.image.withUnsafeBytes { imageBuffer in
                    assets.trustCache.withUnsafeBytes { trustBuffer in
                        assets.manifest.withUnsafeBytes { manifestBuffer in
                            wd_mount_personalized(
                                device,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageBuffer.count,
                                trustBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustBuffer.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestBuffer.count,
                                chipID, &err, err.count
                            )
                        }
                    }
                }
                guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
            }
            mounted = true
            DiagLog.shared.log("ffi: disk image mounted")
        }

        return DeveloperStatus(developerMode: enabled == 1,
                               diskImageMounted: mounted,
                               productVersion: version)
    }

    // MARK: - Location

    func setLocation(latitude: Double, longitude: Double) async throws {
        guard let device, connected else { throw SinkError.notConnected("tunnel not open") }
        try await onQueue {
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_set_location(device, latitude, longitude, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
        }
    }

    func clearLocation() async throws {
        guard let device, connected else { return }
        try await onQueue {
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_clear_location(device, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
        }
    }

    func disconnect() {
        guard let device else { return }
        queue.async { wd_disconnect(device) }
        self.device = nil
        connected = false
        mounted = false
    }

    // MARK: - Plumbing

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func string(_ buffer: [CChar]) -> String {
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        return text.isEmpty ? "unknown error" : text
    }
}
