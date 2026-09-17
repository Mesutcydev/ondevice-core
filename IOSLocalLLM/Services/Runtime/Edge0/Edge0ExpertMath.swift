import Foundation
import MLX

// MARK: - Edge0ExpertMath
//
// Gathered quantized expert math on the pinned MLX Swift fork.
//
// The Python reference calls `mx.gather_qmm(x, w, scales, biases,
// rhs_indices=..., transpose=True, group_size=64, bits=4, mode="affine")`.
// mlx-swift exposes the same kernel as `MLX.gatherQuantizedMM`, used
// identically here — no wrapper, fork, or dependency change is needed.

enum Edge0ExpertMath {
    static let bits = 4
    static let groupSize = 64
    static let mode: QuantizationMode = .affine

    /// Quantized matmul over the subset of experts named by `indices`.
    /// - Parameters:
    ///   - x: input with a trailing feature dimension
    ///   - weight: `[numExperts, out, in * bits / 32]` u32
    ///   - scales: `[numExperts, out, in / groupSize]`
    ///   - biases: `[numExperts, out, in / groupSize]`
    ///   - indices: expert ids gathered along the expert axis
    static func gatheredProjection(
        _ x: MLXArray,
        weight: MLXArray,
        scales: MLXArray,
        biases: MLXArray?,
        indices: MLXArray,
        groupSize: Int = Edge0ExpertMath.groupSize,
        bits: Int = Edge0ExpertMath.bits,
        mode: QuantizationMode = Edge0ExpertMath.mode,
        sortedIndices: Bool = false
    ) -> MLXArray {
        MLX.gatherQuantizedMM(
            x,
            weight,
            scales: scales,
            biases: biases,
            rhsIndices: indices,
            transpose: true,
            groupSize: groupSize,
            bits: bits,
            mode: mode,
            sortedIndices: sortedIndices
        )
    }

    /// `silu(x) = x * sigmoid(x)` (MLXNN's activation, inlined so the math
    /// helper only needs the `MLX` module).
    static func silu(_ x: MLXArray) -> MLXArray {
        x * MLX.sigmoid(x)
    }

    /// Edge0 upstream parity: `_swiglu(up, gate) = silu(gate) * up`.
    static func swiglu(up: MLXArray, gate: MLXArray) -> MLXArray {
        silu(gate) * up
    }

    /// One routed expert's full FFN for the selected indices.
    static func expertForward(
        _ x: MLXArray,
        up: Edge0ExpertQuantizedMatrix,
        gate: Edge0ExpertQuantizedMatrix,
        down: Edge0ExpertQuantizedMatrix,
        indices: MLXArray
    ) -> MLXArray {
        let projectedUp = gatheredProjection(
            x, weight: up.weight, scales: up.scales, biases: up.biases,
            indices: indices
        )
        let projectedGate = gatheredProjection(
            x, weight: gate.weight, scales: gate.scales, biases: gate.biases,
            indices: indices
        )
        let hidden = swiglu(up: projectedUp, gate: projectedGate)
        return gatheredProjection(
            hidden, weight: down.weight, scales: down.scales, biases: down.biases,
            indices: indices
        )
    }

    /// Upstream `SwitchGLU` layout: expand a `[B,T,D]` input by two
    /// singleton axes so gather_qmm produces `[B,T,K,1,out]`.
    static func switchGLUExpandedInput(_ x: MLXArray) -> MLXArray {
        x.expandedDimensions(axes: [-2, -3])
    }

    /// One routed expert FFN in upstream SwitchGLU layout:
    /// expand once, gather up/gate, swiglu, gather down, squeeze.
    static func switchGLUExpertForward(
        _ x: MLXArray,
        up: Edge0ExpertQuantizedMatrix,
        gate: Edge0ExpertQuantizedMatrix,
        down: Edge0ExpertQuantizedMatrix,
        indices: MLXArray
    ) -> MLXArray {
        let expanded = switchGLUExpandedInput(x)
        let projectedUp = gatheredProjection(
            expanded, weight: up.weight, scales: up.scales, biases: up.biases,
            indices: indices
        )
        let projectedGate = gatheredProjection(
            expanded, weight: gate.weight, scales: gate.scales, biases: gate.biases,
            indices: indices
        )
        let hidden = swiglu(up: projectedUp, gate: projectedGate)
        return gatheredProjection(
            hidden, weight: down.weight, scales: down.scales, biases: down.biases,
            indices: indices
        ).squeezed(axis: -2)
    }

    /// Dequantizes a stored expert matrix back to floating point. Used by
    /// tests as the parity reference and available to diagnostics.
    static func dequantize(
        _ matrix: Edge0ExpertQuantizedMatrix,
        groupSize: Int = Edge0ExpertMath.groupSize,
        bits: Int = Edge0ExpertMath.bits,
        mode: QuantizationMode = Edge0ExpertMath.mode
    ) -> MLXArray {
        MLX.dequantized(
            matrix.weight,
            scales: matrix.scales,
            biases: matrix.biases,
            groupSize: groupSize,
            bits: bits,
            mode: mode
        )
    }
}
