import Foundation

/// UI-only graph/tokenizer fixtures with the pinned public Laya metadata.
/// Exercises the production row builder/readout; never loads model weights.
@MainActor enum ClassifierFixture {
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
                return .init(id: id, name: "Laya Multilingual", window: contract.window,
                    supportsCalibration: contract.calibratedTemperatures != nil, hasDirectAnswerHead: true)
            }, run: { request in
                try await adapter.classify(state: request.input, question: request.question,
                    calibration: request.calibrated == true ? .published : .source)
            }, validate: { request in try await adapter.validate(state: request.input, question: request.question) },
            cancel: { Task { await adapter.cancel() } }, unload: {}
        ))
    }
}
