import SwiftUI

@main
struct WanderingApp: App {
    @StateObject private var state = AppState()
    @StateObject private var audio = AudioKeepAlive()
    @StateObject private var location = LocationKeepAlive()

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(state)
                .task {
                    // Ask once, early: background location needs authorisation
                    // before the first session, not during it.
                    location.requestPermission()
                    DiagLog.shared.note("app ready · pairing file "
                        + (PairingStore.current == nil ? "missing" : "present"))
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
