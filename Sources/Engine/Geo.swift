import CoreLocation

/// Spherical helpers. Small, dependency-free, and testable without a device.
enum Geo {
    static let earthRadius = 6_371_008.8
    static let metresPerDegreeLat = 111_320.0

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees, 0 = north, clockwise.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Absolute heading change, wrapped into 0...180.
    static func turnAngle(_ a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D,
                          _ c: CLLocationCoordinate2D) -> Double {
        let raw = abs(bearing(b, c) - bearing(a, b)).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                     _ f: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f
        )
    }

    /// Offset a coordinate by metres north/east.
    static func offset(_ c: CLLocationCoordinate2D, north: Double, east: Double)
        -> CLLocationCoordinate2D {
        let dLat = north / metresPerDegreeLat
        let scale = max(cos(c.latitude * .pi / 180), 1e-6)
        let dLon = east / (metresPerDegreeLat * scale)
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
        -> CLLocationCoordinate2D {
        lerp(a, b, 0.5)
    }

    /// Projected distance in metres from `p` to segment `a`–`b` (local flat approximation).
    static func distance(from p: CLLocationCoordinate2D,
                         toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let scale = max(cos(p.latitude * .pi / 180), 1e-6)
        func xy(_ q: CLLocationCoordinate2D) -> (Double, Double) {
            (q.longitude * metresPerDegreeLat * scale, q.latitude * metresPerDegreeLat)
        }
        let (px, py) = xy(p)
        let (ax, ay) = xy(a)
        let (bx, by) = xy(b)
        let dx = bx - ax
        let dy = by - ay
        if dx == 0 && dy == 0 { return hypot(px - ax, py - ay) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
