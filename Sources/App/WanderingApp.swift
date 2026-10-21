import SwiftUI

@main
struct WanderingApp: App {
    @StateObject private var state = AppState()
    @StateObject private var audio = AudioKeepAlive()
    @StateObject private var location = LocationKeepAlive()

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(state)
                .environmentObject(location)
                .task {
                    // Ask once, early: background location needs authorisation
                    // before the first session, not during it.
                    location.requestPermission()
                    state.session.refreshPairings()
                    state.player.audioTick = { [weak audio] in
                        let waited = await audio?.nextTick() ?? false
                        if !waited {
                            try? await Task.sleep(
                                nanoseconds: UInt64(AudioKeepAlive.tickPeriod * 1_000_000_000))
                        }
                    }
                    state.player.audioTickPeriod = AudioKeepAlive.tickPeriod
                    state.chaser.audioTick = { [weak audio] in
                        let waited = await audio?.nextTick() ?? false
                        if !waited {
                            try? await Task.sleep(
                                nanoseconds: UInt64(AudioKeepAlive.tickPeriod * 1_000_000_000))
                        }
                    }
                    state.chaser.audioTickPeriod = AudioKeepAlive.tickPeriod
                    audio.onTick = nil
                    state.session.fixProbe = { [weak location] in
                        (location?.lastCoordinate, location?.lastFix)
                    }
                    await state.autoResumeIfNeeded()
                    DiagLog.shared.note("app ready · pairing file "
                        + (PairingStore.current == nil ? "missing" : "present"))
                }
                .onReceive(location.$lastCoordinate) { fix in
                    if let fix { state.supervisor.observeRealFix(fix) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        state.airplane.flushPendingRestore()
                        state.resumeAfterForeground()
                    }
                }
                .onReceive(state.player.$phase) { phase in
                    if phase.isActive || state.chaser.isRunning {
                        if keepAliveAudio { audio.start() }
                        if keepAliveLocation { location.start() }
                    } else {
                        audio.stop()
                        location.stop()
                    }
                }
                .onReceive(state.chaser.$isRunning) { running in
                    if running {
                        if keepAliveAudio { audio.start() }
                        if keepAliveLocation { location.start() }
                    } else if !state.player.phase.isActive {
                        audio.stop()
                        location.stop()
                    }
                }
        }
    }
}
