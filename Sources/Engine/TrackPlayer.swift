import CoreLocation
import Foundation

/// Plays a coordinate stream into a `LocationSink`, then holds the last point.
///
/// Design notes that matter in the field:
/// * writes are serialised (one in flight, ever) — the developer service refuses
///   a second write while one is outstanding, and a refusal is silently dropped;
/// * a pause sends nothing at all, because a still device that keeps receiving
///   the same coordinate looks frozen;
/// * the final position is re-asserted every few seconds, otherwise iOS re-queries
///   and the fix drifts back to the real GPS.
@MainActor
final class TrackPlayer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case playing
        case paused
        case holding
        case failed(String)

        var isActive: Bool {
            switch self {
            case .playing, .paused, .holding: return true
            case .idle, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .playing: return "Moving"
            case .paused: return "Paused"
            case .holding: return "Holding"
            case .failed: return "Failed"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: CLLocationCoordinate2D?
    @Published private(set) var writtenCount = 0
    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var lastError: String?

    /// Playback rate multiplier: 1 = real time, 4 = four times faster.
    @Published var rate: Double = 1.0

    /// Called when a write fails. Returning true means the transport recovered and
    /// the same sample should be retried; false lets the failure counter climb.
    /// Supplied by the app: waits for one audio buffer, so the playback clock keeps
    /// running while the app is backgrounded.
    var audioTick: (() async -> Void)?
    var audioTickPeriod: Double = 0

    var onWriteFailure: (@MainActor (Error) async -> Bool)?
    /// Fired after every successful write, so the supervisor knows the stream is alive.
    var onWriteSuccess: (@MainActor (CLLocationCoordinate2D) -> Void)?

    private var sink: LocationSink?
    private var task: Task<Void, Never>?
    private var pauseFlag = false
    private var stopFlag = false

    var isBusy: Bool { phase.isActive }

    // MARK: - Control

    func play(samples: [TrackSample], sink: LocationSink, rate: Double = 1.0,
              holdAtEnd: Bool = true) {
        // A second start while one is running used to interleave two streams
        // and produce the play/stop churn seen in the logs.
        if phase.isActive {
            DiagLog.shared.log("play: another playback was already running — "
                               + "replacing it")
            stop(clear: false)
        }
        stop(clear: false)
        guard !samples.isEmpty else { return }
        self.sink = sink
        self.rate = max(rate, 0.1)
        pauseFlag = false
        stopFlag = false
        progress = 0
        writtenCount = 0
        speedKmh = 0
        lastError = nil
        phase = .playing

        let start = Date()
        task = Task { [weak self] in
            guard let self else { return }
            await sink.beginStreaming()
            var failures = 0
            var previous = samples.first?.coordinate
            var index = 0

            while index < samples.count {
                if self.stopFlag || Task.isCancelled { return }
                if self.pauseFlag {
                    await self.slice(0.2)
                    continue
                }
                let sample = samples[index]
                if index > 0 {
                    await self.slice(sample.delay / self.rate)
                    if self.stopFlag || Task.isCancelled { return }
                }
                var wrote = false
                var lastFailure: Error?
                for attempt in 0..<3 {
                    do {
                        try await sink.setLocation(latitude: sample.coordinate.latitude,
                                                   longitude: sample.coordinate.longitude)
                        wrote = true
                        failures = 0
                        break
                    } catch {
                        lastFailure = error
                        failures += 1
                        self.lastError = error.localizedDescription
                        DiagLog.shared.note("write failed (\(failures), attempt \(attempt + 1)): "
                            + error.localizedDescription)
                        // Ask the supervisor to rebuild the tunnel before retrying.
                        if attempt < 2, let recover = self.onWriteFailure,
                           await recover(error) {
                            continue
                        }
                        try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
                    }
                }
                guard wrote else {
                    if failures >= 4 {
                        self.phase = .failed(lastFailure?.localizedDescription
                                             ?? "device stopped accepting writes")
                        return
                    }
                    index += 1
                    continue
                }

                self.onWriteSuccess?(sample.coordinate)

                if let previous {
                    let d = Geo.distance(previous, sample.coordinate)
                    let dt = max(sample.delay, 0.05)
                    self.speedKmh = d / dt * 3.6
                }
                previous = sample.coordinate
                self.current = sample.coordinate
                self.writtenCount += 1
                self.progress = Double(index + 1) / Double(samples.count)
                index += 1
            }

            let elapsed = Date().timeIntervalSince(start)
            DiagLog.shared.note("track finished: \(samples.count) writes in "
                + String(format: "%.1f", elapsed) + "s")

            await sink.endStreaming()

            guard holdAtEnd, let anchor = samples.last?.coordinate,
                  !self.stopFlag else {
                self.phase = .idle
                return
            }
            // Parked. No re-sends: the device keeps a simulated location until it is
            // cleared or the device reboots, so the tunnel can stay closed here. The
            // supervisor watches the phone's own fix and re-asserts only if it drifts.
            self.phase = .holding
            self.current = anchor
            DiagLog.shared.note("track finished: parked at "
                + String(format: "%.5f", anchor.latitude) + ", "
                + String(format: "%.5f", anchor.longitude))
            // Stay here for real: re-send on a slow cadence so the parked point survives
            // iOS re-checks, and stop only when the user stops.
            await sink.hold(at: anchor)
            while !self.stopFlag && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Send one coordinate and stay there (a teleport).
    func teleport(to coordinate: CLLocationCoordinate2D, sink: LocationSink,
                  holdAtEnd: Bool = true) {
        let samples = [TrackSample(coordinate: coordinate, delay: 0)]
        play(samples: samples, sink: sink, rate: 1, holdAtEnd: holdAtEnd)
    }

    /// Re-send the current coordinate right now — used when the fix drifts back
    /// to the real GPS, or after the transport has been rebuilt.
    func reassert() {
        guard phase.isActive, let coordinate = current, let sink else { return }
        Task {
            try? await sink.setLocation(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude)
            DiagLog.shared.note("re-asserted \(String(format: "%.5f", coordinate.latitude)), "
                + "\(String(format: "%.5f", coordinate.longitude))")
        }
    }

    func pause() {
        guard phase == .playing || phase == .holding else { return }
        pauseFlag = true
        if phase == .playing { phase = .paused }
        DiagLog.shared.note("pause")
    }

    func resume() {
        guard phase == .paused else { return }
        pauseFlag = false
        phase = .playing
        DiagLog.shared.note("resume")
    }

    func stop(clear: Bool = false) {
        stopFlag = true
        task?.cancel()
        task = nil
        pauseFlag = false
        let sink = self.sink
        self.sink = nil
        if let sink, clear { Task { await sink.endStreaming() } }
        phase = .idle
        progress = 0
        speedKmh = 0
        if clear, let sink {
            Task { try? await sink.clearLocation() }
            DiagLog.shared.note("stop + clear")
        } else if sink != nil {
            DiagLog.shared.note("stop (device keeps last coordinate until it is cleared)")
        }
    }

    func slideToError(_ message: String) {
        phase = .failed(message)
    }

    // MARK: - Timing

    /// Sleeps in slices so pause/stop react within ~150 ms even on a 5 s hold tick.
    private func slice(_ interval: TimeInterval) async {
        var remaining = max(interval, 0)
        while remaining > 0 {
            if stopFlag || Task.isCancelled { return }
            if pauseFlag {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            if let audioTick, audioTickPeriod > 0 {
                // Advance by real audio time, not by a sleep the suspension can eat.
                await audioTick()
                remaining -= audioTickPeriod
            } else {
                let step = min(remaining, 0.15)
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                remaining -= step
            }
        }
    }
}
