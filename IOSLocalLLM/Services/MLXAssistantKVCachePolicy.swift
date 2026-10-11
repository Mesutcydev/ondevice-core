import Foundation

/// The experiment changes cache storage only. Existing context limits,
/// residency, sampler settings, and memory/thermal admission still apply.
struct MLXAssistantKVCachePolicy: Equatable, Sendable {
    static let preferenceKey = "assistantTurboQuantEnabled"
    static let standard = Self(scheme: nil)

    let scheme: String?
    var usesTurboQuant: Bool { scheme != nil }

    /// Start with affine 8-bit keys and TurboQuant 3-bit values. Restrict the
    /// experiment to dense text architectures and precomputed power-of-two
    /// head dimensions; model-native rotating/recurrent caches stay unchanged.
    static func resolve(
        enabled: Bool, boundedCache: Bool, vision: Bool,
        config: [String: Any]?
    ) -> Self {
        guard enabled, !boundedCache, !vision, let config,
              config["text_config"] == nil,
              let architecture = config["model_type"] as? String,
              ["llama", "mistral", "qwen2", "qwen3"].contains(architecture),
              let layers = config["num_hidden_layers"] as? Int,
              layers > 0, layers <= 1_000_000,
              let heads = config["num_attention_heads"] as? Int,
              heads > 0, heads <= 1_000_000,
              let hidden = config["hidden_size"] as? Int,
              hidden > 0, hidden <= 1_000_000,
              let intermediate = config["intermediate_size"] as? Int,
              intermediate > 0, intermediate <= 1_000_000,
              let vocabulary = config["vocab_size"] as? Int,
              vocabulary > 0, vocabulary <= 1_000_000 else { return .standard }

        let kvHeads = config["num_key_value_heads"] as? Int ?? heads
        let headDim = config["head_dim"] as? Int ?? hidden / heads
        let dtype = config["torch_dtype"] as? String ?? config["dtype"] as? String
        guard kvHeads > 0, kvHeads <= heads, heads.isMultiple(of: kvHeads),
              [64, 128, 256].contains(headDim),
              ["float16", "bfloat16"].contains(dtype ?? "") else { return .standard }
        return .init(scheme: "turbo8v3")
    }
}
