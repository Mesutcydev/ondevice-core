import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

/// Isolated adapter for the publisher's schema-2, grouped-GDN 9B text weights.
/// No global kernels, existing model registrations, or weight files are changed.
final class Bonsai2MLXModel: Module, LLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "language_model") var languageModel: Qwen35TextModel
    private let records: [Record]
    let vocabularySize: Int
    let kvHeads: [Int]

    private struct Configuration: Decodable {
        let text_config: Qwen35TextConfiguration
        let modules: [Record]
    }
    private typealias Record = Bonsai2PackedLayers.Record
    enum LoadError: Error { case unsupportedConfiguration, invalidPackedLayer }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Bonsai2Compatibility.supportsText(json) else { throw LoadError.unsupportedConfiguration }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        records = config.modules
        let base = Qwen35TextModel(config.text_config)
        vocabularySize = base.vocabularySize
        kvHeads = base.kvHeads
        _languageModel.wrappedValue = base
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }
    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try languageModel.newCache(parameters: parameters)
    }
    var loraLayers: [Module] { [] }
    var toolCallFormat: ToolCallFormat? { .qwen35 }
    var reasoningConfig: ReasoningConfig? { QwenReasoningProtocol.tagged }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        do {
            // The pack is already in MLX layout with shifted RMSNorm weights.
            // Running the raw-HF sanitizer again would change trained parameters.
            return try Bonsai2PackedLayers.install(weights: weights, records: records, model: self)
        } catch {
            // sanitize cannot throw. An empty parameter set makes loadWeights'
            // strict update fail before evaluation or publication of this model.
            return [:]
        }
    }
}

enum Bonsai2MLXRegistration {
    static func register() async {
        await LLMTypeRegistry.shared.registerModelType("prism_hadamard_qwen35") { data in
            try Bonsai2MLXModel(data: data)
        }
    }
}
