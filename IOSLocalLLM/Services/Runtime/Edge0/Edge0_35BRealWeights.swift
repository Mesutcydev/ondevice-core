import Foundation
import MLX

// MARK: - Edge0LoRA
//
// Unmerged Recover-LoRA adapter: `y = base(x) + scale * B(A(x))`.
// Rank/scale come from the artifact contract (r=16, alpha=32, scale=2.0).

struct Edge0LoRA: @unchecked Sendable {
    let a: MLXArray   // [rank, in]
    let b: MLXArray   // [out, rank]
    let scale: Float

    /// Upstream `LoraLinear.__call__`: cast x to the adapter dtype (fp16),
    /// compute the delta in that dtype, scale, cast back to the base dtype.
    func delta(_ x: MLXArray) -> MLXArray {
        let adapterDType = a.dtype
        let adapterInput = x.dtype == adapterDType
            ? x : x.asType(adapterDType)
        let d = MLX.matmul(
            MLX.matmul(adapterInput, a.transposed(1, 0)),
            b.transposed(1, 0)
        )
        return (d * scale).asType(x.dtype)
    }

    func apply(_ x: MLXArray, base: MLXArray) -> MLXArray {
        base + delta(x).asType(base.dtype)
    }
}

// MARK: - Edge0_35BLinear
//
// Quantized linear with per-module bit width (4-bit default, 8-bit for the
// router and shared-expert gates) plus an optional unmerged LoRA delta.

struct Edge0_35BLinear: @unchecked Sendable {
    let weight: MLXArray   // [out, in*bits/32] U32
    let scales: MLXArray   // [out, in/groupSize] BF16
    let biases: MLXArray   // [out, in/groupSize] BF16
    let bits: Int
    let groupSize: Int
    let lora: Edge0LoRA?

    var outputDim: Int { weight.dim(0) }
    var inputDim: Int { weight.dim(1) * 32 / max(1, bits) }

    func base(_ x: MLXArray) -> MLXArray {
        MLX.quantizedMM(
            x, weight,
            scales: scales,
            biases: biases,
            transpose: true,
            groupSize: groupSize,
            bits: bits
        )
    }

    func apply(_ x: MLXArray) -> MLXArray {
        let baseOutput = base(x)
        guard let lora else { return baseOutput }
        return lora.apply(x, base: baseOutput)
    }
}

// MARK: - Edge0_35BExpertWeights

struct Edge0_35BExpertWeights: @unchecked Sendable {
    let gate: Edge0ExpertQuantizedMatrix
    let up: Edge0ExpertQuantizedMatrix
    let down: Edge0ExpertQuantizedMatrix

    var byteSize: UInt64 {
        var total: UInt64 = 0
        for matrix in [gate, up, down] {
            total += UInt64(matrix.weight.nbytes)
            total += UInt64(matrix.scales.nbytes)
            total += UInt64(matrix.biases.nbytes)
        }
        return total
    }
}

// MARK: - Edge0_35BExpertSpec
//
// Verified 35B routed-expert geometry (Phase 5A):
//   gate/up weight [256, 512, 256] U32, scales/biases [256, 512, 32] BF16
//   down    weight [256, 2048, 64] U32, scales/biases [256, 2048, 8] BF16
//   bundle = 1,769,472 bytes

enum Edge0_35BExpertSpec {
    static let expertCount = 256
    static let topK = 4
    static let layerCount = 40
    static let bundleBytes: UInt64 = 1_769_472

    static func name(layer: Int, projection: String, part: String) -> String {
        "language_model.model.layers.\(layer).mlp.switch_mlp."
            + "\(projection).\(part)"
    }
}

// MARK: - Typed attention weights

struct Edge0_35BLinearAttentionWeights: @unchecked Sendable {
    let inProjQKV: Edge0_35BLinear
    let inProjZ: Edge0_35BLinear
    let inProjA: Edge0_35BLinear
    let inProjB: Edge0_35BLinear
    let outProj: Edge0_35BLinear
    let conv1dWeight: MLXArray   // [convDim, kernel, 1] BF16
    let dtBias: MLXArray         // [valueHeads] fp32
    let aLog: MLXArray           // [valueHeads] fp32
    let normWeight: MLXArray     // [valueHeadDim] BF16
}

struct Edge0_35BFullAttentionWeights: @unchecked Sendable {
    let qProj: Edge0_35BLinear
    let kProj: Edge0_35BLinear
    let vProj: Edge0_35BLinear
    let oProj: Edge0_35BLinear
    let qNorm: MLXArray
    let kNorm: MLXArray
}

enum Edge0_35BAttentionWeights: @unchecked Sendable {
    case linear(Edge0_35BLinearAttentionWeights)
    case full(Edge0_35BFullAttentionWeights)
}

struct Edge0_35BLayerWeights: @unchecked Sendable {
    let index: Int
    let inputNorm: MLXArray
    let postAttentionNorm: MLXArray
    let attention: Edge0_35BAttentionWeights
    let routerGate: Edge0_35BLinear          // 8-bit
    let sharedExpertGateProj: Edge0_35BLinear
    let sharedExpertUpProj: Edge0_35BLinear
    let sharedExpertDownProj: Edge0_35BLinear
    let sharedExpertGate: Edge0_35BLinear    // 8-bit, [1, hidden]
}

struct Edge0_35BModelWeights: @unchecked Sendable {
    let configuration: Edge0_35BModelConfiguration
    let embedTokens: Edge0QuantizedEmbedding
    let layers: [Edge0_35BLayerWeights]
    let finalNorm: MLXArray
    let lmHead: Edge0QuantizedEmbedding
}

// MARK: - Edge0_35BWeightLoader

enum Edge0_35BWeightError: Error, LocalizedError {
    case missingTensor(String)
    case badGeometry(String)

    var errorDescription: String? {
        switch self {
        case .missingTensor(let name):
            return "Edge0-35B checkpoint is missing tensor '\(name)'."
        case .badGeometry(let detail):
            return "Edge0-35B tensor geometry mismatch: \(detail)"
        }
    }
}

struct Edge0_35BWeightLoader: Sendable {
    let index: Edge0SafetensorsIndex
    let stores: Edge0TensorStoreSet
    let configuration: Edge0_35BModelConfiguration

    private func location(_ name: String) throws -> Edge0TensorLocation {
        do {
            return try index.location(name)
        } catch {
            throw Edge0_35BWeightError.missingTensor(name)
        }
    }

    private func load(_ name: String) async throws -> MLXArray {
        let location = try location(name)
        guard let dtype = Edge0ResidentTensorLoader.mlxDType(for: location.dtype)
        else {
            throw Edge0_35BWeightError.badGeometry(
                "\(name) has unsupported dtype \(location.dtype.rawValue)"
            )
        }
        let bytes = try await stores.read(location)
        return MLXArray(bytes.bytes, location.shape, dtype: dtype)
    }

    /// Bits for a module: the config's 8-bit overrides are recorded as
    /// absolute module paths without the `language_model.` prefix.
    /// Adapter keys are relative to the text model (`layers.N...`); module
    /// paths carry the full `language_model.model.` prefix.
    static func normalizeLoRAPath(_ path: String) -> String {
        let prefix = "language_model.model."
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private func bits(forModule module: String) -> Int {
        configuration.eightBitModules.contains(module)
            || configuration.eightBitModules.contains(
                "language_model.\(module)"
            )
            ? 8 : configuration.quantizationBits
    }

    private func linear(
        module: String,
        loras: [String: Edge0LoRA]
    ) async throws -> Edge0_35BLinear {
        let weight = try await load("\(module).weight")
        let scales = try await load("\(module).scales")
        let biases = try await load("\(module).biases")
        return Edge0_35BLinear(
            weight: weight,
            scales: scales,
            biases: biases,
            bits: bits(forModule: module),
            groupSize: configuration.quantizationGroupSize,
            lora: loras[Self.normalizeLoRAPath(module)]
        )
    }

    /// Loads the unmerged LoRA pairs, keyed by the module path used in the
    /// checkpoint WITHOUT the `language_model.model.` prefix, e.g.
    /// `layers.0.linear_attn.in_proj_qkv`.
    static func loadLoRAs(
        directory: URL,
        configuration: Edge0_35BModelConfiguration
    ) async throws -> [String: Edge0LoRA] {
        let name = "lora_edge0_35b.safetensors"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: [name]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)
        var pairs: [String: (a: MLXArray?, b: MLXArray?)] = [:]
        var scale: Float?
        for tensorName in index.locations.keys.sorted() {
            let base: String
            let isA: Bool
            if tensorName.hasSuffix(".lora_A") {
                base = String(tensorName.dropLast(".lora_A".count))
                isA = true
            } else if tensorName.hasSuffix(".lora_B") {
                base = String(tensorName.dropLast(".lora_B".count))
                isA = false
            } else {
                continue
            }
            let value = try await loader.load(index.location(tensorName))
            let normalized = Self.normalizeLoRAPath(base)
            var pair = pairs[normalized] ?? (nil, nil)
            if isA { pair.a = value } else { pair.b = value }
            pairs[normalized] = pair
        }
        var loras: [String: Edge0LoRA] = [:]
        for (base, pair) in pairs {
            guard let a = pair.a, let b = pair.b else { continue }
            // scale = alpha / r, read from the artifact geometry once.
            if scale == nil {
                scale = 32.0 / 16.0
            }
            loras[base] = Edge0LoRA(a: a, b: b, scale: scale ?? 2.0)
        }
        await stores.closeAll()
        return loras
    }

    func loadModel(loras: [String: Edge0LoRA]) async throws -> Edge0_35BModelWeights {
        let embedWeight = try await load("language_model.model.embed_tokens.weight")
        let embedScales = try await load("language_model.model.embed_tokens.scales")
        let embedBiases = try await load("language_model.model.embed_tokens.biases")
        let embed = Edge0QuantizedEmbedding(
            weights: Edge0QuantizedLinearWeights(
                weight: embedWeight, scales: embedScales, biases: embedBiases,
                groupSize: configuration.quantizationGroupSize,
                bits: configuration.quantizationBits,
                mode: .affine
            )
        )
        let lmHeadWeight = try await load("language_model.lm_head.weight")
        let lmHeadScales = try await load("language_model.lm_head.scales")
        let lmHeadBiases = try await load("language_model.lm_head.biases")
        let lmHead = Edge0QuantizedEmbedding(
            weights: Edge0QuantizedLinearWeights(
                weight: lmHeadWeight, scales: lmHeadScales, biases: lmHeadBiases,
                groupSize: configuration.quantizationGroupSize,
                bits: configuration.quantizationBits,
                mode: .affine
            )
        )
        let finalNorm = try await load("language_model.model.norm.weight")

        var layers: [Edge0_35BLayerWeights] = []
        layers.reserveCapacity(configuration.numHiddenLayers)
        for layer in 0..<configuration.numHiddenLayers {
            let prefix = "language_model.model.layers.\(layer)"
            let inputNorm = try await load("\(prefix).input_layernorm.weight")
            let postNorm = try await load(
                "\(prefix).post_attention_layernorm.weight"
            )
            let attention: Edge0_35BAttentionWeights
            if configuration.layerTypes[layer] == .linearAttention {
                attention = .linear(Edge0_35BLinearAttentionWeights(
                    inProjQKV: try await linear(
                        module: "\(prefix).linear_attn.in_proj_qkv", loras: loras
                    ),
                    inProjZ: try await linear(
                        module: "\(prefix).linear_attn.in_proj_z", loras: loras
                    ),
                    inProjA: try await linear(
                        module: "\(prefix).linear_attn.in_proj_a", loras: loras
                    ),
                    inProjB: try await linear(
                        module: "\(prefix).linear_attn.in_proj_b", loras: loras
                    ),
                    outProj: try await linear(
                        module: "\(prefix).linear_attn.out_proj", loras: loras
                    ),
                    conv1dWeight: try await load(
                        "\(prefix).linear_attn.conv1d.weight"
                    ),
                    dtBias: try await load("\(prefix).linear_attn.dt_bias"),
                    aLog: (try await load("\(prefix).linear_attn.A_log"))
                        .asType(.float32),
                    normWeight: try await load(
                        "\(prefix).linear_attn.norm.weight"
                    )
                ))
            } else {
                attention = .full(Edge0_35BFullAttentionWeights(
                    qProj: try await linear(
                        module: "\(prefix).self_attn.q_proj", loras: loras
                    ),
                    kProj: try await linear(
                        module: "\(prefix).self_attn.k_proj", loras: loras
                    ),
                    vProj: try await linear(
                        module: "\(prefix).self_attn.v_proj", loras: loras
                    ),
                    oProj: try await linear(
                        module: "\(prefix).self_attn.o_proj", loras: loras
                    ),
                    qNorm: try await load("\(prefix).self_attn.q_norm.weight"),
                    kNorm: try await load("\(prefix).self_attn.k_norm.weight")
                ))
            }
            let layerWeights = Edge0_35BLayerWeights(
                index: layer,
                inputNorm: inputNorm,
                postAttentionNorm: postNorm,
                attention: attention,
                routerGate: try await linear(
                    module: "\(prefix).mlp.gate", loras: loras
                ),
                sharedExpertGateProj: try await linear(
                    module: "\(prefix).mlp.shared_expert.gate_proj", loras: loras
                ),
                sharedExpertUpProj: try await linear(
                    module: "\(prefix).mlp.shared_expert.up_proj", loras: loras
                ),
                sharedExpertDownProj: try await linear(
                    module: "\(prefix).mlp.shared_expert.down_proj", loras: loras
                ),
                sharedExpertGate: try await linear(
                    module: "\(prefix).mlp.shared_expert_gate", loras: loras
                )
            )
            layers.append(layerWeights)
        }
        return Edge0_35BModelWeights(
            configuration: configuration,
            embedTokens: embed,
            layers: layers,
            finalNorm: finalNorm,
            lmHead: lmHead
        )
    }
}

// MARK: - Edge0_35BExpertReadPlan
//
// Upstream `perf: prepare typed mmap expert reads once per layer`
// (Edge0-AI/Edge0#7) ported to the native loader: tensor locations,
// per-expert row geometry and the MLX construction shapes are resolved
// ONCE per layer at model load. The per-expert path is then pure
// advise → pread → wrap — no name building, no index lookup, no geometry
// re-derivation, which the streaming layer previously paid per expert per
// token (upstream measured a 5–12% median reduction of the expert-build
// path from hoisting exactly this work).
//
// The plan changes no byte range and no shape: it is exactness-inert by
// construction.

/// Per-projection geometry of the routed expert bundle (Phase 5A contract):
/// gate/up 512×2048, down 2048×512, 4-bit affine group 64.
struct Edge0_35BExpertGeometry: Sendable, Equatable {
    struct Projection: Sendable, Equatable {
        let name: String
        let outputDim: Int
        let inputDim: Int
    }

    let gate: Projection
    let up: Projection
    let down: Projection
    let bits: Int
    let groupSize: Int

    static let production = Edge0_35BExpertGeometry(
        gate: Projection(name: "gate_proj", outputDim: 512, inputDim: 2048),
        up: Projection(name: "up_proj", outputDim: 512, inputDim: 2048),
        down: Projection(name: "down_proj", outputDim: 2048, inputDim: 512),
        bits: 4,
        groupSize: 64
    )
}

/// One layer's resolved routed-expert read plan.
struct Edge0_35BExpertReadPlan: Sendable {
    /// One stacked tensor: where it lives and how many bytes one expert
    /// (one axis-0 row) occupies.
    struct Tensor: Sendable, Equatable {
        let location: Edge0TensorLocation
        let rowByteCount: UInt64

        /// Byte offset of `expert`'s slice inside the tensor payload.
        func rowOffset(_ expert: Int) -> UInt64 {
            rowByteCount * UInt64(expert)
        }
    }

    struct Projection: Sendable, Equatable {
        let name: String
        let weight: Tensor
        let scales: Tensor
        let biases: Tensor
        /// Row shapes for MLX array construction (expert axis removed).
        let weightShape: [Int]
        let scalesShape: [Int]
    }

    let layer: Int
    let gate: Projection
    let up: Projection
    let down: Projection

    /// Resolves the layer's nine routed-expert tensors once. Missing
    /// tensors and unusable row geometry are typed errors raised at model
    /// load, not during generation.
    static func build(
        layer: Int,
        index: Edge0SafetensorsIndex,
        geometry: Edge0_35BExpertGeometry = .production
    ) throws -> Edge0_35BExpertReadPlan {
        func tensor(projection: String, part: String) throws -> Tensor {
            let name = Edge0_35BExpertSpec.name(
                layer: layer, projection: projection, part: part
            )
            let location = try index.location(name)
            guard let rowByteCount = location.rowByteCount else {
                throw Edge0_35BWeightError.badGeometry(name)
            }
            return Tensor(location: location, rowByteCount: rowByteCount)
        }

        func projection(
            _ spec: Edge0_35BExpertGeometry.Projection
        ) throws -> Projection {
            Projection(
                name: spec.name,
                weight: try tensor(projection: spec.name, part: "weight"),
                scales: try tensor(projection: spec.name, part: "scales"),
                biases: try tensor(projection: spec.name, part: "biases"),
                weightShape: [
                    spec.outputDim,
                    spec.inputDim * geometry.bits / 32,
                ],
                scalesShape: [
                    spec.outputDim,
                    spec.inputDim / geometry.groupSize,
                ]
            )
        }

        return Edge0_35BExpertReadPlan(
            layer: layer,
            gate: try projection(geometry.gate),
            up: try projection(geometry.up),
            down: try projection(geometry.down)
        )
    }
}

// MARK: - Edge0_35BExpertLoader

struct Edge0_35BExpertLoader: Sendable {
    let stores: Edge0TensorStoreSet
    let readPlan: Edge0_35BExpertReadPlan
    /// Phase 5M: advisory kernel readahead over expert byte ranges before
    /// their preads. Default OFF; captured once per engine load.
    var readaheadHints = false

    /// Builds the layer's read plan once, at model load.
    init(
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet,
        layer: Int,
        readaheadHints: Bool = false
    ) throws {
        self.init(
            stores: stores,
            readPlan: try Edge0_35BExpertReadPlan.build(
                layer: layer, index: index
            ),
            readaheadHints: readaheadHints
        )
    }

    init(
        stores: Edge0TensorStoreSet,
        readPlan: Edge0_35BExpertReadPlan,
        readaheadHints: Bool = false
    ) {
        self.stores = stores
        self.readPlan = readPlan
        self.readaheadHints = readaheadHints
    }

    private func matrix(
        _ plan: Edge0_35BExpertReadPlan.Projection,
        expert: Int
    ) async throws -> Edge0ExpertQuantizedMatrix {
        let weightOffset = plan.weight.rowOffset(expert)
        let scalesOffset = plan.scales.rowOffset(expert)
        let biasesOffset = plan.biases.rowOffset(expert)
        if readaheadHints {
            stores.adviseSlice(
                plan.weight.location,
                byteOffset: weightOffset,
                byteLength: Int(plan.weight.rowByteCount)
            )
            stores.adviseSlice(
                plan.scales.location,
                byteOffset: scalesOffset,
                byteLength: Int(plan.scales.rowByteCount)
            )
            stores.adviseSlice(
                plan.biases.location,
                byteOffset: biasesOffset,
                byteLength: Int(plan.biases.rowByteCount)
            )
        }
        let weightBytes = try await stores.readSlice(
            plan.weight.location,
            byteOffset: weightOffset,
            byteLength: Int(plan.weight.rowByteCount)
        )
        let scalesBytes = try await stores.readSlice(
            plan.scales.location,
            byteOffset: scalesOffset,
            byteLength: Int(plan.scales.rowByteCount)
        )
        let biasesBytes = try await stores.readSlice(
            plan.biases.location,
            byteOffset: biasesOffset,
            byteLength: Int(plan.biases.rowByteCount)
        )
        return Edge0ExpertQuantizedMatrix(
            weight: MLXArray(
                weightBytes.bytes, plan.weightShape, dtype: .uint32
            ),
            scales: MLXArray(
                scalesBytes.bytes, plan.scalesShape, dtype: .bfloat16
            ),
            biases: MLXArray(
                biasesBytes.bytes, plan.scalesShape, dtype: .bfloat16
            )
        )
    }

    func load(_ key: Edge0ExpertKey) async throws -> Edge0_35BExpertWeights {
        async let gate = matrix(readPlan.gate, expert: key.expert)
        async let up = matrix(readPlan.up, expert: key.expert)
        async let down = matrix(readPlan.down, expert: key.expert)
        return Edge0_35BExpertWeights(
            gate: try await gate,
            up: try await up,
            down: try await down
        )
    }
}
