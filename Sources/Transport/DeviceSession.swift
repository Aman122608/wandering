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

    /// The pairing file the transport will use (the selected one in PairingStore).
    var pairingFileURL: URL? { PairingStore.current }

    /// How long the tunnel stays up around a write.
    ///
    /// `persistent` keeps it open for the whole session (most reliable).
    /// `burst` opens it for a moment around each write and closes it again, so the
    /// VPN indicator only flashes instead of sitting in the status bar. Whether the
    /// device keeps the simulated fix between bursts is device- and iOS-dependent —
    /// the supervisor watches for a snap-back and switches back to persistent if it
    /// catches one, so burst can never leave you silently un-spoofed.
    @Published var burstTunnel: Bool =
        UserDefaults.standard.bool(forKey: "tunnel.burst") {
        didSet {
            UserDefaults.standard.set(burstTunnel, forKey: "tunnel.burst")
            if !burstTunnel { cancelBurstClose() }
            DiagLog.shared.note("tunnel: lifetime set to \(burstTunnel ? "burst" : "persistent")")
        }
    }

    private var burstCloseWorkItem: DispatchWorkItem?

    private func scheduleBurstClose() {
        cancelBurstClose()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.burstTunnel else { return }
            DiagLog.shared.note("tunnel: closing (burst window elapsed)")
            self.disconnect()
        }
        burstCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func cancelBurstClose() {
        burstCloseWorkItem?.cancel()
        burstCloseWorkItem = nil
    }

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
        cancelBurstClose()
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
            if burstTunnel { scheduleBurstClose() }
        } catch {
            connection = .failed(error.localizedDescription)
            if burstTunnel {
                // A failed burst may just be a torn-down tunnel; drop the handle so
                // the next write rebuilds cleanly instead of reusing a dead one.
                Transport.shared.shutDown()
                connection = .idle
            }
            throw error
        }
    }

    func clearLocation() async throws {
        try await Transport.shared.clearLocation()
        writeCount = 0
        lastWrite = nil
    }

    // MARK: - Status

    func update(developerMode: Bool, diskImageMounted: Bool) {
        self.developerModeEnabled = developerMode
        self.diskImageMounted = diskImageMounted
    }

    // MARK: - Pairing

    @Published private(set) var pairingEntries: [PairingStore.Entry] = []

    func refreshPairings() {
        _ = PairingStore.adoptLooseFiles()
        pairingEntries = PairingStore.all()
    }

    func importPairingFiles(_ urls: [URL]) {
        let imported = PairingStore.importFiles(urls)
        pairingEntries = PairingStore.all()
        if let first = imported.first {
            DiagLog.shared.note("pairing: \(imported.count) file(s) imported, using \(first.name)")
        }
    }

    func selectPairing(_ entry: PairingStore.Entry) {
        PairingStore.setActive(entry)
        pairingEntries = PairingStore.all()
        DiagLog.shared.note("pairing: selected \(entry.name)")
    }

    func removePairing(_ entry: PairingStore.Entry) {
        PairingStore.remove(entry)
        pairingEntries = PairingStore.all()
    }
}
