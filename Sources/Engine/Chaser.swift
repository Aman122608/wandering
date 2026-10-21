import CoreLocation
import Foundation

/// Follows the real drive, but never reports faster than a speed you set.
///
/// The model is a cursor travelling along the path actually driven. Each tick the cursor
/// advances by at most `capKmh`, so driving 80 with a 60 cap makes the reported position
/// fall behind — and because the cursor can only move toward the end of the path, slowing
/// down or stopping lets it close the gap. Nothing is invented: every reported point is a
/// point on the road that was really driven, just delayed.
///
/// Two things make this robust rather than approximate:
/// * the clock is the silent audio buffer (0.25 s), not `Task.sleep`, so it keeps ticking
///   while the app is in the background;
/// * the parked position is re-sent on the same 4 s cadence the rest of the app uses, so
///   iOS re-checks do not quietly put the real fix back.
@MainActor
final class Chaser: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var reportedSpeedKmh = 0.0
    @Published private(set) var gapMeters = 0.0
    @Published private(set) var status = "idle"
    @Published private(set) var fixAge: TimeInterval = .infinity

    /// The cap, in km/h. Nothing above this is ever reported.
    @Published var capKmh: Double = UserDefaults.standard.object(forKey: "chaseCapKmh") as? Double ?? 60 {
        didSet {
            let clamped = min(max(capKmh, 5), 160)
            if clamped != capKmh { capKmh = clamped; return }
            UserDefaults.standard.set(capKmh, forKey: "chaseCapKmh")
        }
    }

    /// Supplied by the app so the loop can follow the audio buffer.
    var audioTick: (() async -> Void)?
    var audioTickPeriod: Double = 0.25

    private let manager = CLLocationManager()
    private let jitter = BreathingJitter()

    private var path: [CLLocationCoordinate2D] = []
    private var lengths: [Double] = [0]
    private var cursor: Double = 0
    private weak var sink: LocationSink?

    private var loopTask: Task<Void, Never>?
    private var lastTick = Date()
    private var lastFixAt = Date.distantPast
    private var lastFixAccuracy: Double = .infinity
    private var lastAccepted: CLLocation?
    private var sinceLastWrite = Date.distantPast
    private var consecutiveFailures = 0

    /// Path kept behind the cursor before it is trimmed, so a long drive cannot grow
    /// without bound. Far larger than any realistic lag.
    private let maxPathMeters = 8_000.0

    /// The write cadence while following. One a second is what a real receiver looks like.
    private let writeInterval: TimeInterval = 1.0

    /// A fix older than this is treated as "no GPS" and the point is held, not moved.
    private let staleFix: TimeInterval = 12

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        manager.allowsBackgroundLocationUpdates = true
    }

    var capMps: Double { max(capKmh, 5) / 3.6 }

    /// The cap shown to the user, in mph. Stored internally in km/h so the engine and the
    /// logs stay in one unit.
    var capMph: Double {
        get { capKmh / 1.609344 }
        set {
            let mph = min(max(newValue, 3), 100)
            capKmh = mph * 1.609344
            DiagLog.shared.log("chase: cap set to \(Int(mph)) mph")
        }
    }
    var hasFix: Bool { Date().timeIntervalSince(lastFixAt) < staleFix }

    // MARK: - Lifecycle

    func start(sink: LocationSink) {
        guard !isRunning else { return }
        self.sink = sink
        path = []
        lengths = [0]
        cursor = 0
        gapMeters = 0
        reportedSpeedKmh = 0
        consecutiveFailures = 0
        isRunning = true
        sinceLastWrite = .distantPast
        lastTick = Date()

        DiagLog.shared.note("chase: start · cap \(Int(capKmh)) km/h")

        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()

        // If a fresh fix is already in hand, begin exactly where the phone is. Starting
        // from "nowhere" and waiting for movement was the old behaviour, and it made the
        // first seconds look broken.
        if let lastAccepted, Date().timeIntervalSince(lastFixAt) < staleFix {
            append(lastAccepted)
            write(position: lastAccepted, force: true)
            status = "following"
        } else {
            status = "waiting for GPS"
        }

        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                if let tick = self?.audioTick {
                    await tick()
                } else {
                    try? await Task.sleep(nanoseconds: UInt64((self?.audioTickPeriod ?? 0.25) * 1_000_000_000))
                }
                guard let self, self.isRunning else { return }
                ticks += 1
                self.tick()
                // Audio ticks arrive at 4 Hz; the write cadence is 1 Hz.
                if ticks % 4 == 0 { self.maybeWrite() }
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        manager.stopUpdatingLocation()
        reportedSpeedKmh = 0
        status = "stopped"
        DiagLog.shared.note("chase: stopped after \(Int(cursor)) m · cap \(Int(capKmh)) km/h")
        if let sink, let last = path.last {
            // Park: the last reported point stays, re-sent on the usual cadence.
            await sink.hold(at: last)
        }
    }

    /// Re-seed from the current real position, discarding the recorded path.
    func reset() {
        path = []
        lengths = [0]
        cursor = 0
        gapMeters = 0
        status = hasFix ? "following" : "waiting for GPS"
        DiagLog.shared.log("chase: re-centred")
    }

    // MARK: - The loop

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard dt > 0, dt < 5 else { return }   // suspended for long: skip, don't lurch

        guard !path.isEmpty else {
            status = hasFix ? "following" : "waiting for GPS"
            return
        }

        if hasFix {
            let total = lengths.last ?? 0
            let room = max(0, total - cursor)
            let advance = min(capMps * dt, room)
            cursor = min(cursor + advance, total)
            gapMeters = total - cursor
            reportedSpeedKmh = (advance / dt) * 3.6
            status = "following"
            compactIfNeeded()
        } else {
            // No usable fix: hold still rather than keep advancing on stale data.
            reportedSpeedKmh = 0
            status = "no GPS — holding"
        }
        fixAge = Date().timeIntervalSince(lastFixAt)
    }

    private func maybeWrite() {
        guard isRunning, !path.isEmpty else { return }
        guard Date().timeIntervalSince(sinceLastWrite) >= writeInterval - 0.05 else { return }
        sinceLastWrite = Date()

        let point = position(at: cursor)
        write(position: point, force: false)
    }

    private func write(position point: CLLocationCoordinate2D, force: Bool) {
        guard let sink else { return }
        let target = jitter.next(around: point)
        Task { [weak self] in
            do {
                try await sink.setLocation(latitude: target.latitude,
                                           longitude: target.longitude)
                guard let self else { return }
                self.consecutiveFailures = 0
            } catch {
                guard let self else { return }
                self.consecutiveFailures += 1
                if self.consecutiveFailures == 1 || self.consecutiveFailures % 5 == 0 {
                    DiagLog.shared.log("chase: write failed (\(self.consecutiveFailures)) — "
                                       + error.localizedDescription)
                }
                self.status = "write failed — retrying"
            }
        }
    }

    // MARK: - Path

    private func append(_ location: CLLocation) {
        let coordinate = location.coordinate

        guard let last = path.last else {
            path.append(coordinate)
            lengths = [0]
            return
        }

        let step = Geo.distance(last, coordinate)
        guard step > 0.75 else { return }      // ignore receiver wobble while stationary

        // Reject an impossible jump: a bad fix can teleport a kilometre and would drag
        // the whole path with it. Allowed speed is generous, this is not the cap.
        let sinceLast = Date().timeIntervalSince(lastFixAt)
        if sinceLast > 0, step / sinceLast > 60, sinceLast < 4 {
            DiagLog.shared.log("chase: ignored an implausible fix (\(Int(step)) m in "
                               + String(format: "%.1f", sinceLast) + " s)")
            return
        }

        path.append(coordinate)
        lengths.append((lengths.last ?? 0) + step)
        if path.count > 6000 { compact(keeping: 2000) }
    }

    /// Point `metres` along the recorded path.
    private func position(at metres: Double) -> CLLocationCoordinate2D {
        guard path.count > 1 else {
            return path.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        if metres <= 0 { return path[0] }
        if metres >= (lengths.last ?? 0) { return path[path.count - 1] }

        var low = 0
        var high = lengths.count - 1
        while low < high - 1 {
            let mid = (low + high) / 2
            if lengths[mid] <= metres { low = mid } else { high = mid }
        }
        let span = lengths[high] - lengths[low]
        let fraction = span > 0 ? (metres - lengths[low]) / span : 0
        return Geo.lerp(path[low], path[high], fraction)
    }

    private func compactIfNeeded() {
        guard let total = lengths.last, total - cursor > maxPathMeters, path.count > 500 else {
            return
        }
        compact(keeping: 400)
    }

    private func compact(keeping count: Int) {
        guard path.count > count else { return }
        let dropIndex = path.count - count
        let dropped = lengths[dropIndex]
        path.removeFirst(dropIndex)
        lengths = lengths.dropFirst(dropIndex).map { $0 - dropped }
        cursor = max(0, cursor - dropped)
    }
}

// MARK: - Location

extension Chaser: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let usable = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 60
        }
        guard let best = usable.last else { return }
        Task { @MainActor in
            let recovering = !self.hasFix
            self.lastFixAt = Date()
            self.lastFixAccuracy = best.horizontalAccuracy
            self.lastAccepted = best
            self.append(best)
            if recovering {
                DiagLog.shared.note("chase: GPS back (accuracy \(Int(best.horizontalAccuracy)) m)")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                DiagLog.shared.note("chase: location authorised")
                self.manager.startUpdatingLocation()
            case .denied, .restricted:
                self.status = "location permission denied — enable it in Settings"
                DiagLog.shared.log("chase: location permission denied")
                await self.stop()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.status = "location error — \(message)"
            DiagLog.shared.log("chase: \(message)")
        }
    }
}
