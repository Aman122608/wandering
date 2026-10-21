import CoreLocation
import Foundation

/// Keeps a live session alive instead of letting it die quietly.
///
/// Three jobs:
/// 1. **Watchdog** — a session must produce a successful write every few seconds.
///    If the stream stalls (device dropped, tunnel gone, service unresponsive), the
///    supervisor tears the transport down and rebuilds it, then re-asserts the last
///    coordinate.
/// 2. **Snap-back detection** — compares the phone's *real* fix against the target.
///    Two consecutive fixes hundreds of metres away mean the spoof was overridden;
///    it re-asserts immediately and escalates to a full rebuild if that persists.
/// 3. **Honest failure** — after three rebuild attempts it declares the session lost
///    and stops the player, rather than leaving the UI showing a session that is not
///    actually happening.
@MainActor
final class SessionSupervisor: ObservableObject {

    enum Health: Equatable {
        case idle
        case healthy
        case recovering(Int)
        case lost(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .healthy: return "Live"
            case .recovering(let attempt): return "Recovering (\(attempt))"
            case .lost(let why): return "Lost · \(why)"
            }
        }

        var isHealthy: Bool { self == .healthy }
    }

    @Published private(set) var health: Health = .idle
    @Published private(set) var lastWrite: Date?
    @Published private(set) var recoveries = 0
    @Published private(set) var note = ""
    @Published private(set) var realFix: CLLocationCoordinate2D?

    /// A write older than this while a session is live means something is wrong.
    private let staleAfter: TimeInterval = 7
    private let maxRecoveryAttempts = 3
    private let snapBackThreshold: Double = 400   // metres
    private let snapBackHitsBeforeReassert = 2

    private weak var player: TrackPlayer?
    private weak var session: DeviceSession?
    private var timer: Timer?
    private var target: CLLocationCoordinate2D?
    private var recovering = false
    private var failuresInARow = 0
    private var snapBackHits = 0

    // MARK: - Wiring

    func bind(player: TrackPlayer, session: DeviceSession) {
        self.player = player
        self.session = session
        player.onWriteFailure = { [weak self] error in
            await self?.recover(reason: error.localizedDescription) ?? false
        }
    }

    func begin(target: CLLocationCoordinate2D) {
        self.target = target
        failuresInARow = 0
        recoveries = 0
        snapBackHits = 0
        health = .healthy
        lastWrite = Date()
        note = ""
        startWatchdog()
        Defaults.wasSpoofing = true
        Defaults.lastSessionAt = Date()
        Defaults.resumeTarget = target
    }

    func recordWrite() {
        lastWrite = Date()
        failuresInARow = 0
        if health != .healthy, !recovering { health = .healthy }
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
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player, player.phase.isActive else { return }
        guard !recovering else { return }
        let since = Date().timeIntervalSince(lastWrite ?? .distantPast)
        if since > staleAfter {
            note = "No write for \(Int(since))s — rebuilding"
            DiagLog.shared.note("supervisor: stale for \(Int(since))s, rebuilding")
            Task { _ = await recover(reason: "no write for \(Int(since))s") }
        }
    }

    // MARK: - Recovery

    /// Returns true when the transport is usable again.
    @discardableResult
    func recover(reason: String) async -> Bool {
        guard !recovering else { return false }
        guard let session, let player, player.phase.isActive else { return false }

        recovering = true
        defer { recovering = false }
        recoveries += 1
        health = .recovering(recoveries)
        note = "Rebuilding: \(reason)"
        DiagLog.shared.note("supervisor: rebuild #\(recoveries) — \(reason)")

        session.disconnect()
        try? await Task.sleep(nanoseconds: 600_000_000)

        await session.connect()
        guard session.connection.isReady else {
            if recoveries >= maxRecoveryAttempts {
                health = .lost("tunnel did not come back")
                note = "Gave up after \(recoveries) attempts. Reconnect LocalDevVPN and start again."
                DiagLog.shared.note("supervisor: lost — tunnel did not come back")
                player.stop(clear: false)
                Defaults.wasSpoofing = false
            }
            return false
        }

        // Re-assert immediately: a rebuilt tunnel starts with no location set.
        if let target {
            do {
                try await session.setLocation(latitude: target.latitude,
                                              longitude: target.longitude)
                lastWrite = Date()
            } catch {
                DiagLog.shared.note("supervisor: re-assert failed — \(error.localizedDescription)")
                return false
            }
        }
        player.reassert()
        recoveries = 0
        health = .healthy
        note = "Rebuilt"
        DiagLog.shared.note("supervisor: rebuilt and re-asserted")
        return true
    }

    // MARK: - Snap-back

    /// Called with the phone's own location fixes while a session is live.
    func observeRealFix(_ coordinate: CLLocationCoordinate2D) {
        realFix = coordinate
        guard let player, player.phase.isActive, let target else { return }
        let drift = Geo.distance(coordinate, target)
        if drift > snapBackThreshold {
            snapBackHits += 1
        } else {
            snapBackHits = 0
        }
        guard snapBackHits >= snapBackHitsBeforeReassert else { return }
        snapBackHits = 0
        if session?.burstTunnel == true {
            // Burst mode means the tunnel is closed most of the time; if the device
            // is dropping the fix between writes, that trade is not worth it.
            session?.burstTunnel = false
            note = "Burst tunnel cannot hold the fix — switched to persistent"
            DiagLog.shared.note("supervisor: burst tunnel dropped the fix, "
                + "falling back to persistent")
            Task { _ = await recover(reason: "burst tunnel lost the fix") }
            return
        }
        note = "Real fix \(Int(drift)) m from target — re-asserting"
        DiagLog.shared.note("supervisor: snap-back \(Int(drift))m, re-asserting")
        player.reassert()
        lastWrite = Date()
    }
}
