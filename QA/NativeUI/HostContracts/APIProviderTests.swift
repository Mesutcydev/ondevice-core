import XCTest
@testable import NativeUIReview

@MainActor
final class APIProviderTests: XCTestCase {
    private func fixture() -> (APIProviderStore, UserDefaults, APIProviderReviewCredentials) {
        let defaults = UserDefaults(suiteName: "api-tests-\(UUID())")!
        let credentials = APIProviderReviewCredentials()
        return (APIProviderStore(defaults: defaults, credentials: credentials), defaults, credentials)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testEndpointValidationRejectsCredentialURLsAndPublicHTTP() throws {
        for url in ["http://api.example.com/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret",
                    "https://example.com/v1#secret", "file:///tmp/api", "https://example.com/v1/responses"] {
            XCTAssertThrowsError(try APIProviderEndpoint.validated(url))
        }
        XCTAssertEqual(try APIProviderEndpoint.validated("https://api.example.com/v1").host, "api.example.com")
        XCTAssertNoThrow(try APIProviderEndpoint.validated("http://127.0.0.1:8080/v1"))
        XCTAssertNoThrow(try APIProviderEndpoint.validated("http://192.168.1.5:8080/v1"))
    }

    func testAPIIdentityAndExecutionLocationSurviveConversationStorage() throws {
        let selection = APIModelSelection(providerID: UUID(), modelID: "vendor/model:free")
        XCTAssertEqual(APIModelSelection(id: selection.id), selection)
        XCTAssertEqual(ModelExecutionLocation.of(assistantModelID: selection.id), .externalCloud)
        XCTAssertEqual(ModelExecutionLocation.of(assistantModelID: "api:removed"), .externalCloud)
        XCTAssertNil(APIModelSelection(id: "api:removed"))
        let message = ChatMessage(role: .assistant, content: "Reply", generationModelID: selection.id,
                                  generationExecutionLocation: .externalCloud)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.generationModelID, selection.id)
        XCTAssertEqual(restored.generationExecutionLocation, .externalCloud)
    }

    func testKeysAreSeparateFromMetadataAndEndpointChangesRevokeTrust() throws {
        let (store, defaults, credentials) = fixture()
        var provider = APIProviderConfiguration(kind: .openAI)
        provider.models = [.init(id: "test-model", name: "Test")]
        try store.save(provider, newKey: "unit-test-secret")
        try store.acceptConsent(for: provider.id, fingerprint: provider.privacyFingerprint)
        XCTAssertTrue(store.target(provider.selectionID(for: provider.models[0]))?.provider.hasConsent == true)
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: APIProviderStore.defaultsKey)), encoding: .utf8)!.contains("unit-test-secret"))
        let restored = APIProviderStore(defaults: defaults, credentials: credentials)
        XCTAssertTrue(restored.hasKey(for: provider.id))
        provider = try XCTUnwrap(restored.provider(provider.id))
        provider.baseURL = "https://other.example.com/v1"
        try restored.save(provider)
        XCTAssertFalse(try XCTUnwrap(restored.provider(provider.id)).hasConsent)
        XCTAssertFalse(restored.hasKey(for: provider.id))
        XCTAssertThrowsError(try restored.acceptConsent(for: provider.id, fingerprint: "old"))
    }

    func testCredentialFailureDoesNotPublishAnUnsavedProfile() throws {
        let (store, _, credentials) = fixture()
        credentials.failWrites = true
        XCTAssertThrowsError(try store.save(.init(kind: .openAI), newKey: "fake-key"))
        XCTAssertTrue(store.providers.isEmpty)
    }

    func testCustomNoAuthenticationDoesNotSendASavedKey() throws {
        let (store, _, _) = fixture()
        var provider = APIProviderConfiguration(kind: .custom)
        provider.baseURL = "http://127.0.0.1:8080/v1"
        provider.requiresAPIKey = false
        try store.save(provider, newKey: "saved-but-disabled-key")
        XCTAssertEqual(try store.key(for: provider), "")
        let request = try APIProviderClient.authorizedRequest(url: URL(string: provider.baseURL)!, provider: provider,
            key: "saved-but-disabled-key", format: .chatCompletions)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try store.save(provider, newKey: "key\u{0000}injection"))
    }

    func testCatalogRefreshPreservesManualModelsAndDeleteRemovesKeys() throws {
        let (store, _, credentials) = fixture()
        var provider = APIProviderConfiguration(kind: .custom)
        provider.baseURL = "https://custom.example.com/v1"
        provider.models = [.init(id: "private-model", name: "Private", isManual: true)]
        try store.save(provider, newKey: "fake-key")
        try store.replaceCatalog([.init(id: "public-model", name: "Public")], for: provider.id, matching: provider.privacyFingerprint)
        XCTAssertEqual(Set(try XCTUnwrap(store.provider(provider.id)).models.map(\.id)), ["private-model", "public-model"])
        try store.delete(provider.id)
        XCTAssertTrue(store.providers.isEmpty)
        XCTAssertNil(try credentials.key(for: provider.id))
        XCTAssertNil(store.target(provider.selectionID(for: provider.models[0])))
    }

    func testOpenAIResponsesUsesStatelessInputWithoutUnsupportedMessageNames() throws {
        let provider = APIProviderConfiguration(kind: .openAI)
        let request = try APIProviderClient.chatRequest(provider: provider, model: .init(id: "test-model", name: "Test"),
            key: "fake-key", messages: [.init(role: .system, text: "System"), .init(role: .user, text: "Question"),
                                       .init(role: .assistant, text: "Previous")], maximumOutputTokens: 512, sessionID: UUID())
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
        let payload = try body(request)
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["instructions"] as? String, "System")
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 512)
        let messages = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0["name"] == nil })
        XCTAssertNil(payload["temperature"])
    }

    func testAnthropicMergesAdjacentUserTurnsAndKeepsSystemSeparate() throws {
        let request = try APIProviderClient.chatRequest(provider: .init(kind: .anthropic), model: .init(id: "claude-test", name: "Test"),
            key: "fake-key", messages: [.init(role: .system, text: "Rules"), .init(role: .user, text: "Question"),
                                       .init(role: .user, text: "Tool result")], maximumOutputTokens: 512, sessionID: UUID())
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fake-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let payload = try body(request)
        XCTAssertEqual(payload["system"] as? String, "Rules")
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages[0]["name"])
    }

    func testGeminiKeyIsInHeaderAndImagesAreInline() throws {
        var provider = APIProviderConfiguration(kind: .gemini)
        provider.allowImages = true
        let request = try APIProviderClient.chatRequest(provider: provider, model: .init(id: "models/gemini-test", name: "Test"),
            key: "fake-key", messages: [.init(role: .user, text: "Photo", images: [Data([1, 2, 3])])],
            maximumOutputTokens: 512, sessionID: UUID())
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-test:streamGenerateContent")
        XCTAssertEqual(request.url?.query, "alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fake-key")
        let contents = try XCTUnwrap(try body(request)["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotNil(parts[1]["inlineData"])
    }

    func testOpenCodeRoutesPublicAPIsAndUsesConversationSession() throws {
        let session = UUID()
        for (model, suffix) in [("gpt-test", "responses"), ("grok-test", "responses"),
                                ("claude-test", "messages"), ("qwen-test", "messages"),
                                ("glm-test", "chat/completions")] {
            let request = try APIProviderClient.chatRequest(provider: .init(kind: .openCode), model: .init(id: model, name: model),
                key: "fake-key", messages: [.init(role: .user, text: "Question")], maximumOutputTokens: 512, sessionID: session)
            XCTAssertEqual(request.url?.path, "/zen/go/v1/" + suffix)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), session.uuidString)
        }
    }

    func testModelCatalogFiltersFreeRoutesAndGeminiEmbeddingModels() throws {
        let free = try APIProviderClient.models(in: ["data": [["id": "vendor/paid"], ["id": "vendor/model:free", "name": "Free",
            "architecture": ["input_modalities": ["text", "image"]], "context_length": 128_000]]], provider: .init(kind: .openRouterFree))
        XCTAssertEqual(free.map(\.id), ["vendor/model:free"])
        XCTAssertTrue(free[0].supportsImages)
        let gemini = try APIProviderClient.models(in: ["models": [
            ["name": "models/chat", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 8_192],
            ["name": "models/embed", "supportedGenerationMethods": ["embedContent"]]]], provider: .init(kind: .gemini))
        XCTAssertEqual(gemini.map(\.id), ["chat"])
    }

    func testChatStreamCombinesReasoningAndTextAndDetectsTokenLimit() throws {
        var decoder = APIProviderStreamDecoder(format: .chatCompletions)
        try decoder.consume(line: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Plan\"}}]}")
        try decoder.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}")
        try decoder.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")
        try decoder.finish()
        XCTAssertEqual(decoder.reply.text, "<think>Plan</think>Answer")
        XCTAssertTrue(decoder.reply.hitTokenLimit)
    }

    func testResponsesStreamHandlesUsageAndProviderFailureWithoutReflectingSecrets() throws {
        var decoder = APIProviderStreamDecoder(format: .responses)
        try decoder.consume(line: "event: response.output_text.delta")
        try decoder.consume(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}")
        try decoder.consume(line: "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}")
        try decoder.finish()
        XCTAssertEqual(decoder.reply.text, "Hi")
        XCTAssertEqual(decoder.reply.inputTokens, 10)
        var failed = APIProviderStreamDecoder(format: .responses)
        XCTAssertThrowsError(try failed.consume(line: "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"secret-key user prompt\"}}")) {
            XCTAssertFalse(APIProviderClient.safeError($0).contains("secret-key"))
        }
    }

    func testAnthropicAndGeminiStreamCompletion() throws {
        var anthropic = APIProviderStreamDecoder(format: .anthropic)
        try anthropic.consume(line: "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}")
        try anthropic.consume(line: "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":2}}")
        try anthropic.consume(line: "data: {\"type\":\"message_stop\"}")
        try anthropic.finish()
        XCTAssertEqual(anthropic.reply.text, "Hi")
        XCTAssertEqual(anthropic.reply.outputTokens, 2)
        var gemini = APIProviderStreamDecoder(format: .gemini)
        try gemini.consume(line: "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":4,\"candidatesTokenCount\":2}}")
        try gemini.finish()
        XCTAssertEqual(gemini.reply.text, "Hi")
        XCTAssertEqual(gemini.reply.inputTokens, 4)
    }

    func testDisconnectedAndMultilineStreams() throws {
        var incomplete = APIProviderStreamDecoder(format: .responses)
        try incomplete.consume(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}")
        XCTAssertThrowsError(try incomplete.finish()) { XCTAssertEqual($0 as? APIProviderError, .incompleteStream) }
        var multiline = APIProviderStreamDecoder(format: .responses)
        try multiline.consume(line: "data: {\"type\":\"response.output_text.delta\",")
        try multiline.consume(line: "data: \"delta\":\"Joined\"}")
        try multiline.consume(line: "data: {\"type\":\"response.completed\"}")
        try multiline.finish()
        XCTAssertEqual(multiline.reply.text, "Joined")
    }

    func testJSONFallbackAndOversizedEvent() throws {
        var decoder = APIProviderStreamDecoder(format: .chatCompletions)
        try decoder.consumeJSON(Data("{\"choices\":[{\"message\":{\"content\":\"Fallback\"},\"finish_reason\":\"stop\"}]}".utf8), isFinalResponse: true)
        XCTAssertEqual(decoder.reply.text, "Fallback")
        var oversized = APIProviderStreamDecoder(format: .responses)
        XCTAssertThrowsError(try oversized.consume(line: String(repeating: "a", count: 256 * 1_024 + 1))) {
            XCTAssertEqual($0 as? APIProviderError, .responseTooLarge)
        }
    }
}
