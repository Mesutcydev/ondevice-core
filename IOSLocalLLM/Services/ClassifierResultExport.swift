import Foundation

enum ClassifierResultExport {
    static func object(_ answer: CoreAIClassifierAnswer, modelID: String? = nil, elapsedSeconds: Double? = nil) -> [String: Any] {
        var result: [String: Any] = ["options": Array(zip(answer.optionIDs, answer.probabilities)).map { ["id": $0.0, "probability": $0.1] as [String: Any] }, "temperature": answer.temperature]
        if let value = answer.choice { result["choice"] = value }
        if let value = answer.score { result["score"] = value }
        if let value = answer.trueProbability { result["true_probability"] = value }
        if let value = answer.directAnswerProbability { result["direct_answer_probability"] = value }
        if let modelID {
            result["model"] = modelID
            if let entry = ClassifierCatalog.model(id: modelID) {
                result["repository"] = entry.repo; result["source_revision"] = entry.revision
                result["runtime"] = entry.runtime.rawValue; result["modality"] = entry.isImage ? "image" : "text"
            }
        }
        if let elapsedSeconds, elapsedSeconds.isFinite { result["elapsed_seconds"] = elapsedSeconds }
        return result
    }
    static func json(_ answer: CoreAIClassifierAnswer, modelID: String? = nil, elapsedSeconds: Double? = nil) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object(answer, modelID: modelID, elapsedSeconds: elapsedSeconds), options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }
}
