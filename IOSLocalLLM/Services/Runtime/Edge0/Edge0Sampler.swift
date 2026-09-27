import Foundation
import MLX

// MARK: - Edge0Sampler
//
// Sampling semantics for Edge0 generation, mirrored from the app's MLX path
// (`mlx-swift-lm` `GenerateParameters`, `TopPSampler`, and the penalty
// processors) so the same logits + settings produce the same decision on
// both runtimes:
//
//   1. penalties over the recent-token window:
//        repetition: logit < 0 ? logit * penalty : logit / penalty
//        presence:   logit -= presencePenalty (once per unique token)
//        frequency:  logit -= frequencyPenalty * count in window
//   2. temperature <= 0 (or NaN) -> argmax (greedy; the exact parity mode)
//   3. otherwise: log-softmax -> top-p -> min-p -> top-k -> categorical(/temp)
//
// Filter order and math follow `mlx_lm.sample_utils` exactly: top-p keeps
// tokens whose cumulative probability exceeds `1 - topP`, min-p keeps tokens
// with probability >= maxProb * minP, top-k keeps the k highest logits.

struct Edge0Sampler: Sendable {
    var temperature: Float = 0
    var topP: Float = 1
    var topK: Int = 0
    var minP: Float = 0
    var repetitionPenalty: Float?
    var presencePenalty: Float?
    var frequencyPenalty: Float?
    var penaltyContextSize: Int = 20

    var isGreedy: Bool {
        !(temperature > 0) || temperature.isNaN
    }

    /// Deterministic decision boundary used by both the engine and tests.
    /// `previousTokens` is the recent context window (prompt + generated).
    func sample(logits: MLXArray, previousTokens: [Int]) -> Int {
        // Work in [1, vocab] like mlx-swift-lm; scalar/1-D shapes do not
        // broadcast through put_along_axis on every MLX build.
        var scores = logits.ndim == 1 ? logits.reshaped([1, -1]) : logits
        if scores.dtype != .float32 {
            scores = scores.asType(.float32)
        }
        scores = applyPenalties(scores, previousTokens: previousTokens)

        if isGreedy {
            return Int(
                argMax(scores, axis: -1)
                    .asType(.int32).asArray(Int32.self)[0]
            )
        }

        var logprobs = scores - scores.logSumExp(axis: -1, keepDims: true)
        if topP > 0 && topP < 1 {
            logprobs = Self.applyTopP(logprobs, topP: topP)
        }
        if minP > 0 {
            logprobs = Self.applyMinP(logprobs, minP: minP)
        }
        if topK > 0 {
            logprobs = Self.applyTopK(logprobs, topK: topK)
        }

        let sampled = MLXRandom.categorical(logprobs / temperature)
        return Int(sampled.asType(.int32).asArray(Int32.self)[0])
    }

    // MARK: - Penalties

    func applyPenalties(_ logits: MLXArray, previousTokens: [Int]) -> MLXArray {
        let usesPenalty = (repetitionPenalty ?? 0) != 0
            || (presencePenalty ?? 0) != 0
            || (frequencyPenalty ?? 0) != 0
        guard usesPenalty, !previousTokens.isEmpty else { return logits }

        let window = previousTokens.suffix(max(1, penaltyContextSize))
        var counts: [Int: Int] = [:]
        for token in window {
            counts[token, default: 0] += 1
        }
        let indices = counts.keys.sorted()
        let mlxIndices = MLXArray(indices.map { Int32($0) })[.newAxis, 0...]
        var selected = takeAlong(logits, mlxIndices, axis: -1)

        if let repetitionPenalty, repetitionPenalty != 0 {
            selected = MLX.where(
                selected .< 0,
                selected * repetitionPenalty,
                selected / repetitionPenalty
            )
        }
        if let presencePenalty, presencePenalty != 0 {
            selected = selected - presencePenalty
        }
        if let frequencyPenalty, frequencyPenalty != 0 {
            let deltas = indices.map {
                Float(counts[$0] ?? 0) * frequencyPenalty
            }
            selected = selected - MLXArray(deltas)
        }

        return putAlong(logits, mlxIndices, values: selected, axis: -1)
    }

    // MARK: - Filters (mlx-lm order: top-p, min-p, top-k)

    static func applyTopP(_ logprobs: MLXArray, topP: Float) -> MLXArray {
        let sortedIndices = argSort(logprobs, axis: -1)
        let sortedLogprobs = takeAlong(logprobs, sortedIndices, axis: -1)
        let cumulativeProbs = exp(sortedLogprobs).cumsum(axis: -1)
        let filtered = MLX.where(
            cumulativeProbs .> (1 - topP),
            sortedLogprobs,
            MLXArray.full(sortedLogprobs.shape, values: MLXArray(-Float.infinity))
        )
        return putAlong(logprobs, sortedIndices, values: filtered, axis: -1)
    }

    static func applyMinP(_ logprobs: MLXArray, minP: Float) -> MLXArray {
        let maxLogprob = logprobs.max(axis: -1, keepDims: true)
        let threshold = maxLogprob + log(MLXArray(minP))
        return MLX.where(
            logprobs .>= threshold,
            logprobs,
            MLXArray.full(logprobs.shape, values: MLXArray(-Float.infinity))
        )
    }

    static func applyTopK(_ logprobs: MLXArray, topK: Int) -> MLXArray {
        let vocabularySize = logprobs.dim(-1)
        guard topK < vocabularySize else { return logprobs }
        let partition = argPartition(-logprobs, kth: topK - 1, axis: -1)
        // Flatten and drop the retained prefix so the mask shape matches the
        // input rank (1-D tests and 2-D production paths both work).
        let masked = partition.flattened()[topK...]
        let maskIndices = logprobs.ndim == 1 ? masked : masked[.newAxis, 0...]
        return putAlong(
            logprobs,
            maskIndices,
            values: MLXArray.full(maskIndices.shape, values: MLXArray(-Float.infinity)),
            axis: -1
        )
    }
}
