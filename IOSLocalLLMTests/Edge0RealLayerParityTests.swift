import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0RealLayerParityTests
//
// Real-checkpoint decoder block parity for layers 0 (dense KDA), 1 (KDA +
// streaming MoE) and 3 (MLA + streaming MoE), plus one cached decode step
// through layer 3. Requires EDGE0_8B_MODEL and the real_layers fixture.

final class Edge0RealLayerParityTests: XCTestCase {

    func testRealLayersMatchUpstream() async throws {
        let context = try realContext()
        let config = context.configuration
        let loader = context.weightLoader

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
                capacityBytes: max(budget.expertPoolBytes, 64 * 1_048_576)
            ),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )

        for layerIndex in [0, 1, 3] {
            let layerWeights = try await loader.layer(layerIndex)
            let block = Edge0DecoderLayer(
                weights: layerWeights,
                configuration: config,
                expertLayout: Edge0ExpertLayout(),
                expertIndex: context.index
            )
            let input = try await context.fixture.tensor(
                "layer_\(layerIndex)_block_input"
            ).asType(.bfloat16)
            var state = Edge0LayerState.fresh(for: layerWeights)
            let output = try await block(input, state: &state, pool: pool)

            let expectedOutput = try await context.fixture.tensor(
                "layer_\(layerIndex)_output"
            )
            let outputMetrics = compare(output, expectedOutput)

            print("[Edge0 real layer \(layerIndex)] block relL2=\(outputMetrics.relativeL2) maxAbs=\(outputMetrics.maxAbs)")

            // State parity.
            switch state {
            case .kda(let kdaState):
                let convMetrics = compare(
                    try XCTUnwrap(kdaState.qConv),
                    try await context.fixture.tensor(
                        "layer_\(layerIndex)_kda_conv_state"
                    )
                )
                let recurrentMetrics = compare(
                    try XCTUnwrap(kdaState.recurrent),
                    try await context.fixture.tensor(
                        "layer_\(layerIndex)_kda_recurrent"
                    )
                )
                print("[Edge0 real layer \(layerIndex)] KDA conv=\(convMetrics.relativeL2) recurrent=\(recurrentMetrics.relativeL2)")
                XCTAssertLessThan(convMetrics.relativeL2, 1e-3)
                XCTAssertLessThan(recurrentMetrics.relativeL2, 1e-2)
            case .mla(let mlaState):
                let keyMetrics = compare(
                    try XCTUnwrap(mlaState.keys),
                    try await context.fixture.tensor(
                        "layer_\(layerIndex)_keys"
                    )
                )
                let valueMetrics = compare(
                    try XCTUnwrap(mlaState.values),
                    try await context.fixture.tensor(
                        "layer_\(layerIndex)_values"
                    )
                )
                print("[Edge0 real layer \(layerIndex)] MLA keys=\(keyMetrics.relativeL2) values=\(valueMetrics.relativeL2)")
                XCTAssertLessThan(keyMetrics.relativeL2, 1e-2)
                XCTAssertLessThan(valueMetrics.relativeL2, 1e-2)
            }

            if layerIndex == 1 || layerIndex == 3 {
                let router = Edge0Router(configuration: config)
                let moeWeights = try await loader.layer(layerIndex)
                guard case .moe(let moe) = moeWeights.mlp else {
                    return XCTFail("expected MoE layer")
                }
                let mlpNorm = try await context.fixture.tensor(
                    "layer_\(layerIndex)_mlp_norm"
                ).asType(.bfloat16)
                let selection = router(
                    mlpNorm,
                    weight: moe.routerWeight,
                    expertBias: moe.expertBias
                )
                let actualIDs = selection.indices.asType(.int32).asArray(Int32.self)
                let expectedIDs = try await context.fixture.tensor(
                    "layer_\(layerIndex)_router_indices"
                ).asType(.int32).asArray(Int32.self)
                let mismatches = zip(actualIDs, expectedIDs)
                    .filter { $0 != $1 }.count
                let weightMetrics = compare(
                    selection.weights,
                    try await context.fixture.tensor(
                        "layer_\(layerIndex)_router_weights"
                    )
                )
                print("[Edge0 real layer \(layerIndex)] router mismatches=\(mismatches)/\(actualIDs.count) weights=\(weightMetrics.relativeL2)")
                XCTAssertEqual(mismatches, 0, "layer \(layerIndex) router expert identity")
            }
            XCTAssertLessThan(
                outputMetrics.relativeL2,
                2e-2,
                "layer \(layerIndex) block output"
            )
        }

        // Cached decode step through layer 3.
        let layerThree = try await loader.layer(3)
        let block = Edge0DecoderLayer(
            weights: layerThree,
            configuration: config,
            expertLayout: Edge0ExpertLayout(),
            expertIndex: context.index
        )
        var state = Edge0LayerState.fresh(for: layerThree)
        _ = try await block(
            try await context.fixture.tensor("layer_3_block_input")
                .asType(.bfloat16),
            state: &state,
            pool: pool
        )
        let decodeOutput = try await block(
            try await context.fixture.tensor("layer_3_decode_input")
                .asType(.bfloat16),
            state: &state,
            pool: pool
        )
        let decodeMetrics = compare(
            decodeOutput,
            try await context.fixture.tensor("layer_3_decode_output")
        )
        print("[Edge0 real layer 3 decode] relL2=\(decodeMetrics.relativeL2) maxAbs=\(decodeMetrics.maxAbs)")
        XCTAssertLessThan(decodeMetrics.relativeL2, 2e-2)

        await context.stores.closeAll()
    }

    // MARK: - Context

    private struct Context {
        let configuration: Edge0ModelConfiguration
        let index: Edge0SafetensorsIndex
        let stores: Edge0TensorStoreSet
        let weightLoader: Edge0RealWeightLoader
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
            weightLoader: Edge0RealWeightLoader(
                configuration: configuration,
                index: index,
                stores: stores
            ),
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
