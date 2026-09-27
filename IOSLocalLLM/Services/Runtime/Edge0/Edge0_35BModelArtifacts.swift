import Foundation

// MARK: - Edge0_35BArtifactError

enum Edge0_35BArtifactError: Error, Equatable, Sendable {
    case missingFile(String)
    case truncatedFile(name: String, expected: UInt64, actual: UInt64)
    case invalidIndex(String)
    case shardOutsideModelDirectory(String)
    case unsupportedArchitecture(String)
    case invalidConfiguration(String)
    case invalidWeightGeometry(String)
    case invalidLoRAContract(String)
}

extension Edge0_35BArtifactError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingFile(let name):
            return "Edge0-35B model is missing required artifact '\(name)'."
        case .truncatedFile(let name, let expected, let actual):
            return "Edge0-35B artifact '\(name)' is truncated (\(actual) of \(expected) bytes). Retry the download."
        case .invalidIndex(let detail):
            return "Edge0-35B shard index is invalid: \(detail)"
        case .shardOutsideModelDirectory(let reference):
            return "Edge0-35B shard index references a path outside the model directory: '\(reference)'."
        case .unsupportedArchitecture(let value):
            return "Edge0-35B architecture '\(value)' is not the supported release."
        case .invalidConfiguration(let detail):
            return "Edge0-35B configuration is invalid: \(detail)"
        case .invalidWeightGeometry(let detail):
            return "Edge0-35B weight geometry is invalid: \(detail)"
        case .invalidLoRAContract(let detail):
            return "Edge0-35B Recover-LoRA artifact is incompatible: \(detail)"
        }
    }
}

// MARK: - Edge0_35BInstallSummary

/// Privacy-safe install/validation summary. Counts and byte sizes only.
struct Edge0_35BInstallSummary: Sendable, Equatable {
    var shardCount = 0
    var tensorCount = 0
    var residentTensorCount = 0
    var expertTensorCount = 0
    var residentPayloadBytes: UInt64 = 0
    var expertPayloadBytes: UInt64 = 0
    var loraTensorCount = 0
    var loraModuleCount = 0
    var loraPayloadBytes: UInt64 = 0
    /// False only when the (optional) prerouter artifact is absent; it never
    /// invalidates exact base+LoRA execution.
    var prerouterPresent = false
}

// MARK: - Edge0_35BModelArtifacts
//
// Validation for exactly one pinned release: Edge0-35B-A3B-preview at
// revision 1ff9f447… (Qwen3.5-MoE text tower + Recover-LoRA). Architecture
// identity alone is NOT enough — an arbitrary Qwen3.5-MoE checkpoint passes
// it — so the install contract additionally pins the curated repo identity
// (checked by `Edge0ModelFamily.resolve`), the exact config expectation, the
// four-shard inventory, the quantization geometry, and the 310-module LoRA
// target set.
//
// Two validation levels:
//   • `validateInstall`    — files, sizes, index containment, LoRA header
//                            contract. Used by model discovery/refresh.
//   • `validateForRuntime` — install + full index geometry resolution; the
//                            model loader repeats payload-level checks.

enum Edge0_35BModelArtifacts {

    // MARK: Pinned inventory (verified Phase 5A/5B)

    static let weightShardNames = [
        "model-00001-of-00004.safetensors",
        "model-00002-of-00004.safetensors",
        "model-00003-of-00004.safetensors",
        "model-00004-of-00004.safetensors",
    ]

    /// Exact byte sizes of the pinned revision. Used for truncation refusal.
    static let pinnedFileSizes: [String: UInt64] = [
        "model-00001-of-00004.safetensors": 4_395_019_264,
        "model-00002-of-00004.safetensors": 5_368_472_749,
        "model-00003-of-00004.safetensors": 5_368_324_139,
        "model-00004-of-00004.safetensors": 4_377_211_365,
        "lora_edge0_35b.safetensors": 42_413_928,
        "prerouter_edge0_35b.safetensors": 138_422_000,
        "tokenizer.json": 19_989_343,
        "model.safetensors.index.json": 180_182,
        "config.json": 23_591,
        "chat_template.jinja": 7_764,
        "tokenizer_config.json": 1_139,
        "generation_config.json": 202,
    ]

    /// Files required for exact base + Recover-LoRA execution. The prerouter
    /// artifact is intentionally excluded: it is optional and unused.
    static let requiredFiles = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "chat_template.jinja",
        "model.safetensors.index.json",
        "lora_edge0_35b.safetensors",
    ] + weightShardNames

    /// Download allowlist for the curated entry. One entry per file so the
    /// downloader's size/preflight/checksum behavior operates on exactly the
    /// artifacts this runtime uses.
    static let downloadAllowlist = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "chat_template.jinja",
        "model.safetensors.index.json",
        "lora_edge0_35b.safetensors",
    ] + weightShardNames

    /// Exact sum of the allowlisted artifacts' bytes (19.57 GB).
    static var downloadSizeBytes: Int64 {
        downloadAllowlist.reduce(0) { partial, name in
            partial + Int64(pinnedFileSizes[name] ?? 0)
        }
    }

    /// Conservative free-space requirement: selected bytes plus one whole
    /// shard for URLSession staging and metadata, plus a fixed margin.
    static var freeSpaceRequirementBytes: Int64 {
        let largest = weightShardNames.compactMap { pinnedFileSizes[$0] }.max() ?? 0
        return downloadSizeBytes + Int64(largest) + 1_073_741_824
    }

    /// Optional advisory prerouter. Downloaded ONLY on explicit request
    /// (incremental single-file fetch); the base + LoRA model stays valid
    /// and runnable without it.
    static let prerouterFileName = "prerouter_edge0_35b.safetensors"
    static let prerouterFileSize: UInt64 = 138_422_000
    static let optionalPrerouterAllowlist = [prerouterFileName]

    static let loraFileName = "lora_edge0_35b.safetensors"
    static let expectedLoRATensorCount = 620
    static let expectedLoRAModuleCount = 310
    static let loRARank = 16

    // MARK: Install validation

    static func validateInstall(
        directory: URL
    ) throws -> Edge0_35BInstallSummary {
        let fileManager = FileManager.default

        // 1. Presence and truncation of the pinned inventory.
        for file in requiredFiles {
            let url = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: url.path) else {
                throw Edge0_35BArtifactError.missingFile(file)
            }
            if let expected = pinnedFileSizes[file] {
                let actual = (try? Edge0FileIO.fileSize(at: url)) ?? 0
                if actual < expected {
                    throw Edge0_35BArtifactError.truncatedFile(
                        name: file, expected: expected, actual: actual
                    )
                }
            }
        }

        // 2. Configuration identity (exact Edge0-35B release expectation).
        let configuration: Edge0_35BModelConfiguration
        do {
            configuration = try Edge0_35BModelConfiguration.decode(
                from: Data(contentsOf: directory.appendingPathComponent("config.json"))
            )
            try configuration.validateEdge0_35B()
        } catch let error as Edge0_35BModelConfiguration.DecodeError {
            switch error {
            case .unsupportedArchitecture(let value):
                throw Edge0_35BArtifactError.unsupportedArchitecture(value)
            default:
                throw Edge0_35BArtifactError.invalidConfiguration(
                    error.localizedDescription
                )
            }
        } catch {
            throw Edge0_35BArtifactError.invalidConfiguration(
                error.localizedDescription
            )
        }

        // 3. Shard index: containment + exact pinned shard set.
        let indexURL = directory.appendingPathComponent(
            "model.safetensors.index.json"
        )
        let shardNames = try referencedShardNames(at: indexURL)
        for shard in shardNames {
            guard isSafeShardReference(shard) else {
                throw Edge0_35BArtifactError.shardOutsideModelDirectory(shard)
            }
        }
        guard Set(shardNames) == Set(weightShardNames) else {
            throw Edge0_35BArtifactError.invalidIndex(
                "expected exactly \(weightShardNames.count) pinned shards, found \(Set(shardNames).count)"
            )
        }

        // 4. LoRA header contract.
        let loraSummary = try validateLoRAFile(
            at: directory.appendingPathComponent(loraFileName)
        )

        var summary = Edge0_35BInstallSummary()
        summary.shardCount = shardNames.count
        summary.loraTensorCount = loraSummary.tensorCount
        summary.loraModuleCount = loraSummary.moduleCount
        summary.loraPayloadBytes = loraSummary.payloadBytes
        summary.prerouterPresent = fileManager.fileExists(
            atPath: directory.appendingPathComponent(
                "prerouter_edge0_35b.safetensors"
            ).path
        )
        return summary
    }

    /// Install validation plus full metadata geometry (headers only, no
    /// payload). The model loader still verifies payloads as it materializes
    /// them; this catches a wrong-shape checkpoint before any tensors load.
    static func validateForRuntime(
        directory: URL
    ) throws -> Edge0_35BInstallSummary {
        var summary = try validateInstall(directory: directory)
        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: directory.appendingPathComponent("config.json"))
        )
        let index = try Edge0SafetensorsIndex.openSharded(in: directory)
        try validateWeightGeometry(index: index, configuration: configuration)
        applyWeightAccounting(
            Edge0_35BModelArtifacts.weightAccounting(for: index),
            to: &summary
        )
        return summary
    }

    /// Tensor/payload accounting from an open index (metadata only).
    static func weightAccounting(
        for index: Edge0SafetensorsIndex
    ) -> (
        tensorCount: Int,
        residentTensorCount: Int,
        residentPayloadBytes: UInt64,
        expertTensorCount: Int,
        expertPayloadBytes: UInt64
    ) {
        var residentTensors = 0
        var residentBytes: UInt64 = 0
        var expertTensors = 0
        var expertBytes: UInt64 = 0
        for (name, location) in index.locations {
            if name.contains(".mlp.switch_mlp.") {
                expertTensors += 1
                expertBytes += location.byteCount
            } else {
                residentTensors += 1
                residentBytes += location.byteCount
            }
        }
        return (
            index.tensorCount, residentTensors, residentBytes,
            expertTensors, expertBytes
        )
    }

    static func applyWeightAccounting(
        _ accounting: (
            tensorCount: Int,
            residentTensorCount: Int,
            residentPayloadBytes: UInt64,
            expertTensorCount: Int,
            expertPayloadBytes: UInt64
        ),
        to summary: inout Edge0_35BInstallSummary
    ) {
        summary.tensorCount = accounting.tensorCount
        summary.residentTensorCount = accounting.residentTensorCount
        summary.residentPayloadBytes = accounting.residentPayloadBytes
        summary.expertTensorCount = accounting.expertTensorCount
        summary.expertPayloadBytes = accounting.expertPayloadBytes
    }

    // MARK: Index helpers

    /// Reads only the index JSON and returns the referenced shard names.
    /// Rejects non-string entries and duplicate tensor references.
    static func referencedShardNames(at indexURL: URL) throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            throw Edge0_35BArtifactError.missingFile(
                indexURL.lastPathComponent
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            let weightMap = root["weight_map"] as? [String: String] else {
            throw Edge0_35BArtifactError.invalidIndex("weight_map missing")
        }
        guard !weightMap.isEmpty else {
            throw Edge0_35BArtifactError.invalidIndex("weight_map empty")
        }
        return Array(Set(weightMap.values)).sorted()
    }

    /// A shard reference must be a plain file name inside the model
    /// directory: no separators, no traversal, no absolute paths.
    static func isSafeShardReference(_ reference: String) -> Bool {
        guard !reference.isEmpty,
              !reference.hasPrefix("/"),
              !reference.contains(".."),
              !reference.contains("/"),
              !reference.contains("\\") else {
            return false
        }
        return reference.hasSuffix(".safetensors")
    }

    // MARK: LoRA contract

    struct LoRASummary: Sendable, Equatable {
        var tensorCount = 0
        var moduleCount = 0
        var payloadBytes: UInt64 = 0
    }

    /// Required adapter targets for one layer. Router gates
    /// (`mlp.gate`, `mlp.shared_expert_gate`) are quantized 8-bit base
    /// tensors and are deliberately NOT LoRA-adapted.
    static func requiredLoRATargets(layer: Int) -> [String] {
        let isFullAttention = (layer + 1) % 4 == 0
        var targets = [
            "mlp.shared_expert.gate_proj",
            "mlp.shared_expert.up_proj",
            "mlp.shared_expert.down_proj",
        ]
        if isFullAttention {
            targets.append(contentsOf: [
                "self_attn.q_proj",
                "self_attn.k_proj",
                "self_attn.v_proj",
                "self_attn.o_proj",
            ])
        } else {
            targets.append(contentsOf: [
                "linear_attn.in_proj_qkv",
                "linear_attn.in_proj_z",
                "linear_attn.in_proj_a",
                "linear_attn.in_proj_b",
                "linear_attn.out_proj",
            ])
        }
        return targets.map { "layers.\(layer).\($0)" }
    }

    static var expectedLoRATargetSet: Set<String> {
        var targets = Set<String>()
        for layer in 0..<40 {
            targets.formUnion(requiredLoRATargets(layer: layer))
        }
        return targets
    }

    /// Parses the LoRA file header only (names/dtypes/shapes; no payload) and
    /// enforces the pinned 310-module / 620-tensor rank-16 contract.
    static func validateLoRAFile(at url: URL) throws -> LoRASummary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Edge0_35BArtifactError.missingFile(loraFileName)
        }
        let index: Edge0SafetensorsIndex
        do {
            index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        } catch {
            throw Edge0_35BArtifactError.invalidLoRAContract(
                "unreadable safetensors header (\(error.localizedDescription))"
            )
        }
        guard index.tensorCount == expectedLoRATensorCount else {
            throw Edge0_35BArtifactError.invalidLoRAContract(
                "expected \(expectedLoRATensorCount) tensors, found \(index.tensorCount)"
            )
        }

        var modules: [String: (a: Edge0TensorLocation, b: Edge0TensorLocation)] = [:]
        var payloadBytes: UInt64 = 0
        for (name, location) in index.locations {
            payloadBytes += location.byteCount
            let suffix: String
            let isA: Bool
            if name.hasSuffix(".lora_A") {
                suffix = ".lora_A"
                isA = true
            } else if name.hasSuffix(".lora_B") {
                suffix = ".lora_B"
                isA = false
            } else {
                throw Edge0_35BArtifactError.invalidLoRAContract(
                    "unexpected tensor '\(name)'"
                )
            }
            guard location.dtype == .f16 else {
                throw Edge0_35BArtifactError.invalidLoRAContract(
                    "tensor '\(name)' is \(location.dtype.rawValue), expected F16"
                )
            }
            let base = canonicalModuleName(String(name.dropLast(suffix.count)))
            var entry = modules[base] ?? (
                a: location, b: location
            )
            if isA { entry.a = location } else { entry.b = location }
            modules[base] = entry
        }

        let expected = expectedLoRATargetSet
        let found = Set(modules.keys)
        guard found == expected else {
            let missing = expected.subtracting(found).sorted().prefix(3)
            let extra = found.subtracting(expected).sorted().prefix(3)
            throw Edge0_35BArtifactError.invalidLoRAContract(
                "target set mismatch · missing \(Array(missing)) · unexpected \(Array(extra))"
            )
        }

        for (module, pair) in modules {
            // lora_A is [rank, in], lora_B is [out, rank].
            guard pair.a.shape.first == loRARank,
                  pair.b.shape.last == loRARank else {
                throw Edge0_35BArtifactError.invalidLoRAContract(
                    "module '\(module)' is not rank \(loRARank)"
                )
            }
        }

        var summary = LoRASummary()
        summary.tensorCount = index.tensorCount
        summary.moduleCount = modules.count
        summary.payloadBytes = payloadBytes
        return summary
    }

    /// `language_model.model.layers.N.…` and `layers.N.…` resolve to the same
    /// canonical module key.
    static func canonicalModuleName(_ name: String) -> String {
        for prefix in ["language_model.model.", "model."] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    // MARK: Weight geometry (metadata only)

    /// Representative exact geometry for the pinned quantization contract:
    /// 4-bit group-64 affine weights (U32 packs 8 values, BF16 scales/biases
    /// of width hidden/64) plus the 8-bit router/shared-expert-gate overrides
    /// (U32 packs 4, BF16 scales/biases of width hidden/64) and the
    /// 3-D routed-expert bundles.
    static func validateWeightGeometry(
        index: Edge0SafetensorsIndex,
        configuration: Edge0_35BModelConfiguration
    ) throws {
        let hidden = configuration.hiddenSize
        let vocab = configuration.vocabSize
        let n = configuration.numHiddenLayers
        let packed4 = hidden / 8
        let packed8 = hidden / 4
        let groups = hidden / 64
        let expertIntermediate = configuration.moeIntermediateSize
        let expertPacked4 = expertIntermediate / 8

        func require(
            _ tensor: String,
            dtype: Edge0SafetensorsDType,
            shape: [Int]
        ) throws {
            let location: Edge0TensorLocation
            do {
                location = try index.location(tensor)
            } catch {
                throw Edge0_35BArtifactError.invalidWeightGeometry(
                    "missing tensor '\(tensor)'"
                )
            }
            guard location.dtype == dtype, location.shape == shape else {
                throw Edge0_35BArtifactError.invalidWeightGeometry(
                    "\(tensor): found \(location.dtype.rawValue) \(location.shape), expected \(dtype.rawValue) \(shape)"
                )
            }
        }

        // Embedding and output head (untied, 4-bit affine).
        for prefix in [
            "language_model.model.embed_tokens",
            "language_model.lm_head",
        ] {
            try require("\(prefix).weight", dtype: .u32, shape: [vocab, packed4])
            try require("\(prefix).scales", dtype: .bf16, shape: [vocab, groups])
            try require("\(prefix).biases", dtype: .bf16, shape: [vocab, groups])
        }
        try require(
            "language_model.model.norm.weight", dtype: .bf16, shape: [hidden]
        )

        for layer in 0..<n {
            let prefix = "language_model.model.layers.\(layer)"
            let isFullAttention = (layer + 1) % 4 == 0
            try require(
                "\(prefix).input_layernorm.weight", dtype: .bf16, shape: [hidden]
            )
            try require(
                "\(prefix).post_attention_layernorm.weight", dtype: .bf16,
                shape: [hidden]
            )

            if isFullAttention {
                // q_proj packs the query and its output gate: 16 heads ×
                // 2 × 256 = 8192 output; k/v are 2 × 256 = 512.
                try require(
                    "\(prefix).self_attn.q_proj.weight", dtype: .u32,
                    shape: [8192, packed4]
                )
                try require(
                    "\(prefix).self_attn.k_proj.weight", dtype: .u32,
                    shape: [512, packed4]
                )
                try require(
                    "\(prefix).self_attn.v_proj.weight", dtype: .u32,
                    shape: [512, packed4]
                )
                try require(
                    "\(prefix).self_attn.o_proj.weight", dtype: .u32,
                    shape: [hidden, 4096 / 8]
                )
                try require(
                    "\(prefix).self_attn.q_norm.weight", dtype: .bf16,
                    shape: [256]
                )
                try require(
                    "\(prefix).self_attn.k_norm.weight", dtype: .bf16,
                    shape: [256]
                )
            } else {
                let convDim = 2 * 2048 + 4096
                try require(
                    "\(prefix).linear_attn.in_proj_qkv.weight", dtype: .u32,
                    shape: [convDim, packed4]
                )
                try require(
                    "\(prefix).linear_attn.in_proj_z.weight", dtype: .u32,
                    shape: [4096, packed4]
                )
                try require(
                    "\(prefix).linear_attn.in_proj_a.weight", dtype: .u32,
                    shape: [32, packed4]
                )
                try require(
                    "\(prefix).linear_attn.in_proj_b.weight", dtype: .u32,
                    shape: [32, packed4]
                )
                try require(
                    "\(prefix).linear_attn.out_proj.weight", dtype: .u32,
                    shape: [hidden, 4096 / 8]
                )
                try require(
                    "\(prefix).linear_attn.conv1d.weight", dtype: .bf16,
                    shape: [convDim, 4, 1]
                )
                try require(
                    "\(prefix).linear_attn.A_log", dtype: .bf16, shape: [32]
                )
                try require(
                    "\(prefix).linear_attn.dt_bias", dtype: .bf16, shape: [32]
                )
                try require(
                    "\(prefix).linear_attn.norm.weight", dtype: .bf16,
                    shape: [128]
                )
            }

            // 8-bit overrides: router gate and shared-expert gate.
            try require(
                "\(prefix).mlp.gate.weight", dtype: .u32, shape: [256, packed8]
            )
            try require(
                "\(prefix).mlp.gate.scales", dtype: .bf16, shape: [256, groups]
            )
            try require(
                "\(prefix).mlp.shared_expert_gate.weight", dtype: .u32,
                shape: [1, packed8]
            )
            try require(
                "\(prefix).mlp.shared_expert_gate.scales", dtype: .bf16,
                shape: [1, groups]
            )

            // Shared expert (4-bit) and routed expert bundles (4-bit).
            try require(
                "\(prefix).mlp.shared_expert.gate_proj.weight", dtype: .u32,
                shape: [expertIntermediate, packed4]
            )
            try require(
                "\(prefix).mlp.shared_expert.up_proj.weight", dtype: .u32,
                shape: [expertIntermediate, packed4]
            )
            try require(
                "\(prefix).mlp.shared_expert.down_proj.weight", dtype: .u32,
                shape: [hidden, expertPacked4]
            )
            try require(
                "\(prefix).mlp.switch_mlp.gate_proj.weight", dtype: .u32,
                shape: [configuration.numExperts, expertIntermediate, packed4]
            )
            try require(
                "\(prefix).mlp.switch_mlp.gate_proj.scales", dtype: .bf16,
                shape: [configuration.numExperts, expertIntermediate, groups]
            )
            try require(
                "\(prefix).mlp.switch_mlp.gate_proj.biases", dtype: .bf16,
                shape: [configuration.numExperts, expertIntermediate, groups]
            )
            try require(
                "\(prefix).mlp.switch_mlp.up_proj.weight", dtype: .u32,
                shape: [configuration.numExperts, expertIntermediate, packed4]
            )
            try require(
                "\(prefix).mlp.switch_mlp.down_proj.weight", dtype: .u32,
                shape: [configuration.numExperts, hidden, expertPacked4]
            )
        }
    }
}
