import Foundation
import MLX

// MARK: - Edge0KDAState

/// Per-layer, per-generation recurrent state for a KDA layer.
/// `nil` fields mean "not yet initialized" (fresh generation).
struct Edge0KDAState: @unchecked Sendable {
    /// Rolling short-conv windows: `[B, kernel-1, projectionDim]`.
    var qConv: MLXArray?
    var kConv: MLXArray?
    var vConv: MLXArray?
    /// Delta-rule state: `[B, heads, vHeadDim, headDim]` (float32).
    var recurrent: MLXArray?

    static let empty = Edge0KDAState()
}

// MARK: - Edge0KDAWeights

struct Edge0KDAWeights: @unchecked Sendable {
    let qProj: Edge0LinearWeight
    let kProj: Edge0LinearWeight
    let vProj: Edge0LinearWeight
    /// Depthwise conv weights in module layout `[projectionDim, kernel, 1]`.
    let qConvWeight: MLXArray
    let kConvWeight: MLXArray
    let vConvWeight: MLXArray
    let fProj: Edge0LinearWeight
    let gProj: Edge0LinearWeight
    let bProj: Edge0LinearWeight
    let aLog: MLXArray
    let dtBias: MLXArray
    let oNorm: MLXArray
    let oProj: Edge0LinearWeight
}

// MARK: - Edge0KDAAttention
//
// Exact port of upstream `BailingKDA` (Ling 3.0 Kimi Delta Attention with the
// V3 safe gate) using mlx-lm's ops-based delta-rule step, which is the
// reference implementation `gated_delta_ops` and is bit-exact with the fused
// Metal kernel's math:
//
//   q,k,v  = short_conv(proj(x))           (causal, kernel 4, silu)
//   q      = scale * l2norm(q)             (eps 1e-6, float32)
//   k      = l2norm(k)
//   g      = -5 * sigmoid(exp(A_log) * (f + dt_bias))
//   beta   = sigmoid(b_proj(x))
//   state  = state * exp(g); kv = state·k
//   delta  = (v - kv) * beta; state += k⊗delta; y = state·q
//   out    = o_proj(sigmoid(gate) * o_norm(y))
//
// The Metal kernel (`gated_delta_kernel`) is a performance path only and is
// intentionally not ported in this phase.

struct Edge0KDAAttention: Sendable {
    let numHeads: Int
    let headDim: Int
    let convKernelSize: Int
    let safeGate: Bool
    let lowerBound: Float
    let eps: Float
    let scale: Float
    let weights: Edge0KDAWeights

    var projectionDim: Int { numHeads * headDim }

    // MARK: - Forward

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0KDAState
    ) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)

        var qConv: MLXArray
        var kConv: MLXArray
        var vConv: MLXArray
        (qConv, state.qConv) = shortConv(
            weights.qProj.apply(x),
            weight: weights.qConvWeight,
            state: state.qConv
        )
        (kConv, state.kConv) = shortConv(
            weights.kProj.apply(x),
            weight: weights.kConvWeight,
            state: state.kConv
        )
        (vConv, state.vConv) = shortConv(
            weights.vProj.apply(x),
            weight: weights.vConvWeight,
            state: state.vConv
        )

        var q = qConv.reshaped([batch, length, numHeads, headDim])
            .asType(.float32)
        var k = kConv.reshaped([batch, length, numHeads, headDim])
            .asType(.float32)
        let v = vConv.reshaped([batch, length, numHeads, headDim])

        let qNorm = MLXLinalg.norm(q, axes: [-1], keepDims: true)
        let kNorm = MLXLinalg.norm(k, axes: [-1], keepDims: true)
        q = scale * q / (qNorm + 1e-6)
        k = k / (kNorm + 1e-6)

        let f = weights.fProj.apply(x)
            .reshaped([batch, length, numHeads, headDim])
        // Output gate stays in the projection's dtype; upstream only casts
        // the log-decay input inside `_kda_gate`.
        let gate = weights.gProj.apply(x)
            .reshaped([batch, length, numHeads, headDim])
        let g = kdaGate(f)
        let beta = MLX.sigmoid(
            weights.bProj.apply(x).asType(.float32)
        )

        let (y, recurrent) = Self.gatedDeltaOps(
            q: q,
            k: k,
            v: v,
            g: g,
            beta: beta,
            state: state.recurrent
        )
        state.recurrent = recurrent

        var out = Edge0LinearMath.rmsNorm(
            y.asType(x.dtype),
            weight: weights.oNorm,
            eps: eps
        )
        out = out * MLX.sigmoid(gate)
        return weights.oProj.apply(
            out.reshaped([batch, length, projectionDim])
        )
    }

    // MARK: - Short conv

    /// Causal depthwise conv (kernel `convKernelSize`, silu) with a rolling
    /// cache of the previous `kernel-1` inputs, matching upstream
    /// `ShortConv1d`.
    func shortConv(
        _ x: MLXArray,
        weight: MLXArray,
        state: MLXArray?
    ) -> (MLXArray, MLXArray) {
        let batch = x.dim(0)
        let channels = x.dim(2)
        let previous = state ?? MLXArray.zeros(
            [batch, max(0, convKernelSize - 1), channels],
            dtype: x.dtype
        )
        let convInput = MLX.concatenated([previous, x], axis: 1)
        let convolved = MLX.conv1d(
            convInput,
            weight,
            stride: 1,
            padding: 0,
            groups: channels
        )
        let activated = Edge0LinearMath.silu(convolved)
        let total = convInput.dim(1)
        let keep = max(0, convKernelSize - 1)
        let newState = keep == 0
            ? convInput[0..., ..<0, 0...]
            : convInput[0..., (total - keep)..<total, 0...]
        return (activated, newState)
    }

    // MARK: - Safe gate

    /// `g = lower_bound * sigmoid(exp(A_log) * (f + dt_bias))`, or
    /// `-exp(A_log) * softplus(f + dt_bias)` without the safe gate.
    func kdaGate(_ f: MLXArray) -> MLXArray {
        // Upstream `_kda_gate` computes in float32:
        //   f = f.astype(fp32) + dt_bias.astype(fp32)
        //   a = exp(A_log.astype(fp32))
        let shifted = f.asType(.float32)
            + weights.dtBias.asType(.float32).reshaped([numHeads, headDim])
        let a = MLX.exp(weights.aLog.asType(.float32)).reshaped([numHeads, 1])
        if safeGate {
            return lowerBound * MLX.sigmoid(a * shifted)
        }
        let stable = MLX.maximum(shifted, MLXArray(0))
            + MLX.log1p(MLX.exp(-MLX.abs(shifted)))
        return -a * stable
    }

    // MARK: - Gated delta rule (ops reference path)

    /// Per-timestep recurrence, matching `_gated_delta_step_ops` exactly.
    /// `g` is the **log-space** safe gate; it is exponentiated here, matching
    /// upstream `_kda_update` (`g = mx.exp(g_log)`).
    /// Shapes: q,k `[B,T,H,Dk]`, v `[B,T,H,Dv]`, g `[B,T,H,Dk]`,
    /// beta `[B,T,H]`, state `[B,H,Dv,Dk]` float32.
    static func gatedDeltaOps(
        q: MLXArray,
        k: MLXArray,
        v: MLXArray,
        g: MLXArray,
        beta: MLXArray,
        state: MLXArray?
    ) -> (MLXArray, MLXArray) {
        let batch = q.dim(0)
        let length = q.dim(1)
        let heads = q.dim(2)
        let vHeadDim = v.dim(3)
        let decay = MLX.exp(g)
        var recurrent = state ?? MLXArray.zeros(
            [batch, heads, vHeadDim, q.dim(3)],
            dtype: .float32
        )
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(length)

        for step in 0..<length {
            let qStep = q[0..., step, 0..., 0...]
            let kStep = k[0..., step, 0..., 0...]
            let vStep = v[0..., step, 0..., 0...]
            let gStep = decay[0..., step, 0..., 0...]
            let betaStep = beta[0..., step, 0...]

            let decayStep = gStep.expandedDimensions(axis: -2)
            recurrent = recurrent * decayStep
            let kExpanded = kStep.expandedDimensions(axis: -2)
            let kvMemory = (recurrent * kExpanded).sum(axis: -1)
            let delta = (vStep - kvMemory)
                * betaStep.expandedDimensions(axis: -1)
            recurrent = recurrent + kExpanded
                * delta.expandedDimensions(axis: -1)
            let y = (recurrent * qStep.expandedDimensions(axis: -2))
                .sum(axis: -1)
            outputs.append(y.asType(q.dtype))
        }
        return (MLX.stacked(outputs, axis: 1), recurrent)
    }
}
