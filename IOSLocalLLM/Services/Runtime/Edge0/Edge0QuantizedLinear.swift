import Foundation
import MLX

// MARK: - Edge0QuantizedLinearWeights

/// Stored 4-bit affine quantized linear weights, exactly as the Edge0-8B
/// checkpoint ships them:
///   weight `[out, in * bits / 32]` U32
///   scales `[out, in / groupSize]` BF16
///   biases `[out, in / groupSize]` BF16
/// Resident tensors stay in this form; they are never globally dequantized.
struct Edge0QuantizedLinearWeights: @unchecked Sendable {
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray
    let groupSize: Int
    let bits: Int
    let mode: QuantizationMode

    var inputDims: Int {
        Int(weight.dim(1)) * 32 / max(1, bits)
    }

    var outputDims: Int {
        weight.dim(0)
    }
}

// MARK: - Edge0QuantizedLinear

/// Quantized matrix multiplication via the pinned `MLX.quantizedMM`
/// (`mlx_quantized_matmul`), `transpose = true`, matching upstream
/// `nn.QuantizedLinear.__call__`.
struct Edge0QuantizedLinear: Sendable {
    let weights: Edge0QuantizedLinearWeights

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLX.quantizedMM(
            x,
            weights.weight,
            scales: weights.scales,
            biases: weights.biases,
            transpose: true,
            groupSize: weights.groupSize,
            bits: weights.bits,
            mode: weights.mode
        )
    }
}

// MARK: - Edge0QuantizedEmbedding

/// Upstream `nn.QuantizedEmbedding.__call__` semantics: **gather the
/// quantized rows first, then dequantize only those rows**. The full
/// `[vocab, hidden]` matrix is never dequantized.
struct Edge0QuantizedEmbedding: Sendable {
    let weights: Edge0QuantizedLinearWeights

    func callAsFunction(_ tokenIDs: MLXArray) -> MLXArray {
        let rows = MLX.take(weights.weight, tokenIDs, axis: 0)
        let scales = MLX.take(weights.scales, tokenIDs, axis: 0)
        let biases = MLX.take(weights.biases, tokenIDs, axis: 0)
        return MLX.dequantized(
            rows,
            scales: scales,
            biases: biases,
            groupSize: weights.groupSize,
            bits: weights.bits,
            mode: weights.mode
        )
    }

    /// Tied-head path: uses the embedding matrix as a quantized linear.
    func asLinear(_ x: MLXArray) -> MLXArray {
        Edge0QuantizedLinear(weights: weights)(x)
    }
}

// MARK: - Edge0LinearWeight
//
// One resolved linear weight: either an unquantized BF16 array (conv,
// routers, norms and tiny test fixtures) or stored-quantized weights. The
// hot path never inspects dtypes; the case is resolved at model load.

enum Edge0LinearWeight: @unchecked Sendable {
    case dense(MLXArray)
    case quantized(Edge0QuantizedLinearWeights)

    func apply(_ x: MLXArray) -> MLXArray {
        switch self {
        case .dense(let weight):
            return Edge0LinearMath.linear(x, weight: weight)
        case .quantized(let weights):
            return Edge0QuantizedLinear(weights: weights)(x)
        }
    }
}
