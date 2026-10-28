import CoreML
import Foundation
import Hub
import Tokenizers
import ImageIO

/// A session is owned and drained by CoreAIInferenceService's coordinated
/// lifetime, including portable models. No adapter independently admits loads.
enum ClassifierRuntimeSession: Sendable {
    case decision(CoreAIClassifierAdapter)
    case image(FastViTClassifierSession)

    func info(id: String, name: String) async -> ClassifierModelInfo {
        switch self {
        case .decision(let adapter):
            let c = adapter.contract
            return .init(id: id, name: name, window: c.window,
                supportsCalibration: c.calibratedTemperatures != nil, hasDirectAnswerHead: c.actFunction != nil)
        case .image: return .init(id: id, name: name, window: 0, isImage: true)
        }
    }
    func classify(_ request: ClassifierRequest) async throws -> CoreAIClassifierAnswer {
        switch self {
        case .decision(let adapter):
            guard request.imageData == nil else { throw CoreAIClassifierError.invalidQuestion }
            return try await adapter.classify(state: request.input, question: request.question,
                calibration: request.calibrated == true ? .published : .source)
        case .image(let session): return try await session.classify(request.imageData)
        }
    }
    func validate(_ request: ClassifierRequest) async throws -> Int {
        switch self {
        case .decision(let adapter): return try await adapter.validate(state: request.input, question: request.question)
        case .image: _ = try FastViTClassifierSession.decode(request.imageData); return 0
        }
    }
    func cancel() async { if case .decision(let adapter) = self { await adapter.cancel() } }
}

enum PortableClassifierRuntime {
    static func compiledAsset(for entry: ClassifierCatalogModel, in root: URL) throws -> URL {
        let source = try entry.assetURL(in: root)
        return source.pathExtension == "mlpackage" ? try ClassifierCatalogModel.containedURL("model.mlmodelc", in: root) : source
    }

    /// Compilation validates structure without retaining an inference runtime.
    /// Full model specialization is deferred until the host admits activation.
    static func prepareDownload(_ entry: ClassifierCatalogModel, in root: URL) async throws {
        let work = Task.detached(priority: .utility) {
            let source = try entry.assetURL(in: root)
            if source.pathExtension == "mlpackage" {
                let temporary = try MLModel.compileModel(at: source)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                let destination = try compiledAsset(for: entry, in: root)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: temporary, to: destination)
            }
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        let asset = try MLModelAsset(url: compiledAsset(for: entry, in: root))
        let description = try await asset.modelDescription
        if entry.isImage { try validateImage(description) }
        else { _ = try validateLaya(description, entry: entry) }
        try Task.checkCancellation()
    }

    static func loadAdmitted(_ entry: ClassifierCatalogModel, root: URL,
        checkSafety: @escaping @Sendable () async throws -> Void) async throws -> ClassifierRuntimeSession {
        try await checkSafety()
        if entry.runtime == .gguf {
            return .decision(try await GGUFDecisionClassifierRuntime.loadAdmitted(entry, root: root, checkSafety: checkSafety))
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let url = try compiledAsset(for: entry, in: root)
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        try Task.checkCancellation()
        if entry.isImage { return .image(try FastViTClassifierSession(model: model, checkSafety: checkSafety)) }
        return .decision(try await layaAdapter(model: model, entry: entry, root: root, checkSafety: checkSafety))
    }

    private static func layaAdapter(model: MLModel, entry: ClassifierCatalogModel, root: URL,
        checkSafety: @escaping @Sendable () async throws -> Void) async throws -> CoreAIClassifierAdapter {
        let description = model.modelDescription
        let length = entry.window
        let (head, temperatures, buckets) = try validateLaya(description, entry: entry)
        let path = entry.sidecars.contains("tokenizer.json") ? "tokenizer.json" : "tokenizer/tokenizer.json"
        let tokenizerURL = try ClassifierCatalogModel.containedURL(path, in: root)
        let config = try HubApi().configuration(fileURL: tokenizerURL)
        guard let vocabulary = config.model.vocab.dictionary() else { throw CoreAIClassifierError.invalidToken }
        let added = config.addedTokens.array() ?? []
        func special(_ alternatives: [String]) throws -> Int32 {
            for name in alternatives {
                let id = added.first { $0.content.string() == name }?["id"].integer() ?? vocabulary.first { $0.key.string == name }?.value.integer()
                if let id, let value = Int32(exactly: id) { return value }
            }
            throw CoreAIClassifierError.invalidToken
        }
        let maxID = max(vocabulary.values.compactMap { $0.integer() }.max() ?? 0, added.compactMap { $0["id"].integer() }.max() ?? 0)
        let contract = try CoreAIClassifierContract(layout: .laya, window: length, headBudget: min(head, length), vocabSize: maxID + 1,
            cls: special(["<bos>", "[CLS]"]), sep: special(["<eos>", "[SEP]"]), pad: special(["<pad>", "[PAD]"]), mask: special(["<mask>", "[MASK]"]),
            sourceTemperatures: temperatures, calibratedTemperatures: buckets.isEmpty ? nil : temperatures, temperatureBuckets: buckets)
        let encode: CoreAIClassifierAdapter.Encode
        if config.preTokenizer.type.string() == "Metaspace" {
            let tokenizer = try CoreAIClassifierTokenizer(contentsOf: tokenizerURL)
            encode = { tokenizer.encode($0) }
        } else {
            let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerURL.deletingLastPathComponent())
            encode = { text in try tokenizer.encode(text: text, addSpecialTokens: false).map {
                guard let id = Int32(exactly: $0) else { throw CoreAIClassifierError.invalidToken }; return id
            } }
        }
        let session = ModelHandle(model)
        return try CoreAIClassifierAdapter(contract: contract, encode: encode, runMain: { row in
            let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            let markers = try MLMultiArray(shape: [1, 32, NSNumber(value: length)], dataType: .float32)
            let type = try MLMultiArray(shape: [1, 3], dataType: .float32)
            for i in 0..<length { ids[i] = NSNumber(value: row.inputIDs[i]); mask[i] = NSNumber(value: row.attentionMask[i]) }
            for i in 0..<markers.count { markers[i] = 0 }
            for (i, position) in row.markers.enumerated() { markers[[0, NSNumber(value: i), NSNumber(value: position)]] = 1 }
            for i in 0..<3 { type[i] = NSNumber(value: row.questionType[i]) }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask, "marker_map": markers, "question_type": type])
            let output = try await session.model.prediction(from: provider)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.shape.map(\.intValue) == [1, 32],
                  let action = output.featureValue(for: "action_probabilities")?.multiArrayValue, action.shape.map(\.intValue) == [1, 2] else { throw CoreAIClassifierError.invalidOutput }
            var values = [Float](repeating: 0, count: length)
            for (i, marker) in row.markers.enumerated() { values[marker] = logits[[0, NSNumber(value: i)]].floatValue }
            return .init(tokenLogits: values, directAnswerProbability: action[[0, 0]].doubleValue)
        }, checkSafety: checkSafety)
    }

    private static func validateImage(_ description: MLModelDescription) throws {
        guard description.inputDescriptionsByName.count == 1,
              description.inputDescriptionsByName.values.first?.type == .image,
              let output = description.predictedProbabilitiesName, description.outputDescriptionsByName[output]?.type == .dictionary,
              (description.classLabels as? [String])?.count == 1_000 else { throw CoreAIClassifierError.unsupportedContract }
    }
    private static func validateLaya(_ description: MLModelDescription, entry: ClassifierCatalogModel) throws -> (Int, [Double], [String: Double]) {
        let length = entry.window
        let inputs: [String: ([Int], MLMultiArrayDataType)] = [
            "input_ids": ([1, length], .int32), "attention_mask": ([1, length], .int32),
            "marker_map": ([1, 32, length], .float32), "question_type": ([1, 3], .float32)
        ]
        guard Set(description.inputDescriptionsByName.keys) == Set(inputs.keys),
              let creator = description.metadata[.creatorDefinedKey] as? [String: String],
              creator["length"].flatMap(Int.init) == length,
              creator["max_options"].flatMap(Int.init) == 32,
              let head = creator["head_max_len"].flatMap(Int.init),
              let temperatureData = creator["temperature"]?.data(using: .utf8),
              let temperatures = try? JSONDecoder().decode([Double].self, from: temperatureData),
              let bucketData = creator["temperature_by_options"]?.data(using: .utf8),
              let buckets = try? JSONDecoder().decode([String: Double].self, from: bucketData),
              (16...4_096).contains(head), temperatures.count == 3,
              temperatures.allSatisfy({ $0.isFinite && $0 > 0 }), buckets.values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw CoreAIClassifierError.unsupportedContract }
        for (name, (shape, type)) in inputs {
            guard let array = description.inputDescriptionsByName[name]?.multiArrayConstraint,
                  array.shape.map(\.intValue) == shape, array.dataType == type else { throw CoreAIClassifierError.unsupportedContract }
        }
        for (name, shape) in ["logits": [1, 32], "probabilities": [1, 32], "action_probabilities": [1, 2]] {
            guard let array = description.outputDescriptionsByName[name]?.multiArrayConstraint,
                  array.shape.map(\.intValue) == shape, array.dataType == .float32 else { throw CoreAIClassifierError.unsupportedContract }
        }
        return (head, temperatures, buckets)
    }
    /// Immutable Core ML handle captured exclusively by a serial adapter.
    private final class ModelHandle: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }
    }
}

actor FastViTClassifierSession {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let checkSafety: @Sendable () async throws -> Void

    init(model: MLModel, checkSafety: @escaping @Sendable () async throws -> Void) throws {
        let description = model.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              let name = description.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key,
              let output = description.predictedProbabilitiesName,
              description.outputDescriptionsByName[output]?.type == .dictionary,
              let labels = description.classLabels as? [String], labels.count == 1_000 else { throw CoreAIClassifierError.unsupportedContract }
        self.model = model; inputName = name; outputName = output; self.checkSafety = checkSafety
    }

    nonisolated static func decode(_ data: Data?) throws -> CGImage {
        guard let data, !data.isEmpty, data.count <= 20 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
              ] as CFDictionary) else { throw CoreAIInferenceError.unavailable("Choose a valid image under 20 MB.") }
        return image
    }

    func classify(_ data: Data?) async throws -> CoreAIClassifierAnswer {
        let image = try Self.decode(data)
        guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else { throw CoreAIClassifierError.unsupportedContract }
        let value = try MLFeatureValue(cgImage: image, constraint: constraint)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        try await checkSafety()
        let output = try await model.prediction(from: provider)
        try Task.checkCancellation()
        guard let scores = output.featureValue(for: outputName)?.dictionaryValue as? [String: NSNumber], !scores.isEmpty else { throw CoreAIClassifierError.invalidOutput }
        // Apple's two "crane" labels share a dictionary key. Keep exactly the
        // published dictionary scores; do not invent or renormalize categories.
        let ranked = scores.sorted { $0.value.doubleValue == $1.value.doubleValue ? $0.key < $1.key : $0.value.doubleValue > $1.value.doubleValue }
        let values = ranked.map { $0.value.doubleValue }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CoreAIClassifierError.invalidOutput }
        return .init(optionIDs: ranked.map(\.key), probabilities: values, choice: ranked.first?.key,
            score: nil, trueProbability: nil, directAnswerProbability: nil, temperature: 1)
    }
}
