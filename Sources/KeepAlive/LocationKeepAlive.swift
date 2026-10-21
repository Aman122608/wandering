import CoreLocation
import Foundation

/// Second keep-alive: coarse background location.
///
/// This is *not* how the simulated location reaches the device — that goes through
/// the developer tunnel. This exists purely so iOS treats the app as an actively
/// updating location app and does not suspend it. The settings matter: 100 m
/// accuracy or better and no distance filter, otherwise iOS stops delivering
/// updates and the app is suspended within a couple of minutes.
@MainActor
final class LocationKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var running = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastFix: Date?
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = .other
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        wantsUpdates = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        manager.startUpdatingLocation()
        running = true
        DiagLog.shared.note("location keep-alive: start (auth \(manager.authorizationStatus.rawValue))")
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        running = false
        DiagLog.shared.note("location keep-alive: stop")
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            DiagLog.shared.note("location keep-alive: auth → \(status.rawValue)")
            if self.wantsUpdates, status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.lastFix = Date()
            self.lastCoordinate = latest.coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Expected while a simulated fix is in place or indoors; the manager only
        // needs to be running for the background mode to hold.
        Task { @MainActor in
            DiagLog.shared.note("location keep-alive: \(error.localizedDescription)")
        }
    }
}
