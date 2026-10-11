#if canImport(CoreAI)
import CoreAI
import Foundation

/// SDK bridge for an AIModel already loaded by the host's coordinated
/// residency/admission path. There is intentionally no independent weight
/// loader here. Pass a tokenizer loaded from this bundle's tokenizer folder,
/// with addSpecialTokens=false, and keep the adapter within the host's lifetime.
@available(iOS 27.0, macOS 27.0, *)
enum CoreAIClassifierRuntime {
    /// Called only after the shared host has drained other runtimes and admitted
    /// this allocation. The shared Core AI service owns and drains its lifetime.
    @MainActor static func loadAdmittedAdapter(resourcesAt root: URL,
        checkSafety: @escaping @Sendable () async throws -> Void) async throws -> CoreAIClassifierAdapter {
        let metadata = try Data(contentsOf: root.appendingPathComponent("metadata.json"))
        let contract = try CoreAIClassifierContract(metadata: metadata)
        let tokenizerRoot = root.appendingPathComponent("tokenizer").resolvingSymlinksInPath()
        guard tokenizerRoot.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CoreAIClassifierError.unsafeAssetPath }
        let tokenizerLoad = Task.detached(priority: .userInitiated) {
            try CoreAIClassifierTokenizer(contentsOf: tokenizerRoot.appendingPathComponent("tokenizer.json"))
        }
        let tokenizer = try await withTaskCancellationHandler {
            try await tokenizerLoad.value
        } onCancel: { tokenizerLoad.cancel() }
        try Task.checkCancellation()
        try await checkSafety()
        guard ComputeUnitKind.availableKinds.contains(.gpu) else {
            throw CoreAIInferenceError.unavailable("This classifier pack requires a supported GPU.")
        }
        let model = try await AIModel(contentsOf: contract.modelURL(in: root),
                                      options: SpecializationOptions(preferredComputeUnitKind: .gpu))
        try Task.checkCancellation()
        return try makeAdapter(model: model, metadata: metadata,
                               encode: { tokenizer.encode($0) }, checkSafety: checkSafety)
    }

    static func makeAdapter(
        model: AIModel,
        metadata: Data,
        encode: @escaping CoreAIClassifierAdapter.Encode,
        checkSafety: @escaping @Sendable () async throws -> Void
    ) throws -> CoreAIClassifierAdapter {
        let contract = try CoreAIClassifierContract(metadata: metadata)
        guard let mainName = contract.mainFunction,
              let descriptor = model.functionDescriptor(for: mainName),
              Set(descriptor.inputNames) == ["input_ids", "attention_mask", "qtype_onehot"],
              descriptor.stateNames.isEmpty,
              let function = try model.loadFunction(named: mainName)
        else { throw CoreAIClassifierError.unsupportedContract }
        let ids = try requireTensor(descriptor.inputDescriptor(of: "input_ids"), .int32, [1, contract.window])
        let mask = try requireTensor(descriptor.inputDescriptor(of: "attention_mask"), .int32, [1, contract.window])
        let type = try requireTensor(descriptor.inputDescriptor(of: "qtype_onehot"), .float32, [1, 3])
        _ = try requireTensor(descriptor.outputDescriptor(of: "token_logits"), .float32, [1, contract.window])
        var act: CoreAIClassifierAdapter.RunAct?
        if let name = contract.actFunction, let pooledSize = contract.pooledSize {
            _ = try requireTensor(descriptor.outputDescriptor(of: "pooled_cls"), .float32, [1, pooledSize])
            guard let actDescriptor = model.functionDescriptor(for: name),
                  Set(actDescriptor.inputNames) == ["pooled_cls", "feats"],
                  actDescriptor.stateNames.isEmpty, let actFunction = try model.loadFunction(named: name)
            else { throw CoreAIClassifierError.unsupportedContract }
            let pooled = try requireTensor(actDescriptor.inputDescriptor(of: "pooled_cls"), .float32, [1, pooledSize])
            let features = try requireTensor(actDescriptor.inputDescriptor(of: "feats"), .float32, [1, 4])
            _ = try requireTensor(actDescriptor.outputDescriptor(of: "act_logits"), .float32, [1, 2])
            act = { hidden, values in
                var outputs = try await actFunction.run(inputs: [
                    "pooled_cls": array(pooled, hidden), "feats": array(features, values)
                ])
                guard let logits = outputs.remove("act_logits")?.ndArray else { throw CoreAIClassifierError.invalidOutput }
                return try read(logits, expected: 2)
            }
        }
        return try CoreAIClassifierAdapter(contract: contract, encode: encode, runMain: { row in
            // Capturing model explicitly keeps its lifetime tied to the adapter.
            defer { withExtendedLifetime(model) {} }
            var outputs = try await function.run(inputs: [
                "input_ids": array(ids, row.inputIDs),
                "attention_mask": array(mask, row.attentionMask),
                "qtype_onehot": array(type, row.questionType)
            ])
            guard let logits = outputs.remove("token_logits")?.ndArray else { throw CoreAIClassifierError.invalidOutput }
            var result = CoreAIClassifierOutput(tokenLogits: try read(logits, expected: contract.window))
            if let pooledSize = contract.pooledSize {
                guard let pooled = outputs.remove("pooled_cls")?.ndArray else { throw CoreAIClassifierError.invalidOutput }
                result.pooledCLS = try read(pooled, expected: pooledSize)
            }
            return result
        }, runAct: act, checkSafety: checkSafety)
    }

    private static func requireTensor(_ descriptor: InferenceValue.Descriptor?, _ type: NDArray.ScalarType, _ shape: [Int]) throws -> NDArrayDescriptor {
        guard case .ndArray(let tensor) = descriptor, tensor.scalarType == type, tensor.shape == shape else {
            throw CoreAIClassifierError.unsupportedContract
        }
        return tensor
    }

    private static func array<T: BitwiseCopyable>(_ descriptor: NDArrayDescriptor, _ values: [T]) -> NDArray {
        var result = NDArray(descriptor: descriptor)
        var view = result.mutableView(as: T.self)
        view.copyElements(fromContentsOf: values)
        return result
    }

    private static func read(_ array: borrowing NDArray, expected: Int) throws -> [Float] {
        guard array.scalarType == .float32, array.shape == [1, expected] else {
            throw CoreAIClassifierError.invalidOutput
        }
        // Framework arrays may have padded rows. Honor their actual strides.
        return array.view(as: Float.self).withUnsafePointer { pointer, _, strides in
            (0..<expected).map { pointer[$0 * strides[1]] }
        }
    }
}
#endif
