import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0_35BConfigurationTests
//
// Phase 5A discovery gate for Edge0/Edge0-35B-A3B-preview. Real-checkpoint
// metadata tests are gated on EDGE0_35B_MODEL (a staged directory with
// config.json, tokenizer.json, chat_template.jinja, tokenizer_fixture.json
// and optionally shard_inventory.json — the 19.5 GB shards are not needed).

final class Edge0_35BConfigurationTests: XCTestCase {

    private func stagedDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment[
            "EDGE0_35B_MODEL"
        ], !directory.isEmpty,
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: directory)
                    .appendingPathComponent("config.json").path
            ) else {
            throw XCTSkip("Set EDGE0_35B_MODEL to a staged 35B metadata dir")
        }
        return URL(fileURLWithPath: directory)
    }

    func testConfigurationMatchesVerifiedContract() throws {
        let directory = try stagedDirectory()
        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: directory.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_35B()

        XCTAssertEqual(configuration.modelType, "qwen3_5_moe_text")
        XCTAssertEqual(configuration.wrapperModelType, "qwen3_5_moe")
        XCTAssertEqual(configuration.releasedExpertsPerToken, 4)
        XCTAssertEqual(configuration.configuredExpertsPerToken, 8)
        XCTAssertEqual(configuration.tieWordEmbeddings, false)
        XCTAssertEqual(configuration.headDim, 256)
        XCTAssertEqual(configuration.numKeyValueHeads, 2)
        XCTAssertEqual(configuration.partialRotaryFactor, 0.25)
        XCTAssertEqual(configuration.mropeSection, [11, 11, 10])
        XCTAssertEqual(configuration.linearNumValueHeads, 32)
        XCTAssertEqual(configuration.linearNumKeyHeads, 16)
        XCTAssertEqual(configuration.mambaSSMDtype, "float32")

        // Full-attention layers at 3, 7, ... 39.
        for index in stride(from: 3, to: 40, by: 4) {
            XCTAssertEqual(configuration.layerTypes[index], .fullAttention)
        }
        XCTAssertEqual(
            configuration.layerTypes.filter { $0 == .linearAttention }.count,
            30
        )
    }

    func testQuantizationContract() throws {
        let directory = try stagedDirectory()
        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: directory.appendingPathComponent("config.json"))
        )
        XCTAssertEqual(configuration.quantizationBits, 4)
        XCTAssertEqual(configuration.quantizationGroupSize, 64)
        XCTAssertEqual(configuration.quantizationMode, "affine")
        XCTAssertEqual(configuration.eightBitModules.count, 80)
        XCTAssertTrue(configuration.eightBitModules.allSatisfy {
            $0.hasSuffix(".mlp.gate") || $0.hasSuffix(".mlp.shared_expert_gate")
        })
    }

    func testExpertLayoutAccounting() throws {
        let layout = Edge0_35BExpertLayout.shared
        XCTAssertEqual(
            layout.perExpertBundleBytes,
            3 * layout.perProjectionBytes
        )
        XCTAssertEqual(
            layout.totalRoutedExpertBytes,
            UInt64(layout.layerCount) * UInt64(layout.expertCount)
                * layout.perExpertBundleBytes
        )
        XCTAssertEqual(
            layout.checkpointBytes,
            layout.totalRoutedExpertBytes + layout.residentCommonBytes
        )
        XCTAssertEqual(
            layout.tensorName(layer: 7, projection: "down_proj", part: "weight"),
            "language_model.model.layers.7.mlp.switch_mlp.down_proj.weight"
        )
    }

    func testArchitectureIdentityCoversBothFamilies() {
        let bailing: [String: Any] = ["architectures": ["BailingMoeV3ForCausalLM"]]
        let qwen35: [String: Any] = [
            "architectures": ["Qwen3_5MoeForConditionalGeneration"],
        ]
        let other: [String: Any] = ["architectures": ["LlamaForCausalLM"]]
        XCTAssertTrue(Edge0_35BModelConfiguration.isEdge0Architecture(bailing))
        XCTAssertTrue(Edge0_35BModelConfiguration.isEdge0Architecture(qwen35))
        XCTAssertFalse(Edge0_35BModelConfiguration.isEdge0Architecture(other))
        XCTAssertFalse(Edge0_35BModelConfiguration.isEdge0Architecture(nil))
    }

    func testShardInventoryMatchesAccounting() throws {
        let directory = try stagedDirectory()
        let inventoryURL = directory.appendingPathComponent("shard_inventory.json")
        guard FileManager.default.fileExists(atPath: inventoryURL.path) else {
            throw XCTSkip("shard_inventory.json not staged")
        }
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: inventoryURL)
        ) as? [String: [String: Any]] ?? [:]
        XCTAssertEqual(raw.count, Edge0_35BModelConfiguration.edge0_35BExpectation.tensorCount)
        let total = raw.values.reduce(UInt64(0)) {
            $0 + UInt64(($1["bytes"] as? Int) ?? 0)
        }
        XCTAssertEqual(total, Edge0_35BExpertLayout.shared.checkpointBytes)
        let experts = raw.filter { $0.key.contains(".switch_mlp.") }
            .values.reduce(UInt64(0)) { $0 + UInt64(($1["bytes"] as? Int) ?? 0) }
        XCTAssertEqual(
            experts, Edge0_35BExpertLayout.shared.totalRoutedExpertBytes
        )
        let shards = Set(raw.values.compactMap { $0["shard"] as? String })
        XCTAssertEqual(
            shards.count,
            Edge0_35BModelConfiguration.edge0_35BExpectation.shardCount
        )
    }

    // MARK: Tokenizer / chat template parity

    func testTokenizerAndChatTemplateMatchPython() async throws {
        let directory = try stagedDirectory()
        let fixtureURL = directory.appendingPathComponent("tokenizer_fixture.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("tokenizer_fixture.json not staged")
        }
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL)
        ) as? [String: Any] ?? [:]
        let strings = fixture["strings"] as? [String: [Int]] ?? [:]
        let chatIDs = fixture["chat_template_ids"] as? [Int] ?? []

        let tokenizer = try await Edge0Tokenizer.load(from: directory)
        for (name, expected) in strings {
            XCTAssertEqual(
                tokenizer.encode(name == "specials" ? "hello" : Self.texts[name] ?? ""),
                expected,
                "tokenizer mismatch for \(name)"
            )
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "The capital of France is"],
        ]
        let rendered = try tokenizer.applyChatTemplate(
            messages: messages, templateDirectory: directory
        )
        XCTAssertEqual(rendered, chatIDs, "chat template token IDs")
    }

    private static let texts: [String: String] = [
        "english": "The capital of France is",
        "code": "def add(a, b):\n    return a + b\n",
        "turkish": "İstanbul'da hava çok güzel.",
        "chinese": "今天天气很好。",
        "newline": "a\n\nb",
    ]
}
