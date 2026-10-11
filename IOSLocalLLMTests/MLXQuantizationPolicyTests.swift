import Foundation
import XCTest
@testable import IOSLocalLLM

final class MLXQuantizationPolicyTests: XCTestCase {
    private var dense: [String: Any] {
        ["model_type": "qwen3", "num_hidden_layers": 32,
         "num_attention_heads": 32, "num_key_value_heads": 8,
         "hidden_size": 4_096, "head_dim": 128,
         "intermediate_size": 14_336, "vocab_size": 151_936,
         "torch_dtype": "bfloat16"]
    }

    private func policy(
        enabled: Bool = true, bounded: Bool = false, vision: Bool = false,
        config: [String: Any]? = nil
    ) -> MLXAssistantKVCachePolicy {
        .resolve(enabled: enabled, boundedCache: bounded, vision: vision, config: config ?? dense)
    }

    func testExistingDefaultsAndBoundedFamiliesKeepTheirCachePolicy() {
        XCTAssertEqual(policy(enabled: false), .standard)
        XCTAssertEqual(policy(bounded: true), .standard)
        XCTAssertEqual(policy(vision: true), .standard)
        for architecture in ["qwen3_5", "qwen3_5_text", "bailing_moe", "gemma3", "mamba", "unknown"] {
            var config = dense
            config["model_type"] = architecture
            XCTAssertEqual(policy(config: config), .standard, architecture)
        }
    }

    func testSupportedDenseModelsUseAsymmetricSchemeOnlyWhenOptedIn() {
        for architecture in ["llama", "mistral", "qwen2", "qwen3"] {
            for dimension in [64, 128, 256] {
                var config = dense
                config["model_type"] = architecture
                config["head_dim"] = dimension
                XCTAssertEqual(policy(config: config).scheme, "turbo8v3")
            }
        }
    }

    func testUnknownAndMalformedShapesRetainStandardCache() {
        XCTAssertEqual(MLXAssistantKVCachePolicy.resolve(
            enabled: true, boundedCache: false, vision: false, config: nil
        ), .standard)
        for (key, value): (String, Any) in [
            ("head_dim", 80), ("head_dim", -128), ("num_attention_heads", 0),
            ("num_key_value_heads", 0), ("num_key_value_heads", 7),
            ("hidden_size", Int.max), ("torch_dtype", "float32"),
            ("vocab_size", 0), ("intermediate_size", Int.max),
            ("text_config", dense), ("num_hidden_layers", 0),
        ] {
            var config = dense
            config[key] = value
            XCTAssertEqual(policy(config: config), .standard, key)
        }
    }

    func testTurboAdmissionIncludesRawPrefillAndConversionOverlap() throws {
        func estimate(scheme: String?, rotating: Bool = false, bits: Int = 8) throws -> MLXModelMemoryEstimate {
            try XCTUnwrap(MLXModelMemoryEstimate.estimate(
                weights: 0, config: dense, contextTokens: 2_048,
                rotatingCache: rotating, kvBits: bits, prefillTokens: 128,
                allocatorCache: 0, runtimeReserve: 250_000_000,
                kvScheme: scheme
            ))
        }
        let affine = try estimate(scheme: nil)
        let raw = try estimate(scheme: nil, bits: 0)
        let turbo = try estimate(scheme: "turbo8v3")
        XCTAssertGreaterThan(turbo.kvCache, raw.kvCache)
        XCTAssertGreaterThan(turbo.peak, affine.peak)
        XCTAssertEqual(turbo.weights, 0, "Already resident weights stay charged only once")
        XCTAssertGreaterThan(turbo.prefillScratch, raw.prefillScratch,
                             "TurboQuant normalization also needs FP32 workspace")
        XCTAssertEqual(try estimate(scheme: "turbo8v3", rotating: true),
                       try estimate(scheme: nil, rotating: true))
    }

    func testLittleBitMetadataDoesNotMisclassifyBonsaiOrRepositoryNames() {
        XCTAssertTrue(ModelCheckpointCompatibility.identifiesLittleBit(["quant_mod": "LittleBitLinear"]))
        XCTAssertTrue(ModelCheckpointCompatibility.identifiesLittleBit([
            "quantization_config": ["quant_method": "littlebit-2"]
        ]))
        XCTAssertFalse(ModelCheckpointCompatibility.identifiesLittleBit([
            "_name_or_path": "example/littlebit-notes", "model_type": "llama",
            "quantization": ["bits": 1, "group_size": 64, "mode": "affine"]
        ]))
    }

    func testLittleBitSidecarFailsBeforeWeightsAreOpenedAndPreservesFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: dense).write(to: config)
        XCTAssertNoThrow(try ModelCheckpointCompatibility.validateMLXDirectory(directory))
        let marker = directory.appendingPathComponent("littlebit_config.json")
        try Data("{}".utf8).write(to: marker)
        XCTAssertThrowsError(try ModelCheckpointCompatibility.validateMLXDirectory(directory)) { error in
            XCTAssertTrue(error is ModelCheckpointCompatibility.UnsupportedLittleBit)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
