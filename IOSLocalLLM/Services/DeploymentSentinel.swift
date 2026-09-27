import Foundation

// MARK: - DeploymentSentinel
//
// Developer-only persistence probe. Write it from build A, install build B
// as an UPDATE, then check: a missing sentinel proves the installer deleted
// the app container (which is also what removes downloaded models).
// Never written automatically; only the Diagnostics screen triggers it.

enum DeploymentSentinel {
    static let fileName = "deployment-persistence-test.txt"

    static var url: URL {
        ModelStoragePaths.documents.appendingPathComponent(fileName)
    }

    /// Writes the sentinel and returns a human-readable description.
    @discardableResult
    static func write() -> String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "?"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "?"
        let text = "written \(ISO8601DateFormatter().string(from: Date()))"
            + " · build \(version) (\(build))"
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return text
        } catch {
            return "write failed: \(ModelStoragePathError.describeFailure(path: fileName, error: error))"
        }
    }

    /// Returns the sentinel contents, or nil when the container lost it.
    static func read() -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
