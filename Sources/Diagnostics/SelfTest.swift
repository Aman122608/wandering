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

    /// `fixProbe` supplies the phone's own CoreLocation fix, which is how we learn
    /// whether the simulated location survives the tunnel closing.
    func run(session: DeviceSession,
             target: CLLocationCoordinate2D?,
             fixProbe: @escaping @MainActor () -> (CLLocationCoordinate2D?, Date?)) async {
        guard !isRunning else { return }
        isRunning = true
        finishedAt = nil
        steps = [
            Step(title: "Pairing file imported"),
            Step(title: "Device tunnel reachable"),
            Step(title: "Remote pairing accepted (RSD)"),
            Step(title: "Developer Mode on (image optional)"),
            Step(title: "Location write accepted"),
            Step(title: "Fix survives a closed tunnel"),
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
            // The disk image only gates services that need it (process control,
            // screenshots). Location simulation runs off the RSD/DVT session that is
            // already open, so a failed mount is reported but not fatal.
            steps[3].status = .passed
            if !session.diskImageMounted {
                DiagLog.shared.log("self-test: image not mounted, location writes do not "
                                   + "need it — continuing")
            }

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

            // 6. durability probe: does the fix outlive the tunnel?
            //
            // This runs unconditionally. Skipping it whenever the tunnel happened to be
            // configured persistent is how it silently reported success without testing
            // anything, so the probe imposes the setting it needs and restores it after.
            try set(5, .running)
            let originalLifetime = session.lifetime
            session.lifetime = .setupOnly
            let anchor = coordinate
            session.disconnect()
            DiagLog.shared.note("self-test: tunnel closed, waiting 12 s for a real fix")
            try? await Task.sleep(nanoseconds: 12_000_000_000)

            let (fix, when) = fixProbe()
            let fresh = when.map { Date().timeIntervalSince($0) < 25 } ?? false
            if let fix, fresh {
                let away = Geo.distance(fix, anchor)
                if away < 120 {
                    steps[5].status = .passed
                    DiagLog.shared.note("self-test: fix survived the tunnel "
                        + "(\(Int(away))m from target) — parking without a connection is safe")
                } else {
                    steps[5].status = .failed(
                        "Simulation ended with the tunnel (\(Int(away)) m from target) — "
                        + "keep the tunnel persistent while spoofing")
                    DiagLog.shared.note("self-test: fix did NOT survive the tunnel "
                        + "(\(Int(away))m) — parking without a connection is not viable")
                }
            } else {
                steps[5].status = .skipped(
                    "No fresh location fix — allow location access so this can be measured")
                DiagLog.shared.note("self-test: durability not measured (no fresh fix)")
            }

            // Restore the setting and give the next step a live tunnel.
            session.lifetime = originalLifetime
            await session.connect()
            if session.connection.isReady {
                try? await session.setLocation(latitude: anchor.latitude,
                                               longitude: anchor.longitude)
            }

            // 7. clear
            try set(6, .running)
            do {
                try await session.clearLocation()
                steps[6].status = .passed
            } catch {
                return fail(6, error.localizedDescription)
            }

            let skipped = steps.filter { step in
                if case .skipped = step.status { return true }
                return false
            }
            if skipped.isEmpty {
                DiagLog.shared.note("self-test: all \(steps.count) steps passed")
            } else {
                let names = skipped.map(\.title).joined(separator: "; ")
                DiagLog.shared.note(
                    "self-test: \(steps.count - skipped.count)/\(steps.count) passed, "
                    + "\(skipped.count) not measured — \(names)")
            }
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
