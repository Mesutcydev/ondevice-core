import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0ModelArtifactsTests

final class Edge0ModelArtifactsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("artifacts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRealCheckpointValidates() throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        XCTAssertNoThrow(
            try Edge0ModelArtifacts.validate(
                directory: URL(fileURLWithPath: modelDirectory)
            )
        )
    }

    func testMissingArtifactIsRejected() throws {
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("config.json")
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer.json")
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer_config.json")
        )
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            XCTAssertEqual(
                error as? Edge0ModelArtifactError,
                .missingFile("model.safetensors")
            )
        }
    }

    func testWrongArchitectureIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(Edge0ModelConfigurationTests.realConfigJSON.utf8)
            ) as? [String: Any]
        )
        object["architectures"] = ["SomethingElseForCausalLM"]
        try writeArtifacts(config: object, includeWeights: true)
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            guard case .unsupportedArchitecture? =
                error as? Edge0ModelArtifactError else {
                return XCTFail("Expected unsupportedArchitecture, got \(error)")
            }
        }
    }

    func testWrongExpertGeometryIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(Edge0ModelConfigurationTests.realConfigJSON.utf8)
            ) as? [String: Any]
        )
        object["num_experts"] = 64
        try writeArtifacts(config: object, includeWeights: true)
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            guard case .invalidConfiguration? =
                error as? Edge0ModelArtifactError else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
        }
    }

    func testWeightGeometryMismatchIsRejected() throws {
        try writeArtifacts(
            config: try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(Edge0ModelConfigurationTests.realConfigJSON.utf8)
                ) as? [String: Any]
            ),
            includeWeights: false
        )
        // A header-only weights file with no embedding/expert tensors.
        try Edge0TestFixtures.writeSafetensors(
            at: directory.appendingPathComponent("model.safetensors"),
            tensors: [("model.norm.weight", "BF16", [1536], Data(count: 3072))]
        )
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            guard case .invalidWeightGeometry? =
                error as? Edge0ModelArtifactError else {
                return XCTFail("Expected invalidWeightGeometry, got \(error)")
            }
        }
    }

    private func writeArtifacts(
        config: [String: Any],
        includeWeights: Bool
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer.json")
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer_config.json")
        )
        if includeWeights {
            try Data(count: 1).write(
                to: directory.appendingPathComponent("model.safetensors")
            )
        }
    }
}
