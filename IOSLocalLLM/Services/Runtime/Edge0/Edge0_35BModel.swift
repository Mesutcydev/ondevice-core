import Foundation
import MLX

// MARK: - Edge0_35BLayerState

enum Edge0_35BLayerState: @unchecked Sendable {
    case linear(Edge0_35BLinearAttentionState)
    case full(Edge0_35BFullAttentionState)
}

struct Edge0_35BModelState: @unchecked Sendable {
    var layers: [Edge0_35BLayerState]
    /// Number of tokens consumed by the model so far.
    var position: Int
}

// MARK: - Edge0_35BMoE
//
// True-router MoE, processed one token at a time so the bounded expert pool
// never pins more than the released top-4 experts (plus transient overlap).
// Selection is the frozen release contract: precise softmax -> top-4 ->
// renormalize (norm_topk_prob), no expert bias, no prerouter.

struct Edge0_35BMoE: @unchecked Sendable {
    let weights: Edge0_35BLayerWeights
    let configuration: Edge0_35BModelConfiguration
    let expertLoader: Edge0_35BExpertLoader
    let pool: Edge0ExpertPool<Edge0_35BExpertWeights>
    /// Expert acquisition strategy. Exact awaits each selected expert in
    /// router order; boundedPrefetch acquires the token's selected missing
    /// experts concurrently (at most top-4 leases) and still executes them
    /// in router order.
    var executionMode: Edge0ExecutionMode = .exact
    /// Optional debug trace hook (never set in the production path).
    var trace: ((String, MLXArray) -> Void)? = nil
    /// Receives the already-materialized selected expert ids per token.
    /// Diagnostics only (profiling); never set in the production path.
    var onSelectedExperts: ((Int, [Int]) -> Void)? = nil
    /// Phase 5J advisory tap: receives (owner layer, MoE input, executed
    /// top-k ids) AFTER the true router selection. Nil in every default
    /// path; predictions can only start advisory loads, never execution.
    var prerouterTap: ((Int, MLXArray, [Int]) -> Void)? = nil

    private var layerIndex: Int { weights.index }
    private var topK: Int { configuration.releasedExpertsPerToken }

    /// Frozen release selection: precise softmax -> top-k -> renormalize.
    /// Shared by the MoE and the oracle-replay parity tests.
    static func select(
        logits: MLXArray,
        topK: Int
    ) -> (indices: MLXArray, scores: MLXArray, gates: MLXArray) {
        let gates = MLX.softmax(logits, axis: -1, precise: true)
        // Mirror upstream EXACTLY: `argpartition(gates, kth=-k)[..., -k:]`.
        // Ties at the k-th boundary are resolved by the partition kernel, so
        // negating the array (a different kernel input) can select a
        // different member of an equal-score tie. Same formulation => same
        // tie behaviour.
        let vocabulary = gates.dim(-1)
        let start = max(0, vocabulary - topK)
        let indices = MLX.argPartition(
            gates, kth: start, axis: -1
        )[.ellipsis, start...]
        var scores = MLX.takeAlong(gates, indices, axis: -1)
        scores = scores / (scores.sum(axis: -1, keepDims: true) + 1e-20)
        return (indices, scores, gates)
    }

    /// Per-token routed execution: pins only this token's selected experts
    /// and releases every lease before the next token, so a prompt whose
    /// selected-expert union exceeds the pool capacity still completes with
    /// a pool sized for a single token's top-k.
    /// One token's router decision, computed with the same M=1 ops as the
    /// per-token path so selections stay bit-identical.
    struct TokenSelection {
        var selected: [Int]
        var scores: MLXArray
        var indicesShape: [Int]
    }

    /// Phase 5K candidate: lazily computed per-token routing selection (same
    /// math as `tokenSelection`, without the forced CPU readback).
    struct LazySelection {
        var indices: MLXArray
        var scores: MLXArray
    }

    /// 0 = production (one forced readback per token per layer),
    /// 1 = candidate (all pending router readbacks materialized once per
    /// group). Values are bit-identical; only the completion boundary for
    /// the index readback changes.
    var routerReadbackMode: Int = 0

    func callAsFunction(
        _ x: MLXArray,
        profile: Edge0ComponentProfile? = nil,
        onRouter: ((Int, MLXArray) -> Void)? = nil
    ) async throws -> MLXArray {
        let batch = x.dim(0)
        let tokens = x.dim(1)
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(batch * tokens)
        // Staged prefill: the next token's true-router selection is computed
        // ahead and its experts start loading while the current token
        // computes. Decode (single token) falls through to bounded
        // acquisition below. Selection hooks still fire in token order
        // inside routedToken.
        let capacitySlots = pool.configuredCapacitySlots
        let capacityGroup = topK > 0 ? max(1, capacitySlots / topK) : 1
        let groupSize = max(
            1,
            min(Edge0EnginePreferences.edge0_35BMicrobatchGroupSize, capacityGroup)
        )
        if executionMode == .staged, tokens > 1, groupSize > 1 {
            // Phase 5H candidate: one batched routed computation per bounded
            // token group (union of selected experts, per-token local
            // indices, batched gather-QMM). The router projection itself
            // stays per token.
            return try await microbatchPrefill(
                x, groupSize: groupSize, profile: profile,
                onSelectedExperts: onSelectedExperts
            )
        }
        if executionMode == .staged, tokens > 1 {
            // Windowed completion (Phase 5G candidate): evaluate the routed
            // graphs of up to `window` tokens together and release that
            // window's leases afterwards. Per-token math is unchanged (M=1
            // QMM); only the completion boundary and lease lifetime move.
            // The window is bounded by pool capacity / topK so small pools
            // keep working.
            let capacity = pool.configuredCapacitySlots
            let capacityWindow = topK > 0 ? max(1, capacity / topK) : 1
            let window = max(
                1,
                min(Edge0EnginePreferences.edge0_35BStagedEvalWindow, capacityWindow)
            )
            var windowOutputs: [MLXArray] = []
            var windowLeases: [Edge0ExpertLease<Edge0_35BExpertWeights>] = []

            func flushWindow() async {
                guard !windowOutputs.isEmpty else { return }
                let evalStarted = ContinuousClock.now
                MLX.eval(windowOutputs)
                profile?.record(
                    \.moeEvalSeconds,
                    seconds: evalStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeEvalSamples, seconds: 1)
                }
                let releaseStarted = ContinuousClock.now
                for lease in windowLeases {
                    await pool.release(lease)
                }
                profile?.record(
                    \.moeReleaseSeconds,
                    seconds: releaseStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeReleaseSamples, seconds: 1)
                }
                windowOutputs.removeAll()
                windowLeases.removeAll()
            }

            do {
                var lookahead: TokenSelection?
                for tokenIndex in 0..<tokens {
                    try Task.checkCancellation()
                    let tokenInput = x[
                        0..<1, tokenIndex..<(tokenIndex + 1), 0...
                    ]
                    let selection = lookahead
                        ?? Self.tokenSelection(
                            weights: weights, x: tokenInput, topK: topK
                        )
                    if tokenIndex + 1 < tokens {
                        let nextInput = x[
                            0..<1, (tokenIndex + 1)..<(tokenIndex + 2), 0...
                        ]
                        let next = Self.tokenSelection(
                            weights: weights, x: nextInput, topK: topK
                        )
                        lookahead = next
                        var unique: [Int] = []
                        for expert in next.selected
                        where !unique.contains(expert) {
                            unique.append(expert)
                        }
                        await pool.beginPrefetch(unique.map {
                            Edge0ExpertKey(layer: layerIndex, expert: $0)
                        })
                    } else {
                        lookahead = nil
                    }
                    let result = try await routedToken(
                        tokenInput, precomputed: selection,
                        profile: profile, onRouter: onRouter, deferred: true
                    )
                    outputs.append(result.output)
                    windowOutputs.append(result.output)
                    windowLeases.append(contentsOf: result.leases)
                    if windowOutputs.count >= window {
                        await flushWindow()
                    }
                }
                await flushWindow()
            } catch {
                for lease in windowLeases {
                    await pool.release(lease)
                }
                throw error
            }
            return MLX.concatenated(outputs, axis: 1)
        }
        for batchIndex in 0..<batch {
            for tokenIndex in 0..<tokens {
                let tokenInput = x[
                    batchIndex..<(batchIndex + 1),
                    tokenIndex..<(tokenIndex + 1),
                    0...
                ]
                let result = try await routedToken(
                    tokenInput, profile: profile, onRouter: onRouter
                )
                outputs.append(result.output)
            }
        }
        return MLX.concatenated(outputs, axis: 1)
    }

    /// True-router selection for one token (no hooks, no side effects).
    static func tokenSelection(
        weights: Edge0_35BLayerWeights,
        x: MLXArray,
        topK: Int
    ) -> TokenSelection {
        let lazy = tokenSelectionLazy(weights: weights, x: x, topK: topK)
        let selected = lazy.indices.asType(.int32)
            .asArray(Int32.self).map { Int($0) }
        return TokenSelection(
            selected: selected, scores: lazy.scores,
            indicesShape: lazy.indices.shape
        )
    }

    /// Same router gate + `select` math, but the returned indices stay lazy
    /// so a caller can materialize several tokens with ONE eval.
    static func tokenSelectionLazy(
        weights: Edge0_35BLayerWeights,
        x: MLXArray,
        topK: Int
    ) -> LazySelection {
        let logits = weights.routerGate.base(x)
        let (indices, scores, _) = select(logits: logits, topK: topK)
        return LazySelection(indices: indices, scores: scores)
    }

    /// Computes one token's routed MoE output. With `deferred` the caller
    /// receives the graph plus its expert leases and is responsible for the
    /// completion boundary and lease release (staged eval window); otherwise
    /// the token is evaluated and released here (exact/bounded/decode).
    private func routedToken(
        _ x: MLXArray,
        precomputed: TokenSelection? = nil,
        profile: Edge0ComponentProfile? = nil,
        onRouter: ((Int, MLXArray) -> Void)? = nil,
        deferred: Bool = false
    ) async throws -> (output: MLXArray, leases: [Edge0ExpertLease<Edge0_35BExpertWeights>]) {
        let selection: TokenSelection
        if let precomputed {
            selection = precomputed
        } else {
            let routerStarted = ContinuousClock.now
            let logits = weights.routerGate.base(x)
            trace?("gate_logits", logits)
            trace?("moe_input", x)
            let (indices, scores, _) = Self.select(
                logits: logits, topK: topK
            )
            onRouter?(layerIndex, indices)
            profile?.record(
                \.routerSeconds,
                seconds: routerStarted.duration(to: .now).timeInterval
            )
            selection = TokenSelection(
                selected: indices.asType(.int32)
                    .asArray(Int32.self).map { Int($0) },
                scores: scores,
                indicesShape: indices.shape
            )
        }
        let selected = selection.selected
        onSelectedExperts?(layerIndex, selected)
        prerouterTap?(layerIndex, x, selected)
        var uniqueExperts: [Int] = []
        for expert in selected where !uniqueExperts.contains(expert) {
            uniqueExperts.append(expert)
        }
        // Impossible capacity must fail fast, never wait forever. This is
        // a constant read — never a pool statistics snapshot (that used to
        // run per token and grew with read-latency history).
        let capacity = pool.configuredCapacitySlots
        if capacity > 0, uniqueExperts.count > capacity {
            throw Edge0_35BMoEError.insufficientPoolSlots(
                required: uniqueExperts.count, available: capacity
            )
        }

        let moeStarted = ContinuousClock.now
        var leases: [Edge0ExpertLease<Edge0_35BExpertWeights>] = []
        do {
            let acquireStarted = ContinuousClock.now
            var leasesByExpert: [Int: Edge0ExpertLease<Edge0_35BExpertWeights>] = [:]
            let concurrentAcquire = executionMode == .boundedPrefetch
                || executionMode == .staged
            if concurrentAcquire, uniqueExperts.count > 1 {
                // Acquire this token's selected missing experts concurrently
                // (bounded by the pool and the store's read semaphore). The
                // execution order below stays router order regardless of
                // which acquisition finishes first.
                try await withThrowingTaskGroup(
                    of: (Int, Edge0ExpertLease<Edge0_35BExpertWeights>).self
                ) { group in
                    for expert in uniqueExperts {
                        group.addTask { [pool, layerIndex] in
                            let key = Edge0ExpertKey(
                                layer: layerIndex, expert: expert
                            )
                            return (expert, try await pool.acquire(key))
                        }
                    }
                    do {
                        for try await (expert, lease) in group {
                            leasesByExpert[expert] = lease
                            leases.append(lease)
                        }
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } else {
                for expert in uniqueExperts {
                    let key = Edge0ExpertKey(
                        layer: layerIndex, expert: expert
                    )
                    let lease = try await pool.acquire(key)
                    leasesByExpert[expert] = lease
                    leases.append(lease)
                }
            }

            profile?.record(
                \.moeAcquireSeconds,
                seconds: acquireStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeAcquireSamples, seconds: 1)
            }
            let stackStarted = ContinuousClock.now
            var position = [Edge0ExpertKey: Int]()
            var gatesStack: [MLXArray] = []
            var upStack: [MLXArray] = []
            var downStack: [MLXArray] = []
            var gateScales: [MLXArray] = []
            var upScales: [MLXArray] = []
            var downScales: [MLXArray] = []
            var gateBiases: [MLXArray] = []
            var upBiases: [MLXArray] = []
            var downBiases: [MLXArray] = []
            for (offset, expert) in uniqueExperts.enumerated() {
                let key = Edge0ExpertKey(layer: layerIndex, expert: expert)
                guard let lease = leasesByExpert[expert] else {
                    throw Edge0_35BMoEError.insufficientPoolSlots(
                        required: uniqueExperts.count,
                        available: leasesByExpert.count
                    )
                }
                position[key] = offset
                gatesStack.append(lease.payload.gate.weight)
                gateScales.append(lease.payload.gate.scales)
                gateBiases.append(lease.payload.gate.biases)
                upStack.append(lease.payload.up.weight)
                upScales.append(lease.payload.up.scales)
                upBiases.append(lease.payload.up.biases)
                downStack.append(lease.payload.down.weight)
                downScales.append(lease.payload.down.scales)
                downBiases.append(lease.payload.down.biases)
            }

            profile?.record(
                \.moeStackBuildSeconds,
                seconds: stackStarted.duration(to: .now).timeInterval
            )
            if let profile {
                let stackSources = gatesStack + gateScales + gateBiases
                    + upStack + upScales + upBiases
                    + downStack + downScales + downBiases
                let stackBytes = stackSources.reduce(UInt64(0)) {
                    $0 + UInt64($1.nbytes)
                }
                profile.record(
                    \.moeStacksBuilt,
                    seconds: Double(uniqueExperts.count * 3)
                )
                profile.record(
                    \.moeStackBytes, seconds: Double(stackBytes)
                )
                profile.recordLast(
                    \.gatherM, value: Double(x.dim(-2))
                )
                profile.recordLast(
                    \.gatherRows, value: Double(selected.count)
                )
                profile.recordLast(
                    \.gatherExperts, value: Double(uniqueExperts.count)
                )
            }
            if profile != nil {
                profile?.record(\.moeStackBuildSamples, seconds: 1)
            }
            let routedStarted = ContinuousClock.now

            let localIndices = MLXArray(
                selected.map {
                    Int32(position[Edge0ExpertKey(
                        layer: layerIndex, expert: $0
                    )] ?? 0)
                },
                selection.indicesShape
            ).asType(.int32)

            let stackedGate = Edge0ExpertQuantizedMatrix(
                weight: MLX.stacked(gatesStack, axis: 0),
                scales: MLX.stacked(gateScales, axis: 0),
                biases: MLX.stacked(gateBiases, axis: 0)
            )
            let stackedUp = Edge0ExpertQuantizedMatrix(
                weight: MLX.stacked(upStack, axis: 0),
                scales: MLX.stacked(upScales, axis: 0),
                biases: MLX.stacked(upBiases, axis: 0)
            )
            let stackedDown = Edge0ExpertQuantizedMatrix(
                weight: MLX.stacked(downStack, axis: 0),
                scales: MLX.stacked(downScales, axis: 0),
                biases: MLX.stacked(downBiases, axis: 0)
            )

            let expertDown = Edge0ExpertMath.switchGLUExpertForward(
                x, up: stackedUp, gate: stackedGate, down: stackedDown,
                indices: localIndices
            )
            let scoresCast = selection.scores.asType(expertDown.dtype)
            let aggregate = (
                expertDown * MLX.expandedDimensions(scoresCast, axis: -1)
            ).sum(axis: -2)

            profile?.record(
                \.moeRoutedSeconds,
                seconds: routedStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeRoutedSamples, seconds: 1)
            }
            let sharedStarted = ContinuousClock.now

            // Shared expert + sigmoid gate.
            let sharedGate = weights.sharedExpertGateProj.apply(x)
            let sharedUp = weights.sharedExpertUpProj.apply(x)
            let sharedHidden = Edge0LinearMath.silu(sharedGate) * sharedUp
            let sharedOut = weights.sharedExpertDownProj.apply(sharedHidden)
            let sharedScaled = MLX.sigmoid(
                weights.sharedExpertGate.base(x)
            ) * sharedOut

            profile?.record(
                \.moeSharedSeconds,
                seconds: sharedStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeSharedSamples, seconds: 1)
            }
            let combineStarted = ContinuousClock.now
            let output = aggregate + sharedScaled
            trace?("out", output)
            profile?.record(
                \.moeCombineSeconds,
                seconds: combineStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeCombineSamples, seconds: 1)
            }
            if let profile {
                let total = moeStarted.duration(to: .now).timeInterval
                switch layerIndex {
                case ..<10:
                    profile.record(\.moeEarlySeconds, seconds: total)
                case ..<30:
                    profile.record(\.moeMiddleSeconds, seconds: total)
                default:
                    profile.record(\.moeLateSeconds, seconds: total)
                }
                profile.record(\.moeInvocations, seconds: 1)
            }
            if deferred {
                // Staged eval window: completion and lease release happen
                // together after the window's graphs are submitted.
                return (output, leases)
            }
            let evalStarted = ContinuousClock.now
            MLX.eval(output)
            profile?.record(
                \.moeEvalSeconds,
                seconds: evalStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeEvalSamples, seconds: 1)
            }
            let releaseStarted = ContinuousClock.now
            for lease in leases {
                await pool.release(lease)
            }
            profile?.record(
                \.moeReleaseSeconds,
                seconds: releaseStarted.duration(to: .now).timeInterval
            )
            if profile != nil {
                profile?.record(\.moeReleaseSamples, seconds: 1)
            }
            return (output, [])
        } catch {
            for lease in leases {
                await pool.release(lease)
            }
            throw error
        }
    }
}

// MARK: - Phase 5H microbatch

extension Edge0_35BMoE {
    /// Bounded routed-MoE microbatch. Process `groupSize` prompt tokens with
    /// ONE batched gather-QMM per projection:
    ///   x group            [1, g, 1, 2048]
    ///   union expert stack [U, out, in] (U <= g * topK)
    ///   local indices      [1, g, topK]  (union position per token/expert)
    ///   routed projection  [1, g, topK, out] -> SwiGLU -> down [1, g, topK, 2048]
    ///   weighted reduce    [1, g, 2048] with each token's original scores
    ///   shared expert      unchanged per-token branch, concatenated [1, g, 2048]
    /// Acquire order is the order-preserving union; a shared expert has one
    /// payload in the group and every token refers to its local index.
    func microbatchPrefill(
        _ x: MLXArray,
        groupSize: Int,
        profile: Edge0ComponentProfile? = nil,
        onSelectedExperts: ((Int, [Int]) -> Void)? = nil
    ) async throws -> MLXArray {
        let tokens = x.dim(1)
        let capacitySlots = pool.configuredCapacitySlots
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(tokens)
        var lookahead: [TokenSelection]?
        // Phase 5K candidate state (mode 1): lazy next-group selections and
        // their already-resolved ids, scoped to this layer invocation.
        var lookaheadLazy: [LazySelection]?
        var lookaheadIDs: [[Int]]?
        var tokenIndex = 0

        while tokenIndex < tokens {
            let end = min(tokens, tokenIndex + groupSize)
            let groupCount = end - tokenIndex

            // 1. Per-token true-router selections, in token order. The router
            //    projection is deliberately not batched: shape and rounding
            //    changes there could alter tied selections.
            //
            //    Production (mode 0) forces one CPU readback per token; the
            //    Phase 5K candidate (mode 1) keeps the per-token math and
            //    materializes every pending index readback with ONE eval per
            //    group, removing ~7 of 8 forced synchronizations per layer.
            let selectStarted = ContinuousClock.now
            let nextEnd = end < tokens ? min(tokens, end + groupSize) : end
            var selections: [TokenSelection] = []
            var nextIDs: [[Int]] = []

            if routerReadbackMode == 1 {
                var lazyCurrent = lookaheadLazy ?? []
                if lazyCurrent.count != groupCount {
                    lazyCurrent = (tokenIndex..<end).map { t in
                        Self.tokenSelectionLazy(
                            weights: weights,
                            x: x[0..<1, t..<(t + 1), 0...],
                            topK: topK
                        )
                    }
                    lookaheadIDs = nil
                }
                var lazyNext: [LazySelection] = []
                if end < tokens {
                    lazyNext = (end..<nextEnd).map { t in
                        Self.tokenSelectionLazy(
                            weights: weights,
                            x: x[0..<1, t..<(t + 1), 0...],
                            topK: topK
                        )
                    }
                }
                var currentIDs = lookaheadIDs ?? []
                let needsCurrentIDs = currentIDs.count != lazyCurrent.count
                var batches: [MLXArray] = []
                if needsCurrentIDs { batches = lazyCurrent.map(\.indices) }
                batches += lazyNext.map(\.indices)
                if !batches.isEmpty {
                    let stacked = MLX.concatenated(
                        batches.map { $0.reshaped([1, topK]) }, axis: 0
                    )
                    MLX.eval(stacked)
                    let flat = stacked.asType(.int32)
                        .asArray(Int32.self).map { Int($0) }
                    var cursor = 0
                    func takeIDs(_ count: Int) -> [[Int]] {
                        var out: [[Int]] = []
                        out.reserveCapacity(count)
                        for _ in 0..<count {
                            out.append(Array(flat[cursor..<(cursor + topK)]))
                            cursor += topK
                        }
                        return out
                    }
                    if needsCurrentIDs { currentIDs = takeIDs(lazyCurrent.count) }
                    if !lazyNext.isEmpty { nextIDs = takeIDs(lazyNext.count) }
                }
                lookaheadLazy = lazyNext.isEmpty ? nil : lazyNext
                lookaheadIDs = nextIDs.isEmpty ? nil : nextIDs
                selections = zip(lazyCurrent, currentIDs).map { pair in
                    TokenSelection(
                        selected: pair.1, scores: pair.0.scores,
                        indicesShape: [1, groupCount, topK]
                    )
                }
            } else {
                if let lookahead, lookahead.count == groupCount {
                    selections = lookahead
                } else {
                    selections = (tokenIndex..<end).map { t in
                        Self.tokenSelection(
                            weights: weights,
                            x: x[0..<1, t..<(t + 1), 0...],
                            topK: topK
                        )
                    }
                }
                if end < tokens {
                    let next = (end..<nextEnd).map { t in
                        Self.tokenSelection(
                            weights: weights,
                            x: x[0..<1, t..<(t + 1), 0...],
                            topK: topK
                        )
                    }
                    lookahead = next
                    nextIDs = next.map(\.selected)
                } else {
                    lookahead = nil
                }
            }

            for selection in selections {
                onSelectedExperts?(layerIndex, selection.selected)
            }

            // 2. Next group's advisory loads overlap this group's compute
            //    (same actual-router lookahead in both modes).
            if !nextIDs.isEmpty {
                var union: [Int] = []
                for ids in nextIDs {
                    for expert in ids where !union.contains(expert) {
                        union.append(expert)
                    }
                }
                await pool.beginPrefetch(union.map {
                    Edge0ExpertKey(layer: layerIndex, expert: $0)
                })
            }
            profile?.record(
                \.moeSelectSeconds,
                seconds: selectStarted.duration(to: .now).timeInterval
            )

            // 3. Order-preserving union + hard capacity check.
            var union: [Int] = []
            for selection in selections {
                for expert in selection.selected
                where !union.contains(expert) {
                    union.append(expert)
                }
            }
            if capacitySlots > 0, union.count > capacitySlots {
                throw Edge0_35BMoEError.insufficientPoolSlots(
                    required: union.count, available: capacitySlots
                )
            }

            var leases: [Edge0ExpertLease<Edge0_35BExpertWeights>] = []
            do {
                // 4. Acquire the union concurrently (bounded by the pool).
                let acquireStarted = ContinuousClock.now
                var leasesByExpert: [Int: Edge0ExpertLease<Edge0_35BExpertWeights>] = [:]
                try await withThrowingTaskGroup(
                    of: (Int, Edge0ExpertLease<Edge0_35BExpertWeights>).self
                ) { group in
                    for expert in union {
                        group.addTask { [pool, layerIndex] in
                            let key = Edge0ExpertKey(
                                layer: layerIndex, expert: expert
                            )
                            return (expert, try await pool.acquire(key))
                        }
                    }
                    do {
                        for try await (expert, lease) in group {
                            leasesByExpert[expert] = lease
                            leases.append(lease)
                        }
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
                profile?.record(
                    \.moeAcquireSeconds,
                    seconds: acquireStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeAcquireSamples, seconds: 1)
                }

                let stackStarted = ContinuousClock.now
                var position: [Int: Int] = [:]
                var gatesStack: [MLXArray] = []
                var upStack: [MLXArray] = []
                var downStack: [MLXArray] = []
                var gateScales: [MLXArray] = []
                var upScales: [MLXArray] = []
                var downScales: [MLXArray] = []
                var gateBiases: [MLXArray] = []
                var upBiases: [MLXArray] = []
                var downBiases: [MLXArray] = []
                for (offset, expert) in union.enumerated() {
                    guard let lease = leasesByExpert[expert] else {
                        throw Edge0_35BMoEError.insufficientPoolSlots(
                            required: union.count,
                            available: leasesByExpert.count
                        )
                    }
                    position[expert] = offset
                    gatesStack.append(lease.payload.gate.weight)
                    gateScales.append(lease.payload.gate.scales)
                    gateBiases.append(lease.payload.gate.biases)
                    upStack.append(lease.payload.up.weight)
                    upScales.append(lease.payload.up.scales)
                    upBiases.append(lease.payload.up.biases)
                    downStack.append(lease.payload.down.weight)
                    downScales.append(lease.payload.down.scales)
                    downBiases.append(lease.payload.down.biases)
                }
                let stackedGate = Edge0ExpertQuantizedMatrix(
                    weight: MLX.stacked(gatesStack, axis: 0),
                    scales: MLX.stacked(gateScales, axis: 0),
                    biases: MLX.stacked(gateBiases, axis: 0)
                )
                let stackedUp = Edge0ExpertQuantizedMatrix(
                    weight: MLX.stacked(upStack, axis: 0),
                    scales: MLX.stacked(upScales, axis: 0),
                    biases: MLX.stacked(upBiases, axis: 0)
                )
                let stackedDown = Edge0ExpertQuantizedMatrix(
                    weight: MLX.stacked(downStack, axis: 0),
                    scales: MLX.stacked(downScales, axis: 0),
                    biases: MLX.stacked(downBiases, axis: 0)
                )
                profile?.record(
                    \.moeStackBuildSeconds,
                    seconds: stackStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeStackBuildSamples, seconds: 1)
                }

                // 5. Batched routed computation for the whole group.
                let routedStarted = ContinuousClock.now
                let xGroup = Edge0ExpertMath.switchGLUExpandedInput(
                    x[0..<1, tokenIndex..<end, 0...]
                )
                var localIndexValues: [Int32] = []
                for selection in selections {
                    for expert in selection.selected {
                        localIndexValues.append(
                            Int32(position[expert] ?? 0)
                        )
                    }
                }
                let localIndices = MLXArray(
                    localIndexValues, [1, groupCount, topK]
                ).asType(.int32)
                let projectedUp = Edge0ExpertMath.gatheredProjection(
                    xGroup, weight: stackedUp.weight,
                    scales: stackedUp.scales, biases: stackedUp.biases,
                    indices: localIndices
                )
                let projectedGate = Edge0ExpertMath.gatheredProjection(
                    xGroup, weight: stackedGate.weight,
                    scales: stackedGate.scales, biases: stackedGate.biases,
                    indices: localIndices
                )
                let hidden = Edge0ExpertMath.swiglu(
                    up: projectedUp, gate: projectedGate
                )
                let projectedDown = Edge0ExpertMath.gatheredProjection(
                    hidden, weight: stackedDown.weight,
                    scales: stackedDown.scales, biases: stackedDown.biases,
                    indices: localIndices
                ).squeezed(axis: -2)
                let scoresGroup = MLX.concatenated(
                    selections.map(\.scores), axis: 1
                ).asType(projectedDown.dtype)
                let aggregate = (
                    projectedDown
                        * MLX.expandedDimensions(scoresGroup, axis: -1)
                ).sum(axis: -2)
                profile?.record(
                    \.moeRoutedSeconds,
                    seconds: routedStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeRoutedSamples, seconds: 1)
                }

                // 6. Shared expert: per-token projections concatenated.
                //    (Phase 5I group batching was rejected: batched M=g
                //    projections deterministically changed late greedy chat
                //    tokens versus the per-token branch.)
                let sharedStarted = ContinuousClock.now
                var sharedOutputs: [MLXArray] = []
                sharedOutputs.reserveCapacity(groupCount)
                for t in tokenIndex..<end {
                    let tokenInput = x[0..<1, t..<(t + 1), 0...]
                    let sharedGate = weights.sharedExpertGateProj.apply(
                        tokenInput
                    )
                    let sharedUp = weights.sharedExpertUpProj.apply(
                        tokenInput
                    )
                    let sharedHidden =
                        Edge0LinearMath.silu(sharedGate) * sharedUp
                    let sharedOut = weights.sharedExpertDownProj.apply(
                        sharedHidden
                    )
                    sharedOutputs.append(
                        MLX.sigmoid(
                            weights.sharedExpertGate.base(tokenInput)
                        ) * sharedOut
                    )
                }
                let sharedGroup = MLX.concatenated(sharedOutputs, axis: 1)
                profile?.record(
                    \.moeSharedSeconds,
                    seconds: sharedStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeSharedSamples, seconds: 1)
                }

                let combineStarted = ContinuousClock.now
                let groupOutput = aggregate + sharedGroup
                profile?.record(
                    \.moeCombineSeconds,
                    seconds: combineStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeCombineSamples, seconds: 1)
                }

                // 7. Completion before lease release (unchanged barrier),
                //    then append token outputs in original order.
                let evalStarted = ContinuousClock.now
                MLX.eval(groupOutput)
                profile?.record(
                    \.moeEvalSeconds,
                    seconds: evalStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeEvalSamples, seconds: 1)
                }
                if let profile {
                    let total = acquireStarted.duration(
                        to: evalStarted
                    ).timeInterval
                    switch layerIndex {
                    case ..<10:
                        profile.record(\.moeEarlySeconds, seconds: total)
                    case ..<30:
                        profile.record(\.moeMiddleSeconds, seconds: total)
                    default:
                        profile.record(\.moeLateSeconds, seconds: total)
                    }
                    profile.record(\.moeInvocations, seconds: Double(groupCount))
                }
                let releaseStarted = ContinuousClock.now
                for lease in leases {
                    await pool.release(lease)
                }
                profile?.record(
                    \.moeReleaseSeconds,
                    seconds: releaseStarted.duration(to: .now).timeInterval
                )
                if profile != nil {
                    profile?.record(\.moeReleaseSamples, seconds: 1)
                }
                for offset in 0..<groupCount {
                    outputs.append(
                        groupOutput[0..., offset..<(offset + 1), 0...]
                    )
                }
            } catch {
                for lease in leases {
                    await pool.release(lease)
                }
                throw error
            }
            tokenIndex = end
        }
        return MLX.concatenated(outputs, axis: 1)
    }
}

// MARK: - Edge0_35BMoEError

enum Edge0_35BMoEError: Error, LocalizedError, Equatable {
    case insufficientPoolSlots(required: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientPoolSlots(let required, let available):
            return "The expert pool has \(available) slots but this token "
                + "requires \(required); refusing rather than waiting."
        }
    }
}

// MARK: - Edge0_35BDecoderLayer

struct Edge0_35BDecoderLayer: @unchecked Sendable {
    let weights: Edge0_35BLayerWeights
    let configuration: Edge0_35BModelConfiguration
    let expertLoader: Edge0_35BExpertLoader
    let pool: Edge0ExpertPool<Edge0_35BExpertWeights>

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0_35BLayerState,
        mode: Edge0ExecutionMode = .exact,
        profile: Edge0ComponentProfile? = nil,
        onRouter: ((Int, MLXArray) -> Void)? = nil,
        onSelectedExperts: ((Int, [Int]) -> Void)? = nil,
        prerouterTap: ((Int, MLXArray, [Int]) -> Void)? = nil
    ) async throws -> MLXArray {
        let eps = Float(configuration.rmsNormEps)
        let normalized = MLXFast.rmsNorm(
            x, weight: weights.inputNorm, eps: eps
        )
        let attentionOutput: MLXArray
        switch (weights.attention, state) {
        case (.linear(let linearWeights), .linear(var linearState)):
            let attentionStarted = ContinuousClock.now
            let attention = Edge0_35BLinearAttention(
                weights: linearWeights, configuration: configuration
            )
            attentionOutput = attention(normalized, state: &linearState)
            state = .linear(linearState)
            profile?.record(
                \.kdaSeconds,
                seconds: attentionStarted.duration(to: .now).timeInterval
            )
        case (.full(let fullWeights), .full(var fullState)):
            let attentionStarted = ContinuousClock.now
            let attention = Edge0_35BFullAttention(
                weights: fullWeights, configuration: configuration
            )
            attentionOutput = attention(normalized, state: &fullState)
            state = .full(fullState)
            profile?.record(
                \.mlaSeconds,
                seconds: attentionStarted.duration(to: .now).timeInterval
            )
        default:
            throw Edge0_35BWeightError.badGeometry(
                "layer \(weights.index) state/attention variant mismatch"
            )
        }
        let residual = x + attentionOutput
        let mlpInput = MLXFast.rmsNorm(
            residual, weight: weights.postAttentionNorm, eps: eps
        )
        var moe = Edge0_35BMoE(
            weights: weights,
            configuration: configuration,
            expertLoader: expertLoader,
            pool: pool
        )
        moe.executionMode = mode
        moe.routerReadbackMode = Edge0EnginePreferences.edge0_35BRouterReadbackMode
        moe.onSelectedExperts = onSelectedExperts
        moe.prerouterTap = prerouterTap
        let moeStarted = ContinuousClock.now
        let mlpOutput = try await moe(
            mlpInput, profile: profile, onRouter: onRouter
        )
        profile?.record(
            \.moeSeconds,
            seconds: moeStarted.duration(to: .now).timeInterval
        )
        return residual + mlpOutput
    }
}

// MARK: - Edge0_35BModel

final class Edge0_35BModel: @unchecked Sendable {
    let weights: Edge0_35BModelWeights
    let layers: [Edge0_35BDecoderLayer]
    private let stores: Edge0TensorStoreSet
    private let index: Edge0SafetensorsIndex

    private init(
        weights: Edge0_35BModelWeights,
        layers: [Edge0_35BDecoderLayer],
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet
    ) {
        self.weights = weights
        self.layers = layers
        self.index = index
        self.stores = stores
    }

    private static func configuration(
        from directory: URL
    ) throws -> Edge0_35BModelConfiguration {
        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: directory.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_35B()
        return configuration
    }

    /// Convenience load that owns its shard stores (tests, standalone tools).
    static func load(
        directory: URL,
        pool: Edge0ExpertPool<Edge0_35BExpertWeights>
    ) async throws -> Edge0_35BModel {
        let configuration = try Self.configuration(from: directory)
        let index = try Edge0SafetensorsIndex.openSharded(in: directory)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: index.shardNames
        )
        do {
            return try await load(
                directory: directory,
                configuration: configuration,
                index: index,
                stores: stores,
                pool: pool
            )
        } catch {
            await stores.closeAll()
            throw error
        }
    }

    /// Engine load: the caller owns the tensor stores (single descriptor set
    /// per model lifecycle) and the bounded expert pool.
    static func load(
        directory: URL,
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet,
        pool: Edge0ExpertPool<Edge0_35BExpertWeights>
    ) async throws -> Edge0_35BModel {
        let configuration = try Self.configuration(from: directory)
        return try await load(
            directory: directory,
            configuration: configuration,
            index: index,
            stores: stores,
            pool: pool
        )
    }

    private static func load(
        directory: URL,
        configuration: Edge0_35BModelConfiguration,
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet,
        pool: Edge0ExpertPool<Edge0_35BExpertWeights>
    ) async throws -> Edge0_35BModel {
        let loader = Edge0_35BWeightLoader(
            index: index, stores: stores, configuration: configuration
        )
        let loras = try await Edge0_35BWeightLoader.loadLoRAs(
            directory: directory, configuration: configuration
        )
        let weights = try await loader.loadModel(loras: loras)
        var layers: [Edge0_35BDecoderLayer] = []
        layers.reserveCapacity(weights.layers.count)
        for layerWeights in weights.layers {
            layers.append(Edge0_35BDecoderLayer(
                weights: layerWeights,
                configuration: configuration,
                expertLoader: try Edge0_35BExpertLoader(
                    index: index, stores: stores, layer: layerWeights.index
                ),
                pool: pool
            ))
        }
        return Edge0_35BModel(
            weights: weights, layers: layers, index: index, stores: stores
        )
    }

    /// Number of distinct modules carrying a Recover-LoRA adapter (310 in the
    /// pinned release). Header-only; no weights are read.
    static func loraApplicationCount(directory: URL) throws -> Int {
        try Edge0_35BModelArtifacts.validateLoRAFile(
            at: directory.appendingPathComponent(
                Edge0_35BModelArtifacts.loraFileName
            )
        ).moduleCount
    }

    func close() async {
        await stores.closeAll()
    }

    /// Cheap, eval-free generation-state summary for boundary checks:
    /// position, total full-attention KV tokens, and fixed linear state bytes.
    struct StateSummary: Sendable, Equatable {
        var position = 0
        var kvTokens = 0
        var linearStateBytes = 0
    }

    func stateSummary(_ state: Edge0_35BModelState) -> StateSummary {
        var summary = StateSummary()
        summary.position = state.position
        for layer in state.layers {
            switch layer {
            case .full(let full):
                summary.kvTokens += full.keys?.dim(2) ?? 0
            case .linear(let linear):
                summary.linearStateBytes += linear.conv?.nbytes ?? 0
                summary.linearStateBytes += linear.recurrent?.nbytes ?? 0
            }
        }
        return summary
    }

    func makeState() -> Edge0_35BModelState {
        Edge0_35BModelState(
            layers: weights.layers.map { layer in
                switch layer.attention {
                case .linear: return .linear(.empty)
                case .full: return .full(.empty)
                }
            },
            position: 0
        )
    }

    /// Prefill: returns the last position's logits `[vocab]`.
    func prefill(
        tokenIDs: [Int],
        state: inout Edge0_35BModelState,
        mode: Edge0ExecutionMode = .exact,
        profile: Edge0ComponentProfile? = nil,
        onLayer: ((Int, MLXArray) -> Void)? = nil,
        onRouter: ((Int, MLXArray) -> Void)? = nil,
        onSelectedExperts: ((Int, [Int]) -> Void)? = nil
    ) async throws -> MLXArray {
        profile?.begin(.prefill)
        let ids = MLXArray(
            tokenIDs.map { Int32($0) }, [1, tokenIDs.count]
        )
        let embedStarted = ContinuousClock.now
        var hidden = weights.embedTokens(ids)
        profile?.record(
            \.embeddingSeconds,
            seconds: embedStarted.duration(to: .now).timeInterval
        )
        for (index, layer) in layers.enumerated() {
            hidden = try await layer(
                hidden, state: &state.layers[index], mode: mode,
                profile: profile, onRouter: onRouter,
                onSelectedExperts: onSelectedExperts
            )
            onLayer?(index, hidden)
        }
        state.position += tokenIDs.count
        let headStarted = ContinuousClock.now
        let normed = MLXFast.rmsNorm(
            hidden, weight: weights.finalNorm,
            eps: Float(weights.configuration.rmsNormEps)
        )
        let logits = weights.lmHead.asLinear(
            normed[0..., (tokenIDs.count - 1)..<tokenIDs.count, 0...]
        )
        profile?.record(
            \.lmHeadSeconds,
            seconds: headStarted.duration(to: .now).timeInterval
        )
        return logits[0, -1]
    }

    /// One cached decode step: returns logits `[vocab]`.
    func decode(
        tokenID: Int,
        state: inout Edge0_35BModelState,
        mode: Edge0ExecutionMode = .exact,
        profile: Edge0ComponentProfile? = nil,
        prerouterTap: ((Int, MLXArray, [Int]) -> Void)? = nil
    ) async throws -> MLXArray {
        profile?.begin(.decode)
        let ids = MLXArray([Int32(tokenID)], [1, 1])
        let embedStarted = ContinuousClock.now
        var hidden = weights.embedTokens(ids)
        profile?.record(
            \.embeddingSeconds,
            seconds: embedStarted.duration(to: .now).timeInterval
        )
        for (index, layer) in layers.enumerated() {
            hidden = try await layer(
                hidden, state: &state.layers[index], mode: mode,
                profile: profile, prerouterTap: prerouterTap
            )
        }
        state.position += 1
        let headStarted = ContinuousClock.now
        let normed = MLXFast.rmsNorm(
            hidden, weight: weights.finalNorm,
            eps: Float(weights.configuration.rmsNormEps)
        )
        let logits = weights.lmHead.asLinear(normed)
        profile?.record(
            \.lmHeadSeconds,
            seconds: headStarted.duration(to: .now).timeInterval
        )
        return logits[0, -1]
    }
}


private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
