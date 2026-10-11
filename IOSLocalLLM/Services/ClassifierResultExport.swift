import Foundation

enum ClassifierResultExport {
    static func object(_ answer: CoreAIClassifierAnswer) -> [String: Any] {
        var result: [String: Any] = ["options": Array(zip(answer.optionIDs, answer.probabilities)).map { ["id": $0.0, "probability": $0.1] as [String: Any] }, "temperature": answer.temperature]
        if let value = answer.choice { result["choice"] = value }
        if let value = answer.score { result["score"] = value }
        if let value = answer.trueProbability { result["true_probability"] = value }
        if let value = answer.directAnswerProbability { result["direct_answer_probability"] = value }
        return result
    }
    static func json(_ answer: CoreAIClassifierAnswer) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object(answer), options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }
}
