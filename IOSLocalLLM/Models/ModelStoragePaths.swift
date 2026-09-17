import Foundation

// MARK: - ModelStoragePaths
//
// Canonical app-sandbox locations for downloaded model trees. Every
// subsystem — download destination, installed-model discovery, and runtime
// model resolution — must build these paths from here so a stale, relative,
// or security-scoped URL can never be introduced by one caller.
//
// These are app-owned locations under the sandbox `Documents` directory.
// They must never require `startAccessingSecurityScopedResource()` and must
// never resolve to the filesystem root (`/LLMModels`).

enum ModelStoragePaths {

    /// The app's own sandbox Documents directory.
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `Documents/LLMModels` — canonical root for assistant text models.
    static var llmModels: URL {
        documents.appendingPathComponent("LLMModels", isDirectory: true)
    }

    /// A named model directory under the canonical assistant root.
    static func llmModelDirectory(named name: String) -> URL {
        llmModels.appendingPathComponent(name, isDirectory: true)
    }

    /// Known app-owned model roots, in discovery order. Every root is inside
    /// the sandbox Documents directory.
    static var modelRoots: [URL] {
        let docs = documents
        return [
            llmModels,
            docs.appendingPathComponent("HFModels", isDirectory: true),
            docs.appendingPathComponent("GGUFModels", isDirectory: true),
        ]
    }

    /// Privacy-safe path for diagnostics: strips the sandbox prefix.
    static func sandboxRelativePath(_ url: URL) -> String {
        guard isInsideSandbox(url) else { return "outside-container" }
        let prefix = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(prefix.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    /// Writes and removes a tiny probe file to prove the directory accepts
    /// writes before a multi-GB transfer is allowed to start.
    static func probeWritability(of directory: URL) throws {
        let probe = directory.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        do {
            try Data([0x1]).write(to: probe, options: .atomic)
            _ = try Data(contentsOf: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw ModelStoragePathError.probeFailed(
                path: sandboxRelativePath(directory),
                underlying: error
            )
        }
    }

    /// Last path component of a repo id — the on-disk directory name used by
    /// the download center (`Edge0/Edge0-8B-A1B-preview` → `Edge0-8B-A1B-preview`).
    static func directoryName(forRepoID repoID: String) -> String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }

    /// `/` → `_` form used for legacy/custom scan roots.
    static func flattenedRepoID(_ repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "_")
    }

    /// True when `url` is inside the given sandbox root.
    static func isInside(root: URL, _ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    /// True when `url` is inside the app's Documents sandbox.
    static func isInsideSandbox(_ url: URL) -> Bool {
        isInside(root: documents, url)
    }

    /// Creates a directory (and intermediates) under `root`, returning a
    /// precise, diagnosable error instead of a collapsed "no permission"
    /// message. Sandbox containment is enforced before any write.
    static func createDirectory(at url: URL, root: URL) throws {
        guard isInside(root: root, url) else {
            throw ModelStoragePathError.outsideSandbox(url.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw ModelStoragePathError.creationFailed(
                path: url.path,
                underlying: error
            )
        }
    }

    /// Convenience over `createDirectory(at:root:)` for app-owned locations.
    static func createDirectoryInSandbox(at url: URL) throws {
        try createDirectory(at: url, root: documents)
    }
}

// MARK: - ModelStoragePathError

enum ModelStoragePathError: LocalizedError {
    case outsideSandbox(String)
    case creationFailed(path: String, underlying: Error)
    case probeFailed(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .outsideSandbox(let path):
            return "Refusing to write outside the app container: \(path)"
        case .creationFailed(let path, let underlying):
            return ModelStoragePathError.describeFailure(
                path: path, error: underlying
            )
        case .probeFailed(let path, let underlying):
            return "Write probe failed in \(path) — "
                + ModelStoragePathError.describeFailure(path: path, error: underlying)
        }
    }

    /// Human-readable, diagnosable failure text: path + error domain/code +
    /// underlying POSIX error when Foundation wrapped one.
    static func describeFailure(path: String, error: Error) -> String {
        let ns = error as NSError
        var message = "Couldn't create \(path) — \(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return message
    }
}
