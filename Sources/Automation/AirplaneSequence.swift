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

    /// `move` performs the injection (teleport or route start).
    func run(target: CLLocationCoordinate2D?,
             shortcutOn: String,
             shortcutOff: String,
             connect: @escaping () async throws -> Void,
             move: @escaping () async -> Void) async {
        guard !phase.isRunning else { return }

        do {
            phase = .waitingForTunnel
            detail = "Connecting the tunnel first — it has to be up before the radios go off."
            do {
                try await connect()
            } catch {
                throw SequenceError.message(
                    "Connect LocalDevVPN, then retry: \(error.localizedDescription)")
            }

            // With Wi-Fi up there is nothing to gain from dropping the radios, and a
            // cycle would only risk the tunnel. Straight to work.
            if hasWiFi {
                detail = "Wi-Fi is up — skipping the Airplane Mode cycle."
                DiagLog.shared.note("airplane: skipped (Wi-Fi present)")
                phase = .moving
                await move()
                phase = .finished
                detail = "Done (no radio cycle was needed)."
                return
            }

            phase = .airplaneOn
            detail = "Running “\(shortcutOn)”."
            openShortcut(named: shortcutOn, input: "on")
            let wentOffline = await waitForRadiosOff(timeout: 25)
            if !wentOffline {
                detail = "Airplane Mode did not engage — trying the tunnel anyway."
                DiagLog.shared.note("airplane: radios still up after 25s")
            }

            phase = .waitingForTunnel
            detail = "Checking the tunnel still answers with the radios off."
            guard await waitForTunnel(timeout: 20) else {
                throw SequenceError.message(
                    "The tunnel stopped answering once the radios went off. "
                    + "Reconnect LocalDevVPN and try again.")
            }

            phase = .moving
            detail = target.map { "Setting \(Router.format($0))." } ?? "Starting the route."
            await move()

            phase = .airplaneOff
            detail = "Running “\(shortcutOff)”."
            openShortcut(named: shortcutOff, input: "off")

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
            openShortcut(named: shortcutOff, input: "off")
        } catch {
            phase = .failed(error.localizedDescription)
            openShortcut(named: shortcutOff, input: "off")
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
    private func openShortcut(named name: String, input: String) {
        guard !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://x-callback-url/run-shortcut"
                            + "?name=\(encoded)&input=text&text=\(input)"
                            + "&x-success=wandering://airplane-ok"
                            + "&x-error=wandering://airplane-missing") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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

    private func waitForTunnel(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reachable = await Task.detached(priority: .userInitiated) {
                TunnelProbe.discover() != nil
            }.value
            if reachable { return true }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }
}
