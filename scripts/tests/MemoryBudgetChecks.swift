import Foundation

@main
struct MemoryBudgetChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() throws {
        let exhausted = ProcessMemoryBudget.resolve(footprint: 6_000, kernelHeadroom: 0, fallbackCeiling: 9_000, platformCap: 8_500)
        check(exhausted.available == 0 && exhausted.ceiling == 6_000, "Zero kernel headroom must not invoke a fallback")
        let loaded = ProcessMemoryBudget.resolve(footprint: 2_000, kernelHeadroom: 4_000, fallbackCeiling: 9_000, platformCap: 8_500)
        check(loaded.available == 4_000 && loaded.ceiling == 6_000, "Already resident allocations must be charged once")
        let capped = ProcessMemoryBudget.resolve(footprint: 2_000, kernelHeadroom: 9_000, fallbackCeiling: 9_000, platformCap: 8_500)
        check(capped.available == 6_500, "Platform cap must bound live headroom")
        let overCap = ProcessMemoryBudget.resolve(footprint: 9_000, kernelHeadroom: 500, fallbackCeiling: 9_000, platformCap: 8_500)
        check(overCap.available == 0, "A footprint above the platform cap has no headroom")
        let missing = ProcessMemoryBudget.resolve(footprint: nil, kernelHeadroom: 4_000, fallbackCeiling: 9_000, platformCap: 8_500)
        check(missing.available == 0, "Failed task_info must not pretend the app has no allocations")
        let unsupported = ProcessMemoryBudget.resolve(footprint: 1_000, kernelHeadroom: nil, fallbackCeiling: 7_000, platformCap: 8_500)
        check(unsupported.available == 6_000, "Only unavailable APIs may use the fallback")
        check(MemoryBytes.add(.max, 1) == .max, "Byte sums saturate")
        check(MemoryBytes.count(.infinity) == .max, "Non-finite sizes refuse")
        check(MemoryBytes.count(Double(Int64.max)) == .max, "Int64 floating-point boundary cannot trap")
        check(MemoryBytes.required(peak: 0, reserve: 500, unknownFloor: 3_500) == 4_000, "Unknown weights use a floor")
        for footprint in stride(from: Int64(0), through: 10_000, by: 100) {
            let budget = ProcessMemoryBudget.resolve(footprint: footprint, kernelHeadroom: 1_000, fallbackCeiling: 9_000, platformCap: 8_500)
            check(budget.available <= 1_000 && budget.available >= 0 && budget.ceiling <= 8_500, "Snapshot invariants")
        }

        let dense: [String: Any] = [
            "model_type": "qwen3", "num_hidden_layers": 32,
            "num_attention_heads": 32, "num_key_value_heads": 8,
            "hidden_size": 4_096, "head_dim": 128,
            "intermediate_size": 14_336, "vocab_size": 151_936,
            "torch_dtype": "bfloat16",
        ]
        func estimate(_ config: [String: Any], tokens: Int = 2_048, rotating: Bool = true, bits: Int = 4) -> MLXModelMemoryEstimate? {
            MLXModelMemoryEstimate.estimate(
                weights: 2_000_000_000, config: config, contextTokens: tokens,
                rotatingCache: rotating, kvBits: bits, prefillTokens: 128,
                allocatorCache: 0, runtimeReserve: 250_000_000
            )
        }
        let rotating = estimate(dense)!
        // K + V, 32 layers, 8 KV heads, 2176 slots, 128 FP16 elements.
        check(rotating.kvCache == 285_212_672, "Rotating cache must use its actual unquantized precision")
        check(estimate(dense, bits: 8)!.kvCache == rotating.kvCache, "kvBits must not shrink rotating caches")
        check(estimate(dense, tokens: 4_096)!.peak > rotating.peak, "Longer context must cost more RAM")
        let quantized = estimate(dense, rotating: false)!
        check(quantized.kvCache == 89_128_960, "Affine scales and biases are part of the cache")
        check(quantized.kvCache < rotating.kvCache, "Only supported plain caches get quantization savings")
        var mha = dense; mha["num_key_value_heads"] = 32
        check(estimate(mha)!.kvCache == rotating.kvCache * 4, "Grouped-query head count matters")
        var fp32 = dense; fp32["torch_dtype"] = "float32"
        check(estimate(fp32)!.kvCache == rotating.kvCache * 2, "Activation dtype matters")
        var hybrid = dense; hybrid["model_type"] = "qwen3_5"
        let hybridEstimate = estimate(["model_type": "qwen3_5", "text_config": hybrid])!
        check(hybridEstimate.kvCache == rotating.kvCache / 4, "Qwen35 has full attention every fourth layer")
        check(hybridEstimate.recurrentState > 150_000_000, "Linear attention retains FP32 recurrent state")
        check(estimate(["model_type": "unknown"]) == nil, "Unknown architectures retain fallback uncertainty")
        var invalid = dense; invalid["head_dim"] = -128
        check(estimate(invalid) == nil, "Invalid dimensions cannot create negative estimates")
        check(rotating.peak > rotating.weights + 250_000_000, "Runtime state is additional to the reserve")
        let generation = MLXModelMemoryEstimate.estimate(
            weights: 0, config: dense, contextTokens: 2_048, rotatingCache: true,
            kvBits: 4, prefillTokens: 128, allocatorCache: 0, runtimeReserve: 250_000_000
        )!
        check(generation.peak == rotating.peak - rotating.weights, "Generation checks must not charge resident weights twice")
        let longResponse = estimate(dense, tokens: 32_768, rotating: false)!
        check(longResponse.kvCache > estimate(dense, tokens: 8_192, rotating: false)!.kvCache * 3,
              "Large response overrides need their own generation admission")
        let mimoBudget = ProcessMemoryBudget.resolve(
            footprint: 110_000_000, kernelHeadroom: 6_390_000_000,
            fallbackCeiling: 9_300_000_000, platformCap: 8_500_000_000
        )
        check(mimoBudget.ceiling == 6_500_000_000, "A 12 GB phone must still honor a smaller kernel grant")
        check(MemoryBytes.required(peak: 7_120_000_000, reserve: 0, unknownFloor: 3_500_000_000) > mimoBudget.available,
              "MiMo's 7.12 GB weights cannot fit a 6.5 GB grant, even with zero reserve")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func writeShard(_ name: String, offsets: [Int] = [0, 100], payload: Int = 300) throws {
            let header = try JSONSerialization.data(withJSONObject: [
                "language.weight": ["data_offsets": offsets],
                "vision.weight": ["data_offsets": [100, 300]],
            ])
            var data = Data()
            withUnsafeBytes(of: UInt64(header.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(header); data.append(Data(count: payload))
            try data.write(to: directory.appendingPathComponent(name))
        }
        func textBytes() -> Int64? {
            ModelTensorFootprint.textBytes(in: directory, excluding: { $0.hasPrefix("vision.") })
        }
        try writeShard("model.safetensors")
        check(textBytes() == 100, "Text estimates exclude vision tensors")
        try writeShard("second.safetensors")
        check(textBytes() == 200, "Every shard contributes")
        try Data([1, 2]).write(to: directory.appendingPathComponent("second.safetensors"))
        check(textBytes() == nil, "A corrupt shard cannot produce a partial weight total")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("second.safetensors"))
        try writeShard("model.safetensors", offsets: [100, 0])
        check(textBytes() == nil, "Reversed offsets are rejected")
        try writeShard("model.safetensors", offsets: [0, 200])
        check(textBytes() == nil, "Overlapping tensors are rejected")
        try writeShard("model.safetensors", payload: 200)
        check(textBytes() == nil, "Truncated tensor payloads are rejected")
        try writeShard("model.safetensors")
        try Data(#"{"weight_map":{"language.weight":"missing.safetensors"}}"#.utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        check(textBytes() == nil, "Missing indexed shards cannot be counted as a complete model")
        print("\(checks) memory budget checks passed")
    }
}
