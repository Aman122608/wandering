import AVFoundation
import Foundation

/// Keeps the process alive with silent audio.
///
/// The `audio` background mode grants nothing on its own — iOS keeps the app
/// running only while an audio session is genuinely rendering. So this plays one
/// second of zero-filled PCM on a loop forever, and re-asserts the graph every
/// couple of seconds because calls, Siri, and route changes (AirPods, CarPlay)
/// silently kill it without any error.
@MainActor
final class AudioKeepAlive: ObservableObject {

    enum Health: String {
        case off = "off"
        case running = "audio alive"
        case broken = "audio broken"
    }

    @Published private(set) var health: Health = .off

    /// One silent buffer's length, and the tick the movement loop can follow.
    ///
    /// `Task.sleep` stops counting the moment iOS suspends the process, which is why a
    /// route froze as soon as the app went to the background. A player-node completion
    /// keeps firing while the audio session is playing — that is the whole point of the
    /// silent loop — so the playback clock is taken from there instead.
    static let tickPeriod: Double = 0.25

    /// Set by the movement loop: `await nextTick()` returns once per buffer.
    private var tickContinuation: CheckedContinuation<Void, Never>?
    var onTick: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var attached = false
    private var unhealthyTicks = 0
    private var rebuildAttempts = 0
    private var running = false

    // MARK: - Control

    func start() {
        guard !running else { return }
        running = true
        DiagLog.shared.note("audio keep-alive: start")
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        health = .off
        engine.stop()
        if attached { engine.detach(player); attached = false }
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: [.notifyOthersOnDeactivation])
        DiagLog.shared.note("audio keep-alive: stop")
    }

    // MARK: - Graph

    private func build() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            if !attached {
                engine.attach(player)
                attached = true
            }
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try session.setActive(true)
            try engine.start()
            scheduleSilence(format: format)
            player.play()
            health = .running
            unhealthyTicks = 0
            DiagLog.shared.note("audio keep-alive: engine started "
                + "\(Int(format.sampleRate)) Hz")
        } catch {
            health = .broken
            DiagLog.shared.note("audio keep-alive: build failed — \(error.localizedDescription)")
        }
    }

    /// Suspends until the audio graph has played one more buffer.
    /// Returns true when it really waited for a buffer. False means there is no clock
    /// right now, so the caller must fall back to a sleep — returning instantly would
    /// turn the movement loop into a busy spin.
    @discardableResult
    func nextTick() async -> Bool {
        guard running, engine.isRunning, player.isPlaying else { return false }
        await withCheckedContinuation { continuation in
            tickContinuation = continuation
        }
        return true
    }

    private func scheduleSilence(format: AVAudioFormat) {
        let frames = AVAudioFrameCount(max(format.sampleRate * Self.tickPeriod, 2_048))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        // No `.loops`: each completion is a tick, and scheduling the next buffer from
        // inside it is what turns the silent loop into a background-capable clock.
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.scheduleSilence(format: format)
                self.onTick?()
                self.tickContinuation?.resume()
                self.tickContinuation = nil
            }
        }
    }

    // MARK: - Health

    private func tick() {
        guard running else { return }
        // If a completion never arrives (interrupted route, graph rebuild), release the
        // playback loop anyway — it advances in 2 s steps rather than freezing.
        if let pending = tickContinuation {
            tickContinuation = nil
            pending.resume()
        }
        let playing = player.isPlaying
        let engineRunning = engine.isRunning
        if playing && engineRunning {
            health = .running
            unhealthyTicks = 0
            rebuildAttempts = 0
            return
        }

        unhealthyTicks += 1
        DiagLog.shared.note("audio keep-alive: unhealthy tick \(unhealthyTicks) "
            + "(playing=\(playing) engine=\(engineRunning))")
        // Cheap recovery first: re-activate the session and resume.
        if let session = try? AVAudioSession.sharedInstance() {
            try? session.setActive(true)
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }

        if unhealthyTicks >= 3 {
            health = .broken
            guard rebuildAttempts < 3 else { return }
            rebuildAttempts += 1
            DiagLog.shared.note("audio keep-alive: rebuilding graph (attempt \(rebuildAttempts))")
            engine.stop()
            if attached { engine.detach(player); attached = false }
            build()
        }
    }
}
