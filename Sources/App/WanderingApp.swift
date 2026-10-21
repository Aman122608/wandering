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
                    await state.autoResumeIfNeeded()
                    DiagLog.shared.note("app ready · pairing file "
                        + (PairingStore.current == nil ? "missing" : "present"))
                }
                .onReceive(location.$lastCoordinate) { fix in
                    if let fix { state.supervisor.observeRealFix(fix) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { state.resumeAfterForeground() }
                }
                .onReceive(state.player.$phase) { phase in
                    if phase.isActive {
                        if keepAliveAudio { audio.start() }
                        if keepAliveLocation { location.start() }
                    } else {
                        audio.stop()
                        location.stop()
                    }
                }
        }
    }
}
