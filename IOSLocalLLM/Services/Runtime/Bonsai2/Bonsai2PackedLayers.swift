import Foundation
import MLX
import MLXNN

/// Installs the same verified packed language layers into text and vision backbones.
/// Vision weights stay FP16; generic quantization must not rotate or quantize them.
enum Bonsai2PackedLayers {
    struct Record: Decodable {
        let path: String
        let block: Int
        let embedding: Bool
        let dtype: String
    }
    enum LoadError: Error { case invalidPackedLayer }

    static func install(weights: [String: MLXArray], records: [Record], model: Module) throws -> [String: MLXArray] {
        var textWeights = weights.filter { $0.key.hasPrefix("language_model.") && !$0.key.contains(".mtp.") }
        let originals = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var replacements: [(String, Module)] = []
        let packedPaths = Set(textWeights.keys.filter { $0.hasSuffix(".scales") }.map {
            String($0.dropLast(".scales".count))
        })
        guard packedPaths == Set(records.map { "language_model." + $0.path }) else { throw LoadError.invalidPackedLayer }
        for record in records {
            let prefix = "language_model." + record.path
            guard let original = originals[prefix],
                  let weight = textWeights[prefix + ".weight"],
                  let scales = textWeights[prefix + ".scales"],
                  let biases = textWeights[prefix + ".biases"] else { throw LoadError.invalidPackedLayer }
            let shape: [Int]
            if let embedding = original as? Embedding, record.embedding { shape = embedding.weight.shape }
            else if let linear = original as? Linear, !record.embedding { shape = linear.weight.shape }
            else { throw LoadError.invalidPackedLayer }
            guard shape.count == 2, shape[1] % 128 == 0,
                  weight.dtype == .uint32, weight.shape == [shape[0], shape[1] / 16],
                  scales.shape == [shape[0], shape[1] / 128], biases.shape == scales.shape,
                  scales.dtype == .float16, biases.dtype == .float16 else { throw LoadError.invalidPackedLayer }
            let replacement: Module
            if record.block > 0 {
                guard let signs = textWeights[prefix + ".signs"], signs.shape == [shape[1]] else { throw LoadError.invalidPackedLayer }
                let transform = try SignedBlockHadamard(blockSize: record.block, signs: signs.asArray(Float.self))
                if record.embedding {
                    replacement = try HadamardQuantizedEmbedding(weight: weight, scales: scales, biases: biases,
                        groupSize: 128, bits: 2, transform: transform, outputDType: .float16)
                } else {
                    // Both this checkpoint and Qwen35TextModel use grouped GDN heads.
                    // Do not apply a second permutation to the output projection.
                    replacement = try HadamardQuantizedLinear(weight: weight, scales: scales, biases: biases,
                        groupSize: 128, bits: 2, transform: transform)
                }
            } else {
                guard !record.embedding, textWeights[prefix + ".signs"] == nil else { throw LoadError.invalidPackedLayer }
                replacement = QuantizedLinear(weight: weight, bias: nil, scales: scales, biases: biases, groupSize: 128, bits: 2)
            }
            replacements.append((prefix, replacement))
            textWeights.removeValue(forKey: prefix + ".signs")
        }
        try model.update(modules: ModuleChildren.unflattened(replacements), verify: [.all])
        return textWeights
    }
}
