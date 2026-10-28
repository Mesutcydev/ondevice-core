import Foundation
import CryptoKit

/// Serial, encrypted, device-local storage. No plaintext fallback or iCloud sync.
actor CodingWorkspaceVault {
    static let directoryName = "CodingWorkspaces"
    private let root: URL
    private let testKey: SymmetricKey?

    init(root: URL? = nil, testKey: SymmetricKey? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        self.testKey = testKey
    }

    func load(scope: String, checkpoint: UUID? = nil) throws -> CodingWorkspaceState? {
        try Task.checkCancellation()
        let url = location(scope, checkpoint)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 3_000_028 else { throw GitHubError.tooLarge }
        let sealed = try Data(contentsOf: url)
        let data = try GitHubDraftProtection.open(sealed, context: context(scope, checkpoint), using: testKey)
        return try JSONDecoder().decode(CodingWorkspaceState.self, from: data).validated()
    }

    func save(_ state: CodingWorkspaceState, scope: String, checkpoint: UUID? = nil) throws {
        try Task.checkCancellation()
        _ = try state.validated()
        let data = try JSONEncoder().encode(checkpoint == nil ? state.persisted : state)
        guard data.count <= 2_900_000 else { throw GitHubError.tooLarge }
        let sealed = try GitHubDraftProtection.seal(data, context: context(scope, checkpoint), using: testKey)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try sealed.write(to: location(scope, checkpoint), options: [.atomic, .completeFileProtection])
    }

    func remove(scope: String, checkpoint: UUID? = nil) throws {
        let url = location(scope, checkpoint)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func clearAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func context(_ scope: String, _ checkpoint: UUID?) -> String {
        "coding-workspace.v1/" + scope + "/" + (checkpoint?.uuidString ?? "current")
    }
    private func location(_ scope: String, _ checkpoint: UUID?) -> URL {
        // Names are hashes/UUIDs, never user-controlled repository paths.
        let name = SHA256.hash(data: Data(context(scope, checkpoint).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".sealed")
    }
}
