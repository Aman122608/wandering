import CoreLocation

/// One device write: where, and how long to wait before sending it.
struct TrackSample {
    var coordinate: CLLocationCoordinate2D
    var delay: TimeInterval
}

/// A route as the router hands it over: geometry plus per-segment road speeds
/// (metres/second), which is what makes the car presets feel like traffic.
struct PlannedRoute: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coordinates: [CLLocationCoordinate2D]
    var distance: Double        // metres
    var expectedTravelTime: Double
    var segmentSpeeds: [Double] // count == coordinates.count - 1 (or empty)

    static func == (lhs: PlannedRoute, rhs: PlannedRoute) -> Bool { lhs.id == rhs.id }

    var distanceKm: Double { distance / 1000 }
    var points: Int { coordinates.count }
}

struct PlayoutOptions {
    var preset: TravelPreset
    var maxSpeedKmh: Double
    /// Life360 / Find My style: always keep noise and micro-pauses on and never
    /// report a suspiciously perfect fix. Radius floor is 1.5 m.
    var sharingMode: Bool = false
    var useRoadSpeeds: Bool = true
    var jitter: Bool = true
    var variation: Bool = true
    var pauses: Bool = true
    var minTick: TimeInterval = 0.5

    var maxSpeed: Double { maxSpeedKmh / 3.6 }
}

/// Builds the paced coordinate stream. Pure functions only — no device, no UI,
/// so the whole engine is unit-testable.
enum TrackBuilder {

    static func build(route: PlannedRoute, options: PlayoutOptions) -> [TrackSample] {
        let coords = route.coordinates
        guard coords.count >= 2 else {
            return coords.first.map { [TrackSample(coordinate: $0, delay: 0)] } ?? []
        }

        // 1. Per-segment target speed: road speed if we have one, else the preset.
        var speeds: [Double] = []
        speeds.reserveCapacity(coords.count - 1)
        for i in 0..<(coords.count - 1) {
            var v = preset(route: route, options: options, index: i)
            v = min(v, options.maxSpeed)
            // 2. Turn weighting: a car brakes into a corner; a pedestrian barely does.
            if options.preset.obeysSpeedLimits, i + 2 < coords.count {
                let turn = Geo.turnAngle(coords[i], coords[i + 1], coords[i + 2])
                v *= max(1 - min(turn / 120, 1) * 0.62, 0.38)
            }
            speeds.append(max(v, 0.4))
        }

        // 3. Walk each segment with a fixed number of equal sub-steps.
        var samples: [TrackSample] = [TrackSample(coordinate: coords[0], delay: 0)]
        for i in 0..<(coords.count - 1) {
            let segment = Geo.distance(coords[i], coords[i + 1])
            guard segment > 0.05 else { continue }
            let duration = segment / speeds[i]
            let steps = max(1, Int(ceil(duration / options.minTick)))
            for step in 1...steps {
                let f = Double(step) / Double(steps)
                samples.append(TrackSample(
                    coordinate: Geo.lerp(coords[i], coords[i + 1], f),
                    delay: duration / Double(steps)
                ))
            }
        }

        // 4. Uniform cadence — sub-metre segments would otherwise emit writes
        //    faster than any device accepts, and those get dropped, not queued.
        samples = resample(samples, tick: options.minTick)

        // 5. Life: speed variation, pedestrian pauses, then GPS noise.
        if options.variation { samples = vary(samples, options: options) }
        if options.pauses || options.sharingMode, options.preset.pausesPerMinute > 0 {
            samples = insertPauses(samples, options: options)
        }
        if options.jitter || options.sharingMode {
            let wanted = max(options.preset.jitterRadius, options.sharingMode ? 0.75 : 0)
            samples = addJitter(samples, radius: min(wanted, maxJitterRadius))
        }
        return samples
    }

    private static func preset(route: PlannedRoute, options: PlayoutOptions, index: Int) -> Double {
        if options.useRoadSpeeds, options.preset.obeysSpeedLimits,
           route.segmentSpeeds.count == route.coordinates.count - 1 {
            return route.segmentSpeeds[index]
        }
        if options.preset == .cruise {
            return options.maxSpeed
        }
        if options.preset == .drive, route.expectedTravelTime > 0,
           route.segmentSpeeds.isEmpty {
            // No per-segment data: fall back to the route's own average.
            return max(route.distance / route.expectedTravelTime, 1)
        }
        return options.preset.speed
    }

    // MARK: - Cadence

    static func resample(_ samples: [TrackSample], tick: TimeInterval) -> [TrackSample] {
        guard samples.count > 2, tick > 0 else { return samples }
        var times: [Double] = [0]
        times.reserveCapacity(samples.count)
        for s in samples.dropFirst() { times.append(times.last! + max(s.delay, 0)) }
        let total = times.last!
        guard total > tick else { return samples }

        var out: [TrackSample] = [samples[0]]
        var target = tick
        var index = 1
        while target <= total {
            while index < times.count && times[index] < target { index += 1 }
            if index >= times.count { break }
            let t0 = times[index - 1]
            let t1 = times[index]
            let span = t1 - t0
            let f = span <= 0 ? 0 : (target - t0) / span
            out.append(TrackSample(
                coordinate: Geo.lerp(samples[index - 1].coordinate, samples[index].coordinate,
                                    Geo.clamp(f, 0, 1)),
                delay: tick
            ))
            target += tick
        }
        return out
    }

    // MARK: - Variation

    static func vary(_ samples: [TrackSample], options: PlayoutOptions) -> [TrackSample] {
        let range = options.preset.speedWobble
        var out = samples
        // A slow drift on top of per-tick noise: real pacing is not white noise.
        var drift = 1.0
        for i in 1..<out.count {
            drift = Geo.clamp(drift * 0.94 + Double.random(in: 0.97...1.03) * 0.06,
                              0.9, 1.12)
            let wobble = Double.random(in: range)
            out[i].delay = max(out[i].delay * wobble * drift, 0.12)
        }
        return out
    }

    static func insertPauses(_ samples: [TrackSample], options: PlayoutOptions) -> [TrackSample] {
        guard samples.count > 4 else { return samples }
        let perTick = options.preset.pausesPerMinute * options.minTick / 60
        var out: [TrackSample] = [samples[0]]
        var sincePause = 0.0
        for sample in samples.dropFirst() {
            sincePause += sample.delay
            if sincePause > 12, Double.random(in: 0...1) < perTick {
                // Park: re-assert the same coordinate after a 2–6 s pause.
                let pause = Double.random(in: 2...6)
                out.append(TrackSample(coordinate: out.last?.coordinate ?? sample.coordinate,
                                       delay: pause))
                sincePause = 0
            }
            out.append(sample)
        }
        return out
    }

    // MARK: - Jitter

    /// Hard ceiling on apparent GPS noise: 1.5 m across the worst case, i.e. a
    /// 0.75 m radius. Anything wider is visible as jumping on Life360/Find My — a
    /// 2.5 m offset at highway speed reads as a car sliding sideways off the road.
    static let maxJitterRadius = 0.75

    /// Correlated GPS error. Independent per-sample noise on a 0.5 s cadence
    /// manufactures fake speed spikes (2 x 2.5 m in half a second = 36 km/h of
    /// velocity that never happened), so the offset is a bounded random walk.
    final class JitterWalk {
        let radius: Double
        var north = 0.0
        var east = 0.0

        init(radius: Double) { self.radius = radius }

        func next(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            let retention = 0.82
            let step = radius * 0.24
            north = north * retention + Double.random(in: -1...1) * step
            east = east * retention + Double.random(in: -1...1) * step
            let norm = hypot(north, east)
            if norm > radius {
                north *= radius / norm
                east *= radius / norm
            }
            return Geo.offset(coordinate, north: north, east: east)
        }
    }

    static func addJitter(_ samples: [TrackSample], radius: Double) -> [TrackSample] {
        guard radius > 0 else { return samples }
        let walk = JitterWalk(radius: radius)
        return samples.map { sample in
            var copy = sample
            copy.coordinate = walk.next(sample.coordinate)
            return copy
        }
    }

    /// Stationary hold: breathing offset, mean-reverting, clamped.
    static func breathingHold(anchor: CLLocationCoordinate2D, minutes: Double,
                              tick: TimeInterval = 4.0, radius: Double = 2.2) -> [TrackSample] {
        guard minutes > 0 else { return [] }
        var north = 0.0
        var east = 0.0
        var out: [TrackSample] = []
        let count = Int(minutes * 60 / tick)
        for _ in 0..<count {
            north = north * 0.85 + Double.random(in: -0.5...0.5) * 0.9
            east = east * 0.85 + Double.random(in: -0.5...0.5) * 0.9
            let norm = hypot(north, east)
            if norm > radius {
                north *= radius / norm
                east *= radius / norm
            }
            out.append(TrackSample(coordinate: Geo.offset(anchor, north: north, east: east),
                                   delay: tick))
        }
        return out
    }
}
