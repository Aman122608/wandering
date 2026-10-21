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
    init() {
        installPinProvider()
        installPairableHost()
    }


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

    /// Default is now persistent: on this device the simulated location lives inside the
    /// developer session, so closing the tunnel reverts it. "Close after setup" is kept
    /// as an option for experiments, not as the default it used to be.
    @Published var lifetime: TunnelLifetime =
        TunnelLifetime(rawValue: UserDefaults.standard.string(forKey: "tunnel.lifetime.v2") ?? "")
        ?? .persistent {
        didSet {
            UserDefaults.standard.set(lifetime.rawValue, forKey: "tunnel.lifetime.v2")
            if lifetime == .persistent { cancelIdleClose() }
            DiagLog.shared.note("tunnel: lifetime → \(lifetime.title)")
        }
    }

    /// The pairing file the transport will use (the selected one in PairingStore).
    var pairingFileURL: URL? { PairingStore.current }

    @Published private(set) var pairingEntries: [PairingStore.Entry] = []
    /// Why the last import did nothing — surfaced to the user instead of failing silently.
    @Published var importError: String?
    /// What the phone's own CoreLocation said after the last write.
    @Published private(set) var lastVerification: Verification?
    /// Second backend: lockdownd's developer service needs no pairing at all.
    let lockdown = LockdownTransport()
    /// One measured answer about whether a write actually moved the device.
    struct Verification: Equatable {
        let offsetMeters: Double
        let checkedAt: Date
        var tookEffect: Bool { offsetMeters < 60 }
    }

    /// Supplies the phone's own CoreLocation fix, so a write can be confirmed
    /// rather than merely reported as accepted.
    var fixProbe: (() -> (CLLocationCoordinate2D?, Date?))?
    /// True once a write path has been chosen: the pairing tunnel or lockdownd.
    @Published private(set) var useLockdown = false

    /// One connect at a time. The supervisor, the player's retry and the UI all ask for a
    /// connection, and each one used to launch its own six-second probe sweep — that pile-up
    /// is what made the app crawl.
    private var holdTask: Task<Void, Never>?
    private var holdCoordinate: CLLocationCoordinate2D?
    private var connectInFlight = false
    private var lastConnectFailure: Date?

    /// Set by the probe: true when the device kept the socket open, waiting for us.
    private var lastProbeWaitedForUs = false

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
        if connectInFlight {
            DiagLog.shared.log("connect: already in flight — joining instead of starting another")
            return
        }
        if let failedAt = lastConnectFailure,
           Date().timeIntervalSince(failedAt) < 4 {
            DiagLog.shared.log("connect: cooling down after a failure")
            return
        }
        connectInFlight = true
        defer { connectInFlight = false }
        connection = .preparing("Looking for the developer tunnel…")
        DiagLog.shared.note("connect: begin")
        probeTunnel()

        // If the pairing service kept the socket open, the tunnel is the way in.
        if lastProbeWaitedForUs {
            do {
                try await Transport.shared.bringUp(session: self)
                useLockdown = false
                connection = .ready(address: Transport.shared.dialedAddress ?? "tunnel")
                reconnectAttempts = 0
                DiagLog.shared.note("connect: ready at \(Transport.shared.dialedAddress ?? "?")")
                return
            } catch {
                DiagLog.shared.note("connect: pairing tunnel failed — \(error.localizedDescription)")
                offerPairingAfterReset(error.localizedDescription)
            }
        }

        // The pairing service hung up on us, so try lockdownd: it needs no pairing.
        let lockdownStatus = await lockdown.prepare()
        if lockdown.isReady {
            useLockdown = true
            connection = .ready(address: "lockdownd · service \(lockdown.servicePort)")
            reconnectAttempts = 0
            DiagLog.shared.note("connect: ready via lockdownd")
            return
        }
        DiagLog.shared.note("connect: lockdownd unavailable — \(lockdownStatus)")

        // Last try, mostly for the case where the probe was wrong.
        do {
            try await Transport.shared.bringUp(session: self)
            useLockdown = false
            connection = .ready(address: Transport.shared.dialedAddress ?? "tunnel")
            reconnectAttempts = 0
            DiagLog.shared.note("connect: ready at \(Transport.shared.dialedAddress ?? "?")")
        } catch {
            connection = .failed(error.localizedDescription)
            lastConnectFailure = Date()
            DiagLog.shared.note("connect: failed — \(error.localizedDescription)")
        }
    }

    /// Reports what the tunnel actually does before any handshake is attempted.
    ///
    /// Three measurements, because they fail differently:
    /// * 49152 — the remote-pairing service (silent = waits for us, close = nothing there)
    /// * 62078 — lockdownd, which LocalDevVPN is documented to expose on 10.7.0.1
    /// * a real QueryType to lockdownd, which needs no pairing and so proves the tunnel
    private func probeTunnel() {
        var buffer = [CChar](repeating: 0, count: 256)

        // Only the swap target matters: if it refuses, nothing else on this device will
        // answer, and sweeping the rest of the candidates just costs seconds.
        let swapTarget = "10.7.0.1"
        _ = swapTarget.withCString { wd_probe_tunnel($0, 49152, &buffer, 256) }
        let pairingProbe = String(cString: buffer)
        DiagLog.shared.log("probe \(swapTarget):49152 — \(pairingProbe)")
        lastProbeWaitedForUs = pairingProbe.contains("waits for us")

        if !lastProbeWaitedForUs {
            DiagLog.shared.log("probe: the pairing service is not answering — skipping lockdownd")
            return
        }
    }

    /// A reset only means "this record was replaced" when the device waited for us to
    /// speak. If it hung up unprompted, the tunnel is the problem and pairing would be
    /// theatre.
    private func offerPairingAfterReset(_ message: String) {
        let lowered = message.lowercased()
        guard lowered.contains("reset") || lowered.contains("54") else { return }
        guard lastProbeWaitedForUs else {
            DiagLog.shared.note("connect: reset with an unresponsive tunnel — pairing skipped")
            return
        }
        guard !PairHostBroker.shared.isPairing else { return }
        DiagLog.shared.note("connect: reset — starting the pairing flow the device accepts")
        PairHostBroker.shared.onPaired = { [weak self] _ in
            Task { await self?.connect() }
        }
        PairHostBroker.shared.start()
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
            if useLockdown {
                try await lockdown.setLocation(latitude: latitude, longitude: longitude)
            } else {
                try await Transport.shared.setLocation(latitude: latitude, longitude: longitude)
            }
            writeCount += 1
            lastWrite = Date()
            if lifetime == .setupOnly, !isStreaming { scheduleIdleClose() }
            scheduleVerification(target: CLLocationCoordinate2D(latitude: latitude,
                                                               longitude: longitude))
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
        endHold()
        if !connection.isReady {
            await connect()
            guard connection.isReady else {
                throw SinkError.notConnected(connection.label)
            }
        }
        if useLockdown {
            try await lockdown.clearLocation()
        } else {
            try await Transport.shared.clearLocation()
        }
        writeCount = 0
        lastWrite = nil
        scheduleIdleClose(after: 0.6)
    }

    /// Reads back the phone's own fix a couple of seconds after a write.
    ///
    /// A successful DVT call only means the daemon accepted the message. What matters is
    /// whether CoreLocation actually reports the new position — without this, a spoof that
    /// silently reverts looks exactly like one that worked.
    private func scheduleVerification(target: CLLocationCoordinate2D) {
        guard let fixProbe else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard self != nil else { return }
            let (fix, when) = fixProbe()
            guard let fix, let when,
                  Date().timeIntervalSince(when) < 10 else {
                DiagLog.shared.log("verify: no fresh fix to compare yet")
                return
            }
            let away = Geo.distance(fix, target)
            self?.lastVerification = Verification(offsetMeters: away, checkedAt: Date())
            if away < 60 {
                DiagLog.shared.note("verify: device reports the target "
                                    + "(\(Int(away))m off) — write took effect")
            } else {
                DiagLog.shared.note("verify: device is \(Int(away))m from the target — "
                                    + "write was accepted but did not take effect")
            }
        }
    }

    /// Pins a parked coordinate, re-sending every 4 s with a breathing offset.
    ///
    /// The shipping app does this for the same reason and says so in a comment: iOS
    /// re-checks the simulated location, and a single write can be replaced by the real
    /// fix. Four seconds is its cadence, and it is what makes Find My / Life360 show the
    /// held point instead of snapping back.
    func hold(at coordinate: CLLocationCoordinate2D) async {
        holdTask?.cancel()
        holdCoordinate = coordinate
        guard lifetime == .persistent else { return }

        holdTask = Task { [weak self] in
            var jitter = BreathingJitter()
            var tick = 0
            while !Task.isCancelled {
                let target = jitter.next(around: coordinate)
                do {
                    if useLockdown {
                        try await self?.lockdown.setLocation(latitude: target.latitude,
                                                             longitude: target.longitude)
                    } else {
                        try await Transport.shared.setLocation(latitude: target.latitude,
                                                                longitude: target.longitude)
                    }
                    tick += 1
                    if tick % 15 == 1 {
                        DiagLog.shared.log("hold: still pinned (\(tick) resends)")
                    }
                } catch {
                    DiagLog.shared.log("hold: resend failed — \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Stops pinning. The last written coordinate stays until it is cleared.
    func endHold() {
        holdTask?.cancel()
        holdTask = nil
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
            if useLockdown {
                try await lockdown.setLocation(latitude: coordinate.latitude,
                                               longitude: coordinate.longitude)
            } else {
                try await Transport.shared.setLocation(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude)
            }
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

    /// Replaces the active pairing record with a newly generated one and connects,
    /// which makes the handshake run pair-setup instead of a doomed pair-verify.
    func pairFromScratch() async {
        do {
            _ = try PairingStore.generateFresh()
            pairingEntries = PairingStore.all()
            importError = nil
            DiagLog.shared.note("pairing: fresh record active — pairing now")
        } catch {
            importError = error.localizedDescription
            DiagLog.shared.log("pairing: could not generate a fresh record — "
                               + error.localizedDescription)
            return
        }
        await connect()
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
