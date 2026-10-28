import Foundation
import Combine
import Security
import UIKit

nonisolated protocol GitHubCredentialStorage: Sendable {
    func token(for id: UUID) throws -> String?
    func setToken(_ token: String, for id: UUID) throws
    func deleteAll() throws
}

/// Separate service, no shared access group, no synchronization or file fallback.
nonisolated struct GitHubKeychain: GitHubCredentialStorage {
    private let service = "com.token.TokenAI.github"
    private func query(_ id: UUID? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { value[kSecAttrAccount as String] = id.uuidString }
        return value
    }
    func token(for id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw GitHubError.keychain }
        return token
    }
    func setToken(_ token: String, for id: UUID) throws {
        var item = query(id)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                           kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            guard SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary) == errSecSuccess else { throw GitHubError.keychain }
        } else if status != errSecSuccess { throw GitHubError.keychain }
    }
    func deleteAll() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubError.keychain }
    }
}

@MainActor
final class GitHubConnectionStore: ObservableObject {
    static let shared = GitHubConnectionStore()
    static let metadataKey = "github.account.metadata.v1"
    static let enabledKey = "github.tools.enabled.v1"
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults
    private let credentials: any GitHubCredentialStorage
    private var connectionOperation = UUID()

    init(defaults: UserDefaults = .standard, credentials: any GitHubCredentialStorage = GitHubKeychain()) {
        self.defaults = defaults; self.credentials = credentials
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let data = defaults.data(forKey: Self.metadataKey) { account = try? JSONDecoder().decode(GitHubAccount.self, from: data) }
    }

    func credential(for accountID: UUID) throws -> String {
        guard account?.id == accountID else { throw account == nil ? GitHubError.disconnected : GitHubError.wrongAccount }
        guard let token = try credentials.token(for: accountID), GitHubValidation.token(token) else { throw GitHubError.disconnected }
        return token
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        revision = UUID()
    }

    func connect(token: String, client: GitHubClient = .shared) async throws {
        guard account == nil else { throw GitHubError.staleReview }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubValidation.token(token) else { throw GitHubError.invalidCredential }
        let operation = UUID(); connectionOperation = operation
        let user = try await client.user(token: token)
        try Task.checkCancellation()
        guard connectionOperation == operation, account == nil else { throw GitHubError.cancelled }
        guard user.id > 0, GitHubValidation.component(user.login) else { throw GitHubError.invalidResponse }
        let value = GitHubAccount(id: UUID(), login: user.login, userID: user.id)
        // Clear orphaned credentials before adding the only active connection.
        try credentials.deleteAll()
        try credentials.setToken(token, for: value.id)
        account = value
        defaults.set(try JSONEncoder().encode(value), forKey: Self.metadataKey)
        revision = UUID()
    }

    func disconnect() throws {
        connectionOperation = UUID()
        // Revoke app-side access even when Keychain temporarily refuses deletion.
        setEnabled(false)
        try credentials.deleteAll()
        account = nil
        isEnabled = false
        defaults.removeObject(forKey: Self.metadataKey)
        defaults.removeObject(forKey: Self.enabledKey)
        revision = UUID()
    }
}

/// Device authorization contains temporary codes only in memory. Polling observes
/// GitHub's minimum interval and slowdown. Background time is solely for Safari sign-in.
@MainActor
final class GitHubSignInSession: ObservableObject {
    // The working registration belongs to SiteAgent. A dedicated registration can
    // replace this public client ID in project.yml without changing stored credentials.
    static var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String ?? "Ov23likbAwZPky4GT7B5"
    }
    static var usesSiteAgentRegistration: Bool { clientID == "Ov23likbAwZPky4GT7B5" }
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?
    private var code: GitHubDeviceCode?
    private var deadline: Date?
    private var interval: Int = 5
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    let store: GitHubConnectionStore
    let client: GitHubClient

    init(store: GitHubConnectionStore? = nil, client: GitHubClient = .shared) { self.store = store ?? .shared; self.client = client }

    func start() {
        cancel()
        let scope = generation
        isWorking = true; error = nil
        task = Task {
            do {
                let code = try await client.startDeviceSignIn(clientID: Self.clientID)
                try Task.checkCancellation()
                guard generation == scope else { return }
                self.code = code; userCode = code.userCode; verificationURL = code.verificationURI
                deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                interval = max(5, code.interval ?? 5)
                task = nil
                resumePolling()
            } catch {
                guard generation == scope, !Task.isCancelled else { return }
                self.error = GitHubError.safeMessage(error); isWorking = false; task = nil
            }
        }
    }

    func resumePolling() {
        guard task == nil, let code, let deadline, store.account == nil else { return }
        let scope = generation
        isWorking = true
        task = Task {
            do {
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    try Task.checkCancellation()
                    guard generation == scope else { throw CancellationError() }
                    switch try await client.pollDeviceSignIn(clientID: Self.clientID, deviceCode: code.deviceCode) {
                    case .pending: break
                    case .slowDown: interval += 5
                    case .authorized(let token):
                        try Task.checkCancellation()
                        try await store.connect(token: token, client: client)
                        guard generation == scope else { return }
                        cancel()
                        return
                    }
                }
                throw GitHubError.deviceExpired
            } catch {
                guard generation == scope else { return }
                task = nil; isWorking = false; endBackgroundTime()
                if !Task.isCancelled {
                    self.error = GitHubError.safeMessage(error)
                    self.code = nil; userCode = nil; verificationURL = nil
                }
            }
        }
    }

    func allowSafariSignInInBackground() {
        guard code != nil, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GitHub device sign-in") { [weak self] in
            Task { @MainActor in
                self?.task?.cancel(); self?.task = nil
                self?.isWorking = false; self?.endBackgroundTime()
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        code = nil; deadline = nil; userCode = nil; verificationURL = nil; isWorking = false
        endBackgroundTime()
    }
    private func endBackgroundTime() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
