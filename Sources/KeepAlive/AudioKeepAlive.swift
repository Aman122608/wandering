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

    private func scheduleSilence(format: AVAudioFormat) {
        let frames = AVAudioFrameCount(max(format.sampleRate, 8_000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
    }

    // MARK: - Health

    private func tick() {
        guard running else { return }
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
