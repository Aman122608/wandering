import CoreLocation
import Foundation

/// End-to-end check of the thing that can actually fail: the phone side.
///
/// Each step is the real code path — no mocks — so a pass here means a pass in
/// normal use. It is deliberately ordered from cheapest to most invasive, and it
/// stops on the first failure so the first broken link is the one reported.
@MainActor
final class SelfTestRunner: ObservableObject {

    enum Status: Equatable {
        case pending
        case running
        case passed
        case failed(String)
        case skipped(String)

        var symbol: String {
            switch self {
            case .pending: return "circle"
            case .running: return "circle.dotted"
            case .passed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .skipped: return "minus.circle"
            }
        }
    }

    struct Step: Identifiable {
        let id = UUID()
        var title: String
        var status: Status = .pending
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finishedAt: Date?

    func run(session: DeviceSession, target: CLLocationCoordinate2D?) async {
        guard !isRunning else { return }
        isRunning = true
        finishedAt = nil
        steps = [
            Step(title: "Pairing file imported"),
            Step(title: "Device tunnel reachable"),
            Step(title: "Remote pairing accepted (RSD)"),
            Step(title: "Developer Mode on · disk image mounted"),
            Step(title: "Location write accepted"),
            Step(title: "Clear accepted (real GPS back)"),
        ]

        do {
            // 1. pairing
            try set(0, .running)
            guard PairingStore.current != nil else {
                return fail(0, "No pairing file — Settings → Import pairing files")
            }
            steps[0].status = .passed

            // 2. tunnel
            try set(1, .running)
            let endpoint = await Task.detached(priority: .userInitiated) {
                TunnelProbe.discover()
            }.value
            guard let endpoint else {
                return fail(1, "Nothing answered on port \(TunnelProbe.developerPort). "
                            + "Is LocalDevVPN connected?")
            }
            steps[1].status = .passed

            // 3. connect (pair-verify, TLS-PSK, RSD, DTX)
            try set(2, .running)
            session.disconnect()
            await session.connect()
            guard session.connection.isReady else {
                return fail(2, session.connection.label)
            }
            steps[2].status = .passed

            // 4. developer services
            try set(3, .running)
            guard session.developerModeEnabled else {
                return fail(3, "Developer Mode is off on the phone (Settings → Privacy & Security)")
            }
            guard session.diskImageMounted else {
                return fail(3, "The disk image did not mount — see the log for the reason")
            }
            steps[3].status = .passed

            // 5. write
            let coordinate = target ?? Defaults.resumeTarget
                ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            try set(4, .running)
            do {
                try await session.setLocation(latitude: coordinate.latitude,
                                              longitude: coordinate.longitude)
                steps[4].status = .passed
            } catch {
                return fail(4, error.localizedDescription)
            }

            // 6. clear
            try set(5, .running)
            do {
                try await session.clearLocation()
                steps[5].status = .passed
            } catch {
                return fail(5, error.localizedDescription)
            }

            DiagLog.shared.note("self-test: all steps passed")
        } catch {
            DiagLog.shared.note("self-test aborted: \(error.localizedDescription)")
        }
        isRunning = false
        finishedAt = Date()
    }

    private func set(_ index: Int, _ status: Status) throws {
        guard steps.indices.contains(index) else { return }
        steps[index].status = status
    }

    private func fail(_ index: Int, _ message: String) {
        guard steps.indices.contains(index) else { return }
        steps[index].status = .failed(message)
        for later in steps.indices where later > index {
            steps[later].status = .skipped("Not reached")
        }
        DiagLog.shared.note("self-test failed at step \(index + 1): \(message)")
        isRunning = false
        finishedAt = Date()
    }
}
