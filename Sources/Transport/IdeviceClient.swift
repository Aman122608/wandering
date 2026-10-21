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

    /// A wedged FFI call cannot be interrupted, so each connection gets its own
    /// queue: dropping the tunnel abandons the old queue and its stuck call instead
    /// of letting it block every future write.
    private var queue = DispatchQueue(label: "com.aman.wandering.iddevice.0", qos: .userInitiated)
    private var generation = 0
    private var device: OpaquePointer?
    private var connected = false
    private var mounted = false

    // MARK: - Connection

    func connect(endpoint: TunnelEndpoint, pairingFile: URL) async throws {
        if connected { return }
        generation += 1
        queue = DispatchQueue(label: "com.aman.wandering.iddevice.\(generation)",
                              qos: .userInitiated)
        let handle = try await onQueue(timeout: 25) { () -> OpaquePointer in
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

        // The first connect can add `alt_irk` to the pairing file in place. Write it
        // back, otherwise the next launch re-runs pair-setup and the device asks for
        // consent again.
        do {
            try await onQueue(timeout: 8) {
                var err = [CChar](repeating: 0, count: 512)
                let status = wd_persist_pairing_file(handle, pairingFile.path, &err, err.count)
                guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
            }
            DiagLog.shared.log("ffi: pairing file persisted")
        } catch {
            DiagLog.shared.log("ffi: could not persist pairing file — \(error.localizedDescription)")
        }

        DiagLog.shared.log("ffi: tunnel open to \(endpoint.address):\(endpoint.port)")
    }

    func prepareDeveloperServices() async throws -> DeveloperStatus {
        guard let device, connected else {
            throw SinkError.notConnected("tunnel not open")
        }

        let version: String = try await onQueue(timeout: 10) { () -> String in
            var out = [CChar](repeating: 0, count: 64)
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_product_version(device, &out, out.count, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
            return Self.string(out)
        }

        var enabled: Int32 = 0
        try await onQueue(timeout: 10) {
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
            let chipID: UInt64 = try await onQueue(timeout: 10) {
                var value: UInt64 = 0
                var err = [CChar](repeating: 0, count: 512)
                let status = wd_unique_chip_id(device, &value, &err, err.count)
                guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
                return value
            }
            DiagLog.shared.log("ffi: UniqueChipID \(chipID)")

            try await onQueue(timeout: 90) {
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
        do {
            try await write(device: device, latitude: latitude, longitude: longitude)
        } catch {
            if case SinkError.timedOut = error {
                connected = false
                mounted = false
            }
            throw error
        }
    }

    private func write(device: OpaquePointer, latitude: Double, longitude: Double) async throws {
        try await onQueue(timeout: 6) {
            var err = [CChar](repeating: 0, count: 512)
            let status = wd_set_location(device, latitude, longitude, &err, err.count)
            guard status == 0 else { throw SinkError.deviceRefused(Self.string(err)) }
        }
    }

    func clearLocation() async throws {
        guard let device, connected else { return }
        try await onQueue(timeout: 6) {
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

    /// Runs one blocking FFI call on the serial queue.
    ///
    /// `timeout` matters: the FFI wraps only TCP connect in a timeout, so a device
    /// that drops off mid-call blocks `set`/`clear`/mount forever. When the bound is
    /// hit the tunnel is marked dead — the abandoned call cannot be interrupted, but
    /// the session can be rebuilt around it.
    private func onQueue<T>(timeout: TimeInterval? = nil,
                            _ body: @escaping () throws -> T) async throws -> T {
        let work = { () async throws -> T in
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    do {
                        continuation.resume(returning: try body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        guard let timeout else { return try await work() }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SinkError.timedOut("device call exceeded \(Int(timeout))s")
            }
            guard let first = try await group.next() else {
                throw SinkError.internalFailure("no result from device call")
            }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func string(_ buffer: [CChar]) -> String {
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        return text.isEmpty ? "unknown error" : text
    }
}
