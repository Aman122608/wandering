import CoreLocation
import Foundation
import Network
import UIKit

/// Starts a session without Wi-Fi, the way the paid apps do it: airplane mode on,
/// tunnel already up, teleport, airplane mode off.
///
/// Why this exists: with the radios off there is no network path for iOS to
/// re-resolve location from, so the first fix after the sequence comes from the
/// simulated location instead of a cached network fix. Shortcuts is the only way
/// to flip Airplane Mode — iOS exposes no API for it — so the app drives two
/// user-created Shortcuts and verifies each step itself.
///
/// The tunnel here belongs to LocalDevVPN, which we cannot start (it is another
/// app's configuration), so the sequence asks you to connect it once and then
/// waits for it rather than pretending to do it.
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

    private let monitor = NWPathMonitor()
    private var monitorStarted = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkAvailable = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.aman.wandering.path"))
        monitorStarted = true
    }

    deinit {
        if monitorStarted { monitor.cancel() }
    }

    /// `move` is what actually injects — a teleport or a route start.
    func run(target: CLLocationCoordinate2D?,
             shortcutOn: String,
             shortcutOff: String,
             connect: @escaping () async throws -> Void,
             move: @escaping () async -> Void) async {
        guard !phase.isRunning else { return }

        do {
            phase = .waitingForTunnel
            detail = "Connecting the tunnel first — it must be up before the radios go off."
            do {
                try await connect()
            } catch {
                throw SequenceError.message(
                    "Connect LocalDevVPN, then retry: \(error.localizedDescription)")
            }

            phase = .airplaneOn
            detail = "Running “\(shortcutOn)”."
            openShortcut(named: shortcutOn)
            let wentOffline = await waitForNetwork(false, timeout: 25)
            if !wentOffline {
                detail = "Airplane Mode did not engage — continuing anyway."
            }

            phase = .waitingForTunnel
            detail = "Checking the tunnel still answers with the radios off."
            let tunnelAlive = await waitForTunnel(timeout: 20)
            guard tunnelAlive else {
                throw SequenceError.message(
                    "The tunnel stopped answering once the radios went off. "
                    + "Reconnect LocalDevVPN and try again.")
            }

            phase = .moving
            detail = target.map { "Setting \(Router.format($0))." } ?? "Starting the route."
            await move()

            phase = .airplaneOff
            detail = "Running “\(shortcutOff)”."
            openShortcut(named: shortcutOff)

            phase = .restoring
            detail = "Waiting for a radio to come back (up to 25 s)."
            let back = await waitForNetwork(true, timeout: 25)
            phase = .finished
            detail = back
                ? "Radios are back. Session is live."
                : "Network did not return — turn Airplane Mode off yourself."
        } catch let error as SequenceError {
            phase = .failed(error.message)
            detail = error.message
            DiagLog.shared.note("airplane sequence failed: \(error.message)")
            // Always try to restore the radios, even on failure.
            openShortcut(named: shortcutOff)
        } catch {
            phase = .failed(error.localizedDescription)
            openShortcut(named: shortcutOff)
        }
        DiagLog.shared.note("airplane sequence: \(phase.label)")
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

    private func openShortcut(named name: String) {
        guard !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func waitForNetwork(_ wantAvailable: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if networkAvailable == wantAvailable { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return networkAvailable == wantAvailable
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
