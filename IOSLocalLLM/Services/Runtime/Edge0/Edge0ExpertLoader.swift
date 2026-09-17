import Foundation
import MLX

// MARK: - Edge0ExpertQuantizedMatrix

/// One expert's quantized projection: packed weights plus per-group affine
/// scales and biases. Shapes after the expert axis is removed:
///   weight `[out, in * bits / 32]` (u32 words)
///   scales `[out, in / groupSize]` (bf16)
///   biases `[out, in / groupSize]` (bf16)
struct Edge0ExpertQuantizedMatrix: @unchecked Sendable {
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray
}

// MARK: - Edge0ExpertWeights

/// One routed expert's full payload, in Edge0 bundle order
/// (up, gate, down — matching `_swiglu(up, gate)`).
struct Edge0ExpertWeights: @unchecked Sendable {
    let key: Edge0ExpertKey
    let up: Edge0ExpertQuantizedMatrix
    let gate: Edge0ExpertQuantizedMatrix
    let down: Edge0ExpertQuantizedMatrix
    /// Exact bytes read from the checkpoint for this expert.
    let byteSize: UInt64

    /// Every array this payload owns. Used for the explicit evaluation
    /// barrier before the payload can be cached.
    var arrays: [MLXArray] {
        [
            up.weight, up.scales, up.biases,
            gate.weight, gate.scales, gate.biases,
            down.weight, down.scales, down.biases,
        ]
    }
}

// MARK: - Edge0ExpertLoader
//
// Reads exactly the 9 tensor slices that make up one expert from the
// range-based tensor store and builds MLX arrays. Nothing else in the
// checkpoint is touched.
//
// Layer resolution happens ONCE per layer at construction (the native form
// of upstream `perf: prepare typed mmap expert reads once per layer`,
// Edge0-AI/Edge0#7): tensor names, index lookups, shape/dtype checks, name
// conformance and quantization geometry are per-LAYER facts, but the old
// loader re-derived them on every expert load — ~184 times per decoded
// token at K=8 over 23 MoE layers. The per-expert path is now: axis-0 row
// slice → pread → MLX array.
//
// MLX evaluation rule: `load` explicitly evaluates every array before
// returning. The pool never writes into an existing MLXArray's storage, so
// evicting a cached payload is a reference release, not an in-place reuse —
// an outstanding graph that still references an evicted payload keeps its
// arrays alive and cannot observe corruption. Explicit evaluation here also
// keeps the first decode step from paying the dequantization lazily.

struct Edge0ExpertLoader: Sendable {
    let stores: Edge0TensorStoreSet
    let layout: Edge0ExpertLayout
    private let layerLocations: [Int: Edge0ExpertLayerLocations]

    /// Resolves and validates every expert layer once (names, shapes,
    /// dtypes, name conformance, quantization geometry), so a malformed
    /// checkpoint fails at model load rather than mid-generation, and the
    /// per-expert path is reduced to axis-0 row slices.
    init(
        index: Edge0SafetensorsIndex,
        stores: Edge0TensorStoreSet,
        layout: Edge0ExpertLayout = Edge0ExpertLayout()
    ) throws {
        var resolved: [Int: Edge0ExpertLayerLocations] = [:]
        for layer in layout.spec.firstExpertLayer...layout.spec.lastExpertLayer {
            let locations = try layout.layerLocations(for: layer, in: index)
            try layout.validateQuantizationGeometry(locations)
            resolved[layer] = locations
        }
        self.stores = stores
        self.layout = layout
        self.layerLocations = resolved
    }

    func load(_ key: Edge0ExpertKey) async throws -> Edge0ExpertWeights {
        guard let locations = layerLocations[key.layer] else {
            throw Edge0ExpertLayoutError.layerOutOfRange(key.layer)
        }
        guard key.expert >= 0, key.expert < layout.spec.numExperts else {
            throw Edge0ExpertLayoutError.expertOutOfRange(
                layer: key.layer, expert: key.expert
            )
        }
        let bundle = locations.bundle(for: key)

        async let upMatrix = loadMatrix(bundle.up, expert: key.expert)
        async let gateMatrix = loadMatrix(bundle.gate, expert: key.expert)
        async let downMatrix = loadMatrix(bundle.down, expert: key.expert)

        let weights = Edge0ExpertWeights(
            key: key,
            up: try await upMatrix,
            gate: try await gateMatrix,
            down: try await downMatrix,
            byteSize: locations.perExpertBytes
        )
        MLX.eval(weights.arrays)
        return weights
    }

    private func loadMatrix(
        _ projection: Edge0ExpertProjectionLocation,
        expert: Int
    ) async throws -> Edge0ExpertQuantizedMatrix {
        let weightRow = try projection.weight.row(expert)
        let scalesRow = try projection.scales.row(expert)
        let biasesRow = try projection.biases.row(expert)

        async let weightBytes = stores.read(weightRow)
        async let scaleBytes = stores.read(scalesRow)
        async let biasBytes = stores.read(biasesRow)

        let (weight, scales, biases) = try await (weightBytes, scaleBytes, biasBytes)
        return Edge0ExpertQuantizedMatrix(
            weight: MLXArray(
                weight.bytes,
                Array(weightRow.shape),
                dtype: .uint32
            ),
            scales: MLXArray(
                scales.bytes,
                Array(scalesRow.shape),
                dtype: .bfloat16
            ),
            biases: MLXArray(
                biases.bytes,
                Array(biasesRow.shape),
                dtype: .bfloat16
            )
        )
    }
}
