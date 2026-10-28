import XCTest
@testable import NativeUIReview

final class LocalAPIWorkspaceTests: XCTestCase {
    func testListenerStateTakesPrecedenceOverSharedRuntimeActivity() {
        for model in [LocalAPIServerActivity.Model.ready, .generating, .loading, .failed, .remote] {
            XCTAssertEqual(LocalAPIServerActivity(listener: .stopped, model: model), .offline)
            XCTAssertEqual(LocalAPIServerActivity(listener: .starting, model: model), .starting)
            XCTAssertEqual(LocalAPIServerActivity(listener: .failed, model: model), .failed)
            XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: model, isStopping: true), .stopping)
        }
    }

    func testRunningListenerRequiresALocalModelToBeReady() {
        XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: .remote), .listening)
        XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: .unloaded), .listening)
        XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: .loading), .loading)
        XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: .ready), .ready)
        XCTAssertEqual(LocalAPIServerActivity(listener: .running, model: .generating), .generating)
        XCTAssertFalse(LocalAPIServerActivity.offline.isWorking)
        XCTAssertFalse(LocalAPIServerActivity.ready.isWorking)
        XCTAssertTrue(LocalAPIServerActivity.generating.isWorking)
    }

    func testSetupUsesTheProvidedListenerPortAndDialect() throws {
        let setup = LocalAPIClientSetup(host: "192.0.2.10", port: 12000, modelID: "org/model")
        XCTAssertEqual(setup.openAIBaseURL, "http://192.0.2.10:12000/v1")
        let openAI = setup.example(for: .openAI, apiKey: "fixture-key")
        XCTAssertTrue(openAI.contains("OPENAI_BASE_URL='http://192.0.2.10:12000/v1'"))
        XCTAssertTrue(openAI.contains("OPENAI_API_KEY='fixture-key'"))
        let ollama = setup.example(for: .ollama, apiKey: "fixture-key")
        XCTAssertTrue(ollama.contains("http://192.0.2.10:12000/api/tags"))
        XCTAssertTrue(ollama.contains("Authorization: Bearer fixture-key"))
        let anthropic = setup.example(for: .anthropic, apiKey: "fixture-key")
        let json = try XCTUnwrap(anthropic.components(separatedBy: "-d '").last?.dropLast())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "org/model")
        XCTAssertEqual(body["max_tokens"] as? Int, 128)
        XCTAssertTrue(anthropic.contains("x-api-key: fixture-key"))
    }

    func testRecipesEscapeImportedModelNamesAndShellMetacharacters() throws {
        let identifier = "local/Model \"quoted\"\\name"
        let setup = LocalAPIClientSetup(host: "192.0.2.10", port: 11434, modelID: identifier)
        let example = setup.example(for: .anthropic, apiKey: "fixture-key")
        let json = try XCTUnwrap(example.components(separatedBy: "-d '").last?.dropLast())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, identifier)
        let credential = "fixture'$(test)"
        let shell = setup.example(for: .openAI, apiKey: credential)
        XCTAssertTrue(shell.contains("OPENAI_API_KEY='fixture'\"'\"'$(test)'"))
    }

    func testModelDetailURLKeepsIdentifierInOnePathComponent() throws {
        let route = try XCTUnwrap(LocalAPIClientSetup.routes.first { $0.path == "/v1/models/{model}" })
        let setup = LocalAPIClientSetup(host: "localhost", port: 11434, modelID: "org/model?size=1#copy")
        XCTAssertEqual(setup.url(for: route), "http://localhost:11434/v1/models/org%2Fmodel%3Fsize=1%23copy")
        XCTAssertEqual(URL(string: setup.url(for: route))?.query, nil)
        XCTAssertEqual(URL(string: setup.url(for: route))?.fragment, nil)
    }

    func testEndpointCatalogIncludesClassifierFunctionsAndUniqueRoutes() {
        let routes = LocalAPIClientSetup.routes
        XCTAssertEqual(routes.count, Set(routes.map(\.id)).count)
        XCTAssertTrue(routes.contains { $0.id == "GET /v1/classifiers" })
        XCTAssertTrue(routes.contains { $0.id == "POST /v1/classifiers/activate" })
        XCTAssertTrue(routes.contains { $0.id == "POST /v1/classifications" })
    }
}
