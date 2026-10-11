import Foundation
import Combine
import Security

nonisolated protocol APIProviderCredentialStorage: Sendable {
    func key(for id: UUID) throws -> String?
    func setKey(_ key: String, for id: UUID) throws
    func deleteKey(for id: UUID) throws
    func deleteAll() throws
}

nonisolated struct APIProviderKeychain: APIProviderCredentialStorage {
    private let service = "com.mesutcydev.ondevicemax.chatproviders"
    private func query(_ id: UUID? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        if let id { result[kSecAttrAccount as String] = id.uuidString }
        return result
    }
    func key(for id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw APIProviderError.credentialStorage }
        return key
    }
    func setKey(_ key: String, for id: UUID) throws {
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(id).merging(values) { _, new in new }
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIProviderError.credentialStorage }
    }
    func deleteKey(for id: UUID) throws { try remove(query(id)) }
    func deleteAll() throws { try remove(query()) }
    private func remove(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIProviderError.credentialStorage
        }
    }
}

extension Notification.Name {
    static let apiProviderConfigurationsChanged = Notification.Name("apiProviderConfigurationsChanged")
}

/// Only non-secret configuration and model metadata are encoded in defaults.
@MainActor
final class APIProviderStore: ObservableObject {
    static let shared = APIProviderStore()
    static let defaultsKey = "chat.apiProviderConfigurations.v1"
    @Published private(set) var providers: [APIProviderConfiguration]
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let credentials: any APIProviderCredentialStorage

    init(defaults: UserDefaults = .standard,
         credentials: any APIProviderCredentialStorage = APIProviderKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        providers = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([APIProviderConfiguration].self, from: $0) } ?? []
    }

    func provider(_ id: UUID) -> APIProviderConfiguration? { providers.first { $0.id == id } }
    func target(_ selectionID: String) -> (provider: APIProviderConfiguration, model: APIProviderModel)? {
        guard let selection = APIModelSelection(id: selectionID),
              let provider = provider(selection.providerID),
              let model = provider.models.first(where: { $0.id == selection.modelID }) else { return nil }
        return (provider, model)
    }
    func hasKey(for id: UUID) -> Bool { (try? credentials.key(for: id))?.isEmpty == false }
    func key(for provider: APIProviderConfiguration) throws -> String {
        guard provider.requiresAPIKey else { return "" }
        let key = try credentials.key(for: provider.id) ?? ""
        guard !provider.requiresAPIKey || !key.isEmpty else { throw APIProviderError.missingKey }
        return key
    }
    func canUse(_ provider: APIProviderConfiguration) -> Bool {
        provider.isEnabled && (!provider.requiresAPIKey || hasKey(for: provider.id))
    }

    func save(_ configuration: APIProviderConfiguration, newKey: String? = nil,
              removeKey: Bool = false) throws {
        var value = configuration
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 120 else { throw APIProviderError.invalidName }
        value.baseURL = try APIProviderEndpoint.validated(value.baseURL).absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard value.models.allSatisfy({ APIProviderEndpoint.isValidModelID($0.id) }) else {
            throw APIProviderError.invalidModel
        }
        value.inputTokenBudget = min(1_000_000, max(1_024, value.inputTokenBudget))
        value.maximumOutputTokens = min(65_536, max(256, value.maximumOutputTokens))
        if provider(value.id).map({ $0.baseURL != value.baseURL || $0.kind != value.kind }) == true {
            value.models.removeAll { !$0.isManual }
        }
        if provider(value.id)?.privacyFingerprint != value.privacyFingerprint { value.consentFingerprint = nil }
        let key = newKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            guard APIProviderEndpoint.isValidKey(key) else {
                throw APIProviderError.invalidKey
            }
            try credentials.setKey(key, for: value.id)
        } else if removeKey || provider(value.id).map({ $0.baseURL != value.baseURL || $0.kind != value.kind }) == true {
            try credentials.deleteKey(for: value.id)
        }
        if let index = providers.firstIndex(where: { $0.id == value.id }) { providers[index] = value }
        else { providers.append(value) }
        persist()
    }

    func replaceCatalog(_ models: [APIProviderModel], for id: UUID, matching fingerprint: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == id }),
              providers[index].privacyFingerprint == fingerprint else { throw APIProviderError.unavailable }
        var byID = Dictionary(providers[index].models.filter(\.isManual).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for model in models.prefix(2_000) where APIProviderEndpoint.isValidModelID(model.id) {
            var entry = model
            entry.isManual = byID[model.id]?.isManual ?? model.isManual
            byID[model.id] = entry
        }
        providers[index].models = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    func acceptConsent(for id: UUID, fingerprint: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == id }),
              providers[index].privacyFingerprint == fingerprint else { throw APIProviderError.unavailable }
        providers[index].consentFingerprint = fingerprint
        persist()
    }

    func delete(_ id: UUID) throws {
        try credentials.deleteKey(for: id)
        providers.removeAll { $0.id == id }
        persist()
    }
    func removeAll() throws {
        try credentials.deleteAll()
        providers = []
        persist()
    }
    private func persist() {
        defaults.set(try? JSONEncoder().encode(providers), forKey: Self.defaultsKey)
        revision &+= 1
        NotificationCenter.default.post(name: .apiProviderConfigurationsChanged, object: self)
    }
}
