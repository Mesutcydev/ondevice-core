import Foundation
import MLX

// MARK: - Edge0TypedWeightError

enum Edge0TypedWeightError: Error, Equatable, Sendable {
    case missingTensor(String)
    case unexpectedShape(tensor: String, expected: [Int], actual: [Int])
    case unexpectedDType(tensor: String, expected: String, actual: String)
    case incompatibleLayer(index: Int)
}

extension Edge0TypedWeightError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingTensor(let name):
            return "Edge0 model is missing tensor '\(name)'."
        case .unexpectedShape(let tensor, let expected, let actual):
            return "Tensor '\(tensor)' shape \(actual) != expected \(expected)."
        case .unexpectedDType(let tensor, let expected, let actual):
            return "Tensor '\(tensor)' dtype \(actual) != expected \(expected)."
        case .incompatibleLayer(let index):
            return "Edge0 layer \(index) is not compatible with the validated configuration."
        }
    }
}

// MARK: - Edge0MoEWeights

struct Edge0MoEWeights: @unchecked Sendable {
    let routerWeight: MLXArray   // [num_experts, hidden]
    let expertBias: MLXArray     // [num_experts]
    let shared: Edge0MLP
}

enum Edge0MLPVariant: @unchecked Sendable {
    case dense(Edge0MLP)
    case moe(Edge0MoEWeights)
}

enum Edge0AttentionVariant: @unchecked Sendable {
    case kda(Edge0KDAWeights)
    case mla(Edge0MLAAttentionWeights)
}

struct Edge0LayerWeights: @unchecked Sendable {
    let index: Int
    let attention: Edge0AttentionVariant
    let inputNorm: MLXArray
    let postAttentionNorm: MLXArray
    let mlp: Edge0MLPVariant
}

// MARK: - Edge0RealWeightLoader
//
// Resolves every resident tensor for one layer exactly once at load time,
// validates dtype/shape/quantization geometry, and returns typed weights.
// Routed experts are never resolved here; they remain storage-backed.

struct Edge0RealWeightLoader: @unchecked Sendable {
    let configuration: Edge0ModelConfiguration
    let index: Edge0SafetensorsIndex
    let loader: Edge0ResidentTensorLoader

    init(
        configuration: Edge0ModelConfiguration,
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet
    ) {
        self.configuration = configuration
        self.index = index
        self.loader = Edge0ResidentTensorLoader(index: index, stores: stores)
    }

    // MARK: Tensor access

    func tensor(_ name: String) async throws -> MLXArray {
        guard index.contains(name) else {
            throw Edge0TypedWeightError.missingTensor(name)
        }
        return try await loader.load(index.location(name))
    }

    func bf16(_ name: String) async throws -> MLXArray {
        let array = try await tensor(name)
        guard array.dtype == .bfloat16 else {
            throw Edge0TypedWeightError.unexpectedDType(
                tensor: name,
                expected: "BF16",
                actual: "\(array.dtype)"
            )
        }
        return array
    }

    func expecting(
        _ name: String,
        shape: [Int],
        dtype: DType? = nil
    ) async throws -> MLXArray {
        let array = try await tensor(name)
        guard array.shape == shape else {
            throw Edge0TypedWeightError.unexpectedShape(
                tensor: name,
                expected: shape,
                actual: array.shape
            )
        }
        if let dtype, array.dtype != dtype {
            throw Edge0TypedWeightError.unexpectedDType(
                tensor: name,
                expected: "\(dtype)",
                actual: "\(array.dtype)"
            )
        }
        return array
    }

    func quantizedLinear(_ prefix: String) async throws -> Edge0LinearWeight {
        .quantized(try await quantizedWeights(prefix))
    }

    func quantizedWeights(_ prefix: String) async throws -> Edge0QuantizedLinearWeights {
        let groupSize = configuration.quantization.groupSize
        let bits = configuration.quantization.bits
        let weight = try await bf16OrU32("\(prefix).weight")
        let scales = try await bf16("\(prefix).scales")
        let biases = try await bf16("\(prefix).biases")
        guard weight.dtype == .uint32 else {
            throw Edge0TypedWeightError.unexpectedDType(
                tensor: "\(prefix).weight",
                expected: "U32",
                actual: "\(weight.dtype)"
            )
        }
        guard weight.ndim == 2, scales.ndim == 2, biases.ndim == 2 else {
            throw Edge0TypedWeightError.unexpectedShape(
                tensor: "\(prefix).weight",
                expected: [0, 0],
                actual: weight.shape
            )
        }
        guard weight.dim(0) == scales.dim(0),
              weight.dim(0) == biases.dim(0),
              scales.shape == biases.shape else {
            throw Edge0TypedWeightError.unexpectedShape(
                tensor: "\(prefix).scales",
                expected: scales.shape,
                actual: biases.shape
            )
        }
        let inputFeatures = weight.dim(1) * 32 / bits
        guard scales.dim(1) == inputFeatures / groupSize else {
            throw Edge0TypedWeightError.unexpectedShape(
                tensor: "\(prefix).scales",
                expected: [weight.dim(0), inputFeatures / groupSize],
                actual: scales.shape
            )
        }
        return Edge0QuantizedLinearWeights(
            weight: weight,
            scales: scales,
            biases: biases,
            groupSize: groupSize,
            bits: bits,
            mode: .affine
        )
    }

    private func bf16OrU32(_ name: String) async throws -> MLXArray {
        try await tensor(name)
    }

    /// Depthwise conv weight normalized to module layout `[C, kernel, 1]`.
    func convWeight(_ name: String) async throws -> MLXArray {
        let raw = try await tensor(name)
        if raw.ndim == 3, raw.dim(1) == 1 {
            return raw.transposed(0, 2, 1)
        }
        return raw
    }

    func normalizedConv(_ name: String, expected: [Int]) async throws -> MLXArray {
        let array = try await convWeight(name)
        guard array.shape == expected, array.dtype == .bfloat16 else {
            throw Edge0TypedWeightError.unexpectedShape(
                tensor: name,
                expected: expected,
                actual: array.shape
            )
        }
        return array
    }

    // MARK: Layer

    func layer(_ layerIndex: Int) async throws -> Edge0LayerWeights {
        guard layerIndex >= 0, layerIndex < configuration.numHiddenLayers else {
            throw Edge0TypedWeightError.incompatibleLayer(index: layerIndex)
        }
        let prefix = "model.layers.\(layerIndex)"
        let attention: Edge0AttentionVariant
        if configuration.isMLALayer(layerIndex) {
            attention = .mla(try await mlaWeights(prefix: prefix))
        } else {
            attention = .kda(try await kdaWeights(prefix: prefix))
        }

        let inputNorm = try await expecting(
            "\(prefix).input_layernorm.weight",
            shape: [configuration.hiddenSize],
            dtype: .bfloat16
        )
        let postNorm = try await expecting(
            "\(prefix).post_attention_layernorm.weight",
            shape: [configuration.hiddenSize],
            dtype: .bfloat16
        )

        let mlp: Edge0MLPVariant
        if layerIndex < configuration.firstKDenseReplace {
            mlp = .dense(Edge0MLP(
                gateProj: try await quantizedLinear("\(prefix).mlp.gate_proj"),
                upProj: try await quantizedLinear("\(prefix).mlp.up_proj"),
                downProj: try await quantizedLinear("\(prefix).mlp.down_proj")
            ))
        } else {
            let routerWeight = try await expecting(
                "\(prefix).mlp.gate.weight",
                shape: [configuration.numExperts, configuration.hiddenSize],
                dtype: .bfloat16
            )
            let expertBias = try await expecting(
                "\(prefix).mlp.gate.expert_bias",
                shape: [configuration.numExperts],
                dtype: .bfloat16
            )
            let shared = Edge0MLP(
                gateProj: try await quantizedLinear(
                    "\(prefix).mlp.shared_experts.gate_proj"
                ),
                upProj: try await quantizedLinear(
                    "\(prefix).mlp.shared_experts.up_proj"
                ),
                downProj: try await quantizedLinear(
                    "\(prefix).mlp.shared_experts.down_proj"
                )
            )
            mlp = .moe(Edge0MoEWeights(
                routerWeight: routerWeight,
                expertBias: expertBias,
                shared: shared
            ))
        }

        return Edge0LayerWeights(
            index: layerIndex,
            attention: attention,
            inputNorm: inputNorm,
            postAttentionNorm: postNorm,
            mlp: mlp
        )
    }

    private func mlaWeights(prefix: String) async throws -> Edge0MLAAttentionWeights {
        let attention = "\(prefix).attention"
        return Edge0MLAAttentionWeights(
            qAProj: try await quantizedLinear("\(attention).q_a_proj"),
            qALayernorm: try await expecting(
                "\(attention).q_a_layernorm.weight",
                shape: [configuration.qLoraRank ?? 0],
                dtype: .bfloat16
            ),
            qBProj: try await quantizedLinear("\(attention).q_b_proj"),
            directQProj: nil,
            kvAProjWithMQA: try await quantizedLinear(
                "\(attention).kv_a_proj_with_mqa"
            ),
            kvALayernorm: try await expecting(
                "\(attention).kv_a_layernorm.weight",
                shape: [configuration.kvLoraRank],
                dtype: .bfloat16
            ),
            kvBProj: try await quantizedLinear("\(attention).kv_b_proj"),
            dense: try await quantizedLinear("\(attention).dense"),
            gProj: try await quantizedLinear("\(attention).g_proj")
        )
    }

    private func kdaWeights(prefix: String) async throws -> Edge0KDAWeights {
        let attention = "\(prefix).attention"
        let projection = configuration.numAttentionHeads * configuration.headDim
        let kernel = configuration.shortConvKernelSize
        return Edge0KDAWeights(
            qProj: try await quantizedLinear("\(attention).q_proj"),
            kProj: try await quantizedLinear("\(attention).k_proj"),
            vProj: try await quantizedLinear("\(attention).v_proj"),
            qConvWeight: try await normalizedConv(
                "\(attention).q_conv1d.weight",
                expected: [projection, kernel, 1]
            ),
            kConvWeight: try await normalizedConv(
                "\(attention).k_conv1d.weight",
                expected: [projection, kernel, 1]
            ),
            vConvWeight: try await normalizedConv(
                "\(attention).v_conv1d.weight",
                expected: [projection, kernel, 1]
            ),
            fProj: try await quantizedLinear("\(attention).f_proj"),
            gProj: try await quantizedLinear("\(attention).g_proj"),
            bProj: try await quantizedLinear("\(attention).b_proj"),
            aLog: try await expecting(
                "\(attention).A_log",
                shape: [configuration.numAttentionHeads],
                dtype: .bfloat16
            ),
            dtBias: try await expecting(
                "\(attention).dt_bias",
                shape: [projection],
                dtype: .bfloat16
            ),
            oNorm: try await expecting(
                "\(attention).o_norm.weight",
                shape: [configuration.headDim],
                dtype: .bfloat16
            ),
            oProj: try await quantizedLinear("\(attention).o_proj")
        )
    }
}

// MARK: - Edge0LayerState

enum Edge0LayerState: @unchecked Sendable {
    case kda(Edge0KDAState)
    case mla(Edge0MLAState)

    static func fresh(for weights: Edge0LayerWeights) -> Edge0LayerState {
        switch weights.attention {
        case .kda: return .kda(.empty)
        case .mla: return .mla(.empty)
        }
    }
}

// MARK: - Edge0DecoderLayer
//
// Exact upstream block order:
//   h = x + attention(input_layernorm(x))
//   out = h + mlp(post_attention_layernorm(h))
// Dense layer 0 uses the dense MLP; layers >= first_k_dense_replace use the
// router + shared + storage-backed routed experts.

struct Edge0DecoderLayer: @unchecked Sendable {
    let weights: Edge0LayerWeights
    let configuration: Edge0ModelConfiguration
    let expertLayout: Edge0ExpertLayout
    let expertIndex: Edge0SafetensorsIndex

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0LayerState,
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        mode: Edge0ExecutionMode = .exact,
        staging: Edge0StagingCollector? = nil,
        prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil,
        positionBase: Int = 0,
        profile: Edge0ComponentProfile? = nil
    ) async throws -> MLXArray {
        let eps = Float(configuration.rmsNormEps)
        let attentionOutput: MLXArray
        switch (weights.attention, state) {
        case (.kda(let kdaWeights), .kda(var kdaState)):
            let kdaStarted = profile == nil ? nil : ContinuousClock.now
            defer {
                if let kdaStarted {
                    profile?.record(
                        \.kdaSeconds,
                        seconds: kdaStarted.duration(to: .now).timeInterval
                    )
                }
            }
            let normalized = Edge0LinearMath.rmsNorm(
                x, weight: weights.inputNorm, eps: eps
            )
            let attention = Edge0KDAAttention(
                numHeads: configuration.numAttentionHeads,
                headDim: configuration.headDim,
                convKernelSize: configuration.shortConvKernelSize,
                safeGate: configuration.kdaSafeGate,
                lowerBound: Float(configuration.kdaLowerBound),
                eps: eps,
                scale: Float(pow(Double(configuration.headDim), -0.5)),
                weights: kdaWeights
            )
            attentionOutput = attention(normalized, state: &kdaState)
            state = .kda(kdaState)
        case (.mla(let mlaWeights), .mla(var mlaState)):
            let mlaStarted = profile == nil ? nil : ContinuousClock.now
            defer {
                if let mlaStarted {
                    profile?.record(
                        \.mlaSeconds,
                        seconds: mlaStarted.duration(to: .now).timeInterval
                    )
                }
            }
            let normalized = Edge0LinearMath.rmsNorm(
                x, weight: weights.inputNorm, eps: eps
            )
            let attention = Edge0MLAAttention(
                numHeads: configuration.numAttentionHeads,
                qkNopeHeadDim: configuration.qkNopeHeadDim,
                qkRopeHeadDim: configuration.qkRopeHeadDim,
                vHeadDim: configuration.vHeadDim,
                kvLoraRank: configuration.kvLoraRank,
                qLoraRank: configuration.qLoraRank,
                scale: Float(pow(Double(configuration.qkHeadDim), -0.5)),
                gateKind: configuration.gatedAttentionGranularity,
                ropeTheta: Float(configuration.ropeTheta),
                eps: eps,
                weights: mlaWeights
            )
            attentionOutput = attention(normalized, state: &mlaState)
            state = .mla(mlaState)
        default:
            throw Edge0TypedWeightError.incompatibleLayer(index: weights.index)
        }

        let residual = x + attentionOutput
        let mlpInput = Edge0LinearMath.rmsNorm(
            residual, weight: weights.postAttentionNorm, eps: eps
        )
        let mlpOutput: MLXArray
        switch weights.mlp {
        case .dense(let mlp):
            mlpOutput = mlp(mlpInput)
        case .moe(let moe):
            let moeStarted = profile == nil ? nil : ContinuousClock.now
            mlpOutput = try await moeForward(
                mlpInput,
                weights: moe,
                pool: pool,
                mode: mode,
                staging: staging,
                prerouter: prerouter,
                positionBase: positionBase,
                profile: profile
            )
            if let moeStarted {
                profile?.record(
                    \.moeSeconds,
                    seconds: moeStarted.duration(to: .now).timeInterval
                )
            }
        }
        return residual + mlpOutput
    }

    // MARK: MoE

    /// Routed MoE, processed one token at a time so the bounded expert pool
    /// never needs more than top-k pins at once. `gather_qmm` reduces the
    /// inner dimension independently per output element, so splitting the
    /// batch does not change results relative to a single stacked gather.
    private func moeForward(
        _ x: MLXArray,
        weights: Edge0MoEWeights,
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        mode: Edge0ExecutionMode,
        staging: Edge0StagingCollector? = nil,
        prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil,
        positionBase: Int = 0,
        profile: Edge0ComponentProfile? = nil
    ) async throws -> MLXArray {
        let router = Edge0Router(configuration: configuration)
        let routerStarted = profile == nil ? nil : ContinuousClock.now
        let selection = router(
            x,
            weight: weights.routerWeight,
            expertBias: weights.expertBias
        )
        if let routerStarted {
            profile?.record(
                \.routerSeconds,
                seconds: routerStarted.duration(to: .now).timeInterval
            )
        }
        if mode == .staged || mode == .stagedPrerouter {
            return try await moeForwardStaged(
                x,
                weights: weights,
                selection: selection,
                pool: pool,
                staging: staging,
                prerouter: prerouter,
                positionBase: positionBase
            )
        }
        let batch = x.dim(0)
        let tokens = x.dim(1)
        let layerIndex = self.weights.index
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(batch * tokens)

        for batchIndex in 0..<batch {
            for tokenIndex in 0..<tokens {
                let tokenInput = x[
                    batchIndex..<(batchIndex + 1),
                    tokenIndex..<(tokenIndex + 1),
                    0...
                ]
                let tokenIndices = selection.indices[
                    batchIndex..<(batchIndex + 1),
                    tokenIndex..<(tokenIndex + 1),
                    0...
                ]
                let tokenWeights = selection.weights[
                    batchIndex..<(batchIndex + 1),
                    tokenIndex..<(tokenIndex + 1),
                    0...
                ]
                if let prerouter {
                    self.advisePrerouter(
                        prerouter,
                        tokenHidden: tokenInput,
                        indices: tokenIndices,
                        layerIndex: layerIndex,
                        token: positionBase + tokenIndex
                    )
                }
                outputs.append(try await self.moeTokenForward(
                    tokenInput,
                    indices: tokenIndices,
                    routerWeights: tokenWeights,
                    shared: weights.shared,
                    layerIndex: layerIndex,
                    pool: pool,
                    mode: mode
                ))
            }
        }
        return MLX.concatenated(outputs, axis: 1)
    }

    // MARK: Staged pipeline

    /// Two-bank staged prefill. While token i's TRUE-router selected experts
    /// compute on the GPU, token i+1's bank is acquired (storage I/O) and is
    /// awaited only at its use point. Banks are lease sets over the existing
    /// expert pool — no duplicated cache, no in-place mutation of payloads,
    /// and per-token arithmetic identical to exact / boundedPrefetch.
    ///
    /// Single-token (decode) work degenerates to the bounded-prefetch path.
    private func moeForwardStaged(
        _ x: MLXArray,
        weights: Edge0MoEWeights,
        selection: Edge0RouterResult,
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        staging: Edge0StagingCollector?,
        prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil,
        positionBase: Int = 0
    ) async throws -> MLXArray {
        let batch = x.dim(0)
        let tokens = x.dim(1)
        let layerIndex = self.weights.index

        func tokenInput(_ index: Int) -> MLXArray {
            x[0..<1, index..<(index + 1), 0...]
        }
        func tokenIndices(_ index: Int) -> MLXArray {
            selection.indices[0..<1, index..<(index + 1), 0...]
        }
        func tokenWeights(_ index: Int) -> MLXArray {
            selection.weights[0..<1, index..<(index + 1), 0...]
        }

        guard batch == 1, tokens > 1 else {
            // Decode / single token: no cross-token pipeline to build.
            var outputs: [MLXArray] = []
            for tokenIndex in 0..<tokens {
                outputs.append(try await moeTokenForward(
                    tokenInput(tokenIndex),
                    indices: tokenIndices(tokenIndex),
                    routerWeights: tokenWeights(tokenIndex),
                    shared: weights.shared,
                    layerIndex: layerIndex,
                    pool: pool,
                    mode: .boundedPrefetch
                ))
            }
            return MLX.concatenated(outputs, axis: 1)
        }

        let currentKeys = Self.selectedKeys(
            indices: tokenIndices(0), layerIndex: layerIndex
        )
        staging?.recordBankScheduled()
        var currentBank = try await Self.acquireConcurrently(
            keys: currentKeys, pool: pool
        )
        staging?.recordBankCompleted()

        var outputs: [MLXArray] = []
        outputs.reserveCapacity(tokens)

        for tokenIndex in 0..<tokens {
            if let prerouter {
                advisePrerouter(
                    prerouter,
                    tokenHidden: tokenInput(tokenIndex),
                    indices: tokenIndices(tokenIndex),
                    layerIndex: layerIndex,
                    token: positionBase + tokenIndex
                )
            }
            var nextTask: Task<[Edge0ExpertLease<Edge0ExpertWeights>], Error>?
            if tokenIndex + 1 < tokens {
                let keys = Self.selectedKeys(
                    indices: tokenIndices(tokenIndex + 1),
                    layerIndex: layerIndex
                )
                staging?.recordBankScheduled()
                nextTask = Task {
                    try await Self.acquireConcurrently(keys: keys, pool: pool)
                }
            }

            do {
                let output = try await computeRouted(
                    tokenInput(tokenIndex),
                    indices: tokenIndices(tokenIndex),
                    routerWeights: tokenWeights(tokenIndex),
                    leases: currentBank,
                    shared: weights.shared,
                    layerIndex: layerIndex,
                    earlyShared: nil
                )
                for lease in currentBank {
                    await pool.release(lease)
                }
                outputs.append(output)

                if let nextTask {
                    let waitStarted = ContinuousClock.now
                    do {
                        currentBank = try await nextTask.value
                    } catch {
                        staging?.recordCancellation()
                        throw error
                    }
                    staging?.recordBankUsed(
                        waitSeconds: waitStarted.duration(to: .now).timeInterval
                    )
                    staging?.recordBankCompleted()
                }
            } catch {
                if let nextTask {
                    if let leaked = try? await nextTask.value {
                        for lease in leaked {
                            await pool.release(lease)
                        }
                    }
                }
                for lease in currentBank {
                    await pool.release(lease)
                }
                staging?.recordStaleDiscard()
                throw error
            }
        }
        return MLX.concatenated(outputs, axis: 1)
    }

    /// Unique, order-preserving expert keys for one token's router selection.
    private static func selectedKeys(
        indices: MLXArray,
        layerIndex: Int
    ) -> [Edge0ExpertKey] {
        selectedExpertIDs(indices: indices).map {
            Edge0ExpertKey(layer: layerIndex, expert: $0)
        }
    }

    /// Unique, order-preserving expert IDs for one token's router selection.
    private static func selectedExpertIDs(indices: MLXArray) -> [Int] {
        let selected = indices.asType(.int32).asArray(Int32.self).map { Int($0) }
        var unique: [Int] = []
        for expert in selected where !unique.contains(expert) {
            unique.append(expert)
        }
        return unique
    }

    /// Advisory prerouter hook: reconcile the true selection for this layer
    /// against the prediction made by the previous layer, then predict the
    /// next layer's demand on this token's MoE input. Predictions only start
    /// speculative loads — the true router remains authoritative.
    private func advisePrerouter(
        _ prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>,
        tokenHidden: MLXArray,
        indices: MLXArray,
        layerIndex: Int,
        token: Int
    ) {
        let ids = Self.selectedExpertIDs(indices: indices)
        prerouter.reconcile(
            targetLayer: layerIndex, token: token, actualIDs: ids
        )
        prerouter.predictAndSchedule(
            owner: layerIndex,
            hidden: tokenHidden.asType(.float16),
            thisIDs: ids,
            token: token,
            targetLayerCount: configuration.numHiddenLayers,
            topK: configuration.numExpertsPerTok
        )
    }

    private func moeTokenForward(
        _ x: MLXArray,
        indices: MLXArray,
        routerWeights: MLXArray,
        shared: Edge0MLP,
        layerIndex: Int,
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        mode: Edge0ExecutionMode
    ) async throws -> MLXArray {
        let usesConcurrentLoads = mode != .exact
        let earlyShared: MLXArray? = usesConcurrentLoads ? shared(x) : nil
        if let earlyShared { MLX.asyncEval([earlyShared]) }

        let keys = Self.selectedKeys(indices: indices, layerIndex: layerIndex)
        let leases: [Edge0ExpertLease<Edge0ExpertWeights>]
        if usesConcurrentLoads {
            // True-router selected experts only. The tensor store's existing
            // bounded read semaphore caps disk concurrency; the expert pool
            // caps slots/bytes. Order is restored by offset so the stacked
            // tensors (and therefore the math) are identical to exact mode.
            leases = try await Self.acquireConcurrently(keys: keys, pool: pool)
        } else {
            var serial: [Edge0ExpertLease<Edge0ExpertWeights>] = []
            serial.reserveCapacity(keys.count)
            for key in keys {
                serial.append(try await pool.acquire(key))
            }
            leases = serial
        }

        do {
            let output = try await computeRouted(
                x,
                indices: indices,
                routerWeights: routerWeights,
                leases: leases,
                shared: shared,
                layerIndex: layerIndex,
                earlyShared: earlyShared
            )
            for lease in leases {
                await pool.release(lease)
            }
            return output
        } catch {
            for lease in leases {
                await pool.release(lease)
            }
            throw error
        }
    }

    /// Stacked gather-QMM for one token's leased experts, plus the shared
    /// expert and router-weighted aggregation. Evaluates before returning so
    /// callers may release leases immediately afterwards.
    private func computeRouted(
        _ x: MLXArray,
        indices: MLXArray,
        routerWeights: MLXArray,
        leases: [Edge0ExpertLease<Edge0ExpertWeights>],
        shared: Edge0MLP,
        layerIndex: Int,
        earlyShared: MLXArray?
    ) async throws -> MLXArray {
        let selected = indices.asType(.int32).asArray(Int32.self).map { Int($0) }
        var position = [Edge0ExpertKey: Int]()
        var upWeights: [MLXArray] = []
        var upScales: [MLXArray] = []
        var upBiases: [MLXArray] = []
        var gateWeights: [MLXArray] = []
        var gateScales: [MLXArray] = []
        var gateBiases: [MLXArray] = []
        var downWeights: [MLXArray] = []
        var downScales: [MLXArray] = []
        var downBiases: [MLXArray] = []

        for (offset, lease) in leases.enumerated() {
            position[lease.key] = offset
            upWeights.append(lease.payload.up.weight)
            upScales.append(lease.payload.up.scales)
            upBiases.append(lease.payload.up.biases)
            gateWeights.append(lease.payload.gate.weight)
            gateScales.append(lease.payload.gate.scales)
            gateBiases.append(lease.payload.gate.biases)
            downWeights.append(lease.payload.down.weight)
            downScales.append(lease.payload.down.scales)
            downBiases.append(lease.payload.down.biases)
        }

        let localIndices = MLXArray(
            selected.map {
                Int32(position[Edge0ExpertKey(layer: layerIndex, expert: $0)] ?? 0)
            },
            indices.shape
        ).asType(.int32)

        let stackedUp = Edge0ExpertQuantizedMatrix(
            weight: MLX.stacked(upWeights, axis: 0),
            scales: MLX.stacked(upScales, axis: 0),
            biases: MLX.stacked(upBiases, axis: 0)
        )
        let stackedGate = Edge0ExpertQuantizedMatrix(
            weight: MLX.stacked(gateWeights, axis: 0),
            scales: MLX.stacked(gateScales, axis: 0),
            biases: MLX.stacked(gateBiases, axis: 0)
        )
        let stackedDown = Edge0ExpertQuantizedMatrix(
            weight: MLX.stacked(downWeights, axis: 0),
            scales: MLX.stacked(downScales, axis: 0),
            biases: MLX.stacked(downBiases, axis: 0)
        )

        let expertDown = Edge0ExpertMath.switchGLUExpertForward(
            x, up: stackedUp, gate: stackedGate, down: stackedDown,
            indices: localIndices
        )
        let routerWeightsCast = routerWeights.asType(expertDown.dtype)
        let aggregate = (
            expertDown
                * MLX.expandedDimensions(routerWeightsCast, axis: -1)
        ).sum(axis: -2)
        let output = aggregate + (earlyShared ?? shared(x))
        MLX.eval(output)
        return output
    }

    /// Concurrent acquisition of the true router's selected experts. The
    /// pool and the tensor store keep hard bounds; a cancelled/failed group
    /// releases every lease it already obtained before rethrowing.
    private static func acquireConcurrently(
        keys: [Edge0ExpertKey],
        pool: Edge0ExpertPool<Edge0ExpertWeights>
    ) async throws -> [Edge0ExpertLease<Edge0ExpertWeights>] {
        try await withThrowingTaskGroup(
            of: (Int, Edge0ExpertLease<Edge0ExpertWeights>).self
        ) { group in
            for (offset, key) in keys.enumerated() {
                group.addTask {
                    let lease = try await pool.acquire(key)
                    if Task.isCancelled {
                        await pool.release(lease)
                        throw CancellationError()
                    }
                    return (offset, lease)
                }
            }
            var collected = [Edge0ExpertLease<Edge0ExpertWeights>?](
                repeating: nil, count: keys.count
            )
            do {
                for try await (offset, lease) in group {
                    collected[offset] = lease
                }
            } catch {
                for lease in collected.compactMap({ $0 }) {
                    await pool.release(lease)
                }
                throw error
            }
            return collected.compactMap { $0 }
        }
    }
}

private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
