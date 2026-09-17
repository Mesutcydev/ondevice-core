import Foundation

// MARK: - Edge0ModelConfigurationError

enum Edge0ModelConfigurationError: Error, Equatable, Sendable {
    case unsupportedArchitecture(String)
    case unsupportedConfiguration(String)
    case missingField(String)

    var localizedDescription: String {
        switch self {
        case .unsupportedArchitecture(let value):
            return "Unsupported Edge0 architecture '\(value)'."
        case .unsupportedConfiguration(let detail):
            return "Unsupported Edge0 configuration: \(detail)"
        case .missingField(let field):
            return "Edge0 config is missing required field '\(field)'."
        }
    }
}

// MARK: - Edge0ModelConfiguration
//
// Typed view of the real Edge0-8B `config.json`
// (`BailingMoeV3ForCausalLM`, Ling 3.0 hybrid). Phase 3 supports exactly the
// verified 8B configuration; anything else is rejected rather than guessed.
//
// Verified against `Edge0/Edge0-8B-A1B-preview` and the upstream reference at
// commit 0700e6532f45e0d0d99e9c588d7d8cd240538ea0.

struct Edge0ModelConfiguration: Decodable, Sendable, Equatable {
    struct Quantization: Decodable, Sendable, Equatable {
        let groupSize: Int
        let bits: Int
        let mode: String

        private enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
            case mode
        }
    }

    let architectures: [String]
    let hiddenSize: Int
    let numHiddenLayers: Int
    let intermediateSize: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let rmsNormEps: Double
    let vocabSize: Int
    let maxPositionEmbeddings: Int
    let tieWordEmbeddings: Bool

    // Layer schedule: groups of [KDA × (g-1), MLA], layer 0 dense MLP.
    let layerGroupSize: Int
    let firstKDenseReplace: Int
    let shortConvKernelSize: Int
    let noKDALora: Bool
    let kdaSafeGate: Bool
    let kdaLowerBound: Double

    // MLA
    let qLoraRank: Int?
    let kvLoraRank: Int
    let qkNopeHeadDim: Int
    let qkRopeHeadDim: Int
    let vHeadDim: Int
    let ropeTheta: Double
    let ropeInterleave: Bool
    let useQKVBias: Bool
    let gatedAttentionGranularity: String

    // MoE
    let numExperts: Int
    let numExpertsPerTok: Int
    let numSharedExperts: Int
    let moeIntermediateSize: Int
    let moeSharedExpertIntermediateSize: Int
    let nGroup: Int
    let topkGroup: Int
    let normTopkProb: Bool
    let routedScalingFactor: Double
    let routerExpertBias: Bool
    let routerDType: String

    let eosTokenID: Int
    let padTokenID: Int
    let quantization: Quantization

    var qkHeadDim: Int { qkNopeHeadDim + qkRopeHeadDim }

    /// Upstream `ModelArgs.is_mla_layer`.
    func isMLALayer(_ index: Int) -> Bool {
        let group = max(1, layerGroupSize)
        let full = numHiddenLayers / group * group
        return (index + 1) % group == 0 || index >= full
    }

    var firstMLALayerIndex: Int? {
        (0..<numHiddenLayers).first { isMLALayer($0) }
    }

    var kdaLayerCount: Int {
        (0..<numHiddenLayers).filter { !isMLALayer($0) }.count
    }

    var mlaLayerCount: Int {
        (0..<numHiddenLayers).filter { isMLALayer($0) }.count
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case architectures
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabSize = "vocab_size"
        case maxPositionEmbeddings = "max_position_embeddings"
        case tieWordEmbeddings = "tie_word_embeddings"
        case layerGroupSize = "layer_group_size"
        case firstKDenseReplace = "first_k_dense_replace"
        case shortConvKernelSize = "short_conv_kernel_size"
        case noKDALora = "no_kda_lora"
        case kdaSafeGate = "kda_safe_gate"
        case kdaLowerBound = "kda_lower_bound"
        case qLoraRank = "q_lora_rank"
        case kvLoraRank = "kv_lora_rank"
        case qkNopeHeadDim = "qk_nope_head_dim"
        case qkRopeHeadDim = "qk_rope_head_dim"
        case vHeadDim = "v_head_dim"
        case ropeTheta = "rope_theta"
        case ropeInterleave = "rope_interleave"
        case useQKVBias = "use_qkv_bias"
        case gatedAttentionGranularity = "gated_attention_proj_granularity_type"
        case numExperts = "num_experts"
        case numExpertsPerTok = "num_experts_per_tok"
        case numSharedExperts = "num_shared_experts"
        case moeIntermediateSize = "moe_intermediate_size"
        case moeSharedExpertIntermediateSize = "moe_shared_expert_intermediate_size"
        case nGroup = "n_group"
        case topkGroup = "topk_group"
        case normTopkProb = "norm_topk_prob"
        case routedScalingFactor = "routed_scaling_factor"
        case routerExpertBias = "moe_router_enable_expert_bias"
        case routerDType = "router_dtype"
        case eosTokenID = "eos_token_id"
        case padTokenID = "pad_token_id"
        case quantization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        architectures = try container.decodeIfPresent(
            [String].self,
            forKey: .architectures
        ) ?? []
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        numHiddenLayers = try container.decode(Int.self, forKey: .numHiddenLayers)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        numAttentionHeads = try container.decode(Int.self, forKey: .numAttentionHeads)
        numKeyValueHeads = try container.decode(Int.self, forKey: .numKeyValueHeads)
        headDim = try container.decode(Int.self, forKey: .headDim)
        rmsNormEps = try container.decode(Double.self, forKey: .rmsNormEps)
        vocabSize = try container.decode(Int.self, forKey: .vocabSize)
        maxPositionEmbeddings = try container.decode(
            Int.self,
            forKey: .maxPositionEmbeddings
        )
        tieWordEmbeddings = try container.decode(
            Bool.self,
            forKey: .tieWordEmbeddings
        )
        layerGroupSize = try container.decode(Int.self, forKey: .layerGroupSize)
        firstKDenseReplace = try container.decode(
            Int.self,
            forKey: .firstKDenseReplace
        )
        shortConvKernelSize = try container.decode(
            Int.self,
            forKey: .shortConvKernelSize
        )
        noKDALora = try container.decode(Bool.self, forKey: .noKDALora)
        kdaSafeGate = try container.decode(Bool.self, forKey: .kdaSafeGate)
        kdaLowerBound = try container.decode(Double.self, forKey: .kdaLowerBound)
        qLoraRank = try container.decodeIfPresent(Int.self, forKey: .qLoraRank)
        kvLoraRank = try container.decode(Int.self, forKey: .kvLoraRank)
        qkNopeHeadDim = try container.decode(Int.self, forKey: .qkNopeHeadDim)
        qkRopeHeadDim = try container.decode(Int.self, forKey: .qkRopeHeadDim)
        vHeadDim = try container.decode(Int.self, forKey: .vHeadDim)
        ropeTheta = try container.decode(Double.self, forKey: .ropeTheta)
        ropeInterleave = try container.decode(Bool.self, forKey: .ropeInterleave)
        useQKVBias = try container.decode(Bool.self, forKey: .useQKVBias)
        gatedAttentionGranularity = try container.decode(
            String.self,
            forKey: .gatedAttentionGranularity
        )
        numExperts = try container.decode(Int.self, forKey: .numExperts)
        numExpertsPerTok = try container.decode(
            Int.self,
            forKey: .numExpertsPerTok
        )
        numSharedExperts = try container.decode(
            Int.self,
            forKey: .numSharedExperts
        )
        moeIntermediateSize = try container.decode(
            Int.self,
            forKey: .moeIntermediateSize
        )
        moeSharedExpertIntermediateSize = try container.decode(
            Int.self,
            forKey: .moeSharedExpertIntermediateSize
        )
        nGroup = try container.decode(Int.self, forKey: .nGroup)
        topkGroup = try container.decode(Int.self, forKey: .topkGroup)
        normTopkProb = try container.decode(Bool.self, forKey: .normTopkProb)
        routedScalingFactor = try container.decode(
            Double.self,
            forKey: .routedScalingFactor
        )
        routerExpertBias = try container.decode(
            Bool.self,
            forKey: .routerExpertBias
        )
        routerDType = try container.decodeIfPresent(
            String.self,
            forKey: .routerDType
        ) ?? "fp32"
        eosTokenID = try container.decode(Int.self, forKey: .eosTokenID)
        padTokenID = try container.decode(Int.self, forKey: .padTokenID)
        quantization = try container.decode(
            Quantization.self,
            forKey: .quantization
        )
    }

    static func decode(from data: Data) throws -> Edge0ModelConfiguration {
        do {
            return try JSONDecoder().decode(
                Edge0ModelConfiguration.self,
                from: data
            )
        } catch let error as Edge0ModelConfigurationError {
            throw error
        } catch {
            throw Edge0ModelConfigurationError.unsupportedConfiguration(
                String(describing: error)
            )
        }
    }

    // MARK: - Validation

    /// The verified shipping configuration. Any deviation is rejected so the
    /// runtime never silently mis-executes a different checkpoint.
    static let edge0_8BExpectation = Edge0ModelExpectation(
        architectures: ["BailingMoeV3ForCausalLM"],
        hiddenSize: 1_536,
        numHiddenLayers: 24,
        intermediateSize: 4_608,
        numAttentionHeads: 16,
        numKeyValueHeads: 16,
        headDim: 128,
        vocabSize: 157_184,
        maxPositionEmbeddings: 131_072,
        layerGroupSize: 4,
        firstKDenseReplace: 1,
        numExperts: 128,
        numExpertsPerTok: 8,
        moeIntermediateSize: 512,
        nGroup: 8,
        topkGroup: 4,
        qLoraRank: 256,
        kvLoraRank: 512,
        qkNopeHeadDim: 128,
        qkRopeHeadDim: 64,
        vHeadDim: 128,
        ropeTheta: 6_000_000,
        quantizationBits: 4,
        quantizationGroupSize: 64
    )

    func validateEdge0_8B() throws {
        let expected = Self.edge0_8BExpectation
        guard expected.architectures.contains(where: architectures.contains) else {
            throw Edge0ModelConfigurationError.unsupportedArchitecture(
                architectures.joined(separator: ",")
            )
        }
        func require(_ matches: Bool, _ detail: String) throws {
            guard matches else {
                throw Edge0ModelConfigurationError.unsupportedConfiguration(detail)
            }
        }
        try require(hiddenSize == expected.hiddenSize, "hidden_size")
        try require(numHiddenLayers == expected.numHiddenLayers, "num_hidden_layers")
        try require(intermediateSize == expected.intermediateSize, "intermediate_size")
        try require(numAttentionHeads == expected.numAttentionHeads, "num_attention_heads")
        try require(numKeyValueHeads == expected.numKeyValueHeads, "num_key_value_heads")
        try require(headDim == expected.headDim, "head_dim")
        try require(vocabSize == expected.vocabSize, "vocab_size")
        try require(
            maxPositionEmbeddings == expected.maxPositionEmbeddings,
            "max_position_embeddings"
        )
        try require(layerGroupSize == expected.layerGroupSize, "layer_group_size")
        try require(
            firstKDenseReplace == expected.firstKDenseReplace,
            "first_k_dense_replace"
        )
        try require(numExperts == expected.numExperts, "num_experts")
        try require(
            numExpertsPerTok == expected.numExpertsPerTok,
            "num_experts_per_tok"
        )
        try require(
            moeIntermediateSize == expected.moeIntermediateSize,
            "moe_intermediate_size"
        )
        try require(nGroup == expected.nGroup, "n_group")
        try require(topkGroup == expected.topkGroup, "topk_group")
        try require(qLoraRank == expected.qLoraRank, "q_lora_rank")
        try require(kvLoraRank == expected.kvLoraRank, "kv_lora_rank")
        try require(qkNopeHeadDim == expected.qkNopeHeadDim, "qk_nope_head_dim")
        try require(qkRopeHeadDim == expected.qkRopeHeadDim, "qk_rope_head_dim")
        try require(vHeadDim == expected.vHeadDim, "v_head_dim")
        try require(ropeTheta == expected.ropeTheta, "rope_theta")
        try require(
            quantization.bits == expected.quantizationBits,
            "quantization.bits"
        )
        try require(
            quantization.groupSize == expected.quantizationGroupSize,
            "quantization.group_size"
        )
        try require(!tieWordEmbeddings, "tie_word_embeddings")
        try require(ropeInterleave, "rope_interleave")
        try require(kdaSafeGate, "kda_safe_gate")
        try require(noKDALora, "no_kda_lora")
        try require(normTopkProb, "norm_topk_prob")
        try require(routerExpertBias, "moe_router_enable_expert_bias")
        guard firstMLALayerIndex != nil else {
            throw Edge0ModelConfigurationError.unsupportedConfiguration(
                "layer schedule has no MLA layer"
            )
        }
    }
}

// MARK: - Edge0ModelExpectation

struct Edge0ModelExpectation: Sendable, Equatable {
    let architectures: [String]
    let hiddenSize: Int
    let numHiddenLayers: Int
    let intermediateSize: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let vocabSize: Int
    let maxPositionEmbeddings: Int
    let layerGroupSize: Int
    let firstKDenseReplace: Int
    let numExperts: Int
    let numExpertsPerTok: Int
    let moeIntermediateSize: Int
    let nGroup: Int
    let topkGroup: Int
    let qLoraRank: Int?
    let kvLoraRank: Int
    let qkNopeHeadDim: Int
    let qkRopeHeadDim: Int
    let vHeadDim: Int
    let ropeTheta: Double
    let quantizationBits: Int
    let quantizationGroupSize: Int
}
