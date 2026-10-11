import Foundation

nonisolated struct APIChatMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    var role: Role
    var text: String
    var images: [Data] = []
}

nonisolated struct APIProviderReply: Sendable {
    var text: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var hitTokenLimit = false
}

/// No redirect may forward a saved credential to another origin (or downgrade TLS).
nonisolated final class APIProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Stateless public HTTP APIs. Never logs payloads, credentials, or provider error bodies.
nonisolated protocol APIProviderModelFetching: Sendable {
    func fetchModels(provider: APIProviderConfiguration, key: String) async throws -> [APIProviderModel]
}

nonisolated final class APIProviderClient: APIProviderModelFetching, @unchecked Sendable {
    static let shared = APIProviderClient()
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: APIProviderRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func fetchModels(provider: APIProviderConfiguration, key: String) async throws -> [APIProviderModel] {
        let base = try APIProviderEndpoint.validated(provider.baseURL)
        var result: [APIProviderModel] = []
        var page: String?
        var seenPages = Set<String>()
        for _ in 0..<20 {
            try Task.checkCancellation()
            var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            if provider.format == .gemini {
                components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                if let page { components.queryItems?.append(.init(name: "pageToken", value: page)) }
            } else if provider.format == .anthropic {
                components.queryItems = [URLQueryItem(name: "limit", value: "100")]
                if let page { components.queryItems?.append(.init(name: "after_id", value: page)) }
            }
            var request = try Self.authorizedRequest(url: components.url!, provider: provider, key: key,
                                                    format: provider.format == .openCode ? .chatCompletions : provider.format)
            request.httpMethod = "GET"
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Self.validate(response)
            let data = try await Self.boundedData(bytes)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIProviderError.invalidResponse
            }
            result += try Self.models(in: object, provider: provider)
            if provider.format == .gemini { page = object["nextPageToken"] as? String }
            else if provider.format == .anthropic, object["has_more"] as? Bool == true {
                page = object["last_id"] as? String
            } else { page = nil }
            guard let page, !page.isEmpty, seenPages.insert(page).inserted, result.count < 2_000 else { break }
        }
        var seen = Set<String>()
        let models = result.filter { seen.insert($0.id).inserted }
        guard !models.isEmpty else { throw APIProviderError.noModels }
        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func stream(provider: APIProviderConfiguration, model: APIProviderModel, key: String,
                messages: [APIChatMessage], maximumOutputTokens: Int, sessionID: UUID,
                onText: @escaping @Sendable (String) -> Void) async throws -> APIProviderReply {
        let request = try Self.chatRequest(provider: provider, model: model, key: key, messages: messages,
                                          maximumOutputTokens: maximumOutputTokens, sessionID: sessionID)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Self.validate(response)
        let format = provider.format.resolved(for: model.id)
        var decoder = APIProviderStreamDecoder(format: format)
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("application/json") == true {
            try decoder.consumeJSON(try await Self.boundedData(bytes), isFinalResponse: true)
            onText(decoder.reply.text)
        } else {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let previous = decoder.reply.text
                try decoder.consume(line: line)
                // A combining mark or emoji joiner can extend the preceding
                // grapheme. Slice appended UTF-8 so that delta is still delivered.
                if decoder.reply.text.utf8.count > previous.utf8.count {
                    onText(String(decoding: decoder.reply.text.utf8.dropFirst(previous.utf8.count), as: UTF8.self))
                }
                if decoder.shouldStopReading { break }
            }
            let previous = decoder.reply.text
            try decoder.finish()
            if decoder.reply.text.utf8.count > previous.utf8.count {
                onText(String(decoding: decoder.reply.text.utf8.dropFirst(previous.utf8.count), as: UTF8.self))
            }
        }
        guard !decoder.reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIProviderError.invalidResponse
        }
        return decoder.reply
    }

    static func safeError(_ error: Error) -> String {
        (error as? APIProviderError ?? .connection).localizedDescription
    }

    static func chatRequest(provider: APIProviderConfiguration, model: APIProviderModel, key: String,
                            messages: [APIChatMessage], maximumOutputTokens: Int,
                            sessionID: UUID) throws -> URLRequest {
        guard APIProviderEndpoint.isValidModelID(model.id) else { throw APIProviderError.invalidModel }
        let base = try APIProviderEndpoint.validated(provider.baseURL)
        let format = provider.format.resolved(for: model.id)
        let limit = min(max(1, maximumOutputTokens), provider.maximumOutputTokens,
                        model.outputTokenLimit ?? provider.maximumOutputTokens)
        let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system && (!$0.text.isEmpty || !$0.images.isEmpty) }
        let imagesAllowed = model.supportsImages || provider.allowImages
        if !imagesAllowed && turns.contains(where: { !$0.images.isEmpty }) {
            throw APIProviderError.invalidResponse
        }
        var body: [String: Any]
        let url: URL
        switch format {
        case .responses:
            url = base.appendingPathComponent("responses")
            body = ["model": model.id, "stream": true, "store": false, "max_output_tokens": limit,
                    "input": turns.map { turn -> [String: Any] in
                        let type = turn.role == .assistant ? "output_text" : "input_text"
                        var content: [[String: Any]] = [["type": type, "text": turn.text]]
                        if turn.role == .user {
                            content += turn.images.map { ["type": "input_image", "image_url": Self.imageURL($0)] }
                        }
                        return ["role": turn.role.rawValue, "content": content]
                    }]
            if !system.isEmpty { body["instructions"] = system }
        case .anthropic:
            url = base.appendingPathComponent("messages")
            body = ["model": model.id, "stream": true, "max_tokens": limit,
                    "messages": Self.mergedTurns(turns).map { turn -> [String: Any] in
                        var content: [[String: Any]] = []
                        if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
                        if turn.role == .user {
                            content += turn.images.map {
                                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
                            }
                        }
                        return ["role": turn.role.rawValue, "content": content]
                    }]
            if !system.isEmpty { body["system"] = system }
        case .gemini:
            let id = model.id.hasPrefix("models/") ? String(model.id.dropFirst(7)) : model.id
            guard !id.contains("/") else { throw APIProviderError.invalidModel }
            var components = URLComponents(url: base.appendingPathComponent("models")
                .appendingPathComponent(id + ":streamGenerateContent"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "alt", value: "sse")]
            url = components.url!
            body = ["generationConfig": ["maxOutputTokens": limit],
                    "contents": Self.mergedTurns(turns).map { turn -> [String: Any] in
                        var parts: [[String: Any]] = []
                        if !turn.text.isEmpty { parts.append(["text": turn.text]) }
                        if turn.role == .user {
                            parts += turn.images.map { ["inlineData": ["mimeType": "image/jpeg", "data": $0.base64EncodedString()]] }
                        }
                        return ["role": turn.role == .assistant ? "model" : "user", "parts": parts]
                    }]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        case .chatCompletions, .openCode:
            url = base.appendingPathComponent("chat/completions")
            body = ["model": model.id, "stream": true, "max_tokens": limit,
                    "messages": messages.map { turn -> [String: Any] in
                        if turn.images.isEmpty || turn.role != .user {
                            return ["role": turn.role.rawValue, "content": turn.text]
                        }
                        var content: [[String: Any]] = [["type": "text", "text": turn.text]]
                        content += turn.images.map { ["type": "image_url", "image_url": ["url": Self.imageURL($0)]] }
                        return ["role": turn.role.rawValue, "content": content]
                    }]
        }
        var request = try authorizedRequest(url: url, provider: provider, key: key, format: format)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider.kind == .openCode { request.setValue(sessionID.uuidString, forHTTPHeaderField: "x-opencode-session") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= 20 * 1_024 * 1_024 else { throw APIProviderError.responseTooLarge }
        return request
    }

    static func authorizedRequest(url: URL, provider: APIProviderConfiguration, key: String,
                                  format: APIProviderFormat) throws -> URLRequest {
        guard !provider.requiresAPIKey || !key.isEmpty else { throw APIProviderError.missingKey }
        guard APIProviderEndpoint.isValidKey(key) else { throw APIProviderError.invalidKey }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 240)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OnDeviceMax/1.0", forHTTPHeaderField: "User-Agent")
        if provider.requiresAPIKey && !key.isEmpty {
            switch format {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                if provider.kind == .openCode { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
        }
        if format == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    static func models(in object: [String: Any], provider: APIProviderConfiguration) throws -> [APIProviderModel] {
        guard object["error"] == nil else { throw APIProviderError.invalidResponse }
        guard let items = (object[provider.format == .gemini ? "models" : "data"] as? [[String: Any]]) else {
            throw APIProviderError.invalidResponse
        }
        return items.compactMap { item in
            if provider.format == .gemini,
               !(item["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { return nil }
            guard let rawID = item[provider.format == .gemini ? "name" : "id"] as? String else { return nil }
            let id = provider.format == .gemini && rawID.hasPrefix("models/") ? String(rawID.dropFirst(7)) : rawID
            guard APIProviderEndpoint.isValidModelID(id) else { return nil }
            if provider.kind == .openRouterFree, id != "openrouter/free", !id.hasSuffix(":free") { return nil }
            let architecture = item["architecture"] as? [String: Any]
            let modalities = architecture?["input_modalities"] as? [String] ?? []
            let top = item["top_provider"] as? [String: Any]
            return APIProviderModel(id: id, name: item["display_name"] as? String
                ?? item["displayName"] as? String ?? item["name"] as? String ?? id,
                contextWindow: Self.positiveInt(item["context_length"] ?? item["inputTokenLimit"]),
                outputTokenLimit: Self.positiveInt(item["outputTokenLimit"] ?? top?["max_completion_tokens"]),
                supportsImages: modalities.contains("image"))
        }
    }

    static func positiveInt(_ value: Any?) -> Int? {
        guard let value = value as? Int, value > 0 else { return nil }
        return value
    }
    private static func imageURL(_ data: Data) -> String { "data:image/jpeg;base64," + data.base64EncodedString() }
    private static func mergedTurns(_ turns: [APIChatMessage]) -> [APIChatMessage] {
        var result: [APIChatMessage] = []
        for turn in turns {
            if result.last?.role == turn.role {
                result[result.count - 1].text += "\n\n" + turn.text
                result[result.count - 1].images += turn.images
            } else { result.append(turn) }
        }
        return result
    }
    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw APIProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw APIProviderError.http(response.statusCode) }
    }
    private static func boundedData(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1_024 * 1_024 else { throw APIProviderError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

/// Incremental SSE parser shared by all API families, independent of UI and networking.
nonisolated struct APIProviderStreamDecoder {
    let format: APIProviderFormat
    private(set) var reply = APIProviderReply(text: "")
    private(set) var isComplete = false
    private var receivedDone = false
    var shouldStopReading: Bool {
        format == .chatCompletions || format == .openCode ? receivedDone : isComplete
    }
    private var pending = ""
    private var isThinking = false

    mutating func consume(line: String) throws {
        guard line.utf8.count <= 256 * 1_024 else { throw APIProviderError.responseTooLarge }
        if line.isEmpty {
            if !pending.isEmpty { try consumeJSON(Data(pending.utf8)); pending = "" }
            return
        }
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { receivedDone = true; isComplete = true; closeThinking(); return }
        pending += (pending.isEmpty ? "" : "\n") + payload
        guard pending.utf8.count <= 256 * 1_024 else { throw APIProviderError.responseTooLarge }
        // Also works with AsyncBytes.lines implementations that skip empty lines.
        if (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) != nil {
            try consumeJSON(Data(pending.utf8))
            pending = ""
        }
    }

    mutating func finish() throws {
        if !pending.isEmpty { try consumeJSON(Data(pending.utf8)); pending = "" }
        guard isComplete else { throw APIProviderError.incompleteStream }
        closeThinking()
    }

    mutating func consumeJSON(_ data: Data, isFinalResponse: Bool = false) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
            throw APIProviderError.invalidResponse
        }
        if isFinalResponse {
            try consumeFinal(object)
            isComplete = true
            closeThinking()
            return
        }
        switch format {
        case .responses:
            let type = object["type"] as? String ?? ""
            if type == "error" || type == "response.failed" { throw APIProviderError.invalidResponse }
            if type == "response.output_text.delta" || type == "response.refusal.delta" {
                try append(object["delta"] as? String ?? "")
            } else if type == "response.reasoning_summary_text.delta" {
                try append(object["delta"] as? String ?? "", thinking: true)
            } else if type == "response.completed" || type == "response.incomplete" {
                let response = object["response"] as? [String: Any] ?? [:]
                readUsage(response["usage"] as? [String: Any])
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                reply.hitTokenLimit = reason == "max_output_tokens"
                if type == "response.incomplete" && !reply.hitTokenLimit { throw APIProviderError.incompleteStream }
                isComplete = true
                closeThinking()
            }
        case .anthropic:
            let type = object["type"] as? String ?? ""
            if type == "error" { throw APIProviderError.invalidResponse }
            if type == "message_start" {
                readUsage((object["message"] as? [String: Any])?["usage"] as? [String: Any])
            } else if type == "content_block_start", let block = object["content_block"] as? [String: Any] {
                if block["type"] as? String == "text" { try append(block["text"] as? String ?? "") }
            } else if type == "content_block_delta", let delta = object["delta"] as? [String: Any] {
                if delta["type"] as? String == "text_delta" { try append(delta["text"] as? String ?? "") }
                if delta["type"] as? String == "thinking_delta" { try append(delta["thinking"] as? String ?? "", thinking: true) }
            } else if type == "message_delta" {
                readUsage(object["usage"] as? [String: Any])
                reply.hitTokenLimit = (object["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens"
            } else if type == "message_stop" { isComplete = true; closeThinking() }
        case .gemini:
            readGeminiUsage(object["usageMetadata"] as? [String: Any])
            if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw APIProviderError.invalidResponse }
            if let candidate = (object["candidates"] as? [[String: Any]])?.first {
                for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                    try append(part["text"] as? String ?? "", thinking: part["thought"] as? Bool == true)
                }
                if let reason = candidate["finishReason"] as? String, !reason.isEmpty {
                    reply.hitTokenLimit = reason == "MAX_TOKENS"
                    isComplete = true
                    closeThinking()
                }
            }
        case .chatCompletions, .openCode:
            readUsage(object["usage"] as? [String: Any])
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                try append(delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? "", thinking: true)
                try append(delta["content"] as? String ?? "")
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                    reply.hitTokenLimit = reason == "length"
                    isComplete = true
                    closeThinking()
                }
            }
        }
    }

    private mutating func consumeFinal(_ object: [String: Any]) throws {
        switch format {
        case .responses:
            guard object["status"] as? String != "failed" else { throw APIProviderError.invalidResponse }
            for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    try append(part["text"] as? String ?? part["refusal"] as? String ?? "")
                }
            }
            readUsage(object["usage"] as? [String: Any])
            reply.hitTokenLimit = (object["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens"
        case .anthropic:
            for part in object["content"] as? [[String: Any]] ?? [] {
                try append(part["thinking"] as? String ?? "", thinking: true)
                try append(part["text"] as? String ?? "")
            }
            readUsage(object["usage"] as? [String: Any])
            reply.hitTokenLimit = object["stop_reason"] as? String == "max_tokens"
        case .gemini:
            try consumeJSON(try JSONSerialization.data(withJSONObject: object))
        case .chatCompletions, .openCode:
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { throw APIProviderError.invalidResponse }
            try append(message["reasoning_content"] as? String ?? "", thinking: true)
            try append(message["content"] as? String ?? "")
            readUsage(object["usage"] as? [String: Any])
            reply.hitTokenLimit = choice["finish_reason"] as? String == "length"
        }
    }
    private mutating func append(_ text: String, thinking: Bool = false) throws {
        guard !text.isEmpty else { return }
        guard reply.text.utf8.count + text.utf8.count < 2 * 1_024 * 1_024 else { throw APIProviderError.responseTooLarge }
        if thinking && !isThinking { reply.text += "<think>"; isThinking = true }
        if !thinking { closeThinking() }
        reply.text += text
    }
    private mutating func closeThinking() {
        if isThinking { reply.text += "</think>"; isThinking = false }
    }
    private mutating func readUsage(_ usage: [String: Any]?) {
        if let input = usage?["input_tokens"] as? Int ?? usage?["prompt_tokens"] as? Int { reply.inputTokens = max(0, input) }
        if let output = usage?["output_tokens"] as? Int ?? usage?["completion_tokens"] as? Int { reply.outputTokens = max(0, output) }
    }
    private mutating func readGeminiUsage(_ usage: [String: Any]?) {
        if let input = usage?["promptTokenCount"] as? Int { reply.inputTokens = max(0, input) }
        if let output = usage?["candidatesTokenCount"] as? Int { reply.outputTokens = max(0, output) }
    }
}
