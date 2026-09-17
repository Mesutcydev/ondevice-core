import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0ModelConfigurationTests
//
// Parses and validates the real Edge0-8B `config.json`
// (BailingMoeV3ForCausalLM). Embedded verbatim so the test runs without a
// checkpoint download; no weights are involved.

final class Edge0ModelConfigurationTests: XCTestCase {

    /// `Edge0/Edge0-8B-A1B-preview` config.json, fetched from the published
    /// artifact; the reference SHA is recorded in Docs/EDGE0_NATIVE_FOUNDATION.md.
    static let realConfigJSON = #"""
{
  "architectures": [
    "BailingMoeV3ForCausalLM"
  ],
  "attention_dropout": 0.0,
  "auto_map": {
    "AutoConfig": "configuration_bailing_moe_v3.BailingMoeV3Config",
    "AutoModel": "modeling_bailing_moe_v3.BailingMoeV3Model",
    "AutoModelForCausalLM": "modeling_bailing_moe_v3.BailingMoeV3ForCausalLM"
  },
  "dtype": "bfloat16",
  "embedding_dropout": 0.0,
  "eos_token_id": 156895,
  "expert_swiglu_limit_list": null,
  "first_k_dense_replace": 1,
  "gated_attention_proj_granularity_type": "head_wise",
  "group_norm_size": 1,
  "head_dim": 128,
  "hidden_act": "silu",
  "hidden_size": 1536,
  "initializer_range": 0.02,
  "intermediate_size": 4608,
  "kda_lower_bound": -5,
  "kda_safe_gate": true,
  "kv_lora_rank": 512,
  "layer_group_size": 4,
  "linear_silu": true,
  "max_position_embeddings": 131072,
  "max_window_layers": 20,
  "moe_intermediate_size": 512,
  "moe_router_enable_expert_bias": true,
  "moe_shared_expert_intermediate_size": 512,
  "mtp_loss_scaling_factor": 0,
  "mtp_use_kda": false,
  "n_group": 8,
  "no_kda_lora": true,
  "norm_topk_prob": true,
  "num_attention_heads": 16,
  "num_experts": 128,
  "num_experts_per_tok": 8,
  "num_hidden_layers": 24,
  "num_key_value_heads": 16,
  "num_kv_heads_for_linear_attn": 0,
  "num_nextn_predict_layers": 0,
  "num_shared_experts": 1,
  "output_dropout": 0.0,
  "output_router_logits": false,
  "pad_token_id": 156892,
  "partial_rotary_factor": 0.5,
  "pregate_cross_token": true,
  "pregate_enabled": true,
  "pregate_hidden": 512,
  "pregate_inference": false,
  "pregate_init_router": false,
  "pregate_opd_ce_weight": 1.0,
  "pregate_opd_strategy": "none",
  "pregate_opd_temperature": 1.0,
  "pregate_opd_topk": 8,
  "pregate_opd_weight": 1.0,
  "pregate_opd_weight_mode": "teacher_p",
  "pregate_shallow_hidden": 1024,
  "pregate_shallow_layers": 5,
  "pregate_shallow_loss_weight": 1.5,
  "pregate_start_layer": 7,
  "pregate_use_prev_token": true,
  "pregate_use_prev_topk": true,
  "q_lora_rank": 256,
  "qk_head_dim": 192,
  "qk_nope_head_dim": 128,
  "qk_rope_head_dim": 64,
  "rms_norm_eps": 1e-06,
  "rope_interleave": true,
  "rope_parameters": {
    "partial_rotary_factor": 0.5,
    "rope_theta": 6000000,
    "rope_type": "default"
  },
  "rope_theta": 6000000,
  "rotary_dim": 64,
  "routed_scaling_factor": 2.5,
  "router_dtype": "fp32",
  "scale_router_input": false,
  "score_function": "sigmoid",
  "scoring_func": "sigmoid",
  "seq_aux": true,
  "share_expert_swiglu_limit_list": null,
  "short_conv_kernel_size": 4,
  "tie_word_embeddings": false,
  "topk_group": 4,
  "topk_method": "noaux_tc",
  "transformers_version": "5.8.1",
  "up_proj_norm": false,
  "use_bias": false,
  "use_cache": false,
  "use_kda_lora": false,
  "use_mla_nope": false,
  "use_nGPT": false,
  "use_qk_norm": true,
  "use_qkv_bias": false,
  "v_head_dim": 128,
  "value_norm": false,
  "vocab_size": 157184,
  "quantization": {
    "group_size": 64,
    "bits": 4,
    "mode": "affine"
  },
  "quantization_config": {
    "group_size": 64,
    "bits": 4,
    "mode": "affine"
  }
}
"""#

    func testRealConfigParses() throws {
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(Self.realConfigJSON.utf8)
        )
        XCTAssertEqual(configuration.architectures, ["BailingMoeV3ForCausalLM"])
        XCTAssertEqual(configuration.hiddenSize, 1536)
        XCTAssertEqual(configuration.numHiddenLayers, 24)
        XCTAssertEqual(configuration.intermediateSize, 4608)
        XCTAssertEqual(configuration.numAttentionHeads, 16)
        XCTAssertEqual(configuration.numKeyValueHeads, 16)
        XCTAssertEqual(configuration.headDim, 128)
        XCTAssertEqual(configuration.vocabSize, 157_184)
        XCTAssertEqual(configuration.maxPositionEmbeddings, 131_072)
        XCTAssertEqual(configuration.qkHeadDim, 192)
        XCTAssertEqual(configuration.qkNopeHeadDim, 128)
        XCTAssertEqual(configuration.qkRopeHeadDim, 64)
        XCTAssertEqual(configuration.vHeadDim, 128)
        XCTAssertEqual(configuration.qLoraRank, 256)
        XCTAssertEqual(configuration.kvLoraRank, 512)
        XCTAssertEqual(configuration.layerGroupSize, 4)
        XCTAssertEqual(configuration.firstKDenseReplace, 1)
        XCTAssertEqual(configuration.shortConvKernelSize, 4)
        XCTAssertTrue(configuration.noKDALora)
        XCTAssertTrue(configuration.kdaSafeGate)
        XCTAssertEqual(configuration.kdaLowerBound, -5)
        XCTAssertEqual(configuration.numExperts, 128)
        XCTAssertEqual(configuration.numExpertsPerTok, 8)
        XCTAssertEqual(configuration.numSharedExperts, 1)
        XCTAssertEqual(configuration.moeIntermediateSize, 512)
        XCTAssertEqual(configuration.moeSharedExpertIntermediateSize, 512)
        XCTAssertEqual(configuration.nGroup, 8)
        XCTAssertEqual(configuration.topkGroup, 4)
        XCTAssertTrue(configuration.normTopkProb)
        XCTAssertEqual(configuration.routedScalingFactor, 2.5)
        XCTAssertTrue(configuration.routerExpertBias)
        XCTAssertFalse(configuration.tieWordEmbeddings)
        XCTAssertEqual(configuration.eosTokenID, 156_895)
        XCTAssertEqual(configuration.padTokenID, 156_892)
        XCTAssertEqual(configuration.quantization.bits, 4)
        XCTAssertEqual(configuration.quantization.groupSize, 64)
        XCTAssertEqual(configuration.quantization.mode, "affine")
    }

    func testEdge0EightBValidationPasses() throws {
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(Self.realConfigJSON.utf8)
        )
        XCTAssertNoThrow(try configuration.validateEdge0_8B())
    }

    func testLayerScheduleIsEighteenKDAAndSixMLA() throws {
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(Self.realConfigJSON.utf8)
        )
        let mlaLayers = (0..<configuration.numHiddenLayers)
            .filter(configuration.isMLALayer)
        XCTAssertEqual(mlaLayers, [3, 7, 11, 15, 19, 23])
        XCTAssertEqual(configuration.mlaLayerCount, 6)
        XCTAssertEqual(configuration.kdaLayerCount, 18)
        XCTAssertEqual(configuration.firstMLALayerIndex, 3)
    }

    func testUnsupportedArchitectureIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(Self.realConfigJSON.utf8)
            ) as? [String: Any]
        )
        object["architectures"] = ["SomethingElseForCausalLM"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let configuration = try Edge0ModelConfiguration.decode(from: data)
        XCTAssertThrowsError(try configuration.validateEdge0_8B()) { error in
            guard case .unsupportedArchitecture? =
                error as? Edge0ModelConfigurationError else {
                return XCTFail("Expected unsupportedArchitecture, got \(error)")
            }
        }
    }

    func testWrongDimensionIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(Self.realConfigJSON.utf8)
            ) as? [String: Any]
        )
        object["num_hidden_layers"] = 12
        let data = try JSONSerialization.data(withJSONObject: object)
        let configuration = try Edge0ModelConfiguration.decode(from: data)
        XCTAssertThrowsError(try configuration.validateEdge0_8B()) { error in
            guard case .unsupportedConfiguration? =
                error as? Edge0ModelConfigurationError else {
                return XCTFail("Expected unsupportedConfiguration, got \(error)")
            }
        }
    }
}
