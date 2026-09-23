import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0QuantizedResidentTests
//
// Synthetic and real-checkpoint parity for the quantized resident spine:
//   • Edge0QuantizedLinear  (MLX.quantizedMM, 4-bit affine, group 64)
//   • Edge0QuantizedEmbedding (gather rows, then dequantize)
//   • lm_head full logits (top-20 identity + argmax)
//
// Real-weight tests require EDGE0_8B_MODEL and the oracle fixture
// (scripts/edge0_reference_dump.py --cases real); they skip otherwise.

final class Edge0QuantizedResidentTests: Edge0MLXTestCase {

    // MARK: - Synthetic

    func testSyntheticQuantizedLinearMatchesDequantizedReference() throws {
        let outDims = 128
        let inDims = 256
        var values = [Float](repeating: 0, count: outDims * inDims)
        for index in 0..<values.count {
            values[index] = Float((index * 7919) % 4093) / 4093.0 - 0.5
        }
        let weights = MLXArray(values, [outDims, inDims])
        let (packed, scales, biasesOptional) = MLX.quantized(
            weights,
            groupSize: 64,
            bits: 4,
            mode: .affine
        )
        let biases = try XCTUnwrap(biasesOptional)

        var inputValues = [Float](repeating: 0, count: 3 * inDims)
        for index in 0..<inputValues.count {
            inputValues[index] = Float((index * 131) % 509) / 509.0 - 0.5
        }
        let x = MLXArray(inputValues, [3, inDims])

        let linear = Edge0QuantizedLinear(weights: Edge0QuantizedLinearWeights(
            weight: packed,
            scales: scales,
            biases: biases,
            groupSize: 64,
            bits: 4,
            mode: .affine
        ))
        let actual = linear(x)
        let reference = MLX.matmul(
            x,
            MLX.dequantized(
                packed,
                scales: scales,
                biases: biases,
                groupSize: 64,
                bits: 4,
                mode: .affine
            ).transposed(1, 0)
        )
        let metrics = compare(actual, reference)
        print("[Edge0 resident] synthetic quantized linear relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbs)")
        XCTAssertLessThan(metrics.relativeL2, 1e-2)
        XCTAssertLessThan(metrics.maxAbs, 0.05)
    }

    // MARK: - Real checkpoint

    func testRealQuantizedLinearMatchesUpstream() async throws {
        let context = try realContext()
        let qw = try await context.fixture.tensor("q_b_proj.weight")
        let qs = try await context.fixture.tensor("q_b_proj.scales")
        let qb = try await context.fixture.tensor("q_b_proj.biases")
        let x = try await context.fixture.tensor("quant_input")
        let expected = try await context.fixture.tensor("quant_output")

        let linear = Edge0QuantizedLinear(weights: Edge0QuantizedLinearWeights(
            weight: qw,
            scales: qs,
            biases: qb,
            groupSize: 64,
            bits: 4,
            mode: .affine
        ))
        let actual = linear(x)
        let metrics = compare(actual, expected)
        print("[Edge0 resident] real q_b_proj relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbs)")
        XCTAssertLessThan(metrics.relativeL2, 1e-4)
        XCTAssertLessThan(metrics.maxAbs, 1e-3)
    }

    func testRealQuantizedEmbeddingMatchesUpstream() async throws {
        let context = try realContext()
        let weights = try await context.realTensor("model.word_embeddings.weight")
        XCTAssertEqual(weights.dtype, .uint32)
        let scales = try await context.realTensor("model.word_embeddings.scales")
        let biases = try await context.realTensor("model.word_embeddings.biases")
        let ids = try await context.fixture.tensor("embed_ids")
        let expected = try await context.fixture.tensor("embed_output")

        let embedding = Edge0QuantizedEmbedding(weights: Edge0QuantizedLinearWeights(
            weight: weights,
            scales: scales,
            biases: biases,
            groupSize: 64,
            bits: 4,
            mode: .affine
        ))
        let actual = embedding(ids)
        let metrics = compare(actual, expected)
        print("[Edge0 resident] real embedding rows relL2=\(metrics.relativeL2) maxAbs=\(metrics.maxAbs)")
        XCTAssertLessThan(metrics.relativeL2, 1e-5)
        XCTAssertLessThan(metrics.maxAbs, 1e-3)
    }

    func testRealLMHeadTopLogitsMatchUpstream() async throws {
        let context = try realContext()
        let weights = try await context.realTensor("lm_head.weight")
        let scales = try await context.realTensor("lm_head.scales")
        let biases = try await context.realTensor("lm_head.biases")
        let hidden = try await context.fixture.tensor("lm_hidden")
        let expectedIndices = try await context.fixture.tensor("lm_top_indices")
        let expectedValues = try await context.fixture.tensor("lm_top_values")
        let expectedArgmax = try await context.fixture.tensor("lm_argmax")

        let head = Edge0QuantizedLinear(weights: Edge0QuantizedLinearWeights(
            weight: weights,
            scales: scales,
            biases: biases,
            groupSize: 64,
            bits: 4,
            mode: .affine
        ))
        let logits = head(hidden).asType(.float32)
        XCTAssertEqual(logits.dim(1), 157_184)

        let order = MLX.argPartition(-logits, kth: 19, axis: -1)[.ellipsis, ..<20]
        let topValues = MLX.takeAlong(logits, order, axis: -1)
        let argmax = MLX.argMax(logits, axis: -1)

        let actualOrder = order.asType(.int32).asArray(Int32.self)
        let expectedOrder = expectedIndices.asType(.int32).asArray(Int32.self)
        XCTAssertEqual(actualOrder, expectedOrder, "top-20 token identity")

        let valueMetrics = compare(topValues, expectedValues)
        print("[Edge0 resident] real lm_head top-20 relL2=\(valueMetrics.relativeL2) maxAbs=\(valueMetrics.maxAbs)")
        XCTAssertLessThan(valueMetrics.relativeL2, 1e-4)
        XCTAssertEqual(
            argmax.asType(.int32).asArray(Int32.self),
            expectedArgmax.asType(.int32).asArray(Int32.self)
        )
    }

    // MARK: - Context

    private struct FixtureContext: @unchecked Sendable {
        let directory: URL
        let index: Edge0SafetensorsIndex
        let stores: Edge0TensorStoreSet
        let loader: Edge0ResidentTensorLoader

        func tensor(_ name: String) async throws -> MLXArray {
            try await loader.load(index.location(name))
        }

        func location(_ name: String) throws -> Edge0TensorLocation {
            try index.location(name)
        }
    }

    private struct RealContext {
        let realIndex: Edge0SafetensorsIndex
        let realLoader: Edge0ResidentTensorLoader
        let fixture: FixtureContext

        func realTensor(_ name: String) async throws -> MLXArray {
            try await realLoader.load(realIndex.location(name))
        }
    }

    private func realContext() throws -> RealContext {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let modelURL = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("model.safetensors")
        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("real_tiny.safetensors")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("real fixture not found at \(fixtureURL.path)")
        }

        let index = try Edge0SafetensorsIndex.openSingleFile(at: modelURL)
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let stores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: modelDirectory),
            shardNames: ["model.safetensors"]
        )
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["real_tiny.safetensors"]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)
        let context = FixtureContext(
            directory: URL(fileURLWithPath: fixtureDirectory),
            index: fixtureIndex,
            stores: fixtureStores,
            loader: Edge0ResidentTensorLoader(
                index: fixtureIndex,
                stores: fixtureStores
            )
        )
        return RealContext(realIndex: index, realLoader: loader, fixture: context)
    }

    // MARK: - Metrics

    private struct Metrics {
        let relativeL2: Double
        let maxAbs: Double
    }

    private func compare(_ actual: MLXArray, _ expected: MLXArray) -> Metrics {
        let a = actual.asType(.float32).asArray(Float.self)
        let e = expected.asType(.float32).asArray(Float.self)
        precondition(a.count == e.count, "shape mismatch \(actual.shape) vs \(expected.shape)")
        var squaredDifference = 0.0
        var squaredReference = 0.0
        var maxAbs = 0.0
        for index in 0..<a.count {
            let difference = Double(a[index] - e[index])
            squaredDifference += difference * difference
            squaredReference += Double(e[index]) * Double(e[index])
            maxAbs = max(maxAbs, abs(difference))
        }
        return Metrics(
            relativeL2: (squaredDifference / max(squaredReference, 1e-12)).squareRoot(),
            maxAbs: maxAbs
        )
    }
}
