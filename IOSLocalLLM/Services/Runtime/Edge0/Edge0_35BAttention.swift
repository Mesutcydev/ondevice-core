import Foundation
import MLX

// MARK: - States

struct Edge0_35BLinearAttentionState: @unchecked Sendable {
    /// Rolling short-conv window `[B, kernel-1, convDim]`.
    var conv: MLXArray?
    /// Recurrent delta-rule state `[B, valueHeads, valueHeadDim, keyHeadDim]` fp32.
    var recurrent: MLXArray?
    static let empty = Edge0_35BLinearAttentionState()
}

struct Edge0_35BFullAttentionState: @unchecked Sendable {
    var keys: MLXArray?     // [B, kvHeads, T, headDim]
    var values: MLXArray?   // [B, kvHeads, T, headDim]
    var offset: Int = 0
    static let empty = Edge0_35BFullAttentionState()
}

// MARK: - Edge0_35BLinearAttention (GatedDeltaNet)
//
// Exact port of the vendored qwen3_5 `GatedDeltaNet` + mlx-lm
// `gated_delta_update`/`_gated_delta_step_ops`:
//   qkv = in_proj_qkv(x); z = in_proj_z(x); b = in_proj_b(x); a = in_proj_a(x)
//   conv_out = silu(conv1d(concat(conv_state, qkv)))
//   q,k = rms_norm (weightless, eps 1e-6) with inv_scale factors
//   decay = exp(-exp(A_log) * softplus(a + dt_bias))   [fp32]
//   per token: state *= decay; kv = state·k; delta = (v - kv)·sigmoid(b)
//              state += k⊗delta; y = state·q
//   out = out_proj(precise_swiglu(rms_norm_gated(y), z))

struct Edge0_35BLinearAttention: @unchecked Sendable {
    let weights: Edge0_35BLinearAttentionWeights
    let configuration: Edge0_35BModelConfiguration
    /// Optional debug trace hook (never set in the production path).
    var trace: ((String, MLXArray) -> Void)? = nil

    private var numKeyHeads: Int { configuration.linearNumKeyHeads }     // 16
    private var numValueHeads: Int { configuration.linearNumValueHeads } // 32
    private var keyHeadDim: Int { configuration.linearKeyHeadDim }       // 128
    private var valueHeadDim: Int { configuration.linearValueHeadDim }   // 128
    private var kernelSize: Int { configuration.linearConvKernelDim }    // 4

    /// Ops recurrence, faithful to mlx-lm `gated_delta_ops` +
    /// `_gated_delta_step_ops` (head repeat handled by the caller, mask
    /// always nil for our single-sequence correctness path).
    static func gatedDeltaOps(
        q: MLXArray, k: MLXArray, v: MLXArray,
        decay: MLXArray, beta: MLXArray, state: MLXArray?
    ) -> (y: MLXArray, state: MLXArray) {
        let batch = q.dim(0)
        let length = q.dim(1)
        let valueHeads = v.dim(2)
        let valueHeadDim = v.dim(3)
        let keyHeadDim = q.dim(3)
        var recurrent = state ?? MLXArray.zeros(
            [batch, valueHeads, valueHeadDim, keyHeadDim], dtype: .float32
        )
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(length)
        for step in 0..<length {
            let qStep = q[0..., step, 0..., 0...]
            let kStep = k[0..., step, 0..., 0...]
            let vStep = v[0..., step, 0..., 0...]
            let decayStep = decay[0..., step, 0...]
            let betaStep = beta[0..., step, 0...]
            let decayBroadcast = decayStep
                .expandedDimensions(axis: -1)
                .expandedDimensions(axis: -1)
            recurrent = recurrent * decayBroadcast
            let kBroadcast = kStep.expandedDimensions(axis: -2)
            let kvMemory = (recurrent * kBroadcast).sum(axis: -1)
            let delta = (vStep - kvMemory)
                * betaStep.expandedDimensions(axis: -1)
            recurrent = recurrent
                + kBroadcast * delta.expandedDimensions(axis: -1)
            let y = (recurrent * qStep.expandedDimensions(axis: -2))
                .sum(axis: -1)
            outputs.append(y.asType(q.dtype))
        }
        return (MLX.stacked(outputs, axis: 1), recurrent)
    }

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0_35BLinearAttentionState
    ) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        let keyDim = keyHeadDim * numKeyHeads
        let valueDim = valueHeadDim * numValueHeads
        let convDim = keyDim * 2 + valueDim

        let qkv = weights.inProjQKV.apply(x)
        let z = weights.inProjZ.apply(x).reshaped(
            [batch, length, numValueHeads, valueHeadDim]
        )
        let b = weights.inProjB.apply(x)
        let a = weights.inProjA.apply(x)

        let convState = state.conv ?? MLXArray.zeros(
            [batch, max(0, kernelSize - 1), convDim], dtype: x.dtype
        )
        let convInput = MLX.concatenated([convState, qkv], axis: 1)
        let keep = max(0, kernelSize - 1)
        state.conv = keep == 0
            ? convInput[0..., ..<0, 0...]
            : convInput[0..., (convInput.dim(1) - keep)..<convInput.dim(1), 0...]

        let convOut = Edge0LinearMath.silu(MLX.conv1d(
            convInput,
            weights.conv1dWeight,
            stride: 1,
            padding: 0,
            groups: convDim
        ))
        let parts = convOut.split(indices: [keyDim, 2 * keyDim], axis: -1)
        var q = parts[0].reshaped([batch, length, numKeyHeads, keyHeadDim])
        var k = parts[1].reshaped([batch, length, numKeyHeads, keyHeadDim])
        let v = parts[2].reshaped([batch, length, numValueHeads, valueHeadDim])

        // Weightless RMSNorm (weight = ones) with upstream eps 1e-6.
        let invScale = Float(pow(Double(keyHeadDim), -0.5))
        let onesK = MLXArray.ones([keyHeadDim], dtype: q.dtype)
        q = (invScale * invScale) * MLXFast.rmsNorm(q, weight: onesK, eps: 1e-6)
        k = invScale * MLXFast.rmsNorm(k, weight: onesK, eps: 1e-6)
        trace?("q_pre_repeat", q)
        trace?("k_pre_repeat", k)
        trace?("v", v)

        // decay = exp(-exp(A_log) * softplus(a + dt_bias)); upstream keeps
        // `a + dt_bias` and the softplus in bf16, then promotes for the
        // A_log multiply (its `compute_g` casts only A_log to fp32).
        let softplusInput = a + weights.dtBias
        let softplus = MLX.logAddExp(
            softplusInput, MLXArray(0, dtype: .bfloat16)
        )                                             // bf16, like nn.softplus
        let aLogExp = MLX.exp(weights.aLog)           // fp32
        let decay = MLX.exp(-(aLogExp * softplus.asType(.float32)))
        trace?("decay", decay)
        let beta = MLX.sigmoid(b)                    // [B,S,32]
        trace?("beta", beta)

        // Head repeat 32/16 = 2 for the delta recurrence.
        let repeatFactor = max(1, numValueHeads / numKeyHeads)
        let qHeads = repeatFactor > 1 ? MLX.repeated(
            q, count: repeatFactor, axis: 2
        ) : q
        let kHeads = repeatFactor > 1 ? MLX.repeated(
            k, count: repeatFactor, axis: 2
        ) : k

        let (deltaOut, recurrent) = Self.gatedDeltaOps(
            q: qHeads, k: kHeads, v: v, decay: decay, beta: beta,
            state: state.recurrent
        )
        state.recurrent = recurrent
        trace?("state", recurrent)
        trace?("delta_out", deltaOut)

        // RMSNormGated + precise swiglu: (silu(z) * rms_norm(out)) in fp32.
        let normed = MLXFast.rmsNorm(
            deltaOut, weight: weights.normWeight, eps: 1e-6
        )
        let gate = Edge0LinearMath.silu(z.asType(.float32))
        let gated = (gate * normed.asType(.float32)).asType(deltaOut.dtype)
        trace?("gated_out", gated)
        let attentionOutput = weights.outProj.apply(
            gated.reshaped([batch, length, valueDim])
        )
        trace?("attn_out", attentionOutput)
        return attentionOutput
    }
}

// MARK: - Edge0_35BFullAttention (GQA + partial mRoPE + output gate)
//
// Exact port of the vendored qwen3_next `Qwen3NextAttention`:
//   q_proj -> split(query, gate) per head; k/v -> 2 KV heads
//   q_norm/k_norm over head_dim; partial interleaved RoPE (64 of 256 dims,
//   theta 1e7); GQA SDPA (scale 1/sqrt(256)); out * sigmoid(gate); o_proj.

struct Edge0_35BFullAttention: @unchecked Sendable {
    let weights: Edge0_35BFullAttentionWeights
    let configuration: Edge0_35BModelConfiguration
    /// Optional debug trace hook (never set in the production path).
    var trace: ((String, MLXArray) -> Void)? = nil

    private var numHeads: Int { configuration.numAttentionHeads }   // 16
    private var kvHeads: Int { configuration.numKeyValueHeads }     // 2
    private var headDim: Int { configuration.headDim }              // 256
    private var rotaryDim: Int {
        max(2, Int(Double(headDim) * configuration.partialRotaryFactor))
    }
    private var scale: Float { Float(pow(Double(headDim), -0.5)) }

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0_35BFullAttentionState
    ) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)

        let qOutputRaw = weights.qProj.apply(x)
        trace?("q_proj_out", qOutputRaw)
        let qOutput = qOutputRaw.reshaped(
            [batch, length, numHeads, headDim * 2]
        )
        let qParts = qOutput.split(indices: [headDim], axis: -1)
        var queries = qParts[0]                                   // [B,S,16,256]
        let gate = qParts[1].reshaped([batch, length, numHeads * headDim])

        let kOutputRaw = weights.kProj.apply(x)
        trace?("k_proj_out", kOutputRaw)
        let vOutputRaw = weights.vProj.apply(x)
        trace?("v_proj_out", vOutputRaw)
        let keysRaw = kOutputRaw.reshaped(
            [batch, length, kvHeads, headDim]
        )
        let valuesRaw = vOutputRaw.reshaped(
            [batch, length, kvHeads, headDim]
        )

        queries = MLXFast.rmsNorm(
            queries, weight: weights.qNorm, eps: 1e-6
        ).transposed(0, 2, 1, 3)
        let keysNormed = MLXFast.rmsNorm(
            keysRaw, weight: weights.kNorm, eps: 1e-6
        ).transposed(0, 2, 1, 3)
        let values = valuesRaw.transposed(0, 2, 1, 3)

        trace?("rope_in", queries)
        trace?("rope_in_k", keysNormed)
        let offset = state.offset
        queries = Self.partialRoPE(
            queries, offset: offset, rotaryDim: rotaryDim,
            theta: Float(configuration.ropeTheta)
        )
        let keysRotated = Self.partialRoPE(
            keysNormed, offset: offset, rotaryDim: rotaryDim,
            theta: Float(configuration.ropeTheta)
        )
        trace?("rope_out", queries)
        trace?("rope_out_k", keysRotated)

        let allKeys: MLXArray
        let allValues: MLXArray
        if let cachedKeys = state.keys, let cachedValues = state.values {
            allKeys = MLX.concatenated([cachedKeys, keysRotated], axis: 2)
            allValues = MLX.concatenated([cachedValues, values], axis: 2)
        } else {
            allKeys = keysRotated
            allValues = values
        }
        state.keys = allKeys
        state.values = allValues
        state.offset += length

        let mask: MLXFast.ScaledDotProductAttentionMaskMode =
            length > 1 ? .causal : .none
        var output = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: allKeys,
            values: allValues,
            scale: scale,
            mask: mask
        )
        trace?("sdpa_out", output)
        output = output
            .transposed(0, 2, 1, 3)
            .reshaped([batch, length, numHeads * headDim])
        let gated = output * MLX.sigmoid(gate)
        trace?("o_proj_in", gated)
        let attentionOutput = weights.oProj.apply(gated)
        trace?("attn_out", attentionOutput)
        return attentionOutput
    }

    /// Rotates the first `rotaryDim` dimensions (interleaved pairs) and
    /// passes the remaining dimensions through unchanged.
    /// Matches upstream `nn.RoPE(dims=rotaryDim, traditional=False)` /
    /// `mx.fast.rope(..., traditional=False)`: the two halves of the rotary
    /// span are paired with stride `rotaryDim / 2` (NOT interleaved pairs).
    static func partialRoPE(
        _ x: MLXArray,
        offset: Int,
        rotaryDim: Int,
        theta: Float
    ) -> MLXArray {
        let headDim = x.dim(3)
        guard rotaryDim > 0, rotaryDim <= headDim, rotaryDim % 2 == 0 else {
            return x
        }
        let half = rotaryDim / 2
        let positions = MLX.arange(x.dim(2)).asType(.float32) + Float(offset)
        let frequencies = MLX.pow(
            MLXArray(theta),
            -MLX.arange(half, dtype: .float32) * (2 / Float(rotaryDim))
        )
        let angles = positions.expandedDimensions(axis: -1)
            * frequencies.expandedDimensions(axis: 0)
        // Upstream `mx.fast.rope` computes the rotation in float32 and rounds
        // once to the input dtype; casting cos/sin to bf16 first would leave
        // a ~1 ulp rotation residual.
        let cosines = MLX.cos(angles)
        let sines = MLX.sin(angles)
        let rotary = x[0..., 0..., 0..., ..<rotaryDim].asType(.float32)
        let first = rotary[0..., 0..., 0..., ..<half]
        let second = rotary[0..., 0..., 0..., half..<rotaryDim]
        let rotated = MLX.concatenated(
            [
                first * cosines - second * sines,
                first * sines + second * cosines,
            ],
            axis: -1
        ).asType(x.dtype)
        if rotaryDim == headDim { return rotated }
        return MLX.concatenated(
            [rotated, x[0..., 0..., 0..., rotaryDim...]], axis: -1
        )
    }
}
