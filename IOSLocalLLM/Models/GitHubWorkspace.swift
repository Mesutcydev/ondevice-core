import Foundation
import CryptoKit

/// Public account metadata only. Authentication material never belongs in Codable models.
nonisolated struct GitHubAccount: Codable, Equatable, Sendable {
    let id: UUID
    let login: String
    let userID: Int
}

nonisolated struct GitHubRepository: Identifiable, Decodable, Equatable, Sendable {
    struct Owner: Decodable, Equatable, Sendable { let login: String }
    struct Permissions: Decodable, Equatable, Sendable { let push: Bool? }
    let id: Int
    let name: String
    let owner: Owner
    let defaultBranch: String
    let isPrivate: Bool
    let permissions: Permissions?
    var fullName: String { "\(owner.login)/\(name)" }
    enum CodingKeys: String, CodingKey {
        case id, name, owner, permissions
        case defaultBranch = "default_branch", isPrivate = "private"
    }
}

nonisolated struct GitHubRepositorySelection: Codable, Equatable, Sendable {
    let accountID: UUID
    let owner: String
    let name: String
    var branch: String
    var fullName: String { "\(owner)/\(name)" }
    var label: String { "\(fullName) · \(branch)" }

    func validated() throws -> Self {
        guard GitHubValidation.component(owner), GitHubValidation.component(name) else {
            throw GitHubError.invalidRepository
        }
        guard GitHubValidation.branch(branch) else { throw GitHubError.invalidBranch }
        return self
    }
}

/// Snapshots are encrypted before saving with the protected conversation file.
/// Nil content means absent/deleted. Data preserves user-attached binary files exactly.
nonisolated struct GitHubFileChange: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let original: Data?
    var updated: Data?
    let mode: String
    private var lockedSnapshot: Data?
    private(set) var needsEncryptionMigration = false
    var isLocked: Bool { lockedSnapshot != nil }
    var kind: String { isLocked ? "Encrypted" : original == nil ? "Added" : updated == nil ? "Deleted" : "Modified" }
    var originalText: String? { original.flatMap { String(data: $0, encoding: .utf8) } }
    var updatedText: String? { updated.flatMap { String(data: $0, encoding: .utf8) } }

    private struct Snapshot: Codable { let original: Data?; let updated: Data? }
    private enum CodingKeys: String, CodingKey { case path, mode, encryptedSnapshot, original, updated }
    init(path: String, original: Data?, updated: Data?, mode: String) {
        self.path = path; self.original = original; self.updated = updated; self.mode = mode
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try GitHubValidation.path(values.decode(String.self, forKey: .path))
        mode = try values.decode(String.self, forKey: .mode)
        guard ["100644", "100755"].contains(mode) else { throw GitHubError.unsupportedFile }
        if let sealed = try values.decodeIfPresent(Data.self, forKey: .encryptedSnapshot) {
            do {
                let plain = try GitHubDraftProtection.open(sealed, context: path + "\n" + mode,
                    using: decoder.userInfo[GitHubDraftProtection.keyInfo] as? SymmetricKey)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: plain)
                original = snapshot.original; updated = snapshot.updated
            } catch {
                // A locked device or another device's backup must not make
                // the entire conversation unreadable or erase its draft.
                original = nil; updated = nil; lockedSnapshot = sealed
            }
        } else {
            // Existing drafts are encrypted on their next save.
            original = try values.decodeIfPresent(Data.self, forKey: .original)
            updated = try values.decodeIfPresent(Data.self, forKey: .updated)
            needsEncryptionMigration = true
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(mode, forKey: .mode)
        if let lockedSnapshot {
            try values.encode(lockedSnapshot, forKey: .encryptedSnapshot)
            return
        }
        let snapshot = try JSONEncoder().encode(Snapshot(original: original, updated: updated))
        try values.encode(GitHubDraftProtection.seal(snapshot, context: path + "\n" + mode,
            using: encoder.userInfo[GitHubDraftProtection.keyInfo] as? SymmetricKey), forKey: .encryptedSnapshot)
    }

    func unlocked(using key: SymmetricKey? = nil) throws -> Self {
        guard let lockedSnapshot else { return self }
        let plain = try GitHubDraftProtection.open(lockedSnapshot, context: path + "\n" + mode, using: key)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: plain)
        return Self(path: path, original: snapshot.original, updated: snapshot.updated, mode: mode)
    }
}

nonisolated struct GitHubWorkspaceDraft: Codable, Equatable, Sendable {
    var selection: GitHubRepositorySelection
    var baseSHA: String?
    var changes: [GitHubFileChange] = []
    var revision = UUID()
    /// Stable across staging/commits; different chats must not share editor drafts.
    var editorID: UUID? = UUID()
}

nonisolated enum GitHubReviewAction: Equatable, Sendable {
    case commit(message: String)
    case createBranch(name: String)
    case pullRequest(title: String, base: String, body: String)
    case revert(reason: String, treeSHA: String, changedFiles: [String])

    var title: String {
        switch self {
        case .commit: "Commit changes"
        case .createBranch: "Create branch"
        case .pullRequest: "Open pull request"
        case .revert: "Revert latest commit"
        }
    }
}

/// Immutable approval snapshot. A changed account, branch, draft, or HEAD invalidates it.
nonisolated struct GitHubReviewPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let draft: GitHubWorkspaceDraft
    let expectedSHA: String
    let action: GitHubReviewAction
    var includedPaths: Set<String>? = nil
    var changesToCommit: [GitHubFileChange] {
        guard let includedPaths else { return draft.changes }
        return draft.changes.filter { includedPaths.contains($0.path) }
    }
}

nonisolated enum GitHubToolOutcome: Sendable {
    case result(String)
    case review(GitHubReviewPlan)
}

nonisolated enum GitHubError: Error, LocalizedError, Equatable, Sendable {
    case invalidRepository, invalidBranch, invalidPath, invalidCredential, invalidResponse
    case disabled, disconnected, wrongAccount, notFound, conflict, permission, rateLimited, tooLarge
    case keychain, emptyChanges, staleReview, unsupportedFile, cancelled, connection
    case deviceExpired, deviceDenied, invalidClient, unsupportedRevert, detectedSecrets, lockedDraft

    var errorDescription: String? {
        switch self {
        case .lockedDraft: "This repository draft is encrypted. Unlock the original device and reconnect the repository, or discard the draft to start again."
        case .detectedSecrets: "Potential credentials were found. Stage their removal with redact_secrets before publishing this file. Values were withheld."
        case .invalidRepository: "Choose a valid GitHub repository."
        case .invalidBranch: "Enter a valid branch name."
        case .invalidPath: "Use a relative file path inside the selected repository."
        case .invalidCredential: "Enter a valid GitHub access token."
        case .invalidResponse: "GitHub returned an unexpected response."
        case .disabled: "GitHub tools are off. Enable them in Settings before using repository tools."
        case .disconnected: "Connect GitHub and select a repository first."
        case .wrongAccount: "This chat's repository belongs to a different GitHub connection. Select it again."
        case .notFound: "GitHub could not find this file, branch, or repository. Check the selection and token access."
        case .conflict: "The branch changed on GitHub. Your draft is safe; discard it and ask the agent to prepare the changes again."
        case .permission: "GitHub denied access. Check token permissions, organization approval, and branch protection."
        case .rateLimited: "GitHub's rate limit was reached. Try again later."
        case .tooLarge: "This operation exceeds the repository tool's size limit. Use a smaller file or a narrower folder."
        case .keychain: "The GitHub credential could not be accessed securely. Try again while the device is unlocked."
        case .emptyChanges: "There are no staged changes to review."
        case .staleReview: "The repository or draft changed after this review opened. Review the current changes again."
        case .unsupportedFile: "This file is binary, a symlink, or a submodule. Use upload_attachment for a new binary file."
        case .cancelled: "The GitHub operation was cancelled."
        case .connection: "Could not connect to GitHub. Check your connection and try again."
        case .deviceExpired: "The sign-in code expired. Start GitHub sign-in again."
        case .deviceDenied: "GitHub sign-in was declined."
        case .invalidClient: "GitHub device sign-in is unavailable. Connect with a fine-grained access token instead."
        case .unsupportedRevert: "A first commit or merge commit needs a manual revert on GitHub. Choose a commit with one parent for this tool."
        }
    }

    static func safeMessage(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return GitHubError.cancelled.localizedDescription
        }
        return (error as? GitHubError ?? .connection).localizedDescription
    }
}

nonisolated enum GitHubValidation {
    static func component(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
    static func path(_ value: String, allowRoot: Bool = false) throws -> String {
        if value.isEmpty && allowRoot { return "" }
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.hasPrefix("/"),
              !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !value.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else {
            throw GitHubError.invalidPath
        }
        return value
    }
    static func branch(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("-"),
              !value.contains(".."), !value.contains("@{"), value != "@", !value.hasSuffix("."),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: " ~^:?*[\\").contains($0) }) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }
    static func sha(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy { $0.isHexDigit }
    }
    static func token(_ value: String) -> Bool {
        (20...512).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }
}
