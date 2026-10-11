import Foundation

enum LocalClassifierAPI {
    static func decodeActivation(_ body: Data) throws -> String {
        guard body.count <= 4_096,
              let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(value.keys) == ["model"], let id = value["model"] as? String,
              !id.isEmpty, id.count <= 512 else { throw CoreAIClassifierError.invalidQuestion }
        return id.hasPrefix("coreai:") ? id : "coreai:\(id)"
    }
    static func decodeRequest(_ body: Data) throws -> ClassifierRequest {
        let keys: Set<String> = ["model", "input", "instructions", "type", "options", "rubric", "falseCriterion", "trueCriterion", "calibrated"]
        guard body.count <= 192_000,
              let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(value.keys).isSubset(of: keys) else { throw CoreAIClassifierError.invalidQuestion }
        let decoded = try JSONDecoder().decode(ClassifierRequest.self, from: body)
        guard !decoded.model.isEmpty, decoded.model.count <= 512,
              decoded.input.utf8.count <= 64_000, decoded.instructions.utf8.count <= 16_000,
              decoded.options.map({ (2...20).contains($0.count) && $0.allSatisfy { !$0.id.isEmpty && $0.id.count <= 128 && $0.description.utf8.count <= 8_000 } }) ?? true,
              decoded.rubric.map({ (2...20).contains($0.count) && $0.allSatisfy { $0.utf8.count <= 8_000 } }) ?? true,
              (decoded.falseCriterion?.utf8.count ?? 0) <= 8_000,
              (decoded.trueCriterion?.utf8.count ?? 0) <= 8_000 else { throw CoreAIClassifierError.invalidQuestion }
        let request = ClassifierRequest(model: decoded.model.hasPrefix("coreai:") ? decoded.model : "coreai:\(decoded.model)",
            input: decoded.input, instructions: decoded.instructions, type: decoded.type,
            options: decoded.options, rubric: decoded.rubric, falseCriterion: decoded.falseCriterion,
            trueCriterion: decoded.trueCriterion, calibrated: decoded.calibrated)
        _ = try request.question
        return request
    }
}
