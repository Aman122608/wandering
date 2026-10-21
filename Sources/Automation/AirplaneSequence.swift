import CoreLocation
import Foundation
import Network
import UIKit

/// Starts a session without Wi-Fi, the way the paid apps do it: airplane mode on,
/// tunnel already up, set the location, airplane mode off.
///
/// Why this exists: with the radios off there is no network path for iOS to
/// re-resolve a location from, so the first fix after the sequence comes from the
/// simulated location instead of a cached Wi-Fi fix.
///
/// Shortcuts is the only way to flip Airplane Mode (iOS exposes no API), so the app
/// drives a Shortcut and verifies the outcome itself instead of trusting it. The
/// tunnel belongs to LocalDevVPN, which we cannot start, so the sequence waits for
/// it rather than pretending to.
@MainActor
final class AirplaneSequence: ObservableObject {

    enum Phase: Equatable {
        case idle
        case airplaneOn
        case waitingForTunnel
        case moving
        case airplaneOff
        case restoring
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .airplaneOn: return "Turning Airplane Mode on"
            case .waitingForTunnel: return "Waiting for the tunnel"
            case .moving: return "Setting the location"
            case .airplaneOff: return "Turning Airplane Mode off"
            case .restoring: return "Waiting for the network"
            case .finished: return "Done"
            case .failed(let why): return "Failed · \(why)"
            }
        }

        var isRunning: Bool {
            switch self {
            case .airplaneOn, .waitingForTunnel, .moving, .airplaneOff, .restoring:
                return true
            case .idle, .finished, .failed:
                return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detail = ""
    @Published private(set) var networkAvailable = true
    @Published private(set) var hasWiFi = false
    @Published private(set) var onCellular = false

    private let monitor = NWPathMonitor()
    private var monitorStarted = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkAvailable = path.status == .satisfied
                self?.hasWiFi = path.usesInterfaceType(.wifi)
                self?.onCellular = path.usesInterfaceType(.cellular)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.aman.wandering.path"))
        monitorStarted = true
    }

    deinit {
        if monitorStarted { monitor.cancel() }
    }

    /// How the radio is toggled.
    enum ShortcutStyle: String, CaseIterable, Identifiable {
        /// One Shortcut that flips the radio from its input text — the shape the
        /// paid app ships ("Wander Cellular Mode", input `on` / `off`), so an
        /// already-installed file can be reused as-is.
        case singleSwitch
        /// Two separate Shortcuts, one per state.
        case twoShortcuts

        var id: String { rawValue }
        var title: String { self == .singleSwitch ? "One Shortcut" : "Two Shortcuts" }
    }

    /// Remembers what to send when a run is cut short.
    /// A restore leg that could not be sent because the app was not in the foreground.
    /// `UIApplication.open` fails silently from the background, which left the radio off —
    /// that is the "finicky" part of cellular mode.
    private var pendingRestore = false

    private var lastStyle: ShortcutStyle = .singleSwitch
    private var lastOn = ""
    private var lastOff = ""

    /// The radio came back underneath us (the user left Airplane Mode, or Wi-Fi
    /// returned). Send the restore leg and stop claiming the run is in progress.
    func finishEarly() {
        guard phase.isRunning else { return }
        DiagLog.shared.note("airplane: radio returned — finishing the cellular run")
        openShortcut(style: lastStyle, on: lastOn, off: lastOff, input: "off")
        phase = .finished
        detail = "Stopped — the radio came back."
    }

    /// `move` performs the injection (teleport or route start).
    ///
    /// Order copied from the shipping app, which is the opposite of what intuition says:
    /// the radio goes quiet FIRST, and only then is the tunnel dialled. Dialling while the
    /// radio is still up gets refused, and dialling before the cycle leaves nothing for the
    /// quiet period to protect — the tunnel is built inside it.
    func run(target: CLLocationCoordinate2D?,
             style: ShortcutStyle,
             shortcutOn: String,
             shortcutOff: String,
             connect: @escaping () async throws -> Void,
             move: @escaping () async -> Void) async {
        guard !phase.isRunning else { return }
        lastStyle = style
        lastOn = shortcutOn
        lastOff = shortcutOff

        do {
            // With Wi-Fi up there is nothing to gain from dropping the radios.
            if hasWiFi {
                phase = .waitingForTunnel
                detail = "Wi-Fi is up — connecting directly."
                DiagLog.shared.note("airplane: skipped (Wi-Fi present)")
                try await connect()
                phase = .moving
                await move()
                phase = .finished
                detail = "Done (no radio cycle was needed)."
                return
            }

            // Step 1: radio off.
            phase = .airplaneOn
            detail = "Running “\(shortcutOn)”."
            openShortcut(style: style, on: shortcutOn, off: shortcutOff, input: "on")

            // 8 s, like the shipping app: dropping interfaces is fast, and every extra
            // second here is signal lost for nothing.
            let quiet = await waitForRadiosOff(timeout: 8)
            if quiet {
                DiagLog.shared.note("airplane: radio confirmed off — building the tunnel inside it")
            } else {
                throw SequenceError.message(
                    "Airplane Mode did not switch on. “\(shortcutOn)” may be missing, "
                    + "renamed, or was cancelled. Nothing was turned off, so nothing "
                    + "needs turning back on — set the shortcut up and try again.")
            }

            // Step 2: build the tunnel now that the radio is quiet.
            phase = .waitingForTunnel
            var connected = false
            var lastError = ""
            for attempt in 1...6 {
                detail = "Connecting the tunnel with the radio off (attempt \(attempt))."
                do {
                    try await connect()
                    connected = true
                    DiagLog.shared.note("airplane: tunnel up on attempt \(attempt)")
                    break
                } catch {
                    lastError = error.localizedDescription
                    DiagLog.shared.note("airplane: connect attempt \(attempt) failed — \(lastError)")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            guard connected else {
                throw SequenceError.message(
                    "The tunnel would not come up with the radio off. Check that "
                    + "LocalDevVPN is installed and allowed to run in the background. "
                    + "(\(lastError))")
            }

            // Step 3: write, then put the radio back — always, even if the write failed.
            phase = .moving
            detail = target.map { "Setting \(Router.format($0))." } ?? "Starting the route."
            await move()

            phase = .airplaneOff
            detail = "Running “\(shortcutOff)”."
            openShortcut(style: style, on: shortcutOn, off: shortcutOff, input: "off")

            phase = .restoring
            detail = "Waiting for a radio to come back (up to 25 s — modem re-attach is slow)."
            let back = await waitForNetwork(timeout: 25)
            phase = .finished
            detail = back
                ? "Radios are back. Session is live."
                : "Network did not return — turn Airplane Mode off yourself."
        } catch let error as SequenceError {
            phase = .failed(error.message)
            detail = error.message
            DiagLog.shared.note("airplane: failed — \(error.message)")
            openShortcut(style: style, on: shortcutOn, off: shortcutOff, input: "off")
        } catch {
            phase = .failed(error.localizedDescription)
            openShortcut(style: style, on: shortcutOn, off: shortcutOff, input: "off")
        }
        DiagLog.shared.note("airplane: \(phase.label)")
    }

    func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
        detail = ""
    }

    // MARK: - Steps

    private enum SequenceError: Error {
        case message(String)
        var message: String {
            if case .message(let text) = self { return text }
            return "unknown"
        }
    }

    /// Runs the shortcut through Shortcuts' x-callback scheme. The callback is not
    /// required for the sequence to work — the radios themselves are the evidence —
    /// but it makes the Shortcut able to report back later.
    /// Send the restore leg as soon as the app is in the foreground.
    func flushPendingRestore() {
        guard pendingRestore else { return }
        pendingRestore = false
        DiagLog.shared.note("airplane: app is active again — sending the restore leg")
        openShortcut(style: lastStyle, on: lastOn, off: lastOff, input: "off")
    }

    private func openShortcut(style: ShortcutStyle, on: String, off: String, input: String) {
        // A shortcut can only be opened from the foreground. Queueing beats pretending it
        // ran and leaving the radio off.
        guard UIApplication.shared.applicationState == .active else {
            if input == "off" {
                pendingRestore = true
                DiagLog.shared.log("airplane: restore queued (app is not in the foreground)")
            } else {
                DiagLog.shared.log("airplane: not sent — app is not in the foreground")
            }
            return
        }
        let name = style == .singleSwitch ? on : (input == "on" ? on : off)
        guard !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://x-callback-url/run-shortcut"
                            + "?name=\(encoded)&input=text&text=\(input)"
                            + "&x-success=wandering://airplane-ok"
                            + "&x-error=wandering://airplane-missing") else { return }
        DiagLog.shared.note("airplane: running Shortcut \"\(name)\" with input \(input)")
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                DiagLog.shared.log("airplane: Shortcuts refused to open \"\(name)\"")
            }
        }
    }

    private func waitForNetwork(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if networkAvailable { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return networkAvailable
    }

    private func waitForRadiosOff(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !hasWiFi && !onCellular { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !hasWiFi && !onCellular
    }

    /// Waits for the tunnel to answer again after the radio comes back down, retrying
    /// rather than sampling once — LocalDevVPN needs a moment to reinstall its route.
    private func waitForTunnel(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let reachable = await Task.detached(priority: .userInitiated) {
                TunnelProbe.discover() != nil
            }.value
            if reachable {
                DiagLog.shared.note("airplane: tunnel answered on attempt \(attempt)")
                return true
            }
            DiagLog.shared.note("airplane: tunnel silent (attempt \(attempt)) — retrying")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return false
    }
}
