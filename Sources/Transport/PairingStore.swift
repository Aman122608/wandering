import Foundation

/// Holds imported RemotePairing files and tracks which one is active.
///
/// You can keep several — one per device, or older copies — and switch without
/// re-importing. Files can arrive two ways: the Files picker, or dropped straight
/// into the app's Documents folder (file sharing is on), which is adopted on launch.
enum PairingStore {

    struct Entry: Identifiable, Equatable {
        let url: URL
        var id: String { url.lastPathComponent }
        var name: String { url.lastPathComponent }
        var size: Int
        var added: Date
        /// The pairing identifier from the plist, if it is readable.
        var identifier: String?

        var subtitle: String {
            var parts: [String] = []
            if let identifier { parts.append(String(identifier.prefix(8))) }
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            parts.append(added.formatted(date: .abbreviated, time: .shortened))
            return parts.joined(separator: " · ")
        }
    }

    private static let activeKey = "pairing.active"
    private static let store = UserDefaults.standard

    // MARK: - Locations

    static var supportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    static var directory: URL? {
        supportDirectory?.appendingPathComponent("PairingFiles", isDirectory: true)
    }

    static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    // MARK: - Inventory

    static func all() -> [Entry] {
        guard let directory else { return [] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { entry(for: $0) }
            .sorted { $0.added > $1.added }
    }

    static func entry(for url: URL) -> Entry? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, size > 0 else { return nil }
        return Entry(url: url,
                     size: size,
                     added: values?.contentModificationDate ?? .distantPast,
                     identifier: identifier(in: url))
    }

    static var activeEntry: Entry? {
        let entries = all()
        guard !entries.isEmpty else { return nil }
        if let name = store.string(forKey: activeKey),
           let match = entries.first(where: { $0.name == name }) {
            return match
        }
        // Nothing chosen yet: exactly one file means it is obviously the one.
        return entries.count == 1 ? entries[0] : entries[0]
    }

    static func setActive(_ entry: Entry) {
        store.set(entry.name, forKey: activeKey)
    }

    /// The path the transport reads. Imported copies live in Application Support.
    static var current: URL? { activeEntry?.url }

    // MARK: - Import

    @discardableResult
    static func importFile(_ source: URL) throws -> Entry {
        guard let directory else {
            throw SinkError.internalFailure("no application support directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A picker URL can point outside the sandbox, or at an iCloud file that has not
        // been materialised yet. Reading it through a coordinator is what makes those
        // two cases work; a plain copyItem fails on both, and fails without a reason.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        DiagLog.shared.log("pairing: reading \(source.lastPathComponent)"
                           + " (scope \(scoped ? "granted" : "not required"))")

        var coordinationError: NSError?
        var failure: Error?
        var stored: Entry?

        NSFileCoordinator().coordinate(readingItemAt: source,
                                       options: [.withoutChanges],
                                       error: &coordinationError) { readable in
            do {
                let name = uniqueName(for: readable.lastPathComponent)
                let destination = directory.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: readable, to: destination)
                } catch {
                    // Different container, or a file iOS has not downloaded: read it.
                    let data = try Data(contentsOf: readable)
                    guard !data.isEmpty else {
                        throw SinkError.internalFailure(
                            "file is empty — is it still downloading from iCloud?")
                    }
                    try data.write(to: destination)
                    DiagLog.shared.log("pairing: copied via read/write fallback (\(data.count) bytes)")
                }
                guard let entry = entry(for: destination) else {
                    throw SinkError.internalFailure("copied file could not be read back")
                }
                setActive(entry)
                DiagLog.shared.log("pairing: imported \(entry.name)"
                    + (entry.identifier.map { " (id \($0.prefix(8)))" } ?? ""))
                stored = entry
            } catch {
                failure = error
            }
        }

        if let stored { return stored }
        if let coordinationError {
            DiagLog.shared.log("pairing: coordinator refused — \(coordinationError.localizedDescription)")
            throw SinkError.internalFailure(coordinationError.localizedDescription)
        }
        throw failure ?? SinkError.internalFailure("import produced no file")
    }

    @discardableResult
    static func importFiles(_ urls: [URL]) -> [Entry] {
        urls.compactMap { url in
            do {
                return try importFile(url)
            } catch {
                DiagLog.shared.log("pairing: import failed for \(url.lastPathComponent) — "
                                   + "\(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Picks up pairing files that were dropped into Documents through the Files app.
    @discardableResult
    static func adoptLooseFiles() -> [Entry] {
        guard let documentsDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var adopted: [Entry] = []
        for url in contents where looksLikePairing(url) {
            guard !all().contains(where: { $0.name == url.lastPathComponent }) else { continue }
            if let entry = try? importFile(url) { adopted.append(entry) }
        }
        return adopted
    }

    static func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        if store.string(forKey: activeKey) == entry.name {
            store.removeObject(forKey: activeKey)
        }
        DiagLog.shared.log("pairing: removed \(entry.name)")
    }

    // MARK: - Helpers

    private static func uniqueName(for name: String) -> String {
        let existing = Set(all().map(\.name))
        guard existing.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    private static func looksLikePairing(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard !url.hasDirectoryPath else { return false }
        if name.hasSuffix(".plist") { return true }
        return name.contains("pairing") || name.contains("rp_pairing")
    }

    private static func identifier(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return nil }

        for key in ["identifier", "Identifier", "UDID", "udid"] {
            if let value = plist[key] as? String { return value }
        }
        // Some copies carry the identifier inside a nested dict or as data.
        for value in plist.values {
            if let text = value as? String, text.count >= 32 {
                return text
            }
        }
        return nil
    }
}
