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

    func testMissingRecoverLoRAIsRejectedBeforeCheckpointParsing() throws {
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(Edge0ModelConfigurationTests.realConfigJSON.utf8)
            ) as? [String: Any]
        )
        try writeArtifacts(config: config, includeWeights: true)
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            XCTAssertEqual(
                error as? Edge0ModelArtifactError,
                .missingFile("lora_edge0_8b.safetensors")
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
        try Edge0TestFixtures.writeSafetensors(
            at: directory.appendingPathComponent("lora_edge0_8b.safetensors"),
            tensors: []
        )
        XCTAssertThrowsError(try Edge0ModelArtifacts.validate(directory: directory)) { error in
            guard case .invalidWeightGeometry? =
                error as? Edge0ModelArtifactError else {
                return XCTFail("Expected invalidWeightGeometry, got \(error)")
            }
        }
    }

    func testPublishedLoRAInventoryAndShapesAreRequired() throws {
        let (configuration, base, adapter) = try syntheticLoRAIndexes()
        XCTAssertNoThrow(try Edge0ModelArtifacts.validateLoRAGeometry(
            adapter: adapter, base: base, configuration: configuration
        ))

        let name = "model.layers.0.attention.q_proj.lora_A"
        var wrongShape = adapter.locations
        wrongShape[name] = location(name, dtype: .f16, shape: [8, 256])
        XCTAssertThrowsError(try Edge0ModelArtifacts.validateLoRAGeometry(
            adapter: index(wrongShape), base: base, configuration: configuration
        ))

        var extra = adapter.locations
        extra["unexpected.lora_A"] = location(
            "unexpected.lora_A", dtype: .f16, shape: [16, 256]
        )
        XCTAssertThrowsError(try Edge0ModelArtifacts.validateLoRAGeometry(
            adapter: index(extra), base: base, configuration: configuration
        ))
    }

    private func syntheticLoRAIndexes() throws -> (
        Edge0ModelConfiguration, Edge0SafetensorsIndex, Edge0SafetensorsIndex
    ) {
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(Edge0ModelConfigurationTests.realConfigJSON.utf8)
        )
        var base: [String: Edge0TensorLocation] = [:]
        var adapter: [String: Edge0TensorLocation] = [:]
        for layer in 0..<24 {
            let prefix = "model.layers.\(layer)"
            let attention = layer % 4 == 3
                ? ["q_b_proj", "kv_b_proj", "dense", "g_proj"]
                : ["q_proj", "k_proj", "v_proj", "f_proj", "g_proj", "b_proj", "o_proj"]
            var modules = attention.map { "\(prefix).attention.\($0)" }
            if layer == 0 {
                modules += ["gate_proj", "up_proj", "down_proj"].map {
                    "\(prefix).mlp.\($0)"
                }
            }
            for module in modules {
                base["\(module).weight"] = location(
                    "\(module).weight", dtype: .u32, shape: [64, 32]
                )
                adapter["\(module).lora_A"] = location(
                    "\(module).lora_A", dtype: .f16, shape: [16, 256]
                )
                adapter["\(module).lora_B"] = location(
                    "\(module).lora_B", dtype: .f16, shape: [64, 16]
                )
            }
        }
        XCTAssertEqual(adapter.count, 306)
        return (configuration, index(base), index(adapter))
    }

    private func index(
        _ locations: [String: Edge0TensorLocation]
    ) -> Edge0SafetensorsIndex {
        Edge0SafetensorsIndex(locations: locations, shardNames: [], fileSizes: [:])
    }

    private func location(
        _ name: String,
        dtype: Edge0SafetensorsDType,
        shape: [Int]
    ) -> Edge0TensorLocation {
        Edge0TensorLocation(
            name: name, shard: "fixture.safetensors", payloadOffset: 0,
            byteCount: UInt64(shape.reduce(1, *) * dtype.byteWidth),
            dtype: dtype, shape: shape
        )
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
