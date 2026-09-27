import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0RouterParityTests
//
// Compares the Swift `Edge0Router` port against fixtures produced by the
// upstream `BailingGate` code (scripts/edge0_reference_dump.py, reference
// commit 0700e6532f45e0d0d99e9c588d7d8cd240538ea0).
//
// Fixtures are development artifacts; set EDGE0_FIXTURE_DIR or generate
// /tmp/edge0-fixtures with the oracle script. Tests skip when absent.

final class Edge0RouterParityTests: Edge0MLXTestCase {

    private struct Fixture: Decodable {
        let reference_sha: String
        let num_experts: Int
        let num_experts_per_tok: Int
        let n_group: Int
        let topk_group: Int
        let routed_scaling_factor: Double
        let norm_topk_prob: Bool
        let hidden_size: Int
        let hidden: [[Float]]
        let router_weight: [[Float]]
        let expert_bias: [Float]
        let expected_indices: [[Int]]
        let expected_weights: [[Float]]
        let expected_scores: [[Float]]
        let expected_group_scores: [[Float]]
    }

    private func loadFixture() throws -> Fixture {
        let directory = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("router_fixture.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("router fixture not found at \(url.path)")
        }
        return try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: url)
        )
    }

    func testRouterMatchesUpstreamGate() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            fixture.reference_sha,
            "0700e6532f45e0d0d99e9c588d7d8cd240538ea0"
        )

        let router = Edge0Router(
            numExperts: fixture.num_experts,
            numExpertsPerTok: fixture.num_experts_per_tok,
            nGroup: fixture.n_group,
            topkGroup: fixture.topk_group,
            routedScalingFactor: Float(fixture.routed_scaling_factor),
            normTopkProb: fixture.norm_topk_prob,
            expertBiasEnabled: true
        )
        let hidden = MLXArray(fixture.hidden.flatMap { $0 }, [fixture.hidden.count, fixture.hidden_size])
        let weight = MLXArray(
            fixture.router_weight.flatMap { $0 },
            [fixture.num_experts, fixture.hidden_size]
        )
        let expertBias = MLXArray(fixture.expert_bias, [fixture.num_experts])

        let result = router(hidden, weight: weight, expertBias: expertBias)

        // Selected expert IDs must match exactly.
        let indices = result.indices.asArray(Int32.self)
        let expectedIndices = fixture.expected_indices
            .flatMap { $0 }
            .map { Int32($0) }
        XCTAssertEqual(indices, expectedIndices)

        // Weights and scores must match numerically.
        let expectedWeights = fixture.expected_weights.flatMap { $0 }
        let actualWeights = result.weights.asArray(Float.self)
        let weightMetrics = compare(actualWeights, expectedWeights)
        print("[Edge0 router] weights relL2=\(weightMetrics.relativeL2) maxAbs=\(weightMetrics.maxAbs)")

        let expectedScores = fixture.expected_scores.flatMap { $0 }
        let actualScores = result.scores.asArray(Float.self)
        let scoreMetrics = compare(actualScores, expectedScores)
        print("[Edge0 router] scores relL2=\(scoreMetrics.relativeL2) maxAbs=\(scoreMetrics.maxAbs)")

        let groupScores = try XCTUnwrap(result.groupScores)
        let expectedGroupScores = fixture.expected_group_scores.flatMap { $0 }
        let groupMetrics = compare(
            groupScores.asArray(Float.self),
            expectedGroupScores
        )
        print("[Edge0 router] groupScores relL2=\(groupMetrics.relativeL2) maxAbs=\(groupMetrics.maxAbs)")

        XCTAssertLessThan(weightMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(weightMetrics.maxAbs, 1e-5)
        XCTAssertLessThan(scoreMetrics.relativeL2, 1e-5)
        XCTAssertLessThan(groupMetrics.relativeL2, 1e-5)
    }

    func testNoGroupDropPathUsesRawSigmoidScores() throws {
        // topk_group == n_group keeps every group; the group mask must not
        // run (upstream guards k_drop > 0).
        let fixture = try loadFixture()
        let router = Edge0Router(
            numExperts: fixture.num_experts,
            numExpertsPerTok: fixture.num_experts_per_tok,
            nGroup: fixture.n_group,
            topkGroup: fixture.n_group,
            routedScalingFactor: 1.0,
            normTopkProb: true,
            expertBiasEnabled: true
        )
        let hidden = MLXArray(
            fixture.hidden.flatMap { $0 },
            [fixture.hidden.count, fixture.hidden_size]
        )
        let weight = MLXArray(
            fixture.router_weight.flatMap { $0 },
            [fixture.num_experts, fixture.hidden_size]
        )
        let expertBias = MLXArray(fixture.expert_bias, [fixture.num_experts])
        let result = router(hidden, weight: weight, expertBias: expertBias)
        XCTAssertNil(result.groupScores)
        XCTAssertEqual(result.indices.shape.last, fixture.num_experts_per_tok)
        // Weights sum (before scaling) to 1 per token.
        let summed = result.weights.sum(axis: -1).asArray(Float.self)
        for value in summed {
            XCTAssertEqual(value, 1.0, accuracy: 1e-5)
        }
    }

    private struct Metrics {
        let relativeL2: Double
        let maxAbs: Double
    }

    private func compare(_ actual: [Float], _ expected: [Float]) -> Metrics {
        precondition(actual.count == expected.count)
        var squaredDifference = 0.0
        var squaredReference = 0.0
        var maxAbs = 0.0
        for index in 0..<actual.count {
            let difference = Double(actual[index] - expected[index])
            let reference = Double(expected[index])
            squaredDifference += difference * difference
            squaredReference += reference * reference
            maxAbs = max(maxAbs, abs(difference))
        }
        return Metrics(
            relativeL2: (squaredDifference / max(squaredReference, 1e-12)).squareRoot(),
            maxAbs: maxAbs
        )
    }
}
