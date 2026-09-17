import Foundation
import MLX

// MARK: - Edge0LinearMath

enum Edge0LinearMath {
    /// `x @ weight.T` for an unquantized weight `[out, in]`.
    static func linear(_ x: MLXArray, weight: MLXArray) -> MLXArray {
        MLX.matmul(x, weight.transposed(1, 0))
    }

    /// RMSNorm via the same fused MLX kernel upstream `nn.RMSNorm` uses
    /// (`mx.fast.rms_norm`, 32-bit accumulation).
    static func rmsNorm(
        _ x: MLXArray,
        weight: MLXArray,
        eps: Float
    ) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }

    static func silu(_ x: MLXArray) -> MLXArray {
        x * MLX.sigmoid(x)
    }
}

// MARK: - Edge0MLAAttentionWeights

struct Edge0MLAAttentionWeights: @unchecked Sendable {
    let qAProj: Edge0LinearWeight?
    let qALayernorm: MLXArray?
    let qBProj: Edge0LinearWeight?
    let directQProj: Edge0LinearWeight?
    let kvAProjWithMQA: Edge0LinearWeight
    let kvALayernorm: MLXArray
    let kvBProj: Edge0LinearWeight
    let dense: Edge0LinearWeight
    let gProj: Edge0LinearWeight?
}

// MARK: - Edge0MLAState

/// Per-layer, per-generation MLA cache matching upstream mlx-lm `KVCache`
/// semantics (appended keys/values plus an absolute-position offset).
///   keys:   `[B, heads, offset, qkNopeHeadDim + qkRopeHeadDim]`
///   values: `[B, heads, offset, vHeadDim]`
struct Edge0MLAState: @unchecked Sendable {
    var keys: MLXArray?
    var values: MLXArray?
    var offset: Int = 0

    static let empty = Edge0MLAState()
}

// MARK: - Edge0MLAAttention
//
// Exact port of upstream `BailingMLA` (DeepSeek-style latent attention plus
// the V3 head-wise output gate):
//
//   q  = q_b_proj(q_a_layernorm(q_a_proj(x)))        (q_lora_rank path)
//   kv_latent, k_pe = split(kv_a_proj_with_mqa(x))
//   kv_latent = kv_a_layernorm(kv_latent)
//   k_nope, v = split(kv_b_proj(kv_latent))
//   RoPE: interleaved, positions = arange(L) + cache offset
//   out = SDPA(concat(q_nope, rotated q_pe), concat(k_nope, broadcast k_pe), v)
//   head-wise gate: out_h *= sigmoid(g_proj(x))_h
//   out = dense(out)

struct Edge0MLAAttention: Sendable {
    let numHeads: Int
    let qkNopeHeadDim: Int
    let qkRopeHeadDim: Int
    let vHeadDim: Int
    let kvLoraRank: Int
    let qLoraRank: Int?
    let scale: Float
    let gateKind: String
    let ropeTheta: Float
    let eps: Float
    let weights: Edge0MLAAttentionWeights

    var qkHeadDim: Int { qkNopeHeadDim + qkRopeHeadDim }

    /// Stateless convenience for tests/fixtures (fresh cache, causal prefill).
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var state = Edge0MLAState.empty
        return callAsFunction(x, state: &state)
    }

    func callAsFunction(
        _ x: MLXArray,
        state: inout Edge0MLAState
    ) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)

        let qProjected: MLXArray
        if let qA = weights.qAProj,
           let qANorm = weights.qALayernorm,
           let qB = weights.qBProj {
            qProjected = qB.apply(
                Edge0LinearMath.rmsNorm(
                    qA.apply(x),
                    weight: qANorm,
                    eps: eps
                )
            )
        } else if let direct = weights.directQProj {
            qProjected = direct.apply(x)
        } else {
            preconditionFailure("Edge0MLA requires a q projection")
        }
        let q = qProjected
            .reshaped([batch, length, numHeads, qkHeadDim])
            .transposed(0, 2, 1, 3)
        let qParts = q.split(indices: [qkNopeHeadDim], axis: -1)
        let qNope = qParts[0]
        var qPe = qParts[1]

        let compressed = weights.kvAProjWithMQA.apply(x)
        let kvParts = compressed.split(indices: [kvLoraRank], axis: -1)
        let kvLatent = Edge0LinearMath.rmsNorm(
            kvParts[0],
            weight: weights.kvALayernorm,
            eps: eps
        )
        var kPe = kvParts[1]
            .reshaped([batch, length, 1, qkRopeHeadDim])
            .transposed(0, 2, 1, 3)

        let kv = weights.kvBProj.apply(kvLatent)
            .reshaped([batch, length, numHeads, qkNopeHeadDim + vHeadDim])
            .transposed(0, 2, 1, 3)
        let kvSplit = kv.split(indices: [qkNopeHeadDim], axis: -1)
        let kNope = kvSplit[0]
        let values = kvSplit[1]

        // Absolute positions continue across decode steps.
        let positions = MLX.arange(length).asType(.float32)
            + Float(state.offset)
        qPe = Self.ropeInterleave(qPe, positions: positions, theta: ropeTheta)
        kPe = Self.ropeInterleave(kPe, positions: positions, theta: ropeTheta)
        let kPeBroadcast = MLX.broadcast(
            kPe,
            to: [batch, numHeads, length, qkRopeHeadDim]
        )

        let queries = MLX.concatenated([qNope, qPe], axis: -1)
        let newKeys = MLX.concatenated([kNope, kPeBroadcast], axis: -1)

        // Cache append, matching mlx-lm KVCache (concatenate along sequence).
        let allKeys: MLXArray
        let allValues: MLXArray
        if let cachedKeys = state.keys, let cachedValues = state.values {
            allKeys = MLX.concatenated([cachedKeys, newKeys], axis: 2)
            allValues = MLX.concatenated([cachedValues, values], axis: 2)
        } else {
            allKeys = newKeys
            allValues = values
        }
        state.keys = allKeys
        state.values = allValues
        state.offset += length

        // Upstream `create_attention_mask`: causal for multi-token prefill,
        // none for cached single-token decode. (Chunked prefill over an
        // existing cache would need an offset-aware mask and is not used.)
        let mask: MLXFast.ScaledDotProductAttentionMaskMode =
            length > 1 ? .causal : .none
        var out = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: allKeys,
            values: allValues,
            scale: scale,
            mask: mask
        )
        out = out
            .transposed(0, 2, 1, 3)
            .reshaped([batch, length, numHeads * vHeadDim])

        if gateKind == "head_wise", let gProj = weights.gProj {
            let gate = MLX.sigmoid(gProj.apply(x))
            out = out.reshaped([batch, length, numHeads, vHeadDim])
                * gate.expandedDimensions(axis: -1)
            out = out.reshaped([batch, length, numHeads * vHeadDim])
        } else if gateKind == "element_wise", let gProj = weights.gProj {
            out = out * MLX.sigmoid(gProj.apply(x))
        }
        return weights.dense.apply(out)
    }

    // MARK: - RoPE

    /// Upstream `_rope_interleave_torch`:
    /// `freqs = 1/theta^(arange(0,D,2)/D)`, `emb = cat(freqs,freqs)`,
    /// rotate consecutive pairs, `out = xi*cos + rotate_half(xi)*sin`.
    static func ropeInterleave(
        _ x: MLXArray,
        positions: MLXArray,
        theta: Float
    ) -> MLXArray {
        let batch = x.dim(0)
        let heads = x.dim(1)
        let length = x.dim(2)
        let dimension = x.dim(3)
        let half = dimension / 2

        let exponents = MLX.arange(0, dimension / 2)
            .asType(.float32) * 2 / Float(dimension)
        let freqs = 1.0 / MLX.pow(MLXArray(theta), exponents)
        let angles = positions.reshaped([length, 1])
            * freqs.reshaped([1, half])
        let emb = MLX.concatenated([angles, angles], axis: -1)
        let cos = MLX.cos(emb).reshaped([1, 1, length, dimension])
        let sin = MLX.sin(emb).reshaped([1, 1, length, dimension])

        let interleaved = x
            .reshaped([batch, heads, length, half, 2])
            .transposed(0, 1, 2, 4, 3)
            .reshaped([batch, heads, length, dimension])
        let rotatedHalf = MLX.concatenated(
            [-interleaved[.ellipsis, half...], interleaved[.ellipsis, ..<half]],
            axis: -1
        )
        return interleaved * cos + rotatedHalf * sin
    }
}

// MARK: - Edge0MLP

/// Dense SwiGLU MLP used by the shared expert and the dense layer-0 block:
/// `down(silu(gate(x)) * up(x))`.
struct Edge0MLP: @unchecked Sendable {
    let gateProj: Edge0LinearWeight
    let upProj: Edge0LinearWeight
    let downProj: Edge0LinearWeight

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let gate = gateProj.apply(x)
        let up = upProj.apply(x)
        return downProj.apply(Edge0LinearMath.silu(gate) * up)
    }
}
