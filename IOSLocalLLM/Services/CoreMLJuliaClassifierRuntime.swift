import CoreML
import Foundation

/// Bridge for the existing Julia Core ML export used in MatchRater:
/// input_ids [1,L] int32 + qtype [1] int32 -> scores [1,L].
/// The host supplies an already admitted, CPU-only MLModel and its tokenizer.
/// Weight loading, residency and unload remain in the host's lifecycle.
@available(iOS 17.0, macOS 14.0, *)
enum CoreMLJuliaClassifierRuntime {
    static func makeAdapter(
        model: MLModel,
        encode: @escaping CoreAIClassifierAdapter.Encode,
        window: Int = 2_048,
        headBudget: Int = 512,
        checkSafety: @escaping @Sendable () async throws -> Void
    ) throws -> CoreAIClassifierAdapter {
        let description = model.modelDescription
        guard model.configuration.computeUnits == .cpuOnly,
              Set(description.inputDescriptionsByName.keys) == ["input_ids", "qtype"],
              let ids = description.inputDescriptionsByName["input_ids"]?.multiArrayConstraint,
              ids.dataType == .int32, accepts(ids, shape: [1, window]),
              let type = description.inputDescriptionsByName["qtype"]?.multiArrayConstraint,
              type.dataType == .int32, accepts(type, shape: [1]),
              let scores = description.outputDescriptionsByName["scores"]?.multiArrayConstraint,
              [.float16, .float32, .double].contains(scores.dataType)
        else { throw CoreAIClassifierError.unsupportedContract }
        let contract = try CoreAIClassifierContract(juliaCoreMLWindow: window, headBudget: headBudget)
        let session = Session(model: model, inputConstraint: ids)
        return try CoreAIClassifierAdapter(contract: contract, encode: encode, runMain: { row in
            // Core ML Julia has a flexible, unpadded sequence. The shared host
            // builds one bounded row; the bridge sends only its real tokens.
            let count = row.realTokenCount
            guard accepts(session.inputConstraint, shape: [1, count]), let questionType = row.questionType.firstIndex(of: 1) else {
                throw CoreAIClassifierError.unsupportedContract
            }
            let tokens = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
            let pointer = tokens.dataPointer.bindMemory(to: Int32.self, capacity: count)
            for index in 0..<count { pointer[index] = row.inputIDs[index] }
            let qtype = try MLMultiArray(shape: [1], dataType: .int32)
            qtype[0] = NSNumber(value: questionType)
            let inputs = try MLDictionaryFeatureProvider(dictionary: ["input_ids": tokens, "qtype": qtype])
            let output = try await session.model.prediction(from: inputs)
            guard let values = output.featureValue(for: "scores")?.multiArrayValue,
                  values.shape.map(\.intValue) == [1, count],
                  [.float16, .float32, .double].contains(values.dataType)
            else { throw CoreAIClassifierError.invalidOutput }
            var logits = [Float](repeating: 0, count: contract.window)
            // Indexed access honors Core ML's strides and scalar type.
            for marker in row.markers { logits[marker] = values[[0, NSNumber(value: marker)]].floatValue }
            return CoreAIClassifierOutput(tokenLogits: logits)
        }, checkSafety: checkSafety)
    }

    /// Core ML's Objective-C model/description types have no Sendable
    /// annotation. This private immutable handle is only captured by the
    /// adapter's serialized executor. The host must not run this model through
    /// another adapter while it is in use.
    private final class Session: @unchecked Sendable {
        let model: MLModel
        let inputConstraint: MLMultiArrayConstraint
        init(model: MLModel, inputConstraint: MLMultiArrayConstraint) {
            self.model = model; self.inputConstraint = inputConstraint
        }
    }

    private static func accepts(_ constraint: MLMultiArrayConstraint, shape: [Int]) -> Bool {
        switch constraint.shapeConstraint.type {
        case .range:
            let ranges = constraint.shapeConstraint.sizeRangeForDimension
            return ranges.count == shape.count && zip(ranges, shape).allSatisfy { NSLocationInRange($1, $0.rangeValue) }
        case .enumerated:
            return constraint.shapeConstraint.enumeratedShapes.contains { $0.map(\.intValue) == shape }
        case .unspecified:
            return constraint.shape.map(\.intValue) == shape
        @unknown default: return false
        }
    }
}
