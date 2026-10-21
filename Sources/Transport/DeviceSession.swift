import CoreLocation
import Foundation

/// The device side of the app: tunnel, developer disk image, location service.
///
/// This class is deliberately small and serialised. Everything that can block is
/// bounded, because the underlying developer call has no timeout of its own and a
/// wedged call would freeze the whole session.
@MainActor
final class DeviceSession: ObservableObject, LocationSink {

    enum Connection: Equatable {
        case idle
        case preparing(String)
        case ready(address: String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .preparing(let what): return what
            case .ready(let address): return "Ready · \(address)"
            case .failed(let why): return "Failed · \(why)"
            }
        }

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var developerModeEnabled = false
    @Published private(set) var diskImageMounted = false
    @Published private(set) var lastWrite: Date?
    @Published private(set) var writeCount = 0

    /// Set by the transport once a pairing file has been imported.
    @Published var pairingFileURL: URL?

    var describe: String { connection.label }

    // MARK: - Lifecycle

    func connect() async {
        guard !connection.isReady else { return }
        connection = .preparing("Looking for the developer tunnel…")
        DiagLog.shared.note("connect: begin")
        do {
            try await Transport.shared.bringUp(session: self)
            connection = .ready(address: Transport.shared.dialedAddress ?? "tunnel")
            DiagLog.shared.note("connect: ready at \(Transport.shared.dialedAddress ?? "?")")
        } catch {
            connection = .failed(error.localizedDescription)
            DiagLog.shared.note("connect: failed — \(error.localizedDescription)")
        }
    }

    func disconnect() {
        Transport.shared.shutDown()
        connection = .idle
        developerModeEnabled = false
        diskImageMounted = false
        DiagLog.shared.note("connect: closed")
    }

    // MARK: - LocationSink

    func setLocation(latitude: Double, longitude: Double) async throws {
        if !connection.isReady {
            await connect()
            guard connection.isReady else {
                throw SinkError.notConnected(connection.label)
            }
        }
        do {
            try await Transport.shared.setLocation(latitude: latitude, longitude: longitude)
            writeCount += 1
            lastWrite = Date()
        } catch {
            connection = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearLocation() async throws {
        try await Transport.shared.clearLocation()
        writeCount = 0
        lastWrite = nil
    }

    // MARK: - Pairing

    func importPairingFile(_ url: URL) {
        do {
            let stored = try PairingStore.importFile(url)
            pairingFileURL = stored
            DiagLog.shared.note("pairing file imported: \(stored.lastPathComponent)")
        } catch {
            DiagLog.shared.note("pairing import failed: \(error.localizedDescription)")
        }
    }
}

/// Keeps the RemotePairing plist in Application Support, where the transport expects it.
enum PairingStore {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    static var current: URL? {
        guard let dir = directory else { return nil }
        let url = dir.appendingPathComponent("rp_pairing_file.plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func importFile(_ source: URL) throws -> URL {
        guard let dir = directory else {
            throw SinkError.internalFailure("no application support directory")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("rp_pairing_file.plist")

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
