import Foundation
import MLX
import MLXNN
import MLXVLM
import MLXLMCommon

/// Qwen3.5's image encoder, multimodal positions and processor with Bonsai's
/// transformed language weights. Both roles share the existing Lens owner.
final class Bonsai2VLMModel: Module, VLMModel {
    @ModuleInfo(key: "backbone") var backbone: Qwen35
    private let records: [Bonsai2PackedLayers.Record]

    private struct Pack: Decodable {
        let modules: [Bonsai2PackedLayers.Record]
    }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Bonsai2Compatibility.supportsVision(json) else {
            throw Bonsai2MLXModel.LoadError.unsupportedConfiguration
        }
        records = try JSONDecoder().decode(Pack.self, from: data).modules
        _backbone.wrappedValue = Qwen35(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    var vocabularySize: Int { backbone.vocabularySize }
    var loraLayers: [Module] { [] }
    var toolCallFormat: ToolCallFormat? { .qwen35 }
    var reasoningConfig: ReasoningConfig? { QwenReasoningProtocol.tagged }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try backbone.newCache(parameters: parameters)
    }
    func prepare() throws { try backbone.prepare() }
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws -> PrepareResult {
        try backbone.prepare(input, cache: cache, state: state, prefill: prefill)
    }
    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        backbone(input, cache: cache, state: state)
    }
    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        do {
            let text = try Bonsai2PackedLayers.install(weights: weights, records: records, model: backbone)
            // Publisher's schema-2 vision tower is already in MLX Conv3d layout.
            // Preserve it exactly; generic HF sanitization would transpose it again.
            let vision = weights.filter { $0.key.hasPrefix("vision_tower.") }
            guard !vision.isEmpty, vision.values.allSatisfy({ $0.dtype == .float16 }) else {
                throw Bonsai2PackedLayers.LoadError.invalidPackedLayer
            }
            return Dictionary(uniqueKeysWithValues: text.merging(vision) { _, new in new }
                .map { ("backbone." + $0.key, $0.value) })
        } catch {
            // Strict parameter loading rejects this before the runtime is published.
            return [:]
        }
    }
}

enum Bonsai2VLMRegistration {
    static func register() async {
        await VLMTypeRegistry.shared.registerModelType("prism_hadamard_qwen35") { data in
            try Bonsai2VLMModel(data: data)
        }
    }
}
