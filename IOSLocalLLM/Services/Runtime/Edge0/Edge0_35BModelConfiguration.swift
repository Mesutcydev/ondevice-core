import Foundation

// MARK: - Edge0_35BModelConfiguration
//
// Verified configuration contract for `Edge0/Edge0-35B-A3B-preview`
// (Qwen3.5-MoE, text tower). Every value below was read from the real
// config.json / safetensors index — see Docs/EDGE0_35B_MODEL_ARCHITECTURE.md.
//
// This type is discovery-foundation: it parses and validates the checkpoint
// contract. It does not execute the model.

enum Edge0_35BLayerType: String, Sendable, Codable {
    case linearAttention = "linear_attention"
    case fullAttention = "full_attention"
}

struct Edge0_35BModelConfiguration: Sendable, Equatable {
    // Identity
    let architectures: [String]
    /// Top-level wrapper model type (`qwen3_5_moe`).
    let wrapperModelType: String
    /// Text tower model type (`qwen3_5_moe_text`).
    let modelType: String

    // Text tower
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let vocabSize: Int
    let maxPositionEmbeddings: Int
    let rmsNormEps: Double
    let ropeTheta: Double
    let partialRotaryFactor: Double
    let mropeSection: [Int]
    let tieWordEmbeddings: Bool
    let attentionBias: Bool
    let attnOutputGate: Bool
    let layerTypes: [Edge0_35BLayerType]

    // MoE
    let numExperts: Int
    /// As declared by the checkpoint (8). Edge0's released 35B tier runs
    /// K=4 (upstream profile `staged_k4`, prerouter_top_k=4).
    let configuredExpertsPerToken: Int
    let releasedExpertsPerToken: Int
    let moeIntermediateSize: Int
    let sharedExpertIntermediateSize: Int
    let releasedNormTopkProb: Bool

    // Linear attention (GatedDeltaNet-style)
    let linearConvKernelDim: Int
    let linearKeyHeadDim: Int
    let linearNumKeyHeads: Int
    let linearNumValueHeads: Int
    let linearValueHeadDim: Int
    let mambaSSMDtype: String

    // Quantization
    let quantizationBits: Int
    let quantizationGroupSize: Int
    let quantizationMode: String
    /// Absolute module paths (e.g. `language_model.model.layers.0.mlp.gate`)
    /// that override the global geometry (8-bit group 64 for the router gate
    /// and the shared-expert gate).
    let eightBitModules: Set<String>

    // Special tokens (from text_config; generation_config may add more EOS)
    let eosTokenIDs: [Int]
    let bosTokenID: Int
    let padTokenID: Int?

    // MARK: Verified expectation

    struct Expectation: Sendable, Equatable {
        var architectures = ["Qwen3_5MoeForConditionalGeneration"]
        var wrapperModelType = "qwen3_5_moe"
        var modelType = "qwen3_5_moe_text"
        var hiddenSize = 2048
        var numHiddenLayers = 40
        var numAttentionHeads = 16
        var numKeyValueHeads = 2
        var headDim = 256
        var vocabSize = 248_320
        var maxPositionEmbeddings = 262_144
        var linearLayerCount = 30
        var fullAttentionStride = 4
        var firstFullAttentionLayer = 3
        var numExperts = 256
        var configuredExpertsPerToken = 8
        var releasedExpertsPerToken = 4
        var moeIntermediateSize = 512
        var sharedExpertIntermediateSize = 512
        var linearConvKernelDim = 4
        var linearKeyHeadDim = 128
        var linearNumKeyHeads = 16
        var linearNumValueHeads = 32
        var linearValueHeadDim = 128
        var quantizationBits = 4
        var quantizationGroupSize = 64
        var quantizationMode = "affine"
        var eightBitModuleCount = 80
        var bosTokenID = 248_044
        var eosTokenID = 248_044

        // Expert accounting (from the real shard headers)
        var perExpertBundleBytes: UInt64 = 1_769_472
        var totalRoutedExpertBytes: UInt64 = 18_119_393_280
        var residentCommonBytes: UInt64 = 1_389_394_176
        var checkpointBytes: UInt64 = 19_508_787_456
        var shardCount = 4
        var tensorCount = 1_757
    }

    static let edge0_35BExpectation = Expectation()

    // MARK: Decode

    enum DecodeError: Error, LocalizedError {
        case unreadable(String)
        case unsupportedArchitecture(String)
        case unsupportedConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "Edge0-35B config unreadable: \(detail)"
            case .unsupportedArchitecture(let value):
                return "Unsupported Edge0-35B architecture: \(value)"
            case .unsupportedConfiguration(let detail):
                return "Unsupported Edge0-35B configuration: \(detail)"
            }
        }
    }

    static func decode(from data: Data) throws -> Edge0_35BModelConfiguration {
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw DecodeError.unreadable("not a JSON object")
        }
        let text = root["text_config"] as? [String: Any] ?? root

        func int(_ key: String) throws -> Int {
            guard let value = text[key] as? Int else {
                throw DecodeError.unsupportedConfiguration("missing \(key)")
            }
            return value
        }
        func double(_ key: String, default fallback: Double) -> Double {
            if let value = text[key] as? Double { return value }
            if let value = text[key] as? Int { return Double(value) }
            return fallback
        }

        let layersRaw = text["layer_types"] as? [String] ?? []
        let layerTypes = layersRaw.compactMap(Edge0_35BLayerType.init(rawValue:))

        let quantization = root["quantization_config"] as? [String: Any]
            ?? root["quantization"] as? [String: Any]
            ?? [:]
        let bits = (quantization["bits"] as? Int) ?? 4
        let groupSize = (quantization["group_size"] as? Int) ?? 64
        let mode = (quantization["mode"] as? String) ?? "affine"
        let overrides = Set(
            quantization.keys.filter {
                !["group_size", "bits", "mode"].contains($0)
            }
        )

        let eosRaw = text["eos_token_id"]
        let eos: [Int]
        if let list = eosRaw as? [Int] {
            eos = list
        } else if let single = eosRaw as? Int {
            eos = [single]
        } else {
            eos = []
        }

        let rope = text["rope_parameters"] as? [String: Any] ?? [:]

        return Edge0_35BModelConfiguration(
            architectures: root["architectures"] as? [String] ?? [],
            wrapperModelType: (root["model_type"] as? String) ?? "",
            modelType: (text["model_type"] as? String)
                ?? (root["model_type"] as? String) ?? "",
            hiddenSize: try int("hidden_size"),
            numHiddenLayers: try int("num_hidden_layers"),
            numAttentionHeads: try int("num_attention_heads"),
            numKeyValueHeads: try int("num_key_value_heads"),
            headDim: try int("head_dim"),
            vocabSize: try int("vocab_size"),
            maxPositionEmbeddings: try int("max_position_embeddings"),
            rmsNormEps: double("rms_norm_eps", default: 1e-6),
            ropeTheta: (rope["rope_theta"] as? Double)
                ?? double("rope_theta", default: 10_000_000),
            partialRotaryFactor: double(
                "partial_rotary_factor", default: 0.25
            ),
            mropeSection: rope["mrope_section"] as? [Int] ?? [],
            tieWordEmbeddings: text["tie_word_embeddings"] as? Bool ?? false,
            attentionBias: text["attention_bias"] as? Bool ?? false,
            attnOutputGate: text["attn_output_gate"] as? Bool ?? false,
            layerTypes: layerTypes,
            numExperts: try int("num_experts"),
            configuredExpertsPerToken: try int("num_experts_per_tok"),
            releasedExpertsPerToken: 4,
            moeIntermediateSize: try int("moe_intermediate_size"),
            sharedExpertIntermediateSize: (try? int(
                "shared_expert_intermediate_size"
            )) ?? (try? int("moe_intermediate_size")) ?? 0,
            releasedNormTopkProb: true,
            linearConvKernelDim: (try? int("linear_conv_kernel_dim")) ?? 0,
            linearKeyHeadDim: (try? int("linear_key_head_dim")) ?? 0,
            linearNumKeyHeads: (try? int("linear_num_key_heads")) ?? 0,
            linearNumValueHeads: (try? int("linear_num_value_heads")) ?? 0,
            linearValueHeadDim: (try? int("linear_value_head_dim")) ?? 0,
            mambaSSMDtype: text["mamba_ssm_dtype"] as? String ?? "",
            quantizationBits: bits,
            quantizationGroupSize: groupSize,
            quantizationMode: mode,
            eightBitModules: overrides,
            eosTokenIDs: eos,
            bosTokenID: (text["bos_token_id"] as? Int) ?? 0,
            padTokenID: text["pad_token_id"] as? Int
        )
    }

    // MARK: Validation

    func validateEdge0_35B() throws {
        let expected = Self.edge0_35BExpectation
        guard architectures.contains(where: {
            $0.caseInsensitiveCompare(expected.architectures[0]) == .orderedSame
        }) else {
            throw DecodeError.unsupportedArchitecture(
                architectures.joined(separator: ",")
            )
        }
        func require(_ condition: Bool, _ detail: String) throws {
            guard condition else {
                throw DecodeError.unsupportedConfiguration(detail)
            }
        }
        try require(hiddenSize == expected.hiddenSize, "hidden_size")
        try require(
            numHiddenLayers == expected.numHiddenLayers, "num_hidden_layers"
        )
        try require(
            numAttentionHeads == expected.numAttentionHeads,
            "num_attention_heads"
        )
        try require(
            numKeyValueHeads == expected.numKeyValueHeads,
            "num_key_value_heads"
        )
        try require(headDim == expected.headDim, "head_dim")
        try require(vocabSize == expected.vocabSize, "vocab_size")
        try require(
            numExperts == expected.numExperts, "num_experts"
        )
        try require(
            moeIntermediateSize == expected.moeIntermediateSize,
            "moe_intermediate_size"
        )
        try require(
            sharedExpertIntermediateSize == expected.sharedExpertIntermediateSize,
            "shared_expert_intermediate_size"
        )
        try require(
            layerTypes.count == expected.numHiddenLayers, "layer_types"
        )
        let linearCount = layerTypes.filter { $0 == .linearAttention }.count
        try require(
            linearCount == expected.linearLayerCount, "linear layer count"
        )
        for index in stride(
            from: expected.firstFullAttentionLayer,
            to: expected.numHiddenLayers,
            by: expected.fullAttentionStride
        ) {
            try require(
                layerTypes[index] == .fullAttention,
                "layer \(index) must be full_attention"
            )
        }
        try require(
            quantizationBits == expected.quantizationBits,
            "quantization bits"
        )
        try require(
            quantizationGroupSize == expected.quantizationGroupSize,
            "quantization group size"
        )
        try require(
            quantizationMode == expected.quantizationMode, "quantization mode"
        )
        try require(
            eightBitModules.count == expected.eightBitModuleCount,
            "8-bit module override count"
        )
        try require(
            eightBitModules.allSatisfy {
                $0.hasSuffix(".mlp.gate")
                    || $0.hasSuffix(".mlp.shared_expert_gate")
            },
            "8-bit overrides must target router/shared gates only"
        )
    }
}

// MARK: - Edge0_35BExpertLayout
//
// Storage contract for the streamed routed experts (verified against the
// real shard headers; see the inventory fixture).

struct Edge0_35BExpertLayout: Sendable, Equatable {
    static let shared = Edge0_35BExpertLayout()

    let expertCount = 256
    let topK = 4
    let layerCount = 40
    /// `language_model.model.layers.{layer}.mlp.switch_mlp.{proj}.{part}`
    let keyTemplate =
        "language_model.model.layers.{layer}.mlp.switch_mlp.{proj}.{part}"
    /// Per-expert U32 weight bytes for gate/up ([512, 256] at 4-bit) and
    /// down ([2048, 64]).
    let perProjectionBytes: UInt64 = 589_824
    let perExpertBundleBytes: UInt64 = 1_769_472
    let totalRoutedExpertBytes: UInt64 = 18_119_393_280
    let residentCommonBytes: UInt64 = 1_389_394_176
    let checkpointBytes: UInt64 = 19_508_787_456

    func tensorName(layer: Int, projection: String, part: String) -> String {
        keyTemplate
            .replacingOccurrences(of: "{layer}", with: "\(layer)")
            .replacingOccurrences(of: "{proj}", with: projection)
            .replacingOccurrences(of: "{part}", with: part)
    }
}

// MARK: - Shared architecture identity

extension Edge0_35BModelConfiguration {
    /// Architectures that classify as the native Edge0 runtime. Both the 8B
    /// (Bailing hybrid) and the 35B (Qwen3.5-MoE) checkpoints are native
    /// Edge0 models; the family distinction is separate from the runtime.
    static let nativeArchitectures: Set<String> = [
        "BailingMoeV3ForCausalLM",
        "Qwen3_5MoeForConditionalGeneration",
    ]

    /// Pure architecture-identity check shared by the registry and tests.
    static func isEdge0Architecture(_ json: [String: Any]?) -> Bool {
        guard let architectures = json?["architectures"] as? [String] else {
            return false
        }
        return architectures.contains { architecture in
            nativeArchitectures.contains {
                $0.caseInsensitiveCompare(architecture) == .orderedSame
            }
        }
    }
}
