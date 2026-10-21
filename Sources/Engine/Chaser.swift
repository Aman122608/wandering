import CoreLocation
import Foundation

/// Follows the real drive, but never reports faster than a speed you set.
///
/// The model is a cursor travelling along the path you have *actually* driven. Every
/// tick the cursor advances by at most `capKmh`, so if you drive 80 with a 60 cap the
/// reported position falls behind — and because it can only move toward the end of the
/// path, standing still lets it close the gap. Nothing is invented: the reported
/// positions are always points on the road you really drove, just delayed.
@MainActor
final class Chaser: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var reportedSpeedKmh = 0.0
    @Published private(set) var gapMeters = 0.0
    @Published private(set) var status = "idle"

    /// The number he typed. Nothing above this is ever reported.
    @Published var capKmh: Double = UserDefaults.standard.object(forKey: "chaseCapKmh") as? Double ?? 60 {
        didSet { UserDefaults.standard.set(capKmh, forKey: "chaseCapKmh") }
    }

    private let manager = CLLocationManager()
    private var path: [CLLocationCoordinate2D] = []
    private var lengths: [Double] = [0]        // cumulative metres at each path point
    private var cursor: Double = 0             // metres travelled along the path
    private var ticker: Timer?
    private var lastTick = Date()
    private weak var sink: LocationSink?
    private var writeInFlight = false

    /// Distance the cursor is allowed to lag before the path is compacted, so an
    /// hours-long drive does not grow forever.
    private let maxPathMeters = 5000.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
    }

    var capMps: Double { max(capKmh, 1) / 3.6 }

    // MARK: - Lifecycle

    func start(sink: LocationSink) {
        guard !isRunning else { return }
        self.sink = sink
        path = []
        lengths = [0]
        cursor = 0
        gapMeters = 0
        reportedSpeedKmh = 0
        isRunning = true
        status = "waiting for a fix"

        DiagLog.shared.note("chase: start · cap \(Int(capKmh)) km/h")
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()

        // The stream needs the tunnel for as long as it runs.
        Task { await sink.beginStreaming() }

        lastTick = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        manager.stopUpdatingLocation()
        status = "stopped"
        reportedSpeedKmh = 0
        DiagLog.shared.note("chase: stopped after \(Int(cursor)) m")
        if let sink { await sink.endStreaming() }
    }

    /// Re-seed from the current real fix, ignoring everything recorded so far.
    func reset() {
        path = []
        lengths = [0]
        cursor = 0
        gapMeters = 0
        status = "re-centred"
    }

    // MARK: - Advancing

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard dt > 0, dt < 10 else { return }
        guard sink != nil, !path.isEmpty else { return }

        let total = lengths.last ?? 0
        let room = max(0, total - cursor)
        let advance = min(capMps * dt, room)
        cursor = min(cursor + advance, total)

        gapMeters = total - cursor
        reportedSpeedKmh = (advance / dt) * 3.6

        write(at: cursor)
        compactIfNeeded()
    }

    private func write(at metres: Double) {
        guard let sink, !writeInFlight else { return }
        let position = point(at: metres)
        writeInFlight = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.writeInFlight = false } }
            do {
                try await sink.setLocation(latitude: position.latitude,
                                           longitude: position.longitude)
                await MainActor.run { self?.status = "live" }
            } catch {
                await MainActor.run { self?.status = "write failed — \(error.localizedDescription)" }
            }
        }
    }

    private func point(at metres: Double) -> CLLocationCoordinate2D {
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

    private func append(_ coordinate: CLLocationCoordinate2D) {
        guard let last = path.last else {
            path.append(coordinate)
            lengths = [0]
            return
        }
        let step = Geo.distance(last, coordinate)
        guard step > 0.6 else { return }   // ignore GPS wobble while stationary
        path.append(coordinate)
        lengths.append((lengths.last ?? 0) + step)
        if path.count > 4000 { compact(keeping: 1500) }
    }

    /// Drop path that is far enough behind the cursor that it can never be needed.
    private func compactIfNeeded() {
        guard let total = lengths.last, total - cursor > maxPathMeters,
              path.count > 400 else { return }
        compact(keeping: 300)
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

extension Chaser: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 40 }
        guard let last = fixes.last else { return }
        Task { @MainActor in
            // First real fix defines the start of the path: the spoof begins where
            // the phone actually is, then lags from there.
            self.append(last.coordinate)
            if self.status == "waiting for a fix" {
                self.status = self.reportedSpeedKmh > 0 ? "live" : "tracking"
                DiagLog.shared.note("chase: first fix · accuracy "
                                    + "\(Int(last.horizontalAccuracy)) m")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                DiagLog.shared.note("chase: location authorised")
            case .denied, .restricted:
                self.status = "location permission denied"
                DiagLog.shared.log("chase: location permission denied")
                await self.stop()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.status = "location error — \(message)"
            DiagLog.shared.log("chase: \(message)")
        }
    }
}
