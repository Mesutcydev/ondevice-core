import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0GatheredQMMTests
//
// Proves selected-expert quantized math on the pinned MLX Swift fork before
// any model code depends on it. Uses synthetic weights with Edge0-8B's real
// projection shapes, bit width (4), and group size (64). No model weights
// involved.

final class Edge0GatheredQMMTests: XCTestCase {
    private let spec = Edge0ExpertSpec.edge0_8B
    /// Small expert count; projection geometry matches the real checkpoint.
    private let syntheticExpertCount = 4

    func testGatheredQuantizedMMMatchesDequantizedReference() throws {
        let matrices = makeSyntheticMatrices()
        let selected: [Int32] = [1, 3]
        let x = makeInput()
        let indices = MLXArray(selected, [1, 1, selected.count])

        let gathered = Edge0ExpertMath.expertForward(
            x,
            up: matrices.up,
            gate: matrices.gate,
            down: matrices.down,
            indices: indices
        )
        let reference = referenceForward(
            x,
            up: matrices.up,
            gate: matrices.gate,
            down: matrices.down,
            selected: selected
        )
        let metrics = compare(gathered, reference)

        print("[Edge0 QMM] experts=\(selected) bits=\(Edge0ExpertMath.bits) group=\(Edge0ExpertMath.groupSize) relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbsError)")
        // The gathered kernel accumulates in reduced (bf16-class) precision
        // after dequantization — the same trade-off Edge0's reference
        // documents at ~0.24% relative L2. Synthetic uniform weights are a
        // slightly harsher case; measured here at ~0.54%.
        XCTAssertLessThan(
            metrics.relativeL2,
            1e-2,
            "relative L2 must stay in the documented bf16-kernel error band"
        )
        XCTAssertLessThan(metrics.maxAbsError, 0.25)
    }

    /// Same-kernel parity: gathering expert rows must equal running the
    /// quantized matmul on each selected expert separately. This isolates
    /// selection correctness from cross-precision drift, so it can use a
    /// tight tolerance.
    func testGatheredQMMMatchesPerExpertQuantizedMM() throws {
        let matrices = makeSyntheticMatrices()
        let selected: [Int32] = [0, 2]
        let x = makeInput()
        let indices = MLXArray(selected, [1, 1, selected.count])

        let gathered = Edge0ExpertMath.gatheredProjection(
            x,
            weight: matrices.up.weight,
            scales: matrices.up.scales,
            biases: matrices.up.biases,
            indices: indices
        ).squeezed(axes: [0, 1])

        for (slot, raw) in selected.enumerated() {
            let expert = Int(raw)
            let single = MLX.quantizedMM(
                x,
                matrices.up.weight[expert],
                scales: matrices.up.scales[expert],
                biases: matrices.up.biases[expert],
                transpose: true,
                groupSize: Edge0ExpertMath.groupSize,
                bits: Edge0ExpertMath.bits,
                mode: .affine
            ).squeezed(axes: [0, 1])
            let metrics = compare(gathered[slot], single)
            print("[Edge0 QMM] per-expert quantizedMM slot=\(slot) relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbsError)")
            XCTAssertLessThan(metrics.relativeL2, 1e-3)
        }
    }

    func testSingleSelectedExpertMatchesReference() throws {
        let matrices = makeSyntheticMatrices()
        let selected: [Int32] = [2]
        let x = makeInput()
        let indices = MLXArray(selected, [1, 1, selected.count])

        let gathered = Edge0ExpertMath.expertForward(
            x, up: matrices.up, gate: matrices.gate, down: matrices.down,
            indices: indices
        )
        let reference = referenceForward(
            x, up: matrices.up, gate: matrices.gate, down: matrices.down,
            selected: selected
        )
        let metrics = compare(gathered, reference)
        print("[Edge0 QMM] single-expert relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbsError)")
        XCTAssertLessThan(metrics.relativeL2, 1e-2)
    }

    func testDifferentSelectionsProduceDifferentOutputs() throws {
        let matrices = makeSyntheticMatrices()
        let x = makeInput()

        let first = Edge0ExpertMath.expertForward(
            x, up: matrices.up, gate: matrices.gate, down: matrices.down,
            indices: MLXArray([Int32(0), Int32(1)], [1, 1, 2])
        )
        let second = Edge0ExpertMath.expertForward(
            x, up: matrices.up, gate: matrices.gate, down: matrices.down,
            indices: MLXArray([Int32(2), Int32(3)], [1, 1, 2])
        )
        let metrics = compare(first, second)
        XCTAssertGreaterThan(
            metrics.relativeL2,
            1e-3,
            "different expert selections must not collapse to the same output"
        )
    }

    func testSwappingGateAndUpChangesTheResult() throws {
        let matrices = makeSyntheticMatrices()
        let selected: [Int32] = [1, 3]
        let x = makeInput()
        let indices = MLXArray(selected, [1, 1, selected.count])

        let reference = referenceForward(
            x, up: matrices.up, gate: matrices.gate, down: matrices.down,
            selected: selected
        )
        let swapped = Edge0ExpertMath.expertForward(
            x, up: matrices.gate, gate: matrices.up, down: matrices.down,
            indices: indices
        )
        let metrics = compare(swapped, reference)
        XCTAssertGreaterThan(
            metrics.relativeL2,
            1e-2,
            "a gate/up swap must be observable"
        )
    }

    // MARK: - Synthetic model

    private struct Matrices {
        let up: Edge0ExpertQuantizedMatrix
        let gate: Edge0ExpertQuantizedMatrix
        let down: Edge0ExpertQuantizedMatrix
    }

    private func makeSyntheticMatrices() -> Matrices {
        Matrices(
            up: quantize(out: spec.expertIntermediateSize, in: spec.hiddenSize, salt: 0.10),
            gate: quantize(out: spec.expertIntermediateSize, in: spec.hiddenSize, salt: 0.37),
            down: quantize(out: spec.hiddenSize, in: spec.expertIntermediateSize, salt: 0.73)
        )
    }

    private func quantize(out: Int, in inFeatures: Int, salt: Float) -> Edge0ExpertQuantizedMatrix {
        let count = syntheticExpertCount * out * inFeatures
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            // Prime modulus so expert-sized strides (which are multiples of
            // 1024) do not alias into identical per-expert patterns.
            let base = Float((index * 6151) % 4093) / 4093.0 - 0.5
            values[index] = base * (0.75 + salt)
        }
        let weights = MLXArray(values, [syntheticExpertCount, out, inFeatures])
        let (quantized, scales, biases) = MLX.quantized(
            weights,
            groupSize: spec.quant.groupSize,
            bits: spec.quant.bits,
            mode: .affine
        )
        return Edge0ExpertQuantizedMatrix(
            weight: quantized,
            // Edge0 stores affine metadata as bf16; mirror that exactly.
            scales: scales.asType(.bfloat16),
            biases: (biases ?? scales).asType(.bfloat16)
        )
    }

    private func makeInput() -> MLXArray {
        var values = [Float](repeating: 0, count: spec.hiddenSize)
        for index in 0..<spec.hiddenSize {
            values[index] = Float((index * 17) % 251) / 251.0 - 0.5
        }
        return MLXArray(values, [1, 1, spec.hiddenSize])
    }

    private func referenceForward(
        _ x: MLXArray,
        up: Edge0ExpertQuantizedMatrix,
        gate: Edge0ExpertQuantizedMatrix,
        down: Edge0ExpertQuantizedMatrix,
        selected: [Int32]
    ) -> MLXArray {
        let dequantizedUp = Edge0ExpertMath.dequantize(up).asType(.float32)
        let dequantizedGate = Edge0ExpertMath.dequantize(gate).asType(.float32)
        let dequantizedDown = Edge0ExpertMath.dequantize(down).asType(.float32)
        let flatX = x.reshaped([1, spec.hiddenSize])

        var outputs: [MLXArray] = []
        for raw in selected {
            let expert = Int(raw)
            let upExpert = dequantizedUp[expert]
            let gateExpert = dequantizedGate[expert]
            let downExpert = dequantizedDown[expert]

            let projectedUp = MLX.matmul(flatX, upExpert.transposed(1, 0))
            let projectedGate = MLX.matmul(flatX, gateExpert.transposed(1, 0))
            let hidden = Edge0ExpertMath.swiglu(
                up: projectedUp,
                gate: projectedGate
            )
            outputs.append(MLX.matmul(hidden, downExpert.transposed(1, 0)))
        }
        return MLX.concatenated(outputs, axis: 0)
    }

    private struct Metrics {
        let relativeL2: Double
        let maxAbsError: Double
    }

    private func compare(_ lhs: MLXArray, _ rhs: MLXArray) -> Metrics {
        let lhsValues = lhs.reshaped([lhs.size]).asArray(Float.self)
        let rhsValues = rhs.reshaped([rhs.size]).asArray(Float.self)
        precondition(lhsValues.count == rhsValues.count)

        var squaredDifference = 0.0
        var squaredReference = 0.0
        var maxAbs = 0.0
        for index in 0..<lhsValues.count {
            let difference = Double(lhsValues[index] - rhsValues[index])
            let reference = Double(rhsValues[index])
            squaredDifference += difference * difference
            squaredReference += reference * reference
            maxAbs = max(maxAbs, abs(difference))
        }
        return Metrics(
            relativeL2: (squaredDifference / max(squaredReference, 1e-12)).squareRoot(),
            maxAbsError: maxAbs
        )
    }
}
