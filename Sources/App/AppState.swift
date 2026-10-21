import CoreLocation
import MapKit
import SwiftUI

/// Everything the UI talks to. Owns the route plan, the presets, the player and
/// the device session; holds no layout.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Plan

    @Published var waypoints: [Waypoint] = []
    @Published private(set) var routes: [PlannedRoute] = []
    @Published var selectedRouteID: UUID?
    @Published private(set) var isPlanning = false
    @Published var planError: String?

    // MARK: - Motion

    @Published var preset: TravelPreset = Defaults.preset {
        didSet {
            maxSpeedKmh = Geo.clamp(maxSpeedKmh, preset.speedRange.lowerBound,
                                    preset.speedRange.upperBound)
            Defaults.preset = preset
        }
    }
    @Published var maxSpeedKmh: Double = Defaults.maxSpeedKmh {
        didSet { Defaults.maxSpeedKmh = maxSpeedKmh }
    }
    @Published var useRoadSpeeds = Defaults.useRoadSpeeds {
        didSet { Defaults.useRoadSpeeds = useRoadSpeeds }
    }
    @Published var variation = Defaults.variation {
        didSet { Defaults.variation = variation }
    }
    @Published var jitter = Defaults.jitter {
        didSet { Defaults.jitter = jitter }
    }
    @Published var pauses = Defaults.pauses {
        didSet { Defaults.pauses = pauses }
    }
    @Published var playbackRate: Double = Defaults.playbackRate {
        didSet { Defaults.playbackRate = playbackRate }
    }
    @Published var sharingMode = Defaults.sharingMode {
        didSet { Defaults.sharingMode = sharingMode }
    }

    // MARK: - Map

    @Published var camera: MapCameraPosition = .automatic
    @Published var searchQuery = ""
    @Published var searchResults: [PlaceResult] = []
    @Published var isSearching = false

    // MARK: - Runtime

    let player = TrackPlayer()
    let session = DeviceSession()
    let airplane = AirplaneSequence()
    let supervisor = SessionSupervisor()
    let network = NetworkMonitor()
    let chaser = Chaser()

    /// Set when the user asked for chase mode, so a cellular start knows what to run.
    @Published var chaseRequested = false

    /// Set when starting without Wi-Fi, so the UI can ask before touching the radios.
    @Published var cellularConsentNeeded = false
    private var consentPending: (() -> Void)?

    init() {
        supervisor.bind(player: player, session: session)
        player.onWriteSuccess = { [weak self] _ in
            self?.supervisor.recordWrite()
        }
    }
    private let router = Router()
    private var searchTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?

    var selectedRoute: PlannedRoute? {
        routes.first { $0.id == selectedRouteID } ?? routes.first
    }

    var isLive: Bool { player.phase.isActive }

    // MARK: - Waypoints

    func addWaypoint(_ place: PlaceResult) {
        waypoints.append(Waypoint(title: place.title, coordinate: place.coordinate))
        searchQuery = ""
        searchResults = []
        plan()
    }

    func addWaypoint(coordinate: CLLocationCoordinate2D, title: String? = nil) {
        let name = title ?? "Pin \(waypoints.count + 1)"
        waypoints.append(Waypoint(title: name, coordinate: coordinate))
        plan()
    }

    func removeWaypoint(_ waypoint: Waypoint) {
        waypoints.removeAll { $0.id == waypoint.id }
        plan()
    }

    func clearPlan() {
        waypoints.removeAll()
        routes = []
        selectedRouteID = nil
        planError = nil
    }

    func reversePlan() {
        waypoints.reverse()
        plan()
    }

    // MARK: - Search

    func search(_ query: String, near center: CLLocationCoordinate2D?) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 280_000_000)   // debounce typing
            if Task.isCancelled { return }
            do {
                let results = try await router.search(trimmed, near: center)
                if Task.isCancelled { return }
                self.searchResults = results
            } catch {
                if !Task.isCancelled { self.searchResults = [] }
            }
            self.isSearching = false
        }
    }

    func describe(_ coordinate: CLLocationCoordinate2D) async -> String {
        await router.describe(coordinate)
    }

    // MARK: - Planning

    func plan() {
        planTask?.cancel()
        guard waypoints.count >= 2 else {
            routes = []
            selectedRouteID = nil
            return
        }
        isPlanning = true
        planError = nil
        let waypoints = self.waypoints
        let preset = self.preset
        planTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await router.routes(waypoints: waypoints, preset: preset)
                if Task.isCancelled { return }
                self.routes = options
                if self.selectedRouteID == nil
                    || !options.contains(where: { $0.id == self.selectedRouteID }) {
                    self.selectedRouteID = options.first?.id
                }
                self.fitCamera()
                DiagLog.shared.note("planned \(options.count) route(s) · "
                    + String(format: "%.2f km", options.first?.distanceKm ?? 0))
            } catch {
                if Task.isCancelled { return }
                self.planError = error.localizedDescription
                self.routes = []
                DiagLog.shared.note("plan failed: \(error.localizedDescription)")
            }
            self.isPlanning = false
        }
    }

    // MARK: - Playback

    /// Starting anything goes through here: with no Wi-Fi the cellular sequence is
    /// needed, and that is worth one confirmation before the radios drop.
    private func gate(_ action: @escaping () -> Void) {
        let wantsCellular = UserDefaults.standard.bool(forKey: "airplaneInit")
        if wantsCellular && !network.isOnWiFi && !airplane.phase.isRunning {
            DiagLog.shared.note("start: no Wi-Fi — asking before cellular mode "
                                + "(online: \(network.isOnline))")
            consentPending = action
            cellularConsentNeeded = true
            return
        }
        action()
    }

    /// Runs whatever the user pressed, once consent is in hand.
    func performStart() {
        if chaseRequested {
            chaser.start(sink: session)
            return
        }
        if selectedRoute != nil {
            performStartRoute()
        } else if let target = waypoints.first?.coordinate {
            performTeleport(to: target)
        }
    }

    func confirmCellularStart() {
        cellularConsentNeeded = false
        consentPending = nil
        runCellularSequence()
    }

    func cancelCellularStart() {
        DiagLog.shared.log("start: cellular mode declined")
        cellularConsentNeeded = false
        consentPending = nil
    }

    /// Tunnel up → Shortcut on → confirm radios dropped → set location → Shortcut off.
    func runCellularSequence() {
        Task {
            await airplane.run(
                target: waypoints.first?.coordinate ?? resumableTarget,
                style: AirplaneSequence.ShortcutStyle(
                    rawValue: UserDefaults.standard.string(forKey: "airplaneShortcutStyle")
                        ?? "singleSwitch") ?? .singleSwitch,
                shortcutOn: UserDefaults.standard.string(forKey: "airplaneShortcutOn")
                    ?? "Wander Cellular Mode",
                shortcutOff: UserDefaults.standard.string(forKey: "airplaneShortcutOff")
                    ?? "Airplane Off",
                connect: { await session.connect() },
                move: { self.performStart() }
            )
        }
    }

    func startSelectedRoute() {
        chaseRequested = false
        gate { self.performStartRoute() }
    }

    func startChase() {
        chaseRequested = true
        gate { self.performStart() }
    }

    func stopChase() {
        chaseRequested = false
        Task { await chaser.stop() }
    }

    private func performStartRoute() {
        guard let route = selectedRoute else { return }
        let options = PlayoutOptions(
            preset: preset,
            maxSpeedKmh: maxSpeedKmh,
            sharingMode: sharingMode,
            useRoadSpeeds: useRoadSpeeds && preset.obeysSpeedLimits,
            jitter: jitter,
            variation: variation,
            pauses: pauses
        )
        let samples = TrackBuilder.build(route: route, options: options)
        DiagLog.shared.note("play \(preset.title) · \(samples.count) samples · "
            + String(format: "%.1f km/h cap", maxSpeedKmh))
        player.play(samples: samples, sink: session, rate: playbackRate)
        if let first = samples.first?.coordinate {
            supervisor.begin(target: first)
        }
    }

    func teleport(to coordinate: CLLocationCoordinate2D) {
        chaseRequested = false
        gate { self.performTeleport(to: coordinate) }
    }

    private func performTeleport(to coordinate: CLLocationCoordinate2D) {
        DiagLog.shared.note("teleport · \(Router.format(coordinate))")
        player.teleport(to: coordinate, sink: session)
        supervisor.begin(target: coordinate)
        remember(coordinate)
    }

    func teleport(to place: PlaceResult) {
        teleport(to: place.coordinate)
    }

    func stop(clear: Bool) {
        player.stop(clear: clear)
        supervisor.end()
    }

    /// Called when the app comes back to the foreground. iOS may have suspended the
    /// whole process, which stops the writes without failing them; this checks the
    /// stream and either nudges it or rebuilds.
    func resumeAfterForeground() {
        guard player.phase.isActive else {
            Task { await autoResumeIfNeeded() }
            return
        }
        let since = Date().timeIntervalSince(supervisor.lastWrite ?? .distantPast)
        DiagLog.shared.note("foreground: session active, last write \(Int(since))s ago")
        if since > 7 {
            Task { _ = await supervisor.repair(reason: "resumed from background") }
        } else {
            player.reassert()
        }
    }

    /// Brings back the last session after a relaunch or a kill, if it is recent.
    /// The tunnel always dies with the process, so this is a rebuild, not a resume
    /// of a running session.
    func autoResumeIfNeeded() async {
        guard !isLive,
              Defaults.wasSpoofing,
              let target = Defaults.resumeTarget,
              Date().timeIntervalSince(Defaults.lastSessionAt) < 12 * 3600 else { return }
        DiagLog.shared.note("auto-resume: restoring \(Router.format(target))")
        await session.connect()
        guard session.connection.isReady else {
            DiagLog.shared.note("auto-resume: tunnel not ready, staying idle")
            return
        }
        teleport(to: target)
    }

    // MARK: - Resume

    private let resumeKey = "wandering.lastTarget"

    private func remember(_ coordinate: CLLocationCoordinate2D) {
        UserDefaults.standard.set([coordinate.latitude, coordinate.longitude],
                                  forKey: resumeKey)
    }

    var resumableTarget: CLLocationCoordinate2D? {
        guard let values = UserDefaults.standard.array(forKey: resumeKey) as? [Double],
              values.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
    }

    func clearResumeTarget() {
        UserDefaults.standard.removeObject(forKey: resumeKey)
    }

    // MARK: - Camera

    func fitCamera() {
        let coordinates: [CLLocationCoordinate2D]
        if let route = selectedRoute {
            coordinates = route.coordinates
        } else {
            coordinates = waypoints.map(\.coordinate)
        }
        guard let first = coordinates.first else { return }
        guard coordinates.count > 1 else {
            camera = .region(MKCoordinateRegion(center: first,
                                                latitudinalMeters: 1_200,
                                                longitudinalMeters: 1_200))
            return
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        camera = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.004),
                                   longitudeDelta: max((maxLon - minLon) * 1.6, 0.004))
        ))
    }
}


/// Small, explicit persistence for the settings a session depends on.
enum Defaults {
    private static let store = UserDefaults.standard

    static var preset: TravelPreset {
        get { TravelPreset(rawValue: store.string(forKey: "motion.preset") ?? "") ?? .drive }
        set { store.set(newValue.rawValue, forKey: "motion.preset") }
    }

    static var maxSpeedKmh: Double {
        get { store.object(forKey: "motion.maxSpeed") as? Double ?? 50 }
        set { store.set(newValue, forKey: "motion.maxSpeed") }
    }

    static var useRoadSpeeds: Bool {
        get { store.object(forKey: "motion.roadSpeeds") as? Bool ?? true }
        set { store.set(newValue, forKey: "motion.roadSpeeds") }
    }

    static var variation: Bool {
        get { store.object(forKey: "motion.variation") as? Bool ?? true }
        set { store.set(newValue, forKey: "motion.variation") }
    }

    static var jitter: Bool {
        get { store.object(forKey: "motion.jitter") as? Bool ?? true }
        set { store.set(newValue, forKey: "motion.jitter") }
    }

    static var pauses: Bool {
        get { store.object(forKey: "motion.pauses") as? Bool ?? true }
        set { store.set(newValue, forKey: "motion.pauses") }
    }

    static var playbackRate: Double {
        get { store.object(forKey: "motion.rate") as? Double ?? 1 }
        set { store.set(newValue, forKey: "motion.rate") }
    }

    static var sharingMode: Bool {
        get { store.object(forKey: "motion.sharing") as? Bool ?? false }
        set { store.set(newValue, forKey: "motion.sharing") }
    }

    // Session intent: what to restore if the app is relaunched mid-session.

    static var wasSpoofing: Bool {
        get { store.object(forKey: "session.wasSpoofing") as? Bool ?? false }
        set { store.set(newValue, forKey: "session.wasSpoofing") }
    }

    static var lastSessionAt: Date {
        get { store.object(forKey: "session.lastAt") as? Date ?? .distantPast }
        set { store.set(newValue, forKey: "session.lastAt") }
    }

    static var resumeTarget: CLLocationCoordinate2D? {
        get {
            guard let values = store.array(forKey: "session.target") as? [Double],
                  values.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
        }
        set {
            guard let newValue else { store.removeObject(forKey: "session.target"); return }
            store.set([newValue.latitude, newValue.longitude], forKey: "session.target")
        }
    }
}
