import Foundation

// MARK: - Edge0ModelArtifactError

enum Edge0ModelArtifactError: Error, Equatable, Sendable {
    case missingFile(String)
    case unreadable(String)
    case unsupportedArchitecture(String)
    case invalidConfiguration(String)
    case invalidWeightGeometry(String)
}

extension Edge0ModelArtifactError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingFile(let name):
            return "Edge0 model is missing required artifact '\(name)'."
        case .unreadable(let detail):
            return "Edge0 model artifacts are unreadable: \(detail)"
        case .unsupportedArchitecture(let value):
            return "Edge0 model architecture '\(value)' is not supported."
        case .invalidConfiguration(let detail):
            return "Edge0 model configuration is invalid: \(detail)"
        case .invalidWeightGeometry(let detail):
            return "Edge0 model weight geometry is invalid: \(detail)"
        }
    }
}

// MARK: - Edge0ModelArtifacts
//
// Install-time validation for exactly one model family: Edge0-8B
// (BailingMoeV3ForCausalLM). A partial or wrong-scale checkpoint must fail
// here rather than during generation. Routed-expert geometry is checked by
// resolving representative expert bundles against the validated layout.

enum Edge0ModelArtifacts {
    static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model.safetensors",
        "lora_edge0_8b.safetensors",
    ]

    static func validate(directory: URL) throws {
        let fileManager = FileManager.default
        for file in requiredFiles {
            let url = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: url.path) else {
                throw Edge0ModelArtifactError.missingFile(file)
            }
        }

        let configuration: Edge0ModelConfiguration
        do {
            configuration = try Edge0ModelConfiguration.decode(
                from: Data(contentsOf: directory.appendingPathComponent("config.json"))
            )
        } catch let error as Edge0ModelConfigurationError {
            switch error {
            case .unsupportedArchitecture(let value):
                throw Edge0ModelArtifactError.unsupportedArchitecture(value)
            default:
                throw Edge0ModelArtifactError.invalidConfiguration(
                    error.localizedDescription
                )
            }
        } catch {
            throw Edge0ModelArtifactError.unreadable(
                error.localizedDescription
            )
        }

        do {
            try configuration.validateEdge0_8B()
        } catch let error as Edge0ModelConfigurationError {
            switch error {
            case .unsupportedArchitecture(let value):
                throw Edge0ModelArtifactError.unsupportedArchitecture(value)
            default:
                throw Edge0ModelArtifactError.invalidConfiguration(
                    error.localizedDescription
                )
            }
        } catch {
            throw Edge0ModelArtifactError.invalidConfiguration(
                String(describing: error)
            )
        }

        do {
            let base = try Edge0SafetensorsIndex.openSingleFile(
                at: directory.appendingPathComponent("model.safetensors")
            )
            let adapter = try Edge0SafetensorsIndex.openSingleFile(
                at: directory.appendingPathComponent("lora_edge0_8b.safetensors")
            )
            try validateWeightGeometry(index: base, configuration: configuration)
            try validateLoRAGeometry(adapter: adapter, base: base, configuration: configuration)
        } catch let error as Edge0ModelArtifactError {
            throw error
        } catch {
            throw Edge0ModelArtifactError.invalidWeightGeometry(
                String(describing: error)
            )
        }
    }

    static func validateWeightGeometry(
        index: Edge0SafetensorsIndex,
        configuration: Edge0ModelConfiguration
    ) throws {
        // Quantized embedding and output head must exist with the exact
        // group geometry the runtime executes.
        for prefix in ["model.word_embeddings", "lm_head"] {
            for part in ["weight", "scales", "biases"] {
                _ = try index.location("\(prefix).\(part)")
            }
        }
        _ = try index.location("model.norm.weight")

        // Representative routed-expert bundles (KDA layer and MLA layer) are
        // resolved and validated against the 8B spec.
        let layout = Edge0ExpertLayout()
        for layer in [1, 3] {
            let bundle = try layout.bundleLocation(
                for: Edge0ExpertKey(layer: layer, expert: 0),
                in: index
            )
            try layout.validateQuantizationGeometry(bundle)
        }
    }

    /// The published 8B Recover-LoRA adapts every KDA/MLA attention target
    /// plus the first dense MLP. Reject missing, extra, or incompatible pairs.
    static func validateLoRAGeometry(
        adapter: Edge0SafetensorsIndex,
        base: Edge0SafetensorsIndex,
        configuration: Edge0ModelConfiguration
    ) throws {
        let rank = 16
        var expectedNames = Set<String>()
        for layer in 0..<configuration.numHiddenLayers {
            let prefix = "model.layers.\(layer)"
            let attention = configuration.isMLALayer(layer)
                ? ["q_b_proj", "kv_b_proj", "dense", "g_proj"]
                : ["q_proj", "k_proj", "v_proj", "f_proj", "g_proj", "b_proj", "o_proj"]
            var targets = attention.map { "\(prefix).attention.\($0)" }
            if layer < configuration.firstKDenseReplace {
                targets += ["gate_proj", "up_proj", "down_proj"].map {
                    "\(prefix).mlp.\($0)"
                }
            }
            for target in targets {
                let weight = try base.location("\(target).weight")
                guard weight.dtype == .u32, weight.shape.count == 2 else {
                    throw Edge0ModelArtifactError.invalidWeightGeometry(
                        "\(target).weight is not a packed linear matrix"
                    )
                }
                let input = weight.shape[1] * 32 / configuration.quantization.bits
                let output = weight.shape[0]
                for (suffix, shape) in [("lora_A", [rank, input]),
                                         ("lora_B", [output, rank])] {
                    let name = "\(target).\(suffix)"
                    expectedNames.insert(name)
                    let tensor = try adapter.location(name)
                    guard tensor.dtype == .f16, tensor.shape == shape else {
                        throw Edge0ModelArtifactError.invalidWeightGeometry(
                            "\(name) must be F16 with shape \(shape)"
                        )
                    }
                }
            }
        }
        guard Set(adapter.locations.keys) == expectedNames else {
            throw Edge0ModelArtifactError.invalidWeightGeometry(
                "8B LoRA tensor inventory does not match the 153 supported modules"
            )
        }
    }
}
