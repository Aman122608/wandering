import Foundation

/// Travel presets. `cruise` is the car preset: it ignores road ETA and holds a
/// user-set ceiling, which is what makes a long motorway run look constant.
enum TravelPreset: String, CaseIterable, Identifiable, Codable {
    case walk
    case bike
    case drive
    case cruise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walking"
        case .bike: return "Biking"
        case .drive: return "Driving"
        case .cruise: return "Car"
        }
    }

    var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .drive: return "car"
        case .cruise: return "speedometer"
        }
    }

    /// Metres per second used when the router gives nothing usable.
    var speed: Double {
        switch self {
        case .walk: return 1.39        // 5 km/h
        case .bike: return 5.0         // 18 km/h
        case .drive: return 13.9       // 50 km/h
        case .cruise: return 22.2      // 80 km/h
        }
    }

    /// GPS error radius in metres. Walking gets the most, because a pedestrian's
    /// fix wanders far more than a car's.
    var jitterRadius: Double {
        switch self {
        case .walk: return 2.6
        case .bike: return 2.0
        case .drive: return 1.4
        case .cruise: return 1.1
        }
    }

    /// ±fraction applied to the target speed every tick.
    var speedWobble: ClosedRange<Double> {
        switch self {
        case .walk: return 0.84...1.14
        case .bike: return 0.90...1.10
        case .drive: return 0.93...1.07
        case .cruise: return 0.97...1.03
        }
    }

    /// Pedestrian micro-pauses: probability per minute of stopping for 2–6 s.
    var pausesPerMinute: Double {
        self == .walk ? 0.7 : 0
    }

    /// Accel / decel in m/s² for the free-movement integrator.
    var acceleration: (up: Double, down: Double) {
        switch self {
        case .walk: return (0.9, 1.4)
        case .bike: return (1.4, 2.0)
        case .drive, .cruise: return (2.5, 3.5)
        }
    }

    /// Whether road speed limits should drive the pacing.
    var obeysSpeedLimits: Bool {
        self == .drive || self == .cruise
    }

    /// Slider bounds in km/h.
    var speedRange: ClosedRange<Double> {
        switch self {
        case .walk: return 1...8
        case .bike: return 5...35
        case .drive: return 10...130
        case .cruise: return 10...160
        }
    }

    var defaultSpeedKmh: Double { speed * 3.6 }
}
