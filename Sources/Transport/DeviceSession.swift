import CoreLocation
import Foundation

/// How long the developer tunnel stays open.
enum TunnelLifetime: String, CaseIterable, Identifiable {
    /// Open only while coordinates are being written, then close. The device keeps
    /// the simulated location, so a parked spoof costs nothing and the VPN indicator
    /// disappears instead of sitting in the status bar.
    case setupOnly
    /// Keep the tunnel for the whole session. Only needed if a device turns out to
    /// drop the fix once the connection goes away.
    case persistent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setupOnly: return "Close after setup"
        case .persistent: return "Keep open"
        }
    }
}

/// The device side of the app: tunnel, developer disk image, location service.
///
/// The lifetime rule is the important part: opening the tunnel is the expensive,
/// visible step, so it is opened for a movement and closed when the movement ends.
/// It is never cycled per write — the device holds the simulated location on its own
/// once it has accepted it.
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
            case .ready(let address): return "Connected · \(address)"
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
    @Published private(set) var isStreaming = false

    @Published var lifetime: TunnelLifetime =
        TunnelLifetime(rawValue: UserDefaults.standard.string(forKey: "tunnel.lifetime") ?? "")
        ?? .setupOnly {
        didSet {
            UserDefaults.standard.set(lifetime.rawValue, forKey: "tunnel.lifetime")
            if lifetime == .persistent { cancelIdleClose() }
            DiagLog.shared.note("tunnel: lifetime → \(lifetime.title)")
        }
    }

    /// The pairing file the transport will use (the selected one in PairingStore).
    var pairingFileURL: URL? { PairingStore.current }

    @Published private(set) var pairingEntries: [PairingStore.Entry] = []
    /// Why the last import did nothing — surfaced to the user instead of failing silently.
    @Published var importError: String?

    var describe: String { connection.label }

    private var idleClose: DispatchWorkItem?
    private var reconnectAttempts = 0

    // MARK: - Tunnel lifetime

    func beginStreaming() async {
        isStreaming = true
        cancelIdleClose()
        DiagLog.shared.note("tunnel: movement started — holding the tunnel open")
    }

    func endStreaming() async {
        isStreaming = false
        DiagLog.shared.note("tunnel: movement ended")
        if lifetime == .setupOnly { scheduleIdleClose() }
    }

    private func scheduleIdleClose(after delay: TimeInterval = 1.2) {
        cancelIdleClose()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStreaming else { return }
            self.closeTunnel()
        }
        idleClose = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelIdleClose() {
        idleClose?.cancel()
        idleClose = nil
    }

    /// Closes the tunnel. The spoof stays in place on the device — there is simply
    /// nothing left to talk to until the next coordinate changes.
    func closeTunnel() {
        guard connection.isReady else { return }
        cancelIdleClose()
        Transport.shared.shutDown()
        connection = .idle
        DiagLog.shared.note("tunnel: closed (simulated location stays)")
    }

    // MARK: - Lifecycle

    func connect() async {
        guard !connection.isReady else { return }
        connection = .preparing("Looking for the developer tunnel…")
        DiagLog.shared.note("connect: begin")
        do {
            try await Transport.shared.bringUp(session: self)
            connection = .ready(address: Transport.shared.dialedAddress ?? "tunnel")
            reconnectAttempts = 0
            DiagLog.shared.note("connect: ready at \(Transport.shared.dialedAddress ?? "?")")
        } catch {
            connection = .failed(error.localizedDescription)
            DiagLog.shared.note("connect: failed — \(error.localizedDescription)")
        }
    }

    func disconnect() {
        cancelIdleClose()
        isStreaming = false
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
            if lifetime == .setupOnly, !isStreaming { scheduleIdleClose() }
        } catch {
            connection = .failed(error.localizedDescription)
            if lifetime == .setupOnly {
                // A failed write may be a torn-down tunnel: drop it so the next
                // attempt rebuilds instead of reusing a dead handle.
                Transport.shared.shutDown()
                connection = .idle
            }
            throw error
        }
    }

    func clearLocation() async throws {
        if !connection.isReady {
            await connect()
            guard connection.isReady else {
                throw SinkError.notConnected(connection.label)
            }
        }
        try await Transport.shared.clearLocation()
        writeCount = 0
        lastWrite = nil
        scheduleIdleClose(after: 0.6)
    }

    /// One burst: open, write, close. Used when the supervisor detects the fix has
    /// been overridden — not as a heartbeat, so it cannot become reconnect churn.
    @discardableResult
    func reassert(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        guard reconnectAttempts < 3 else { return false }
        reconnectAttempts += 1
        DiagLog.shared.note("tunnel: re-assert burst \(reconnectAttempts)")
        if !connection.isReady { await connect() }
        guard connection.isReady else { return false }
        do {
            try await Transport.shared.setLocation(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude)
            lastWrite = Date()
            writeCount += 1
            if lifetime == .setupOnly { scheduleIdleClose() }
            return true
        } catch {
            DiagLog.shared.log("re-assert failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Status

    func update(developerMode: Bool, diskImageMounted: Bool) {
        self.developerModeEnabled = developerMode
        self.diskImageMounted = diskImageMounted
    }

    // MARK: - Pairing

    func refreshPairings() {
        _ = PairingStore.adoptLooseFiles()
        pairingEntries = PairingStore.all()
    }

    func importPairingFiles(_ urls: [URL]) {
        DiagLog.shared.note("pairing: \(urls.count) file(s) chosen")
        var imported: [PairingStore.Entry] = []
        var failures: [String] = []

        for url in urls {
            do {
                imported.append(try PairingStore.importFile(url))
            } catch {
                let reason = "\(url.lastPathComponent): \(error.localizedDescription)"
                failures.append(reason)
                DiagLog.shared.log("pairing: import failed — \(reason)")
            }
        }

        pairingEntries = PairingStore.all()
        if let first = imported.first {
            DiagLog.shared.note("pairing: \(imported.count) imported, using \(first.name) "
                                + "· \(pairingEntries.count) available")
            importError = nil
        } else if !failures.isEmpty {
            importError = failures.joined(separator: " · ")
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
