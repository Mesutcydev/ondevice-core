import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0SamplerTests
//
// Deterministic boundary tests for the Edge0 sampler. The semantics are a
// mirror of the app's MLX path (`mlx-swift-lm`): penalties -> top-p -> min-p
// -> top-k -> temperature, with temperature <= 0 as greedy argmax.

final class Edge0SamplerTests: Edge0MLXTestCase {

    private func logits(_ values: [Float]) -> MLXArray {
        MLXArray(values)
    }

    // MARK: Greedy

    func testGreedyAppliesPenaltiesBeforeArgMax() {
        // Same order as the MLX path: the penalty processor runs before the
        // argmax sampler. Token 1 (5.0) drops to (5.0/10 - 5.0) = -4.5, so
        // token 2 (0.2) wins over token 0 (0.1).
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.repetitionPenalty = 10
        sampler.presencePenalty = 5
        XCTAssertEqual(
            sampler.sample(logits: logits([0.1, 5.0, 0.2]), previousTokens: [1]),
            2
        )
    }

    func testNaNTemperatureIsGreedy() {
        var sampler = Edge0Sampler()
        sampler.temperature = .nan
        XCTAssertEqual(
            sampler.sample(logits: logits([0.0, 3.0, 1.0]), previousTokens: []),
            1
        )
    }

    // MARK: Penalties

    func testRepetitionPenaltyFlipsDecision() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.repetitionPenalty = 3
        // token 1 leads (1.5) but is in the window: 1.5 / 3 = 0.5 < 1.0.
        XCTAssertEqual(
            sampler.sample(logits: logits([1.0, 1.5, 0.0]), previousTokens: [1]),
            0
        )
    }

    func testPresencePenaltyFlipsDecision() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.presencePenalty = 0.8
        // 1.5 - 0.8 = 0.7 < 1.0.
        XCTAssertEqual(
            sampler.sample(logits: logits([1.0, 1.5, 0.0]), previousTokens: [1]),
            0
        )
    }

    func testFrequencyPenaltyScalesWithCount() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.frequencyPenalty = 0.5
        // token 1 appears twice: 1.5 - 2 * 0.5 = 0.5 < 1.0.
        XCTAssertEqual(
            sampler.sample(logits: logits([1.0, 1.5, 0.0]), previousTokens: [1, 1]),
            0
        )
    }

    func testPenaltyWindowHonorsContextSize() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.repetitionPenalty = 3
        sampler.penaltyContextSize = 1
        // Window = [1]: token 1 penalized (2.0/3 = 0.667) so token 2 (1.0)
        // wins; token 2 is not yet penalized.
        XCTAssertEqual(
            sampler.sample(logits: logits([0.9, 2.0, 1.0]), previousTokens: [2, 1]),
            2
        )
        sampler.penaltyContextSize = 2
        // Window = [2, 1]: token 2 drops to 1.0/3 = 0.333, token 0 wins.
        XCTAssertEqual(
            sampler.sample(logits: logits([0.9, 2.0, 1.0]), previousTokens: [2, 1]),
            0
        )
    }

    // MARK: Temperature-path filters

    func testTopKOnePicksArgMax() {
        var sampler = Edge0Sampler()
        sampler.temperature = 1
        sampler.topK = 1
        // Only the highest logit survives the mask, so any RNG picks it.
        XCTAssertEqual(
            sampler.sample(logits: logits([0.0, 1.0, 9.0]), previousTokens: []),
            2
        )
    }

    func testTinyTopPKeepsTopTokenOnly() {
        var sampler = Edge0Sampler()
        sampler.temperature = 1
        sampler.topP = 0.01
        // p(token 2) ~= 1, so the nucleus holds only token 2.
        XCTAssertEqual(
            sampler.sample(logits: logits([0.0, 0.0, 10.0]), previousTokens: []),
            2
        )
    }

    func testMinPKeepsHighestProbabilityToken() {
        var sampler = Edge0Sampler()
        sampler.temperature = 1
        sampler.minP = 0.5
        XCTAssertEqual(
            sampler.sample(logits: logits([0.0, 0.0, 10.0]), previousTokens: []),
            2
        )
    }

    func testDisabledFiltersLeaveSamplerUntouched() {
        // topP == 1, minP == 0, topK == 0 are all no-ops; with temperature 0
        // the result must stay the greedy argmax.
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.topP = 1
        sampler.minP = 0
        sampler.topK = 0
        XCTAssertEqual(
            sampler.sample(logits: logits([1.0, 4.0, 2.0]), previousTokens: []),
            1
        )
    }

    func testNegativeParametersAreDisabled() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0
        sampler.minP = -0.5
        sampler.topK = -3
        XCTAssertEqual(
            sampler.sample(logits: logits([1.0, 4.0, 2.0]), previousTokens: []),
            1
        )
    }

    func testSeededTemperatureSamplingIsReproducible() {
        var sampler = Edge0Sampler()
        sampler.temperature = 0.8
        sampler.topK = 4
        let candidates = logits([0.1, 0.2, 0.3, 0.4, 0.5])
        MLXRandom.seed(42)
        let first = sampler.sample(logits: candidates, previousTokens: [])
        MLXRandom.seed(42)
        let second = sampler.sample(logits: candidates, previousTokens: [])
        XCTAssertEqual(first, second)
    }

    func testTopKFilterKeepsRequestedCount() {
        let filtered = Edge0Sampler.applyTopK(
            logits([0.0, 1.0, 2.0, 3.0]),
            topK: 2
        )
        let values = filtered.asArray(Float.self)
        let kept = values.enumerated().filter { $0.element.isFinite }
        XCTAssertEqual(kept.map(\.offset), [2, 3])
    }

    func testTopPFilterMasksTail() {
        // Normalized log-probs: p = [0.9, 0.1]. The ascending cumulative
        // mask drops token 1 (cum 0.1 <= 1 - 0.5) and keeps token 0.
        let logprobs = logits([Float(log(0.9)), Float(log(0.1))])
        let filtered = Edge0Sampler.applyTopP(logprobs, topP: 0.5)
        let values = filtered.asArray(Float.self)
        XCTAssertTrue(values[0].isFinite)
        XCTAssertFalse(values[1].isFinite)
    }

    func testMinPFilterMasksLowProbabilityTokens() {
        let filtered = Edge0Sampler.applyMinP(
            logits([0.0, 2.0, 10.0]),
            minP: 0.5
        )
        let values = filtered.asArray(Float.self)
        XCTAssertFalse(values[0].isFinite)
        XCTAssertFalse(values[1].isFinite)
        XCTAssertTrue(values[2].isFinite)
    }
}
