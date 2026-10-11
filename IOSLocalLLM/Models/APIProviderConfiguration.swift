import Foundation

/// Public API-key integrations. These are chat destinations, never local runtimes.
nonisolated enum APIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, deepSeek, grok, mistral, openCode
    case openRouterFree, openRouter, groq, qwenCode, kimiCode, longCat, custom

    var id: String { rawValue }
    var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .grok: "xAI"
        case .mistral: "Mistral"
        case .openCode: "OpenCode Go"
        case .openRouterFree: "OpenRouter Free"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .qwenCode: "Qwen Code"
        case .kimiCode: "Kimi Code"
        case .longCat: "LongCat"
        case .custom: "Custom endpoint"
        }
    }
    var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .grok: "https://api.x.ai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .openCode: "https://opencode.ai/zen/go/v1"
        case .openRouterFree, .openRouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .qwenCode: "https://coding-intl.dashscope.aliyuncs.com/v1"
        case .kimiCode: "https://api.kimi.com/coding/v1"
        case .longCat: "https://api.longcat.chat/openai/v1"
        case .custom: ""
        }
    }
    var format: APIProviderFormat {
        switch self {
        case .openAI: .responses
        case .anthropic: .anthropic
        case .gemini: .gemini
        case .openCode: .openCode
        default: .chatCompletions
        }
    }
}

nonisolated enum APIProviderFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions, responses, anthropic, gemini, openCode
    var id: String { rawValue }
    var name: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Gemini"
        case .openCode: "OpenCode automatic"
        }
    }
    func resolved(for modelID: String) -> Self {
        guard self == .openCode else { return self }
        let model = modelID.split(separator: "/").last?.lowercased() ?? modelID.lowercased()
        if model.hasPrefix("gpt-") || model.hasPrefix("grok-") { return .responses }
        if model.hasPrefix("claude-") || model.hasPrefix("qwen") || model.hasPrefix("minimax-") {
            return .anthropic
        }
        return .chatCompletions
    }
}

nonisolated struct APIProviderModel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var contextWindow: Int?
    var outputTokenLimit: Int?
    var supportsImages: Bool = false
    var isManual: Bool = false
}

nonisolated struct APIProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: APIProviderKind
    var name: String
    var baseURL: String
    var format: APIProviderFormat
    var requiresAPIKey = true
    var isEnabled = true
    /// An app-side retention budget, not a claim about an unknown model's window.
    var inputTokenBudget = 8_192
    var maximumOutputTokens = 4_096
    /// Allows image input for manually added models whose catalog has no metadata.
    var allowImages = false
    var models: [APIProviderModel] = []
    var consentFingerprint: String?

    init(kind: APIProviderKind) {
        self.kind = kind
        name = kind.name
        baseURL = kind.baseURL
        format = kind.format
        if kind == .openRouterFree {
            models = [.init(id: "openrouter/free", name: "OpenRouter Free", isManual: true)]
        }
    }

    var endpointHost: String { URLComponents(string: baseURL)?.host ?? "Unconfigured endpoint" }
    var privacyFingerprint: String { "1|\(kind.rawValue)|\(format.rawValue)|\(baseURL)" }
    var hasConsent: Bool { consentFingerprint == privacyFingerprint }
    func selectionID(for model: APIProviderModel) -> String {
        APIModelSelection(providerID: id, modelID: model.id).id
    }
    func inputBudget(for model: APIProviderModel, outputTokens: Int) -> Int {
        let contextBudget = model.contextWindow.map { max(512, $0 - outputTokens - 512) }
        return min(inputTokenBudget, contextBudget ?? inputTokenBudget)
    }
}

/// Stable, reversible identity that does not put a URL or credential in chat records.
nonisolated struct APIModelSelection: Hashable, Sendable {
    let providerID: UUID
    let modelID: String
    var id: String { "api:\(providerID.uuidString):\(Data(modelID.utf8).base64EncodedString())" }

    init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "api", let uuid = UUID(uuidString: String(parts[1])),
              let data = Data(base64Encoded: String(parts[2])), let model = String(data: data, encoding: .utf8),
              APIProviderEndpoint.isValidModelID(model) else { return nil }
        providerID = uuid
        modelID = model
    }
}

nonisolated enum APIProviderEndpoint {
    static func validated(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = parts.url,
              parts.scheme?.lowercased() == "https"
                || (parts.scheme?.lowercased() == "http" && isPrivateHost(host)) else {
            throw APIProviderError.invalidEndpoint
        }
        let forbidden = ["chat/completions", "responses", "messages", "models"]
        guard !forbidden.contains(url.lastPathComponent.lowercased()) else {
            throw APIProviderError.endpointIsMethod
        }
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { (0...255).contains($0) }
            && (parts[0] == 127 || parts[0] == 10
                || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1])))
    }

    static func isValidModelID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && !id.contains(where: { $0.isWhitespace || $0.isNewline })
            && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !id.contains("?") && !id.contains("#") && !id.contains("..")
            && !id.hasPrefix("/") && !id.hasSuffix("/")
    }
    static func isValidKey(_ key: String) -> Bool {
        key.utf8.count <= 8_192 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}

nonisolated enum APIProviderError: Error, LocalizedError, Equatable {
    case invalidEndpoint, endpointIsMethod, invalidModel, missingKey, invalidKey, invalidName
    case consentRequired, unavailable, invalidResponse, incompleteStream, noModels
    case http(Int), connection, credentialStorage, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use an HTTPS base URL. HTTP is allowed only for localhost or a trusted private network. Do not include credentials, a query, or a fragment."
        case .endpointIsMethod: "Enter the API base URL, ending in its version path, without /models, /messages, /responses, or /chat/completions."
        case .invalidModel: "Enter a valid model ID from your provider."
        case .missingKey: "Add an API key in Settings → Models & AI → API providers."
        case .invalidKey: "The API key must be a single line without spaces."
        case .invalidName: "Enter a provider name of 120 characters or fewer."
        case .consentRequired: "Choose this API model again to review where conversation content will be sent."
        case .unavailable: "This API provider or model is unavailable. Choose a model or update its configuration."
        case .invalidResponse: "The provider returned an unsupported response. Check the API format and model ID."
        case .incompleteStream: "The provider connection ended before the reply finished. Send again to retry."
        case .noModels: "The endpoint returned no chat models. You can add a model ID manually."
        case .http(401), .http(403): "The provider refused access. Check your API key and account permissions."
        case .http(429): "The provider's rate or usage limit was reached. Check your account and retry later."
        case .http(let code): "Provider request failed (HTTP \(code)). Check the endpoint, API format, model ID, and account."
        case .connection: "Could not connect to the provider. Check your connection and endpoint, then retry."
        case .credentialStorage: "Could not update the API key in Keychain. The configuration was not saved."
        case .responseTooLarge: "The provider response exceeded the app's request limit."
        }
    }
}
