import CoreLocation
import Foundation

/// Watches a live spoof without becoming a source of churn.
///
/// The model that matters: the tunnel is opened to *write* a location, and once the
/// device has accepted it the fix persists with nothing connected. So there is no
/// heartbeat, no periodic re-assert and no reconnect loop — a parked spoof costs
/// nothing and the VPN stays off. This class only intervenes when something is
/// demonstrably wrong:
///
/// * **while moving**, writes must keep succeeding; a stall means the movement has
///   silently stopped, so the tunnel is rebuilt;
/// * **while parked**, the phone's own fix is compared against the target; a
///   sustained drift means iOS dropped the simulation, so one bounded re-assert burst
///   is sent (rate-limited, max three per session);
/// * after three failed repairs the session is declared lost and playback stops,
///   rather than leaving the UI claiming something that is not happening.
@MainActor
final class SessionSupervisor: ObservableObject {

    enum Health: Equatable {
        case idle
        case streaming
        case established          // parked, fix in place, tunnel closed
        case repairing(Int)
        case lost(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .streaming: return "Moving"
            case .established: return "Spoof in place"
            case .repairing(let attempt): return "Repairing (\(attempt))"
            case .lost(let why): return "Lost · \(why)"
            }
        }

        var isHealthy: Bool {
            switch self {
            case .streaming, .established: return true
            case .idle, .repairing, .lost: return false
            }
        }
    }

    @Published private(set) var health: Health = .idle
    @Published private(set) var lastWrite: Date?
    @Published private(set) var repairs = 0
    @Published private(set) var note = ""
    @Published private(set) var realFix: CLLocationCoordinate2D?
    @Published private(set) var driftMetres: Double = 0

    private let stallTimeout: TimeInterval = 7        // while writing
    private let maxRepairs = 3
    private let driftThreshold: Double = 300          // metres from target
    private let driftHitsBeforeRepair = 2
    private let repairCooldown: TimeInterval = 60

    private weak var player: TrackPlayer?
    private weak var session: DeviceSession?
    private var timer: Timer?
    private var target: CLLocationCoordinate2D?
    private var repairing = false
    private var driftHits = 0
    private var lastRepairAt = Date.distantPast

    // MARK: - Wiring

    func bind(player: TrackPlayer, session: DeviceSession) {
        self.player = player
        self.session = session
        player.onWriteFailure = { [weak self] error in
            await self?.repair(reason: error.localizedDescription) ?? false
        }
    }

    func begin(target: CLLocationCoordinate2D) {
        self.target = target
        repairs = 0
        driftHits = 0
        lastRepairAt = .distantPast
        lastWrite = Date()
        note = ""
        health = player?.phase == .playing ? .streaming : .established
        startWatchdog()
        Defaults.wasSpoofing = true
        Defaults.lastSessionAt = Date()
        Defaults.resumeTarget = target
    }

    func recordWrite() {
        lastWrite = Date()
        if health == .streaming || health == .repairing { health = .streaming }
    }

    func end() {
        timer?.invalidate()
        timer = nil
        health = .idle
        note = ""
        target = nil
        Defaults.wasSpoofing = false
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }

        switch player.phase {
        case .playing:
            // Writing continuously: a gap means the stream died.
            health = repairing ? health : .streaming
            let since = Date().timeIntervalSince(lastWrite ?? .distantPast)
            if since > stallTimeout, !repairing {
                note = "No write for \(Int(since))s"
                DiagLog.shared.note("supervisor: write stall \(Int(since))s, repairing")
                Task { _ = await repair(reason: "write stall") }
            }
        case .holding:
            // Parked: nothing should be connected. Only watch for drift.
            if !repairing { health = .established }
            checkDrift()
        case .paused:
            if !repairing { health = .established }
        default:
            break
        }
    }

    private func checkDrift() {
        guard let target else { return }
        guard let fix = realFix else { return }
        driftMetres = Geo.distance(fix, target)
        if driftMetres > driftThreshold {
            driftHits += 1
            note = "Real fix \(Int(driftMetres)) m away"
        } else {
            driftHits = 0
            if note.hasPrefix("Real fix") { note = "" }
        }
        guard driftHits >= driftHitsBeforeRepair else { return }
        guard Date().timeIntervalSince(lastRepairAt) > repairCooldown else { return }
        driftHits = 0
        lastRepairAt = Date()
        DiagLog.shared.note("supervisor: fix drifted \(Int(driftMetres))m, one re-assert burst")
        Task { await reassertOnce() }
    }

    // MARK: - Repair

    private func reassertOnce() async {
        guard let session, let target, !repairing else { return }
        repairing = true
        health = .repairing(repairs + 1)
        note = "Re-asserting after drift"
        let ok = await session.reassert(target)
        repairs += 1
        repairing = false
        if ok {
            health = .established
            note = "Re-asserted"
            lastWrite = Date()
        } else {
            failIfExhausted(reason: "re-assert failed")
        }
    }

    /// Full rebuild — only used while a movement is streaming, where a dead tunnel
    /// means the movement itself is dead.
    @discardableResult
    func repair(reason: String) async -> Bool {
        guard !repairing, let session, let player else { return false }
        guard player.phase == .playing else { return false }
        repairing = true
        defer { repairing = false }

        repairs += 1
        health = .repairing(repairs)
        note = "Rebuilding: \(reason)"
        DiagLog.shared.note("supervisor: rebuild #\(repairs) — \(reason)")

        session.disconnect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await session.connect()
        guard session.connection.isReady, let target else {
            failIfExhausted(reason: reason)
            return false
        }
        do {
            try await session.setLocation(latitude: target.latitude,
                                          longitude: target.longitude)
            lastWrite = Date()
            health = .streaming
            note = "Rebuilt"
            return true
        } catch {
            failIfExhausted(reason: error.localizedDescription)
            return false
        }
    }

    private func failIfExhausted(reason: String) {
        guard repairs >= maxRepairs else { return }
        health = .lost("gave up after \(repairs) repairs")
        note = "Reconnect LocalDevVPN and start again."
        DiagLog.shared.note("supervisor: lost — \(reason)")
        player?.stop(clear: false)
        Defaults.wasSpoofing = false
    }

    // MARK: - Real fixes

    /// Called with the phone's own location fixes while a session is live.
    func observeRealFix(_ coordinate: CLLocationCoordinate2D) {
        realFix = coordinate
        guard let target else { return }
        driftMetres = Geo.distance(coordinate, target)
    }
}
