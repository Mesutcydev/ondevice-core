import Foundation
import MLX

// MARK: - Edge0RouterResult

struct Edge0RouterResult: @unchecked Sendable {
    /// `[..., top_k]` selected expert indices.
    let indices: MLXArray
    /// `[..., top_k]` normalized selection weights (scaled).
    let weights: MLXArray
    /// `[..., num_experts]` raw sigmoid scores.
    let scores: MLXArray
    /// `[..., n_group]` group scores (nil when no group is dropped).
    let groupScores: MLXArray?
}

// MARK: - Edge0Router
//
// Exact port of upstream `BailingGate` (noaux_tc / SIGMOID_GROUP):
//
//   scores  = sigmoid(logits.astype(fp32))
//   select  = scores + expert_bias
//   groups  = select.reshape(..., n_group, E/n_group)
//   drop    = argpartition(group_top2_sum, kth=k_drop-1)[..., :k_drop]
//   select  = put_along_axis(groups, drop, -inf, axis=-2).reshape(...)
//   idx     = argpartition(-select, kth=top_k-1)[..., :top_k]
//   w       = take_along_axis(scores, idx)     // bias excluded
//   w       = w / (sum(w) + 1e-20) * routed_scaling   (norm_topk_prob)
//
// The gate projection is applied by the caller so the router stays a pure
// selection unit (parity-testable without a model).

struct Edge0Router: Sendable {
    let numExperts: Int
    let numExpertsPerTok: Int
    let nGroup: Int
    let topkGroup: Int
    let routedScalingFactor: Float
    let normTopkProb: Bool
    let expertBiasEnabled: Bool

    init(
        numExperts: Int,
        numExpertsPerTok: Int,
        nGroup: Int,
        topkGroup: Int,
        routedScalingFactor: Float,
        normTopkProb: Bool,
        expertBiasEnabled: Bool
    ) {
        self.numExperts = numExperts
        self.numExpertsPerTok = numExpertsPerTok
        self.nGroup = nGroup
        self.topkGroup = topkGroup
        self.routedScalingFactor = routedScalingFactor
        self.normTopkProb = normTopkProb
        self.expertBiasEnabled = expertBiasEnabled
    }

    init(configuration: Edge0ModelConfiguration) {
        self.init(
            numExperts: configuration.numExperts,
            numExpertsPerTok: configuration.numExpertsPerTok,
            nGroup: configuration.nGroup,
            topkGroup: configuration.topkGroup,
            routedScalingFactor: Float(configuration.routedScalingFactor),
            normTopkProb: configuration.normTopkProb,
            expertBiasEnabled: configuration.routerExpertBias
        )
    }

    /// Applies the router projection and selection.
    /// - Parameters:
    ///   - hidden: `[..., hidden_size]`
    ///   - weight: `[num_experts, hidden_size]`
    ///   - expertBias: `[num_experts]` or nil
    func callAsFunction(
        _ hidden: MLXArray,
        weight: MLXArray,
        expertBias: MLXArray? = nil
    ) -> Edge0RouterResult {
        let logits = MLX.matmul(
            hidden,
            weight.transposed(1, 0)
        ).asType(.float32)
        return Self.groupSelect(
            logits: logits,
            expertBias: expertBiasEnabled ? expertBias : nil,
            numExperts: numExperts,
            numExpertsPerTok: numExpertsPerTok,
            nGroup: nGroup,
            topkGroup: topkGroup,
            routedScalingFactor: routedScalingFactor,
            normTopkProb: normTopkProb
        )
    }

    /// Pure SIGMOID_GROUP selection, shared by the true router and the
    /// prerouter head predictions (upstream `group_select_from_logits`).
    /// `expertBias` is applied only when the caller supplies it.
    static func groupSelect(
        logits: MLXArray,
        expertBias: MLXArray?,
        numExperts: Int,
        numExpertsPerTok: Int,
        nGroup: Int,
        topkGroup: Int,
        routedScalingFactor: Float,
        normTopkProb: Bool
    ) -> Edge0RouterResult {
        let batchShape = Array(logits.shape.dropLast())
        let scores = MLX.sigmoid(logits)
        var select = scores
        if let expertBias {
            select = scores + expertBias
        }

        var groupScores: MLXArray?
        let kDrop = nGroup - topkGroup
        if kDrop > 0 {
            let grouped = select.reshaped(
                batchShape + [nGroup, numExperts / nGroup]
            )
            // Group score = sum of the top-2 selection scores in the group.
            let top2 = MLX.top(grouped, k: 2, axis: -1)
            let computedGroupScores = top2.sum(axis: -1)
            groupScores = computedGroupScores
            let drop = MLX.argPartition(
                computedGroupScores,
                kth: kDrop - 1,
                axis: -1
            )[.ellipsis, ..<kDrop]
            // Broadcasting the trailing size-1 index dim masks every expert
            // slot of each dropped group.
            let masked = MLX.putAlong(
                grouped,
                MLX.expandedDimensions(drop, axis: -1),
                values: MLXArray(-Float.infinity),
                axis: -2
            )
            select = masked.reshaped(batchShape + [numExperts])
        }

        let indices = MLX.argPartition(
            -select,
            kth: numExpertsPerTok - 1,
            axis: -1
        )[.ellipsis, ..<numExpertsPerTok]

        var weights = MLX.takeAlong(scores, indices, axis: -1)
        if normTopkProb {
            weights = weights / (weights.sum(axis: -1, keepDims: true) + 1e-20)
        }
        weights = weights * routedScalingFactor

        return Edge0RouterResult(
            indices: indices,
            weights: weights,
            scores: scores,
            groupScores: groupScores
        )
    }
}
