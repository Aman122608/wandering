import CoreLocation
import MapKit

struct PlaceResult: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
    var symbol: String = "mappin"

    static func == (lhs: PlaceResult, rhs: PlaceResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Waypoints are the user's stops, A, B, C… The first is the origin.
struct Waypoint: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool { lhs.id == rhs.id }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                          count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out.filter { CLLocationCoordinate2DIsValid($0) }
    }
}

/// Address search + route planning. Everything here is MapKit: no API keys, no
/// third-party routing service, and it works for any country the phone knows.
@MainActor
final class Router {
    enum RouterError: LocalizedError {
        case noResults
        case noRoute

        var errorDescription: String? {
            switch self {
            case .noResults: return "No matching place found."
            case .noRoute: return "No route between those points."
            }
        }
    }

    // MARK: - Places

    func search(_ query: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        // A raw "lat, lon" is accepted so coordinates can be pasted in.
        if let parsed = Self.parseCoordinate(trimmed) {
            return [PlaceResult(title: Self.format(parsed), subtitle: "Dropped pin",
                                coordinate: parsed, symbol: "scope")]
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let center {
            request.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: 60_000,
                                                longitudinalMeters: 60_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(12).map { item in
            PlaceResult(
                title: item.name ?? "Unknown place",
                subtitle: item.placemark.title ?? "",
                coordinate: item.placemark.coordinate,
                symbol: item.pointOfInterestCategory == nil ? "mappin" : "building.2"
            )
        }
    }

    /// Reverse lookup for "where am I now" labels and for taps on the map.
    func describe(_ coordinate: CLLocationCoordinate2D) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let place = try? await geocoder.reverseGeocodeLocation(location).first {
            let parts = [place.name, place.locality, place.administrativeArea]
                .compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return Self.format(coordinate)
    }

    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    // MARK: - Routes

    private func mapItem(_ waypoint: Waypoint) -> MKMapItem {
        let placemark = MKPlacemark(coordinate: waypoint.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = waypoint.title
        return item
    }

    private func travelType(_ preset: TravelPreset) -> MKDirectionsTransportType {
        preset == .walk ? .walking : .automobile
    }

    /// Returns up to three distinct routes. For two waypoints that is Apple's
    /// alternate-routes set; for more waypoints it is the same alternates index
    /// applied to every leg, so each option is a genuinely different path.
    func routes(waypoints: [Waypoint], preset: TravelPreset) async throws -> [PlannedRoute] {
        guard waypoints.count >= 2 else { throw RouterError.noRoute }
        let legs = try await legAlternates(waypoints: waypoints, preset: preset)
        guard let firstLeg = legs.first, !firstLeg.isEmpty else { throw RouterError.noRoute }

        let count = min(legs.map(\.count).max() ?? 1, 3)
        var combined: [PlannedRoute] = []
        for index in 0..<count {
            var coordinates: [CLLocationCoordinate2D] = []
            var speeds: [Double] = []
            var distance = 0.0
            var eta = 0.0
            var ok = true

            for legOptions in legs {
                guard index < legOptions.count else { ok = false; break }
                let leg = legOptions[index]
                if !coordinates.isEmpty, let first = leg.coordinates.first,
                   let last = coordinates.last, Geo.distance(last, first) < 1 {
                    coordinates.removeLast()
                }
                coordinates.append(contentsOf: leg.coordinates)
                speeds.append(contentsOf: leg.segmentSpeeds)
                distance += leg.distance
                eta += leg.expectedTravelTime
            }
            guard ok, coordinates.count >= 2 else { continue }
            combined.append(PlannedRoute(
                name: "Route \(index + 1)",
                coordinates: coordinates,
                distance: distance,
                expectedTravelTime: eta,
                segmentSpeeds: speeds
            ))
        }
        guard !combined.isEmpty else { throw RouterError.noRoute }
        return combined.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    private func legAlternates(waypoints: [Waypoint], preset: TravelPreset) async throws -> [[PlannedRoute]] {
        var result: [[PlannedRoute]] = []
        for i in 0..<(waypoints.count - 1) {
            let request = MKDirections.Request()
            request.source = mapItem(waypoints[i])
            request.destination = mapItem(waypoints[i + 1])
            request.transportType = travelType(preset)
            request.requestsAlternateRoutes = true
            let response = try await MKDirections(request: request).calculate()
            let options = response.routes.prefix(3).map { planned(from: $0, index: i) }
            if options.isEmpty { throw RouterError.noRoute }
            result.append(options)
        }
        return result
    }

    /// Flattens Apple's per-step geometry into one polyline plus a speed per
    /// segment. `segmentSpeeds.count == coordinates.count - 1` always holds.
    private func planned(from route: MKRoute, index: Int) -> PlannedRoute {
        var coordinates: [CLLocationCoordinate2D] = []
        var speeds: [Double] = []
        let routeSpeed = route.distance / max(route.expectedTravelTime, 1)

        for step in route.steps where step.polyline.pointCount > 1 {
            var stepCoords = step.polyline.coordinates
            guard stepCoords.count >= 2 else { continue }

            let speed = max(step.expectedTravelTime > 0
                            ? step.distance / step.expectedTravelTime
                            : routeSpeed, 0.5)

            while let first = stepCoords.first, let last = coordinates.last,
                  Geo.distance(last, first) < 0.5 {
                stepCoords.removeFirst()
            }
            guard !stepCoords.isEmpty else { continue }

            if coordinates.isEmpty {
                coordinates.append(stepCoords.removeFirst())
            }
            for point in stepCoords {
                coordinates.append(point)
                speeds.append(speed)
            }
        }

        if coordinates.count < 2 {
            coordinates = route.polyline.coordinates
            speeds = []
        }
        if speeds.count != max(coordinates.count - 1, 0) {
            speeds = []
        }
        return PlannedRoute(
            name: index == 0 ? "Fastest" : "Alternate \(index + 1)",
            coordinates: coordinates,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            segmentSpeeds: speeds
        )
    }
}
