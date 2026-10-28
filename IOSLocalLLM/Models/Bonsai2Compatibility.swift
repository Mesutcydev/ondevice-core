import Foundation

/// Explicit format checks; a repository name alone cannot establish compatibility.
enum Bonsai2Compatibility {
    static let repoID = "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit"

    static func supportsText(_ json: [String: Any]) -> Bool {
        guard json["model_type"] as? String == "prism_hadamard_qwen35",
              json["schema_version"] as? Int == 2,
              json["base_model_type"] as? String == "qwen3_5",
              json["tensor_namespace"] as? String == "mlx-vlm-qwen3_5",
              json["gdn_activation_layout"] as? String == "grouped",
              let quant = json["quantization"] as? [String: Any],
              quant["bits"] as? Int == 2, quant["group_size"] as? Int == 128,
              quant["mode"] as? String == "affine",
              let text = json["text_config"] as? [String: Any],
              text["hidden_size"] as? Int == 4096,
              text["num_hidden_layers"] as? Int == 32,
              text["vocab_size"] as? Int == 248320,
              text["tie_word_embeddings"] as? Bool == false,
              let modules = json["modules"] as? [[String: Any]], !modules.isEmpty else { return false }
        // Only the verified dense 9B geometry is admitted. Reject unknown
        // variants before constructing modules (some kernels require fixed ratios).
        let dimensions = ["intermediate_size": 12288, "num_attention_heads": 16,
                          "num_key_value_heads": 4, "head_dim": 256,
                          "linear_num_key_heads": 16, "linear_num_value_heads": 32,
                          "linear_key_head_dim": 128, "linear_value_head_dim": 128,
                          "linear_conv_kernel_dim": 4, "full_attention_interval": 4]
        guard dimensions.allSatisfy({ text[$0.key] as? Int == $0.value }),
              (text["num_experts"] as? Int ?? 0) == 0,
              (text["mtp_num_hidden_layers"] as? Int ?? 0) == 0,
              text["attention_bias"] as? Bool == false,
              text["rms_norm_eps"] as? Double == 0.000001,
              let rope = text["rope_parameters"] as? [String: Any],
              rope["rope_theta"] as? Int == 10_000_000,
              rope["partial_rotary_factor"] as? Double == 0.25,
              rope["rope_type"] as? String == "default" else { return false }
        let paths = modules.compactMap { $0["path"] as? String }
        guard paths.count == modules.count, Set(paths).count == paths.count,
              paths.contains("model.embed_tokens"), paths.contains("lm_head") else { return false }
        return modules.allSatisfy {
            guard let path = $0["path"] as? String, let block = $0["block"] as? Int,
                  $0["embedding"] is Bool, $0["dtype"] as? String == "float16" else { return false }
            return (path == "lm_head" || path.hasPrefix("model.")) && [0, 512, 1024, 2048, 4096].contains(block)
        }
    }

    static func supportsVision(_ json: [String: Any]) -> Bool {
        guard supportsText(json),
              let components = json["components"] as? [String: Bool], components["vision"] == true,
              let vision = json["vision_config"] as? [String: Any],
              vision["model_type"] as? String == "qwen3_5",
              vision["hidden_act"] as? String == "gelu_pytorch_tanh",
              vision["deepstack_visual_indexes"] as? [Int] == [],
              json["image_token_id"] as? Int == 248056,
              json["video_token_id"] as? Int == 248057,
              json["vision_start_token_id"] as? Int == 248053,
              json["vision_end_token_id"] as? Int == 248054 else { return false }
        let dimensions = ["depth": 27, "hidden_size": 1152, "intermediate_size": 4304,
                          "num_heads": 16, "num_position_embeddings": 2304, "in_channels": 3,
                          "out_hidden_size": 4096, "patch_size": 16, "spatial_merge_size": 2,
                          "temporal_patch_size": 2]
        return dimensions.allSatisfy { vision[$0.key] as? Int == $0.value }
    }

}
