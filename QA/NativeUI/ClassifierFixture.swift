import Foundation

/// UI-only graph/tokenizer fixtures with the pinned public Laya metadata.
/// Exercises the production row builder/readout; never loads model weights.
@MainActor enum ClassifierFixture {
    static let models: [ClassifierModelInfo] = [
        .init(id: "coreai:zoo-laya-multilingual", name: "Laya Multilingual", window: 512),
        .init(id: "classifier:julia-1-q8", name: "Julia-1 · 8-bit", window: 1_024),
        .init(id: "classifier:fastvit-t8", name: "FastViT T8", window: 0, isImage: true)
    ]
    static func makeController() -> CoreAIClassifierWorkbench {
        let metadataURL = Bundle.main.url(forResource: "laya-metadata", withExtension: "json")!
        let contract = try! CoreAIClassifierContract(metadata: Data(contentsOf: metadataURL))
        let adapter = try! CoreAIClassifierAdapter(contract: contract,
            encode: { Array(repeating: 5, count: $0.split(whereSeparator: \.isWhitespace).count) },
            runMain: { row in
                if ProcessInfo.processInfo.arguments.contains("-classifier-slow") { try await Task.sleep(for: .seconds(3)) }
                var logits = Array(repeating: Float(0), count: contract.window)
                for (i, marker) in row.markers.enumerated() { logits[marker] = Float(2 - i) }
                return .init(tokenLogits: logits, pooledCLS: Array(repeating: 0, count: 768))
            }, runAct: { _, _ in [2, 0] }, checkSafety: {})
        return CoreAIClassifierWorkbench(backend: .init(
            activate: { id in
                try await Task.sleep(for: .milliseconds(250))
                if ProcessInfo.processInfo.arguments.contains("-classifier-refused") {
                    throw CoreAIInferenceError.unavailable("Not enough memory to safely activate this classifier.")
                }
                if id == "classifier:fastvit-t8" { return .init(id: id, name: "FastViT T8", window: 0, isImage: true) }
                return .init(id: id, name: "Laya Multilingual", window: contract.window,
                    supportsCalibration: contract.calibratedTemperatures != nil, hasDirectAnswerHead: true)
            }, run: { request in
                if request.imageData != nil {
                    return .init(optionIDs: ["tabby cat", "tiger cat", "Egyptian cat"], probabilities: [0.8, 0.15, 0.05],
                        choice: "tabby cat", score: nil, trueProbability: nil, directAnswerProbability: nil, temperature: 1)
                }
                return try await adapter.classify(state: request.input, question: request.question,
                    calibration: request.calibrated == true ? .published : .source)
            }, validate: { request in
                if request.imageData != nil { return 0 }
                return try await adapter.validate(state: request.input, question: request.question)
            },
            cancel: { Task { await adapter.cancel() } }, unload: {}
        ))
    }
}
