import Foundation

/// A single admission snapshot. Headroom is incremental; the current app and
/// every resident model are already charged against it. Never add them again.
struct ProcessMemoryBudget: Equatable, Sendable {
    let footprint: Int64
    let kernelHeadroom: Int64?
    let ceiling: Int64
    let available: Int64

    static func resolve(
        footprint: Int64?, kernelHeadroom: Int64?,
        fallbackCeiling: Int64, platformCap: Int64
    ) -> Self {
        let cap = max(0, platformCap)
        // Missing accounting must not turn into "the app uses zero bytes".
        guard let footprint, footprint >= 0 else {
            return .init(footprint: 0, kernelHeadroom: kernelHeadroom,
                         ceiling: min(cap, max(0, fallbackCeiling)), available: 0)
        }
        let headroom = kernelHeadroom.map { max(0, $0) }
        let candidate = headroom.map { MemoryBytes.add(footprint, $0) }
            ?? max(0, fallbackCeiling)
        let ceiling = min(cap, candidate)
        return .init(
            footprint: footprint, kernelHeadroom: headroom, ceiling: ceiling,
            available: min(headroom ?? Int64.max, max(0, ceiling - footprint))
        )
    }
}

/// Saturating byte math: malformed model metadata must not wrap or trap into
/// a smaller requirement. Saturation always causes admission to refuse.
enum MemoryBytes {
    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? .max : sum
    }

    static func count(_ value: Double) -> Int64 {
        guard value.isFinite, value < Double(Int64.max) else { return .max }
        return Int64(max(0, value.rounded(.up)))
    }

    static func required(peak: Int64, reserve: Int64, unknownFloor: Int64) -> Int64 {
        add(peak > 0 ? peak : unknownFloor, reserve)
    }
}

/// An explainable text-only MLX estimate, not a measured peak. Weight bytes
/// come from tensor headers; runtime costs follow the actual execution policy.
/// Unsupported architectures retain a heuristic instead of claiming precision.
struct MLXModelMemoryEstimate: Equatable, Sendable {
    let weights: Int64
    let kvCache: Int64
    let recurrentState: Int64
    let prefillScratch: Int64
    let runtimeReserve: Int64
    let allocatorCache: Int64

    var peak: Int64 {
        [kvCache, recurrentState, prefillScratch, runtimeReserve, allocatorCache]
            .reduce(weights, MemoryBytes.add)
    }

    static func estimate(
        weights: Int64, config: [String: Any], contextTokens: Int,
        rotatingCache: Bool, kvBits: Int, prefillTokens: Int,
        allocatorCache: Int64, runtimeReserve: Int64
    ) -> Self? {
        let text = config["text_config"] as? [String: Any] ?? config
        let architecture = text["model_type"] as? String ?? config["model_type"] as? String ?? ""
        let supported = ["llama", "mistral", "qwen2", "qwen3", "qwen3_5", "qwen3_5_text"]
        // Zero weights is used for a generation check after weights are
        // already resident and charged to the process snapshot.
        guard weights >= 0, contextTokens > 0, prefillTokens > 0,
              supported.contains(architecture) else { return nil }
        func dimension(_ key: String, default fallback: Int? = nil) -> Int? {
            guard let value = text[key] as? Int ?? fallback,
                  value > 0, value <= 1_000_000 else { return nil }
            return value
        }
        guard let layers = dimension("num_hidden_layers"),
              let heads = dimension("num_attention_heads"),
              let hidden = dimension("hidden_size"),
              let kvHeads = dimension("num_key_value_heads", default: heads),
              let headDim = dimension("head_dim", default: hidden / heads),
              let intermediate = dimension("intermediate_size"),
              let vocabulary = dimension("vocab_size") else { return nil }

        // BF16/FP16 activations are usual, but don't undercount FP32 packs.
        let dtype = text["torch_dtype"] as? String ?? text["dtype"] as? String
            ?? config["torch_dtype"] as? String ?? config["dtype"] as? String
        let scalarBytes: Double = ["float16", "bfloat16"].contains(dtype ?? "") ? 2 : 4
        var attentionLayers = layers
        var recurrentBytes: Double = 0
        if architecture == "qwen3_5" || architecture == "qwen3_5_text" {
            // Match the pinned Qwen35 factory's layer schedule and defaults.
            guard let interval = dimension("full_attention_interval", default: 4),
                  let valueHeads = dimension("linear_num_value_heads", default: 64),
                  let keyHeads = dimension("linear_num_key_heads", default: 16),
                  let keyDim = dimension("linear_key_head_dim", default: 192),
                  let valueDim = dimension("linear_value_head_dim", default: 128),
                  let conv = dimension("linear_conv_kernel_dim", default: 4) else { return nil }
            attentionLayers = layers / interval
            let state = Double(valueHeads) * Double(keyDim) * Double(valueDim) * 4
            let convolution = Double(conv - 1)
                * (2 * Double(keyHeads) * Double(keyDim) + Double(valueHeads) * Double(valueDim))
                * scalarBytes
            recurrentBytes = Double(layers - attentionLayers) * (state + convolution)
        }

        // RotatingKVCache cannot be quantized in the pinned MLX library.
        // Plain KVCacheSimple can, when its head dimension accepts the group.
        let quantized = !rotatingCache && [4, 8].contains(kvBits) && headDim.isMultiple(of: 64)
        let rowBytes = quantized
            ? ceil(Double(headDim * kvBits) / 32) * 4 + Double(headDim / 64) * 8
            : Double(headDim) * scalarBytes
        // Cache growth uses 256-token blocks. Rotating prefill temporarily
        // retains a chunk beyond the window; account for both cases.
        let tokens = ceil(Double(contextTokens) / 256) * 256 + Double(prefillTokens)
        let kv = 2 * Double(attentionLayers) * Double(kvHeads) * tokens * rowBytes
        let chunk = Double(prefillTokens)
        // Workspace estimate for projections, gated MLP, logits, and one
        // layer's cache replacement/quantization transient. No layer-count
        // multiplier: layers execute sequentially.
        let activations = chunk * (4 * Double(hidden) + 3 * Double(intermediate) + Double(vocabulary)) * scalarBytes
        let cacheTransient = 2 * Double(kvHeads) * tokens * Double(headDim) * scalarBytes
        return .init(
            weights: weights, kvCache: MemoryBytes.count(kv),
            recurrentState: MemoryBytes.count(recurrentBytes),
            prefillScratch: MemoryBytes.count(activations + cacheTransient),
            runtimeReserve: max(0, runtimeReserve), allocatorCache: max(0, allocatorCache)
        )
    }
}

/// Reads only safetensors headers. Partial/corrupt shards must not produce a
/// plausible small weight count. Payloads stay on disk, even for large models.
enum ModelTensorFootprint {
    static func textBytes(in directory: URL, excluding: (String) -> Bool) -> Int64? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let shards = Set(names.filter { $0.hasSuffix(".safetensors") })
        guard !shards.isEmpty else { return nil }
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty,
                  Set(map.values).isSubset(of: shards) else { return nil }
        }
        var total: Int64 = 0
        for name in shards {
            guard let bytes = shardBytes(at: directory.appendingPathComponent(name), excluding: excluding) else { return nil }
            total = MemoryBytes.add(total, bytes)
        }
        return total > 0 ? total : nil
    }

    private static func shardBytes(at url: URL, excluding: (String) -> Bool) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 8,
              (try? handle.seek(toOffset: 0)) != nil,
              let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return nil }
        let length = UInt64(littleEndian: prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard length > 0, length <= 16 * 1_024 * 1_024, length <= fileSize - 8,
              let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
              let tensors = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return nil }
        let payloadBytes = fileSize - 8 - length
        var total: Int64 = 0
        var ranges: [(Int64, Int64)] = []
        for (tensor, info) in tensors where tensor != "__metadata__" {
            guard let offsets = (info as? [String: Any])?["data_offsets"] as? [Int64],
                  offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0],
                  UInt64(offsets[1]) <= payloadBytes else { return nil }
            ranges.append((offsets[0], offsets[1]))
            if !excluding(tensor) { total = MemoryBytes.add(total, offsets[1] - offsets[0]) }
        }
        var end: Int64 = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 >= end else { return nil }
            end = range.1
        }
        return ranges.isEmpty ? nil : total
    }
}
