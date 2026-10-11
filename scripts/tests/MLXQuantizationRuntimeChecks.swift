import Foundation
import MLX
import MLXLMCommon

@main
struct MLXQuantizationRuntimeChecks {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() throws {
        // Exercise the pinned PrismML kernels, without downloading a model.
        // Packed matmul must agree with its own dequantized matrix, including
        // the existing Bonsai 1-bit path and Edge0-style 4-bit affine math.
        for bits in [1, 4, 8] {
            let weights = MLXRandom.normal([64, 64], key: MLXRandom.key(11))
            let input = MLXRandom.normal([1, 64], key: MLXRandom.key(12))
            let packed = quantized(weights, groupSize: 64, bits: bits)
            let output = quantizedMM(input, packed.wq, scales: packed.scales,
                                     biases: packed.biases, transpose: true,
                                     groupSize: 64, bits: bits)
            let dense = dequantized(packed.wq, scales: packed.scales,
                                   biases: packed.biases, groupSize: 64, bits: bits)
            let reference = matmul(input, dense.transposed())
            let error = MLX.abs(output - reference).max().item(Float.self)
            check(error < 1e-3, "\(bits)-bit packed matmul disagrees with dequantized reference: \(error)")
        }

        for dimension in [64, 128, 256] {
            for dtype in [DType.float16, .bfloat16] {
                try checkTurboAttention(dimension: dimension, dtype: dtype)
            }
        }

        // A legacy bounded request must remain rotating and usable when
        // quantization is requested: the new library's compatibility behavior
        // must not turn our Bonsai/Qwen35 profiles into failed generations.
        let boundedParameters = GenerateParameters(maxKVSize: 16, kvBits: 4)
        var bounded = [try makeAttentionKVCache(parameters: boundedParameters)]
        let keys = MLXArray.ones([1, 1, 32, 64], dtype: .float16)
        _ = bounded[0].update(keys: keys, values: keys)
        maybeQuantizeKVCache(cache: &bounded, kvBits: 4)
        check(bounded[0] is RotatingKVCache, "Bounded cache was replaced by quantization")
        let next = MLXArray.ones([1, 1, 1, 64], dtype: .float16)
        let result = attentionWithCacheUpdate(queries: next, keys: next, values: next,
                                              cache: bounded[0], scale: 0.125)
        check(!MLX.isNaN(result).any().item(Bool.self), "Bounded decode failed")
        check(bounded[0].state[0].dim(2) <= 16, "Rotating decode exceeded its window")
        print("\(checks) MLX runtime checks passed (synthetic Apple Silicon GPU inputs; no model-quality or iPhone-performance claim)")
    }

    private static func checkTurboAttention(dimension: Int, dtype: DType) throws {
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
        guard let turbo = cache[0] as? TurboQuantKVCache else {
            preconditionFailure("turbo8v3 did not select the TurboQuant cache")
        }
        let scale = 1 / Float(dimension).squareRoot()
        for step in 0..<4 {
            let query = MLXRandom.normal([1, 4, 1, dimension], key: MLXRandom.key(UInt64(30 + step))).asType(dtype)
            let nextKey = MLXRandom.normal([1, 2, 1, dimension], key: MLXRandom.key(UInt64(40 + step))).asType(dtype)
            let nextValue = MLXRandom.normal([1, 2, 1, dimension], key: MLXRandom.key(UInt64(50 + step))).asType(dtype)
            let output = attentionWithCacheUpdate(queries: query, keys: nextKey, values: nextValue,
                                                  cache: turbo, scale: scale)
            let expected = attentionWithCacheUpdate(queries: query, keys: nextKey, values: nextValue,
                                                    cache: reference, scale: scale)
            check(output.shape == expected.shape, "Compressed attention changed output shape")
            let delta = output.asType(.float32) - expected.asType(.float32)
            let signal = expected.asType(.float32)
            let relativeRMSE = (sqrt((delta * delta).mean()) /
                (sqrt((signal * signal).mean()) + 1e-6)).item(Float.self)
            check(relativeRMSE.isFinite && relativeRMSE < 0.35,
                  "Compressed attention failed numeric comparison: \(relativeRMSE)")
        }
        check(turbo.isCompressed, "First decode did not compress the raw prefill")
        check(turbo.offset == count + 4, "Compressed decode lost token position")
        let liveRawBytes = 2 * 2 * (count + 4) * dimension * 2
        check(turbo.memoryBytes < liveRawBytes, "Compressed cache did not reduce storage")
        check(turbo.trim(turbo.offset) == count + 4 && turbo.offset == 0,
              "Cache reset did not clear its position")
        check(turbo.memoryBytes == 0, "Cache reset retained raw or packed buffers")
    }
}
