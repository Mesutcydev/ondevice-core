import XCTest
@testable import NativeUIReview

nonisolated private final class MockAPIState: @unchecked Sendable {
    struct Response { var status = 200; var type = "application/json"; var body: String; var wait = false }
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> Response)?
    private var recorded: [URLRequest] = []
    private var stopped = 0
    func reset(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { self.handler = handler; recorded = []; stopped = 0 }
    }
    func response(_ request: URLRequest) -> Response {
        let callback = lock.withLock { recorded.append(request); return handler }
        return callback?(request) ?? Response(body: "{}")
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var stopCount: Int { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped += 1 } }
}

nonisolated private final class MockAPIProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockAPIState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.type])!, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: Data(response.body.utf8)) }
        if !response.wait { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop() }
}

nonisolated private final class APITextCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ value: String) { lock.withLock { text += value } }
    var value: String { lock.withLock { text } }
}

@MainActor
final class APIProviderHTTPTests: XCTestCase {
    private func client() -> APIProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAPIProtocol.self]
        return APIProviderClient(configuration: configuration)
    }
    private func provider(_ kind: APIProviderKind = .openAI) -> APIProviderConfiguration {
        var provider = APIProviderConfiguration(kind: kind)
        provider.baseURL = "https://mock.example.com/v1"
        return provider
    }

    func testRealHTTPModelCatalogPaginatesGeminiAndAuthenticatesEveryPage() async throws {
        MockAPIProtocol.state.reset { request in
            if request.url?.query?.contains("pageToken=second") == true {
                return .init(body: "{\"models\":[{\"name\":\"models/chat-two\",\"supportedGenerationMethods\":[\"generateContent\"]}]}")
            }
            return .init(body: "{\"models\":[{\"name\":\"models/chat-one\",\"supportedGenerationMethods\":[\"generateContent\"]}],\"nextPageToken\":\"second\"}")
        }
        let models = try await client().fetchModels(provider: provider(.gemini), key: "fake-key")
        XCTAssertEqual(Set(models.map(\.id)), ["chat-one", "chat-two"])
        XCTAssertEqual(MockAPIProtocol.state.requests.count, 2)
        XCTAssertTrue(MockAPIProtocol.state.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "x-goog-api-key") == "fake-key" && !($0.url?.absoluteString.contains("fake-key") ?? true)
        })
    }

    func testRealHTTPStreamDeliversDeltasAndUsageTrailer() async throws {
        MockAPIProtocol.state.reset { _ in .init(type: "text/event-stream", body: """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}

        data: [DONE]

        """) }
        let capture = APITextCapture()
        let reply = try await client().stream(provider: provider(.deepSeek), model: .init(id: "fixture-chat", name: "Test"),
            key: "fake-key", messages: [.init(role: .user, text: "Question")], maximumOutputTokens: 512,
            sessionID: UUID(), onText: { capture.append($0) })
        XCTAssertEqual(capture.value, "Hello world")
        XCTAssertEqual(reply.text, capture.value)
        XCTAssertEqual(reply.inputTokens, 10)
        XCTAssertEqual(reply.outputTokens, 2)
    }

    func testStreamingCombiningMarksAndJoinedEmojiPreservesEveryDelta() async throws {
        MockAPIProtocol.state.reset { _ in .init(type: "text/event-stream", body: #"""
        data: {"choices":[{"delta":{"content":"Cafe"}}]}

        data: {"choices":[{"delta":{"content":"\u0301"}}]}

        data: {"choices":[{"delta":{"content":" 👩"}}]}

        data: {"choices":[{"delta":{"content":"\u200d"}}]}

        data: {"choices":[{"delta":{"content":"💻"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """#) }
        let capture = APITextCapture()
        let reply = try await client().stream(provider: provider(.deepSeek), model: .init(id: "fixture-chat", name: "Test"),
            key: "fake-key", messages: [.init(role: .user, text: "Question")], maximumOutputTokens: 512,
            sessionID: UUID(), onText: { capture.append($0) })
        XCTAssertEqual(capture.value, "Cafe\u{301} 👩\u{200D}💻")
        XCTAssertEqual(Array(capture.value.unicodeScalars), Array(reply.text.unicodeScalars))
    }

    func testHTTPFailureDoesNotRetryOrReflectProviderErrorBody() async throws {
        MockAPIProtocol.state.reset { _ in .init(status: 401, body: "{\"error\":\"fake-key private question\"}") }
        do {
            _ = try await client().fetchModels(provider: provider(), key: "fake-key")
            XCTFail("Expected access refusal")
        } catch {
            XCTAssertEqual(error as? APIProviderError, .http(401))
            XCTAssertFalse(APIProviderClient.safeError(error).contains("fake-key"))
        }
        XCTAssertEqual(MockAPIProtocol.state.requests.count, 1)
    }

    func testCancellingAStreamingRequestStopsItsURLSessionTask() async throws {
        MockAPIProtocol.state.reset { _ in .init(type: "text/event-stream", body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n", wait: true) }
        let client = client()
        let configuration = provider()
        let capture = APITextCapture()
        let task = Task {
            try await client.stream(provider: configuration, model: .init(id: "fixture-chat", name: "Test"), key: "fake-key",
                messages: [.init(role: .user, text: "Question")], maximumOutputTokens: 512,
                sessionID: UUID(), onText: { capture.append($0) })
        }
        let delivered = NSPredicate { _, _ in capture.value == "Partial" }
        let deliveredExpectation = expectation(for: delivered, evaluatedWith: nil)
        await fulfillment(of: [deliveredExpectation], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertGreaterThan(MockAPIProtocol.state.stopCount, 0)
    }
}
