import XCTest
@testable import IOSLocalLLM

final class Bonsai2CompatibilityTests: XCTestCase {
    private var config: [String: Any] {
        ["model_type": "prism_hadamard_qwen35", "schema_version": 2,
         "base_model_type": "qwen3_5", "tensor_namespace": "mlx-vlm-qwen3_5",
         "gdn_activation_layout": "grouped",
         "quantization": ["bits": 2, "group_size": 128, "mode": "affine"],
         "text_config": ["hidden_size": 4096, "num_hidden_layers": 32, "vocab_size": 248320,
             "tie_word_embeddings": false, "intermediate_size": 12288, "num_attention_heads": 16,
             "num_key_value_heads": 4, "head_dim": 256, "linear_num_key_heads": 16,
             "linear_num_value_heads": 32, "linear_key_head_dim": 128, "linear_value_head_dim": 128,
             "linear_conv_kernel_dim": 4, "full_attention_interval": 4, "attention_bias": false,
             "rms_norm_eps": 0.000001, "rope_parameters": ["rope_theta": 10000000,
                 "partial_rotary_factor": 0.25, "rope_type": "default"]],
         "modules": [["path": "model.embed_tokens", "block": 4096, "embedding": true, "dtype": "float16"],
                     ["path": "lm_head", "block": 4096, "embedding": false, "dtype": "float16"]]]
    }
    func testSupported9BContract() { XCTAssertTrue(Bonsai2Compatibility.supportsText(config)) }
    func testUnknownSchemaAndActivationLayoutAreRejected() {
        for (key, value) in [("schema_version", 1 as Any), ("gdn_activation_layout", "ungrouped" as Any),
                             ("tensor_namespace", "unknown" as Any)] {
            var json = config; json[key] = value
            XCTAssertFalse(Bonsai2Compatibility.supportsText(json), key)
        }
    }
    func testOtherQuantizationCannotUseHadamardAdapter() {
        var json = config
        for bits in [1, 4, 8] {
            json["quantization"] = ["bits": bits, "group_size": 128, "mode": "affine"]
            XCTAssertFalse(Bonsai2Compatibility.supportsText(json))
        }
    }
    func testOtherSizesAndInvalidHeadRatiosAreRejected() {
        for (key, value) in [("hidden_size", 5120), ("num_hidden_layers", 64),
                             ("linear_num_key_heads", 0), ("num_experts", 128)] {
            var json = config; var text = json["text_config"] as! [String: Any]
            text[key] = value; json["text_config"] = text
            XCTAssertFalse(Bonsai2Compatibility.supportsText(json), key)
        }
    }
    func testDuplicateAndUnsupportedTransformRecordsAreRejected() {
        var json = config; var modules = json["modules"] as! [[String: Any]]
        modules.append(modules[0]); json["modules"] = modules
        XCTAssertFalse(Bonsai2Compatibility.supportsText(json))
        modules.removeLast(); modules[0]["block"] = 3; json["modules"] = modules
        XCTAssertFalse(Bonsai2Compatibility.supportsText(json))
    }
    func testExistingModelTypesAreNotClaimed() {
        for type in ["qwen3", "qwen3_5", "llama", "nanbeige", "gemma3"] {
            var json = config; json["model_type"] = type
            XCTAssertFalse(Bonsai2Compatibility.supportsText(json))
        }
    }
    private var visionConfig: [String: Any] {
        var json = config
        json["components"] = ["text": true, "vision": true, "mtp": false]
        json["vision_config"] = ["model_type": "qwen3_5", "hidden_act": "gelu_pytorch_tanh",
            "deepstack_visual_indexes": [Int](), "depth": 27, "hidden_size": 1152,
            "intermediate_size": 4304, "num_heads": 16, "num_position_embeddings": 2304,
            "in_channels": 3, "out_hidden_size": 4096, "patch_size": 16,
            "spatial_merge_size": 2, "temporal_patch_size": 2]
        json["image_token_id"] = 248056; json["video_token_id"] = 248057
        json["vision_start_token_id"] = 248053; json["vision_end_token_id"] = 248054
        return json
    }
    func testCompleteVisionContractAccepted() {
        XCTAssertTrue(Bonsai2Compatibility.supportsVision(visionConfig))
        XCTAssertFalse(Bonsai2Compatibility.supportsVision(config))
    }
    func testMissingVisionAndWrongEncoderGeometryRejected() {
        var json = visionConfig; json["components"] = ["text": true, "vision": false]
        XCTAssertFalse(Bonsai2Compatibility.supportsVision(json))
        for key in ["patch_size", "hidden_size", "spatial_merge_size", "depth"] {
            json = visionConfig; var vision = json["vision_config"] as! [String: Any]
            vision[key] = 0; json["vision_config"] = vision
            XCTAssertFalse(Bonsai2Compatibility.supportsVision(json), key)
            XCTAssertTrue(Bonsai2Compatibility.supportsText(json))
        }
    }
    func testMismatchedImageTokenIDsRejected() {
        for key in ["image_token_id", "video_token_id", "vision_start_token_id", "vision_end_token_id"] {
            var json = visionConfig; json[key] = 0
            XCTAssertFalse(Bonsai2Compatibility.supportsVision(json), key)
        }
    }


}
