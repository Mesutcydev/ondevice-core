import Foundation
import MLX

// MARK: - Edge0ExecutionMode

/// Baseline execution mode: the true router drives storage-backed expert
/// loads, awaited on miss. Optimized modes (prefetch/staging) will be
/// measured against this.
enum Edge0ExecutionMode: String, Sendable, CaseIterable {
    /// True router drives storage-backed loads, awaited on miss. Correctness
    /// and benchmark oracle.
    case exact
    /// Same true router, same experts, same math; selected-expert loads for
    /// one token are issued concurrently (bounded by the tensor store's read
    /// semaphore) and the resident shared expert is scheduled while they
    /// load. Load timing only — never routing, weights, or outputs.
    case boundedPrefetch
    /// Double-buffered prefill: while token i's true-router experts compute,
    /// token i+1's bank is acquired from storage. Decode degenerates to the
    /// bounded-prefetch path. Same math, same experts, pool-bounded.
    case staged
    /// Staged execution plus ADVISORY prerouter preloading. Predictions only
    /// start low-priority expert loads; the true router still decides every
    /// executed expert. Falls back to `.staged` when the predictor is
    /// unavailable.
    case stagedPrerouter
}

// MARK: - Edge0ModelState

struct Edge0ModelState: @unchecked Sendable {
    var layers: [Edge0LayerState]
    var position: Int

    static func fresh(for model: Edge0Model) -> Edge0ModelState {
        Edge0ModelState(
            layers: model.layers.map { Edge0LayerState.fresh(for: $0.weights) },
            position: 0
        )
    }
}

// MARK: - Edge0Model
//
// The complete immutable Edge0-8B model: quantized embedding, 24 resolved
// decoder layers, final norm, quantized lm_head. All resident tensors are
// resolved once during `load`; the forward path performs no tensor-name
// lookups. Routed experts remain storage-backed through `Edge0ExpertPool`.

struct Edge0Model: @unchecked Sendable {
    let configuration: Edge0ModelConfiguration
    let embedding: Edge0QuantizedEmbedding
    let layers: [Edge0DecoderLayer]
    let finalNorm: MLXArray
    let lmHead: Edge0QuantizedLinear

    static func load(
        configuration: Edge0ModelConfiguration,
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet
    ) async throws -> Edge0Model {
        let loader = Edge0RealWeightLoader(
            configuration: configuration,
            index: index,
            stores: stores
        )
        let embedding = Edge0QuantizedEmbedding(
            weights: try await loader.quantizedWeights("model.word_embeddings")
        )
        let finalNorm = try await loader.expecting(
            "model.norm.weight",
            shape: [configuration.hiddenSize],
            dtype: .bfloat16
        )
        let lmHead = Edge0QuantizedLinear(
            weights: try await loader.quantizedWeights("lm_head")
        )
        var layers: [Edge0DecoderLayer] = []
        layers.reserveCapacity(configuration.numHiddenLayers)
        for layerIndex in 0..<configuration.numHiddenLayers {
            let weights = try await loader.layer(layerIndex)
            layers.append(Edge0DecoderLayer(
                weights: weights,
                configuration: configuration,
                expertLayout: Edge0ExpertLayout(),
                expertIndex: index
            ))
        }
        return Edge0Model(
            configuration: configuration,
            embedding: embedding,
            layers: layers,
            finalNorm: finalNorm,
            lmHead: lmHead
        )
    }

    // MARK: - Forward

    /// Full-model prefill. Returns the last-token logits, the initialized
    /// generation state, and the final hidden states (for parity tests).
    @discardableResult
    func prefill(
        tokenIDs: [Int],
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        mode: Edge0ExecutionMode = .exact,
        staging: Edge0StagingCollector? = nil,
        prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil,
        profile: Edge0ComponentProfile? = nil,
        onLayer: ((Int, MLXArray) -> Void)? = nil
    ) async throws -> Edge0PrefillResult {
        profile?.begin(.prefill)
        let ids = MLXArray(
            tokenIDs.map { Int32($0) },
            [1, tokenIDs.count]
        )
        let embedStarted = profile == nil ? nil : ContinuousClock.now
        var hidden = embedding(ids)
        if let embedStarted {
            profile?.record(
                \.embeddingSeconds,
                seconds: embedStarted.duration(to: .now).timeInterval
            )
        }
        var state = Edge0ModelState.fresh(for: self)
        for (layerIndex, layer) in layers.enumerated() {
            hidden = try await layer(
                hidden,
                state: &state.layers[layerIndex],
                pool: pool,
                mode: mode,
                staging: staging,
                prerouter: prerouter,
                positionBase: 0,
                profile: profile
            )
            onLayer?(layerIndex, hidden)
        }
        state.position = tokenIDs.count
        let headStarted = profile == nil ? nil : ContinuousClock.now
        let normed = MLXFast.rmsNorm(
            hidden,
            weight: finalNorm,
            eps: Float(configuration.rmsNormEps)
        )
        let logits = lmHead(normed)
        if let headStarted {
            profile?.record(
                \.lmHeadSeconds,
                seconds: headStarted.duration(to: .now).timeInterval
            )
        }
        return Edge0PrefillResult(
            logits: logits,
            hidden: hidden,
            normedHidden: normed,
            state: state
        )
    }

    /// One cached decode token. Does not recompute the prompt.
    func decode(
        tokenID: Int,
        state: inout Edge0ModelState,
        pool: Edge0ExpertPool<Edge0ExpertWeights>,
        mode: Edge0ExecutionMode = .exact,
        staging: Edge0StagingCollector? = nil,
        prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil,
        profile: Edge0ComponentProfile? = nil
    ) async throws -> MLXArray {
        profile?.begin(.decode)
        let ids = MLXArray([Int32(tokenID)], [1, 1])
        let embedStarted = profile == nil ? nil : ContinuousClock.now
        var hidden = embedding(ids)
        if let embedStarted {
            profile?.record(
                \.embeddingSeconds,
                seconds: embedStarted.duration(to: .now).timeInterval
            )
        }
        for (layerIndex, layer) in layers.enumerated() {
            hidden = try await layer(
                hidden,
                state: &state.layers[layerIndex],
                pool: pool,
                mode: mode,
                staging: staging,
                prerouter: prerouter,
                positionBase: state.position,
                profile: profile
            )
        }
        state.position += 1
        let headStarted = profile == nil ? nil : ContinuousClock.now
        let normed = MLXFast.rmsNorm(
            hidden,
            weight: finalNorm,
            eps: Float(configuration.rmsNormEps)
        )
        let logits = lmHead(normed)
        if let headStarted {
            profile?.record(
                \.lmHeadSeconds,
                seconds: headStarted.duration(to: .now).timeInterval
            )
        }
        return logits
    }
}

struct Edge0PrefillResult: @unchecked Sendable {
    let logits: MLXArray
    let hidden: MLXArray
    let normedHidden: MLXArray
    let state: Edge0ModelState
}

private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
