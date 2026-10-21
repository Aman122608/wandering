import CoreLocation
import Foundation

/// Mean-reverting drift for a parked location.
///
/// A held point that is mathematically frozen reads as fake to apps that sample it
/// repeatedly, and a fresh random offset on every resend reads as a series of tiny
/// teleports. This is the middle: a small random walk that is pulled back towards the
/// anchor, so the reported point wanders inside a metre or two and always returns.
///
/// The ceiling is 1.5 m across, matching the cap used for movement.
struct BreathingJitter {
    /// Radius of the wander, in metres (so the spread across is twice this).
    var radius: Double = 0.75

    private var north: Double = 0
    private var east: Double = 0

    /// One step of the walk, applied to `anchor`.
    mutating func next(around anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let retention = 0.90          // how strongly it remembers where it is
        let step = radius * 0.18      // how far one tick can push it
        north = north * retention + Double.random(in: -1...1) * step
        east = east * retention + Double.random(in: -1...1) * step

        let norm = hypot(north, east)
        if norm > radius {
            north *= radius / norm
            east *= radius / norm
        }
        return Geo.offset(anchor, north: north, east: east)
    }
}
