import Foundation

/// Download and cache the personalised developer disk image.
///
/// The image is what makes `com.apple.instruments…` exist on the device, so
/// without it there is no location service to talk to. Payloads come from the
/// public doronz88/DeveloperDiskImage mirror, which publishes fixed filenames —
/// the personalised set for iOS 17 and newer, and per-version folders before that.
enum DeveloperDiskImage {

    struct Assets {
        var image: Data
        var trustCache: Data
        var manifest: Data
    }

    enum DDIError: LocalizedError {
        case unsupportedVersion(String)
        case downloadFailed(String, Int)
        case missingPayload(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "No disk image published for iOS \(v) — attach a Mac once, or mount it externally."
            case .downloadFailed(let file, let code):
                return "Download failed for \(file) (HTTP \(code))."
            case .missingPayload(let file):
                return "Disk image payload \(file) is empty."
            }
        }
    }

    private static let personalisedBase =
        "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/"

    private static var cacheRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DDI", isDirectory: true)
    }

    /// iOS 17 and newer: one personalised set, personalised per device at mount time.
    static func assets(for version: String,
                       progress: ((String, Double) -> Void)? = nil) async throws -> Assets {
        guard let major = Int(version.split(separator: ".").first ?? "0"), major >= 17 else {
            throw DDIError.unsupportedVersion(version)
        }
        let directory = try cacheDirectory(for: "personalised")

        let image = try await fetch("Image.dmg", into: directory, progress: progress)
        let trust = try await fetch("Image.dmg.trustcache", into: directory, progress: progress)
        let manifest = try await fetch("BuildManifest.plist", into: directory, progress: progress)
        return Assets(image: image, trustCache: trust, manifest: manifest)
    }

    // MARK: - Files

    private static func cacheDirectory(for folder: String) throws -> URL {
        guard let root = cacheRoot else {
            throw DDIError.downloadFailed("cache", 0)
        }
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fetch(_ name: String, into directory: URL,
                              progress: ((String, Double) -> Void)?) async throws -> Data {
        let local = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: local), !data.isEmpty {
            progress?(name, 1)
            return data
        }

        guard let url = URL(string: personalisedBase + name) else {
            throw DDIError.downloadFailed(name, 0)
        }
        progress?(name, 0.1)
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DDIError.downloadFailed(name, http.statusCode)
        }
        guard !data.isEmpty else { throw DDIError.missingPayload(name) }
        try? data.write(to: local, options: .atomic)
        progress?(name, 1)
        return data
    }
}
