import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0FullModelParityTests
//
// Full 24-layer real-checkpoint assembly: prefill parity per layer, final
// norm, top-20 logits, prefill states, cached decode, 16-token greedy
// identity and a 32-step state/cache stress.

final class Edge0FullModelParityTests: XCTestCase {

    func testFullModelPrefillDecodeAndGreedyMatchUpstream() async throws {
        let context = try realContext()
        let config = context.configuration
        let model = try await Edge0Model.load(
            configuration: config,
            index: context.index,
            stores: context.stores
        )
        let budget = Edge0MemoryBudget.resolve(
            availableBytes: UInt64.max / 4,
            ceilingBytes: 6_200_000_000
        )
        let expertLoader = try Edge0ExpertLoader(
            index: context.index,
            stores: context.stores
        )
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(
                capacitySlots: 64,
                capacityBytes: max(budget.expertPoolBytes, 128 * 1_048_576)
            ),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )

        // MARK: Prefill

        let promptIDs = try await context.fixture.tensor("prompt_ids")
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        var layerOutputs: [Int: MLXArray] = [:]
        let prefill = try await model.prefill(
            tokenIDs: promptIDs,
            pool: pool,
            onLayer: { index, hidden in layerOutputs[index] = hidden }
        )
        XCTAssertEqual(prefill.state.position, promptIDs.count)

        let representative = [0, 1, 3, 7, 11, 15, 19, 23]
        for index in 0..<config.numHiddenLayers {
            let expected = try await context.fixture.tensor("layer_\(index)_out")
            let actual = try XCTUnwrap(layerOutputs[index])
            let metrics = compare(actual, expected)
            if representative.contains(index) {
                print("[Edge0 full] layer \(index) relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbs)")
            }
        }
        for index in representative {
            let metrics = compare(
                try XCTUnwrap(layerOutputs[index]),
                try await context.fixture.tensor("layer_\(index)_out")
            )
            XCTAssertLessThan(
                metrics.relativeL2, 2e-2,
                "layer \(index) output"
            )
        }

        // MARK: Final norm + logits

        let normMetrics = compare(
            prefill.normedHidden,
            try await context.fixture.tensor("final_norm")
        )
        let lastLogits = prefill.logits[0, -1].asType(.float32)
        let order = MLX.argPartition(-lastLogits, kth: 19)[..<20]
        let values = MLX.takeAlong(lastLogits, order, axis: -1)
        let argmax = MLX.argMax(lastLogits, axis: -1)
        let expectedIndices = try await context.fixture.tensor(
            "logits_top_indices"
        ).asType(.int32).asArray(Int32.self)
        let actualIndices = order.asType(.int32).asArray(Int32.self)
        let expectedValues = try await context.fixture.tensor("logits_top_values")
        let expectedArgmax = try await context.fixture.tensor("logits_argmax")
            .asType(.int32).asArray(Int32.self)[0]

        let valueMetrics = compare(values, expectedValues)
        print("[Edge0 full] final norm relL2=\(normMetrics.relativeL2) top20Values relL2=\(valueMetrics.relativeL2) maxAbs=\(valueMetrics.maxAbs)")
        XCTAssertEqual(actualIndices, expectedIndices, "top-20 IDs")
        XCTAssertEqual(argmax.asType(.int32).asArray(Int32.self)[0], expectedArgmax, "argmax")

        // MARK: Prefill state parity

        for index in [0, 1, 22] {
            guard case .kda(let state) = prefill.state.layers[index] else {
                return XCTFail("layer \(index) expected KDA")
            }
            let conv = compare(
                try XCTUnwrap(state.qConv),
                try await context.fixture.tensor("state_\(index)_conv")
            )
            let recurrent = compare(
                try XCTUnwrap(state.recurrent),
                try await context.fixture.tensor("state_\(index)_recurrent")
            )
            print("[Edge0 full] KDA state \(index) conv=\(conv.relativeL2) recurrent=\(recurrent.relativeL2)")
            // bf16 accumulation floor; identities are tested separately.
            XCTAssertLessThan(conv.relativeL2, 1e-5)
            XCTAssertLessThan(recurrent.relativeL2, 1e-5)
        }
        for index in [3, 11, 23] {
            guard case .mla(let state) = prefill.state.layers[index] else {
                return XCTFail("layer \(index) expected MLA")
            }
            let keys = compare(
                try XCTUnwrap(state.keys),
                try await context.fixture.tensor("state_\(index)_keys")
            )
            let values = compare(
                try XCTUnwrap(state.values),
                try await context.fixture.tensor("state_\(index)_values")
            )
            print("[Edge0 full] MLA state \(index) keys=\(keys.relativeL2) values=\(values.relativeL2)")
            // bf16 accumulation floor; identities are tested separately.
            XCTAssertLessThan(keys.relativeL2, 1e-5)
            XCTAssertLessThan(values.relativeL2, 1e-5)
        }

        // MARK: 16-token greedy generation

        let expectedGenerated = try await context.fixture.tensor("generated_ids")
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        var state = prefill.state
        var generated: [Int] = [Int(expectedArgmax)]
        var nextToken = Int(expectedArgmax)
        for _ in 0..<16 {
            let logits = try await model.decode(
                tokenID: nextToken,
                state: &state,
                pool: pool
            )
            let last = logits[0, -1].asType(.float32)
            nextToken = Int(MLX.argMax(last, axis: -1).asType(.int32)
                .asArray(Int32.self)[0])
            generated.append(nextToken)
        }
        print("[Edge0 full] Python IDs: \(expectedGenerated)")
        print("[Edge0 full] Swift  IDs: \(generated)")
        XCTAssertEqual(generated, expectedGenerated, "16-token greedy identity")
        XCTAssertEqual(state.position, promptIDs.count + 16)

        // MARK: 32-step state/cache stress

        var stressState = prefill.state
        var token = Int(expectedArgmax)
        for step in 0..<32 {
            let logits = try await model.decode(
                tokenID: token,
                state: &stressState,
                pool: pool
            )
            token = Int(MLX.argMax(logits[0, -1].asType(.float32), axis: -1)
                .asType(.int32).asArray(Int32.self)[0])
            let stats = await pool.statistics()
            XCTAssertLessThanOrEqual(
                stats.occupancySlots, stats.capacitySlots,
                "expert pool slots at step \(step)"
            )
            XCTAssertLessThanOrEqual(
                stats.occupancyBytes, stats.capacityBytes,
                "expert pool bytes at step \(step)"
            )
            XCTAssertEqual(stressState.position, promptIDs.count + step + 1)
        }
        for (index, layerState) in stressState.layers.enumerated() {
            switch layerState {
            case .kda(let kda):
                XCTAssertNotNil(kda.recurrent, "KDA \(index) state")
                let magnitude = MLX.sum(MLX.abs(try XCTUnwrap(kda.recurrent)))
                    .asType(.float32).asArray(Float.self)[0]
                XCTAssertTrue(magnitude.isFinite, "KDA \(index) finite")
            case .mla(let mla):
                XCTAssertEqual(mla.offset, promptIDs.count + 32)
                let magnitude = MLX.sum(MLX.abs(try XCTUnwrap(mla.keys)))
                    .asType(.float32).asArray(Float.self)[0]
                XCTAssertTrue(magnitude.isFinite, "MLA \(index) finite")
            }
        }
        let finalStats = await pool.statistics()
        print("[Edge0 full] stress stats occupancy=\(finalStats.occupancySlots)/\(finalStats.capacitySlots) bytes=\(finalStats.occupancyBytes) evictions=\(finalStats.evictions) hits=\(finalStats.hits) misses=\(finalStats.misses)")

        await context.stores.closeAll()
    }

    // MARK: - Context

    private struct Context {
        let configuration: Edge0ModelConfiguration
        let index: Edge0SafetensorsIndex
        let stores: Edge0TensorStoreSet
        let fixture: FixtureContext

        struct FixtureContext {
            let index: Edge0SafetensorsIndex
            let stores: Edge0TensorStoreSet

            func tensor(_ name: String) async throws -> MLXArray {
                let loader = Edge0ResidentTensorLoader(
                    index: index,
                    stores: stores
                )
                return try await loader.load(index.location(name))
            }
        }
    }

    private func realContext() throws -> Context {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let modelURL = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("model.safetensors")
        let configURL = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("config.json")
        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("real_layers.safetensors")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("real layers fixture not found at \(fixtureURL.path)")
        }

        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: configURL)
        )
        try configuration.validateEdge0_8B()
        let index = try Edge0SafetensorsIndex.openSingleFile(at: modelURL)
        let stores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: modelDirectory),
            shardNames: ["model.safetensors"]
        )
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["real_layers.safetensors"]
        )
        return Context(
            configuration: configuration,
            index: index,
            stores: stores,
            fixture: Context.FixtureContext(
                index: fixtureIndex,
                stores: fixtureStores
            )
        )
    }

    // MARK: - Metrics

    private struct Metrics {
        let relativeL2: Double
        let maxAbs: Double
    }

    private func compare(_ actual: MLXArray, _ expected: MLXArray) -> Metrics {
        let a = actual.asType(.float32).asArray(Float.self)
        let e = expected.asType(.float32).asArray(Float.self)
        precondition(a.count == e.count, "shape mismatch \(actual.shape) vs \(expected.shape)")
        var squaredDifference = 0.0
        var squaredReference = 0.0
        var maxAbs = 0.0
        for index in 0..<a.count {
            let difference = Double(a[index] - e[index])
            squaredDifference += difference * difference
            squaredReference += Double(e[index]) * Double(e[index])
            maxAbs = max(maxAbs, abs(difference))
        }
        return Metrics(
            relativeL2: (squaredDifference / max(squaredReference, 1e-12)).squareRoot(),
            maxAbs: maxAbs
        )
    }
}
