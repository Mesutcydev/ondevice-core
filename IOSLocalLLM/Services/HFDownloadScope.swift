import Foundation

/// Ownership shared by background-task cancellation and persisted receipts.
/// File allowlists keep variants in a shared directory independent.
struct HFDownloadScope: Sendable {
    let destination: URL
    let fileAllowlist: [String]?

    func contains(path: String) -> Bool {
        let root = destination.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return false }
        let relative = String(candidate.dropFirst(root.count + 1))
        return fileAllowlist?.contains { rule in
            rule.hasSuffix("/") ? relative.hasPrefix(rule) : relative == rule
        } ?? true
    }

    private var expectedSizes: [String: Int64] {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(".hf-expected.json")),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return sizes
    }

    var trackedPaths: [String] {
        expectedSizes.keys.filter { contains(path: destination.appendingPathComponent($0).path) }
    }

    func hasResumableReceipt(repoID: String) -> Bool {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent(".repoID")),
              String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == repoID else { return false }
        return !trackedPaths.isEmpty
    }

    /// Remove only this variant's receipt entries after its writers stop.
    /// The last entry also owns the repository marker; otherwise keep both
    /// metadata files for a sibling that is still resumable.
    func discardReceipt(repoID: String) throws {
        let marker = destination.appendingPathComponent(".repoID")
        guard let data = try? Data(contentsOf: marker),
              String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == repoID else { return }
        let receipt = destination.appendingPathComponent(".hf-expected.json")
        let remaining = expectedSizes.filter { !contains(path: destination.appendingPathComponent($0.key).path) }
        if remaining.isEmpty {
            if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
            try FileManager.default.removeItem(at: marker)
        } else {
            try JSONEncoder().encode(remaining).write(to: receipt, options: .atomic)
        }
    }
}
