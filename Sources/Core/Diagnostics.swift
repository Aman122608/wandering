import Foundation

/// In-memory activity log mirrored to Documents/WanderingLogs.
/// Everything the transport does goes through here, so a failed session can be
/// diagnosed from the app alone — no cable, no Xcode.
@MainActor
final class DiagLog: ObservableObject {
    static let shared = DiagLog()

    @Published private(set) var lines: [String] = []

    private var handle: FileHandle?
    private var written: UInt64 = 0
    private let cap: UInt64 = 2 * 1024 * 1024
    private let maxLines = 600

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        prepare()
        note("session start · \(Self.deviceLine)")
    }

    static var deviceLine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WanderingLogs", isDirectory: true)
    }

    var currentFile: URL? { handle.map { _ in logURL } }
    private var logURL: URL = URL(fileURLWithPath: "/dev/null")

    func note(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }

        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle?.write(data)
        written += UInt64(data.count)
        if written > cap { rotate() }
    }

    func copyBundle() -> String {
        "Wandering diagnostics\n\(Self.deviceLine)\n\n" + lines.joined(separator: "\n")
    }

    private func prepare() {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rotate()
    }

    private func rotate() {
        handle?.closeFile()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        logURL = (directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("session-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        written = 0
        prune()
    }

    private func prune() {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }
        let sorted = files
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db
            }
        for old in sorted.dropFirst(8) { try? FileManager.default.removeItem(at: old) }
    }
}
