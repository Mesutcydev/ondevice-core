import XCTest
import MLX
import MLXLMCommon
@testable import IOSLocalLLM

/// Small synthetic inputs exercise the shipping kernels on a physical iPhone.
/// No model weights, downloads, or user prompts are involved. All GPU work
/// shares the production generation gate with any work already in progress.
final class MLXQuantizationRuntimeTests: XCTestCase {
    func testBonsaiOneBitAndExistingAffineMatmul() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX GPU checks require a physical device")
        #else
        try await MLXGenerationGate.shared.run {
            defer { mlxClearCache() }
            for bits in [1, 4, 8] {
                let weights = MLXRandom.normal([64, 64], key: MLXRandom.key(11))
                let input = MLXRandom.normal([1, 64], key: MLXRandom.key(12))
                let packed = quantized(weights, groupSize: 64, bits: bits)
                let output = quantizedMM(input, packed.wq, scales: packed.scales,
                                         biases: packed.biases, transpose: true,
                                         groupSize: 64, bits: bits)
                let dense = dequantized(packed.wq, scales: packed.scales,
                                       biases: packed.biases, groupSize: 64, bits: bits)
                let error = MLX.abs(output - matmul(input, dense.transposed()))
                    .max().item(Float.self)
                XCTAssertLessThan(error, 1e-3, "\(bits)-bit packed matmul parity")
            }
        }
        #endif
    }

    func testTurboAttentionDecodeAndReset() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX GPU checks require a physical device")
        #else
        try await MLXGenerationGate.shared.run {
            defer { mlxClearCache() }
            for dimension in [64, 128, 256] {
                for dtype in [DType.float16, .bfloat16] {
                    try Self.verifyTurboAttention(dimension: dimension, dtype: dtype)
                }
            }
        }
        #endif
    }

    func testBoundedCacheKeepsRotatingBehavior() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX GPU checks require a physical device")
        #else
        try await MLXGenerationGate.shared.run {
            defer { mlxClearCache() }
            let parameters = GenerateParameters(maxKVSize: 16, kvBits: 4)
            var cache = [try makeAttentionKVCache(parameters: parameters)]
            let keys = MLXArray.ones([1, 1, 32, 64], dtype: .float16)
            _ = cache[0].update(keys: keys, values: keys)
            maybeQuantizeKVCache(cache: &cache, kvBits: 4)
            XCTAssertTrue(cache[0] is RotatingKVCache)
            let next = MLXArray.ones([1, 1, 1, 64], dtype: .float16)
            let result = attentionWithCacheUpdate(queries: next, keys: next, values: next,
                                                  cache: cache[0], scale: 0.125)
            XCTAssertFalse(MLX.isNaN(result).any().item(Bool.self))
            XCTAssertLessThanOrEqual(cache[0].state[0].dim(2), 16)
        }
        #endif
    }

    private static func verifyTurboAttention(dimension: Int, dtype: DType) throws {
        let count = 1_024
        let keys = MLXRandom.normal([1, 2, count, dimension], key: MLXRandom.key(21)).asType(dtype)
        let values = MLXRandom.normal([1, 2, count, dimension], key: MLXRandom.key(22)).asType(dtype)
        let parameters = GenerateParameters(kvScheme: "turbo8v3")
        var cache = [try makeAttentionKVCache(parameters: parameters)]
        let reference = KVCacheSimple()
        _ = cache[0].update(keys: keys, values: values)
        _ = reference.update(keys: keys, values: values)
        maybeQuantizeKVCache(cache: &cache, kvBits: parameters.kvBits,
                            kvScheme: parameters.kvScheme)
        let turbo = try XCTUnwrap(cache[0] as? TurboQuantKVCache)
        let scale = 1 / Float(dimension).squareRoot()
        for step in 0..<4 {
            let query = MLXRandom.normal([1, 4, 1, dimension], key: MLXRandom.key(UInt64(30 + step))).asType(dtype)
            let nextKey = MLXRandom.normal([1, 2, 1, dimension], key: MLXRandom.key(UInt64(40 + step))).asType(dtype)
            let nextValue = MLXRandom.normal([1, 2, 1, dimension], key: MLXRandom.key(UInt64(50 + step))).asType(dtype)
            let output = attentionWithCacheUpdate(queries: query, keys: nextKey, values: nextValue,
                                                  cache: turbo, scale: scale)
            let expected = attentionWithCacheUpdate(queries: query, keys: nextKey, values: nextValue,
                                                    cache: reference, scale: scale)
            XCTAssertEqual(output.shape, expected.shape)
            let delta = output.asType(.float32) - expected.asType(.float32)
            let signal = expected.asType(.float32)
            let relativeRMSE = (sqrt((delta * delta).mean()) /
                (sqrt((signal * signal).mean()) + 1e-6)).item(Float.self)
            XCTAssertTrue(relativeRMSE.isFinite)
            XCTAssertLessThan(relativeRMSE, 0.35, "\(dimension)/\(dtype) compressed attention parity")
        }
        XCTAssertTrue(turbo.isCompressed)
        XCTAssertEqual(turbo.offset, count + 4)
        XCTAssertLessThan(turbo.memoryBytes, 2 * 2 * (count + 4) * dimension * 2)
        XCTAssertEqual(turbo.trim(turbo.offset), count + 4)
        XCTAssertEqual(turbo.offset, 0)
        XCTAssertEqual(turbo.memoryBytes, 0)
    }
}
