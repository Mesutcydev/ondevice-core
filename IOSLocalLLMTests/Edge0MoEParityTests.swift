import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0MoEParityTests
//
// End-to-end MoE parity for the tiny oracle fixture: router selection,
// gathered quantized up/gate/down through the Phase 2 math, router-weighted
// aggregation, and the resident shared expert.

final class Edge0MoEParityTests: XCTestCase {

    private struct Tiny {
        static let hiddenSize = 64
        static let numExperts = 8
        static let topK = 2
        static let nGroup = 4
        static let topkGroup = 2
        static let intermediate = 64
        static let routedScaling: Float = 2.5
    }

    func testStreamingMoEMatchesUpstream() async throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("moe_tiny.safetensors")
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["moe_tiny.safetensors"]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)

        func tensor(_ name: String) async throws -> MLXArray {
            try await loader.load(index.location(name))
        }

        let hidden = try await tensor("input")
        let gateWeight = try await tensor("gate.weight")
        let expertBias = try await tensor("expert_bias")

        let router = Edge0Router(
            numExperts: Tiny.numExperts,
            numExpertsPerTok: Tiny.topK,
            nGroup: Tiny.nGroup,
            topkGroup: Tiny.topkGroup,
            routedScalingFactor: Tiny.routedScaling,
            normTopkProb: true,
            expertBiasEnabled: true
        )
        let selection = router(hidden, weight: gateWeight, expertBias: expertBias)

        // Router parity: selected IDs must match exactly.
        let expectedIndices = try await tensor("expected_indices")
            .asType(.int32)
            .asArray(Int32.self)
        let actualIndices = selection.indices.asType(.int32).asArray(Int32.self)
        XCTAssertEqual(actualIndices, expectedIndices)

        let expectedWeights = try await tensor("expected_router_weights")
        let weightMetrics = compare(selection.weights, expectedWeights)
        print("[Edge0 MoE] router weights relL2=\(weightMetrics.relativeL2) maxAbs=\(weightMetrics.maxAbs)")

        // Gathered quantized expert math (same kernel path as Phase 2).
        let up = Edge0ExpertQuantizedMatrix(
            weight: try await tensor("experts.up_proj.weight"),
            scales: try await tensor("experts.up_proj.scales"),
            biases: try await tensor("experts.up_proj.biases")
        )
        let gate = Edge0ExpertQuantizedMatrix(
            weight: try await tensor("experts.gate_proj.weight"),
            scales: try await tensor("experts.gate_proj.scales"),
            biases: try await tensor("experts.gate_proj.biases")
        )
        let down = Edge0ExpertQuantizedMatrix(
            weight: try await tensor("experts.down_proj.weight"),
            scales: try await tensor("experts.down_proj.scales"),
            biases: try await tensor("experts.down_proj.biases")
        )

        let expanded = Edge0ExpertMath.switchGLUExpandedInput(hidden)
        let projectedUp = Edge0ExpertMath.gatheredProjection(
            expanded, weight: up.weight, scales: up.scales, biases: up.biases,
            indices: selection.indices
        )
        let projectedGate = Edge0ExpertMath.gatheredProjection(
            expanded, weight: gate.weight, scales: gate.scales, biases: gate.biases,
            indices: selection.indices
        )
        let swiglu = Edge0ExpertMath.swiglu(up: projectedUp, gate: projectedGate)
        let expertDown = Edge0ExpertMath.gatheredProjection(
            swiglu, weight: down.weight, scales: down.scales, biases: down.biases,
            indices: selection.indices
        ).squeezed(axis: -2)

        let upMetrics = compare(projectedUp, try await tensor("expert_up"))
        let gateMetrics = compare(projectedGate, try await tensor("expert_gate"))
        let swigluMetrics = compare(swiglu, try await tensor("swiglu"))
        let downMetrics = compare(expertDown, try await tensor("expert_down"))
        print("[Edge0 MoE] expert up relL2=\(upMetrics.relativeL2) gate relL2=\(gateMetrics.relativeL2) swiglu relL2=\(swigluMetrics.relativeL2) down relL2=\(downMetrics.relativeL2)")

        let aggregate = (
            expertDown * MLX.expandedDimensions(selection.weights, axis: -1)
        ).sum(axis: -2)
        let aggregateMetrics = compare(aggregate, try await tensor("moe_aggregate"))
        print("[Edge0 MoE] aggregate relL2=\(aggregateMetrics.relativeL2) maxAbs=\(aggregateMetrics.maxAbs)")

        let shared = Edge0MLP(
            gateProj: .dense(try await tensor("shared_gate.weight")),
            upProj: .dense(try await tensor("shared_up.weight")),
            downProj: .dense(try await tensor("shared_down.weight"))
        )(hidden)
        let sharedMetrics = compare(shared, try await tensor("shared_output"))
        print("[Edge0 MoE] shared relL2=\(sharedMetrics.relativeL2) maxAbs=\(sharedMetrics.maxAbs)")

        let output = aggregate + shared
        let outputMetrics = compare(output, try await tensor("moe_output"))
        print("[Edge0 MoE] output relL2=\(outputMetrics.relativeL2) maxAbs=\(outputMetrics.maxAbs)")

        // Same quantized weights and the same kernel: parity must be tight.
        XCTAssertLessThan(upMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(gateMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(swigluMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(downMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(aggregateMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(sharedMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(outputMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(weightMetrics.relativeL2, 1e-5)
        await stores.closeAll()
    }

    // MARK: - Helpers

    private func fixtureDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let url = URL(fileURLWithPath: directory)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("moe_tiny.safetensors").path
        ) else {
            throw XCTSkip("MoE fixture not found in \(url.path)")
        }
        return url
    }

    private struct Metrics {
        let relativeL2: Double
        let maxAbs: Double
    }

    private func compare(_ actual: MLXArray, _ expected: MLXArray) -> Metrics {
        let a = actual.asType(.float32).asArray(Float.self)
        let e = expected.asType(.float32).asArray(Float.self)
        precondition(a.count == e.count, "mismatch \(actual.shape) vs \(expected.shape)")
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
