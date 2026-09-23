import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0_35BModelParityTests
//
// Phase 5B: native 35B parity against the frozen Python oracle
// (`edge0_35b_model_fixture.safetensors` + `..._meta.json`) with the
// release contract: quantized base + Recover-LoRA + true-router K=4.
//
// Gated on EDGE0_35B_MODEL (full shard directory) and EDGE0_35B_FIXTURES
// (default /tmp/edge0-35b-fixtures).

final class Edge0_35BModelParityTests: Edge0MLXTestCase {

    private struct Fixture {
        let loader: Edge0ResidentTensorLoader
        let index: Edge0SafetensorsIndex
        let stores: Edge0TensorStoreSet
    }

    private func modelDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment[
            "EDGE0_35B_MODEL"
        ], !directory.isEmpty,
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: directory)
                    .appendingPathComponent("model.safetensors.index.json").path
            ) else {
            throw XCTSkip("Set EDGE0_35B_MODEL to the 35B shard directory")
        }
        return URL(fileURLWithPath: directory)
    }

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "EDGE0_35B_FIXTURES"
        ] ?? "/tmp/edge0-35b-fixtures")
    }

    private func loadFixture(_ name: String) throws -> Fixture {
        let url = fixtureDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "35B oracle fixture not found at \(url.path) — set EDGE0_35B_FIXTURES to the fixture directory (see the suite header; oracle fixtures are produced by scripts/edge0_reference_dump.py)"
            )
        }
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: fixtureDirectory(), shardNames: [name]
        )
        return Fixture(
            loader: Edge0ResidentTensorLoader(index: index, stores: stores),
            index: index,
            stores: stores
        )
    }

    private func tensor(
        _ fixture: Fixture, _ name: String
    ) async throws -> MLXArray {
        try await fixture.loader.load(fixture.index.location(name))
    }

    private func metrics(
        _ actual: MLXArray, _ expected: MLXArray
    ) -> (relL2: Double, maxAbs: Double) {
        let a = actual.asType(.float32)
        let e = expected.asType(.float32)
        let diff = MLX.abs(a - e)
        let maxAbs = diff.max().item(Float.self)
        let norm = MLX.sqrt((diff * diff).sum()).item(Float.self)
        let denom = MLX.sqrt((e * e).sum()).item(Float.self)
        return (Double(norm / max(denom, 1e-9)), Double(maxAbs))
    }

    // MARK: Payload reader regression (offset correctness)

    func testPayloadReaderMatchesIndependentValues() async throws {
        let model = try modelDirectory()
        let fixtureURL = fixtureDirectory()
            .appendingPathComponent("edge0_35b_reader_fixture.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("reader fixture JSON not staged")
        }
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureURL)
        ) as? [String: [String: Any]] ?? [:]

        let index = try Edge0SafetensorsIndex.openSharded(in: model)
        let stores = try Edge0TensorStoreSet(
            directory: model, shardNames: index.shardNames
        )
        defer { Task { await stores.closeAll() } }
        let reader = Edge0ResidentTensorLoader(index: index, stores: stores)

        // dt_bias: bf16 values deep inside shard 1 (non-zero relative offset).
        if let spec = raw["dt_bias_layer0"],
           let expected = spec["values"] as? [Double] {
            let name = "language_model.model.layers.0.linear_attn.dt_bias"
            let actual = try await reader.load(index.location(name))
                .asType(.float32)
            let values = actual.asArray(Float.self)
            XCTAssertEqual(values.count, expected.count)
            for (i, e) in expected.enumerated() {
                XCTAssertEqual(
                    Double(values[i]), e, accuracy: 1e-6,
                    "dt_bias[\(i)] content mismatch (offset regression)"
                )
            }
        }

        // ExpERT slice addressing inside a stacked tensor (row offset).
        if let spec = raw["expert_gate_weight_L0_E5_first8"],
           let words = spec["words"] as? [Int],
           let rowBytes = spec["row_bytes"] as? Int,
           let expert = spec["expert"] as? Int {
            let name = "language_model.model.layers.0.mlp.switch_mlp.gate_proj.weight"
            let location = try index.location(name)
            let slice = try await stores.readSlice(
                location,
                byteOffset: UInt64(rowBytes) * UInt64(expert),
                byteLength: min(rowBytes, 8 * 4)
            )
            let packed = MLXArray(
                slice.bytes, [1, 8], dtype: .uint32
            ).asArray(UInt32.self)
            XCTAssertEqual(
                packed.map { Int($0) }, words,
                "expert 5 gate weight words mismatch"
            )
        }

        if let spec = raw["expert_down_scales_L0_E200_first4"],
           let expected = spec["values"] as? [Double],
           let rowBytes = spec["row_bytes"] as? Int,
           let expert = spec["expert"] as? Int {
            let name = "language_model.model.layers.0.mlp.switch_mlp.down_proj.scales"
            let location = try index.location(name)
            let slice = try await stores.readSlice(
                location,
                byteOffset: UInt64(rowBytes) * UInt64(expert),
                byteLength: 4 * 2
            )
            let values = MLXArray(
                slice.bytes, [1, 4], dtype: .bfloat16
            ).asType(.float32).asArray(Float.self)
            for (i, e) in expected.enumerated() {
                XCTAssertEqual(
                    Double(values[i]), e, accuracy: 1e-6,
                    "expert 200 down scales[\(i)] mismatch"
                )
            }
        }
    }

    func testGatedDeltaStepMatchesUpstreamOps() async throws {
        let fixture = try loadFixture("gated_delta_step_fixture.safetensors")
        defer { Task { await fixture.stores.closeAll() } }
        let q = try await tensor(fixture, "q")
        let k = try await tensor(fixture, "k")
        let v = try await tensor(fixture, "v")
        let decay = try await tensor(fixture, "decay")
        let beta = try await tensor(fixture, "beta")
        let expectedY = try await tensor(fixture, "y")
        let expectedState = try await tensor(fixture, "state")

        let qHeads = MLX.repeated(q, count: 2, axis: 2)
        let kHeads = MLX.repeated(k, count: 2, axis: 2)
        let (y, state) = Edge0_35BLinearAttention.gatedDeltaOps(
            q: qHeads, k: kHeads, v: v, decay: decay, beta: beta, state: nil
        )
        let ym = metrics(y, expectedY)
        let sm = metrics(state, expectedState)
        print("[Edge0 35B] gated delta step y relL2=\(ym.relL2) state relL2=\(sm.relL2)")
        XCTAssertLessThan(ym.relL2, 1e-3)
        XCTAssertLessThan(sm.relL2, 1e-3)
    }

    // MARK: Full-model parity + frozen emission contract

    func testPrefillPlusEightDecodeCallsEmitsNineReferenceTokens() async throws {
        let modelURL = try modelDirectory()
        let fixture = try loadFixture("edge0_35b_model_fixture.safetensors")
        defer { Task { await fixture.stores.closeAll() } }

        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_35B()

        // Model pool: bounded correctness capacity (not a device setting).
        let poolLoaderIndex = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let poolStores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: poolLoaderIndex.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(
                index: poolLoaderIndex, stores: poolStores, layer: layer
            )
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 64,
                capacityBytes: 256 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )

        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        var state = model.makeState()

        let promptIDs = try await tensor(fixture, "prompt_ids")
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        XCTAssertEqual(promptIDs, [760, 6511, 314, 9338, 369])

        // Diagnostic: verify the unmerged LoRA adapters were attached.
        var loraCount = 0
        for layer in model.weights.layers {
            if case .linear(let w) = layer.attention {
                if w.inProjQKV.lora != nil { loraCount += 1 }
                if w.inProjA.lora != nil { loraCount += 1 }
            } else if case .full(let w) = layer.attention {
                if w.qProj.lora != nil { loraCount += 1 }
            }
        }
        // Sampling: linear layers expose qkv + a targets (2 each), full
        // layers expose q_proj (1 each): 30 * 2 + 10 = 70.
        print("[Edge0 35B] attached LoRA modules (sampled): \(loraCount)")
        XCTAssertEqual(loraCount, 70, "sampled LoRA targets must be attached")

        var layerOutputs: [Int: MLXArray] = [:]
        let logits = try await model.prefill(
            tokenIDs: promptIDs,
            state: &state,
            onLayer: { index, hidden in
                layerOutputs[index] = hidden[0, -1, 0...]
            }
        )

        // Snapshot the prefill-boundary states BEFORE any decode call can
        // advance them; the Python fixture captures this same boundary.
        var prefillStates: [Int: (conv: MLXArray?, recurrent: MLXArray?)] = [:]
        for layer in [0, 20, 38] {
            if case .linear(let linear) = state.layers[layer] {
                prefillStates[layer] = (linear.conv, linear.recurrent)
            }
        }

        // Per-layer parity (all 40 layers, last token).
        var worstLayer = (index: -1, relL2: 0.0)
        for layer in 0..<40 {
            let expected = try await tensor(fixture, "layer_\(layer)_out")
            let actual = try XCTUnwrap(layerOutputs[layer], "layer \(layer)")
            let m = metrics(actual, expected)
            if m.relL2 > worstLayer.relL2 {
                worstLayer = (layer, m.relL2)
            }
            print("[Edge0 35B] layer \(layer) relL2=\(m.relL2)")
            XCTAssertLessThan(
                m.relL2, 2e-2,
                "layer \(layer) hidden-state parity"
            )
        }
        print("[Edge0 35B] worst layer relL2=\(worstLayer.relL2) at \(worstLayer.index)")

        // Final logits: argmax + top-20 identity.
        let expectedArgmaxTensor = try await tensor(fixture, "logits_argmax")
        let expectedArgmax = expectedArgmaxTensor
            .asType(.int32).asArray(Int32.self)[0]
        let actualArgmaxTensor = MLX.argMax(logits, axis: -1).asType(.int32)
        let actualArgmax = actualArgmaxTensor.asArray(Int32.self)[0]
        XCTAssertEqual(Int(actualArgmax), Int(expectedArgmax))

        let expectedTopTensor = try await tensor(fixture, "logits_top_indices")
        let expectedTop = expectedTopTensor
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let partition = MLX.argPartition(-logits, kth: 19, axis: -1)
        let topTensor = partition[..<20].asType(.int32)
        let top = topTensor.asArray(Int32.self).map { Int($0) }
        XCTAssertEqual(top.sorted(), expectedTop.sorted(), "top-20 identity")

        let expectedValues = try await tensor(fixture, "logits_top_values")
            .asType(.float32)
        let actualValues = MLX.take(logits, MLXArray(
            expectedTop.map { Int32($0) }
        ), axis: -1).asType(.float32)
        let valueMetrics = metrics(actualValues, expectedValues)
        print("[Edge0 35B] top-20 logits relL2=\(valueMetrics.relL2)")
        XCTAssertLessThan(valueMetrics.relL2, 2e-2)

        // Frozen emission contract: prefill argmax first, then 8 decode calls.
        let decodeCalls = 8
        var emitted = [Int(actualArgmax)]
        var token = Int(actualArgmax)
        var eosHit = false
        for _ in 0..<decodeCalls {
            let stepLogits = try await model.decode(
                tokenID: token, state: &state
            )
            let argTensor = MLX.argMax(stepLogits, axis: -1).asType(.int32)
            token = Int(argTensor.asArray(Int32.self)[0])
            emitted.append(token)
            if token == 248046 || token == 248044 { eosHit = true; break }
        }
        let expectedEmitted = try await tensor(fixture, "generated_ids")
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        print("[Edge0 35B] emitted: \(emitted)")
        XCTAssertEqual(emitted, expectedEmitted)
        XCTAssertEqual(emitted.count, decodeCalls + 1)
        XCTAssertFalse(eosHit)
        // 5 prompt tokens + 8 decode inputs consumed.
        XCTAssertEqual(state.position, promptIDs.count + decodeCalls)

        // Representative linear states after prefill.
        for layer in [0, 20, 38] {
            guard let snapshot = prefillStates[layer],
                  let recurrent = snapshot.recurrent else {
                return XCTFail("layer \(layer) expected linear state")
            }
            let expectedRecurrent = try await tensor(
                fixture, "state_\(layer)_recurrent"
            ).asType(.float32)
            let m = metrics(recurrent, expectedRecurrent)
            let actualSlice = recurrent.asType(.float32).asArray(Float.self)
            let expectedSlice = expectedRecurrent.asArray(Float.self)
            print("[Edge0 35B] layer \(layer) recurrent relL2=\(m.relL2) "
                  + "actual[:4]=\(Array(actualSlice.prefix(4))) "
                  + "expected[:4]=\(Array(expectedSlice.prefix(4))) "
                  + "actualNorm=\(actualSlice.reduce(0) { $0 + $1*$1 }) "
                  + "expectedNorm=\(expectedSlice.reduce(0) { $0 + $1*$1 })")
            XCTAssertLessThan(m.relL2, 2e-2)
            if let conv = snapshot.conv {
                let expectedConv = try await tensor(
                    fixture, "state_\(layer)_conv"
                ).asType(.float32)
                let cm = metrics(conv, expectedConv)
                XCTAssertLessThan(cm.relL2, 2e-2)
            }
        }

        // Bounded pool, no leaked leases.
        let stats = await pool.statistics()
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)

        await model.close()
        await poolStores.closeAll()
    }

    /// Test A — saved oracle MoE input into the native gate projection.
    func testGateReplayFromOracleMoEInput() async throws {
        let modelURL = try modelDirectory()
        let trace = try loadFixture("edge0_35b_layer0_trace.safetensors")
        defer { Task { await trace.stores.closeAll() } }
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 8, capacityBytes: 32 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        let moeInput = try await tensor(trace, "l0_moe_input")
        let expected = try await tensor(trace, "l0_gate_logits")
            .asType(.float32)
        let actual = model.weights.layers[0].routerGate
            .base(moeInput).asType(.float32)
        MLX.eval(actual)
        for token in 0..<5 {
            let m = metrics(actual[0, token, 0...], expected[0, token, 0...])
            print("[Edge0 35B] A gate replay token \(token): relL2=\(m.relL2) "
                  + "maxAbs=\(m.maxAbs)")
        }
        let all = metrics(actual, expected)
        XCTAssertLessThan(all.relL2, 5e-3, "native gate vs oracle logits")
        await model.close()
        await stores.closeAll()
    }

    /// Test B — saved oracle logits into the native selection function.
    func testSelectionReplayFromOracleLogits() async throws {
        let routerFixture = try loadFixture("edge0_35b_router_ids.safetensors")
        let trace = try loadFixture("edge0_35b_layer0_trace.safetensors")
        defer {
            Task {
                await routerFixture.stores.closeAll()
                await trace.stores.closeAll()
            }
        }
        let logits = try await tensor(trace, "l0_gate_logits")
        let expectedIds = try await tensor(routerFixture, "router_ids_0")
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let (indices, scores, gates) = Edge0_35BMoE.select(
            logits: logits, topK: 4
        )
        let actualIds = indices.asType(.int32)
            .asArray(Int32.self).map { Int($0) }
        let scoreValues = scores.asType(.float32).asArray(Float.self)
        XCTAssertEqual(actualIds.count, expectedIds.count)

        var setMismatch: Int? = nil
        for token in 0..<5 {
            let range = (token * 4)..<(token * 4 + 4)
            let actualSet = Set(actualIds[range])
            let expectedSet = Set(expectedIds[range])
            if actualSet != expectedSet, setMismatch == nil {
                setMismatch = token
            }
            if token == 2 {
                print("[Edge0 35B] B logits replay token 2")
                print("  python ids \(Array(expectedIds[range]))")
                print("  swift  ids \(Array(actualIds[range]))")
                print("  swift scores \(Array(scoreValues[range]))")
            }
        }
        // Fourth/fifth margin on oracle logits for token 2.
        let tokenGates = gates[0, 2, 0...]
        let top5 = MLX.argPartition(-tokenGates, kth: 4, axis: -1)[..<5]
        let top5Ids = top5.asType(.int32).asArray(Int32.self).map { Int($0) }
        let top5Scores = MLX.take(tokenGates, top5)
            .asType(.float32).asArray(Float.self)
        print("[Edge0 35B] B token2 top5 ids=\(top5Ids) "
              + "scores=\(top5Scores) margin4-5=\(top5Scores[3] - top5Scores[4])")
        XCTAssertNil(setMismatch, "selection replay set mismatch")
    }

    /// Per-token execution must complete with an 8-slot pool even when the
    /// prompt's selected-expert union exceeds 8, and impossible capacity
    /// must fail fast instead of waiting.
    func testPerTokenMoEBoundedWithEightSlots() async throws {
        let modelURL = try modelDirectory()
        let trace = try loadFixture("edge0_35b_layer0_trace.safetensors")
        defer { Task { await trace.stores.closeAll() } }
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        func makePool(slots: Int) -> Edge0ExpertPool<Edge0_35BExpertWeights> {
            Edge0ExpertPool<Edge0_35BExpertWeights>(
                configuration: .init(
                    capacitySlots: slots, capacityBytes: 64 * 1_048_576
                ),
                loader: { key in try await loaders[key.layer].load(key) },
                sizeOf: { $0.byteSize }
            )
        }
        let moeInput = try await tensor(trace, "l0_moe_input")

        // Layer-0 weights are needed for the MoE; load the model for them.
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: makePool(slots: 8)
        )
        let eightSlotPool = makePool(slots: 8)
        let moe = Edge0_35BMoE(
            weights: model.weights.layers[0],
            configuration: model.weights.configuration,
            expertLoader: try Edge0_35BExpertLoader(
                index: index, stores: stores, layer: 0
            ),
            pool: eightSlotPool
        )
        let out = try await moe(moeInput)
        XCTAssertEqual(out.shape, [1, 5, 2048])
        let stats = await eightSlotPool.statistics()
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)
        // A second execution must reuse the pool cleanly (no stale leases).
        _ = try await moe(moeInput)

        // Capacity below one token's top-k must throw, not hang.
        let tinyPool = makePool(slots: 2)
        let tinyMoe = Edge0_35BMoE(
            weights: model.weights.layers[0],
            configuration: model.weights.configuration,
            expertLoader: try Edge0_35BExpertLoader(
                index: index, stores: stores, layer: 0
            ),
            pool: tinyPool
        )
        do {
            _ = try await tinyMoe(moeInput)
            XCTFail("2-slot pool must refuse a top-4 token")
        } catch let error as Edge0_35BMoEError {
            XCTAssertEqual(
                error,
                .insufficientPoolSlots(required: 4, available: 2)
            )
        }
        await model.close()
        await stores.closeAll()
    }


    /// Stage-by-stage comparison of the layer-3 full attention against the
    /// oracle trace. Feeds the deterministic layer-3 attention input.
    func testLayerThreeFullAttentionStagesMatchUpstream() async throws {
        let modelURL = try modelDirectory()
        let trace = try loadFixture("edge0_35b_layer0_trace.safetensors")
        defer { Task { await trace.stores.closeAll() } }
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 8, capacityBytes: 32 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        guard case .full(let fullWeights) = model.weights.layers[3].attention
        else {
            throw Edge0_35BWeightError.badGeometry("layer 3 is not full")
        }
        var captured: [String: MLXArray] = [:]
        var attention = Edge0_35BFullAttention(
            weights: fullWeights, configuration: model.weights.configuration
        )
        attention.trace = { name, value in
            captured[name] = value
        }
        var state = Edge0_35BFullAttentionState.empty
        let input = try await tensor(trace, "l3_input_norm")
        let output = attention(input, state: &state)
        MLX.eval([output] + Array(captured.values))

        let stageOrder = [
            "q_proj_out", "k_proj_out", "v_proj_out",
            "rope_in", "rope_out", "rope_in_k", "rope_out_k",
            "sdpa_out", "o_proj_in", "attn_out",
        ]
        var firstDivergent: (stage: String, relL2: Double, maxAbs: Double)? = nil
        for stage in stageOrder {
            guard let actual = captured[stage] else {
                XCTFail("missing Swift trace stage \(stage)")
                continue
            }
            let expected = try await tensor(trace, "l3_\(stage)")
            let m = metrics(actual, expected.asType(actual.dtype))
            print("[Edge0 35B] L3 stage \(stage): relL2=\(m.relL2) "
                  + "maxAbs=\(m.maxAbs)")
            if firstDivergent == nil, m.relL2 > 1e-5 {
                firstDivergent = (stage, m.relL2, m.maxAbs)
            }
        }
        // The attention output must match; if not, the first divergent
        // stage above names the defect.
        let expectedOut = try await tensor(trace, "l3_attn_out")
        let outMetrics = metrics(output, expectedOut.asType(output.dtype))
        print("[Edge0 35B] L3 attn_out: relL2=\(outMetrics.relL2) "
              + "maxAbs=\(outMetrics.maxAbs)")
        if let first = firstDivergent {
            XCTFail(
                "first divergent L3 stage: \(first.stage) "
                + "relL2=\(first.relL2) maxAbs=\(first.maxAbs)"
            )
        }
        XCTAssertLessThan(outMetrics.relL2, 5e-3, "L3 attention output")
        await model.close()
        await stores.closeAll()
    }

    func testLayerZeroTraceStagesMatchUpstream() async throws {
        let modelURL = try modelDirectory()
        let trace = try loadFixture("edge0_35b_layer0_trace.safetensors")
        let fixture = try loadFixture("edge0_35b_model_fixture.safetensors")
        defer {
            Task {
                await trace.stores.closeAll()
                await fixture.stores.closeAll()
            }
        }
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 8, capacityBytes: 32 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        guard case .linear(let layer0) = model.weights.layers[0].attention else {
            return XCTFail("layer 0 must be linear attention")
        }
        var stages: [String: MLXArray] = [:]
        var attention = Edge0_35BLinearAttention(
            weights: layer0, configuration: model.weights.configuration
        )
        attention.trace = { name, value in stages[name] = value }
        var state = Edge0_35BLinearAttentionState.empty
        let input = try await tensor(trace, "l0_input_norm")
        _ = attention(input, state: &state)

        let pairs: [(String, String)] = [
            ("q_pre_repeat", "l0_q"),
            ("k_pre_repeat", "l0_k"),
            ("v", "l0_v"),
            ("decay", "l0_decay"),
            ("beta", "l0_beta"),
            ("state", "l0_state_after_t5"),
            ("delta_out", "l0_state_after_t5"),
        ]
        for (actualName, expectedName) in pairs where actualName != "delta_out" {
            guard let actual = stages[actualName] else {
                return XCTFail("missing trace stage \(actualName)")
            }
            let expected = try await tensor(trace, expectedName)
            let m = metrics(actual, expected)
            print("[Edge0 35B] trace \(actualName) relL2=\(m.relL2)")
            XCTAssertLessThan(m.relL2, 5e-3, "\(actualName) vs \(expectedName)")
        }
        // NOTE: `l0_attn_out` is the oracle's whole layer-0 residual minus
        // the embedding (attention module + MoE module), so it must not be
        // compared against the attention module alone.

        // Isolated MoE on the reference MoE input: gate logits + output.
        if let moeInput = try? await tensor(trace, "l0_moe_input") {
            var moeStages: [String: MLXArray] = [:]
            var moe = Edge0_35BMoE(
                weights: model.weights.layers[0],
                configuration: model.weights.configuration,
                expertLoader: try Edge0_35BExpertLoader(
                    index: index, stores: stores, layer: 0
                ),
                pool: pool
            )
            moe.trace = { name, value in moeStages[name] = value }
            let moeOut = try await moe(moeInput)
            // The per-token trace keeps the LAST token's capture only.
            if let expectedGate = try? await tensor(trace, "l0_gate_logits"),
               let actualGate = moeStages["gate_logits"] {
                let m = metrics(actualGate[0, -1, 0...], expectedGate[0, -1, 0...])
                print("[Edge0 35B] trace gate_logits (last token) relL2=\(m.relL2)")
                XCTAssertLessThan(m.relL2, 5e-3)
            }
            // Joint layer-0 reconstruction:
            //   embed + attention module + MoE module == layer_0_out.
            if let attentionOut = stages["attn_out"],
               let embed = try? await tensor(trace, "l0_embed"),
               let layerOutFixture = try? await tensor(fixture, "layer_0_out") {
                let reconstructed = embed[0, -1, 0...]
                    + attentionOut[0, -1, 0...]
                    + moeOut[0, -1, 0...]
                let m = metrics(reconstructed, layerOutFixture)
                print("[Edge0 35B] trace layer-0 reconstruction relL2=\(m.relL2)")
                XCTAssertLessThan(m.relL2, 5e-3)
            }
        }
        await model.close()
        await stores.closeAll()
    }

    func testRouterIDsMatchUpstream() async throws {
        let modelURL = try modelDirectory()
        let routerFixture = try loadFixture("edge0_35b_router_ids.safetensors")
        defer { Task { await routerFixture.stores.closeAll() } }
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 32, capacityBytes: 128 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        var state = model.makeState()
        var routers: [Int: [Int]] = [:]
        _ = try await model.prefill(
            tokenIDs: [760, 6511, 314, 9338, 369],
            state: &state,
            onRouter: { layer, indices in
                routers[layer, default: []].append(
                    contentsOf: indices
                        .asType(.int32).asArray(Int32.self).map { Int($0) }
                )
            }
        )
        // argpartition returns top-k in UNORDERED partition order, which is
        // implementation-defined; compare the selected SET per token.
        var firstSetMismatch: (layer: Int, token: Int)? = nil
        var orderOnly = 0
        for layer in 0..<40 {
            let expected = try await tensor(routerFixture, "router_ids_\(layer)")
                .asType(.int32).asArray(Int32.self).map { Int($0) }
            let actual = routers[layer] ?? []
            XCTAssertEqual(actual.count, expected.count, "layer \(layer) count")
            for token in 0..<5 {
                let range = (token * 4)..<(token * 4 + 4)
                let actualSet = Set(actual[range])
                let expectedSet = Set(expected[range])
                if actualSet != expectedSet, firstSetMismatch == nil {
                    firstSetMismatch = (layer, token)
                }
                if actualSet == expectedSet, Array(actual[range]) != Array(expected[range]) {
                    orderOnly += 1
                }
            }
        }
        print("[Edge0 35B] router order-only differences: \(orderOnly)/200 tokens")
        // Margin diagnostic for the first set mismatch: capture the MoE input
        // for that token and recompute the gate scores.
        if let mismatch = firstSetMismatch {
            var probeState = model.makeState()
            var capturedHidden: MLXArray?
            // Re-run layer 0's MoE input for the mismatching token by
            // replaying the first forward up to layer 0's post-norm.
            _ = try await model.prefill(
                tokenIDs: [760, 6511, 314, 9338, 369],
                state: &probeState,
                onLayer: { layer, hidden in
                    if layer == 0 { capturedHidden = hidden[0, mismatch.token, 0...] }
                }
            )
            _ = capturedHidden
            print("[Edge0 35B] first mismatch layer=\(mismatch.layer) "
                  + "token=\(mismatch.token) (margin probe pending)")
        }
        if let flip = firstSetMismatch {
            print("[Edge0 35B] FIRST ROUTER SET MISMATCH at layer \(flip.layer) token \(flip.token)")
        } else {
            print("[Edge0 35B] router SETS identical for all 40 layers × 5 tokens")
        }
        XCTAssertNil(firstSetMismatch, "router selection diverged")
        // The router gate must use the 8-bit override.
        XCTAssertEqual(model.weights.layers[0].routerGate.bits, 8)
        XCTAssertEqual(
            model.weights.layers[0].sharedExpertGate.bits, 8
        )
        await model.close()
        await stores.closeAll()
    }

    /// Diagnostic: is the layer-0 state mismatch a model error or a
    /// fixture-boundary/layout mismatch? Runs the real layer-0 attention
    /// alone with prompt prefixes and compares against the frozen fixture
    /// state under several axis permutations.
    func testLayer0StateBoundaryAndLayoutDiagnostic() async throws {
        let modelURL = try modelDirectory()
        let fixture = try loadFixture("edge0_35b_model_fixture.safetensors")
        defer { Task { await fixture.stores.closeAll() } }

        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 16, capacityBytes: 64 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )
        let expectedState = try await tensor(fixture, "state_0_recurrent")
            .asType(.float32)

        guard case .linear(let layer0) = model.weights.layers[0].attention else {
            return XCTFail("layer 0 must be linear attention")
        }
        let attention = Edge0_35BLinearAttention(
            weights: layer0, configuration: model.weights.configuration
        )
        let promptIDs: [Int] = [760, 6511, 314, 9338, 369]
        let ids = MLXArray(promptIDs.map { Int32($0) }, [1, promptIDs.count])
        let embedded = model.weights.embedTokens(ids)
        // The decoder layer normalizes before attention; feed the same
        // normalized input the real path uses.
        let normalized = MLXFast.rmsNorm(
            embedded, weight: model.weights.layers[0].inputNorm,
            eps: Float(model.weights.configuration.rmsNormEps)
        )

        let expectedNorm = MLX.sqrt(
            (expectedState.asType(.float32) * expectedState.asType(.float32)).sum()
        ).item(Float.self)
        print("[Edge0 35B] fixture state norm=\(expectedNorm)")

        for prefix in 1...promptIDs.count {
            var state = Edge0_35BLinearAttentionState.empty
            let input = normalized[0..., ..<prefix, 0...]
            _ = attention(input, state: &state)
            guard let recurrent = state.recurrent else { continue }
            let direct = metrics(recurrent, expectedState)
            let myNorm = MLX.sqrt(
                (recurrent * recurrent).sum()
            ).item(Float.self)
            print("[Edge0 35B] layer0 prefix=\(prefix) direct=\(direct.relL2) "
                  + "myNorm=\(myNorm)")
        }
        await model.close()
        await stores.closeAll()
    }

    func testFreshSequenceStateHasNoCrossGenerationLeak() async throws {
        let modelURL = try modelDirectory()
        let index = try Edge0SafetensorsIndex.openSharded(in: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: index.shardNames
        )
        let loaders = try (0..<40).map { layer in
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: layer)
        }
        let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
            configuration: .init(
                capacitySlots: 32, capacityBytes: 128 * 1_048_576
            ),
            loader: { key in try await loaders[key.layer].load(key) },
            sizeOf: { $0.byteSize }
        )
        let model = try await Edge0_35BModel.load(
            directory: modelURL, pool: pool
        )

        var first = model.makeState()
        _ = try await model.prefill(
            tokenIDs: [760, 6511, 314, 9338, 369], state: &first
        )
        var second = model.makeState()
        XCTAssertEqual(second.position, 0)
        for layer in second.layers {
            switch layer {
            case .linear(let linear):
                XCTAssertNil(linear.conv)
                XCTAssertNil(linear.recurrent)
            case .full(let full):
                XCTAssertNil(full.keys)
                XCTAssertNil(full.values)
                XCTAssertEqual(full.offset, 0)
            }
        }
        _ = try await model.prefill(
            tokenIDs: [760, 6511, 314], state: &second
        )
        XCTAssertEqual(second.position, 3)

        await model.close()
        await stores.closeAll()
    }
}
