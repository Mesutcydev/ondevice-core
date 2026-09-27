import Foundation

// MARK: - CodingAssistantRuntimeBackend
//
// Transitional adapter that exposes the app's existing assistant execution
// (MLX and llama.cpp, both owned by `CodingAssistantService`) behind the
// `RuntimeEngineBackend` contract. No inference math moves here; this is the
// seam the next phase replaces piecewise with engine-owned execution.

@MainActor
final class CodingAssistantRuntimeBackend: RuntimeEngineBackend {
    private let model: AssistantModel

    init(model: AssistantModel) {
        self.model = model
    }

    func load(model requested: LocalModel) async throws {
        let service = CodingAssistantService.shared
        if service.activeModel.id != model.id || service.state != .ready {
            await service.switchTo(model, persistAsDefault: false)
        }
        switch service.state {
        case .ready, .generating:
            return
        case .failed(let detail):
            throw RuntimeError.modelLoadBlocked(reason: detail)
        case .loading(let detail):
            throw RuntimeError.modelLoadBlocked(reason: "The model is still loading: \(detail)")
        case .unloaded:
            throw RuntimeError.modelLoadBlocked(reason: "The model could not be loaded.")
        }
    }

    func unload() async {
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
    }

    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<TokenEvent, Error> {
        let service = CodingAssistantService.shared
        guard service.activeModel.id == model.id else {
            throw RuntimeError.modelNotLoaded(model.repoID)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            service.generate(
                messages: messages,
                maxTokensOverride: options.maxTokens,
                temperatureOverride: options.temperature,
                topPOverride: options.topP,
                jsonMode: options.jsonMode,
                forceNoThinking: options.thinkingMode == .disabled,
                onToken: { token in
                    continuation.yield(.token(token))
                },
                onComplete: { rate in
                    continuation.yield(.usage(
                        tokensPerSecond: rate,
                        inputTokens: nil,
                        outputTokens: nil
                    ))
                    continuation.yield(.completed)
                    continuation.finish()
                },
                onError: { detail in
                    continuation.finish(throwing: RuntimeError.underlying(detail))
                }
            )
        }
    }

    func cancel() async {
        CodingAssistantService.shared.stopGeneration()
    }
}

// MARK: - CoreAIRuntimeBackend
//
// Adapter over Apple's Core AI runtime. The Core AI SDK stays isolated behind
// `CoreAIInferenceService`; this backend only maps the uniform lifecycle and
// streaming contract onto the app facade.

@MainActor
final class CoreAIRuntimeBackend: RuntimeEngineBackend {
    private let selectionID: String

    init(model: LocalModel) {
        self.selectionID = CoreAIInferenceService.normalizedSelectionID(model.id)
    }

    func load(model requested: LocalModel) async throws {
        let store = CoreAIModelStore.shared
        store.refresh()
        do {
            _ = try store.selectModel(id: requested.id)
        } catch {
            throw RuntimeError.invalidModelFiles(
                "The Core AI pack is not installed: \(error.localizedDescription)"
            )
        }
        try await CoreAIInferenceService.shared.load()
        guard CoreAIInferenceService.shared.isLoaded(as: selectionID) else {
            throw RuntimeError.modelLoadBlocked(
                reason: "The selected Core AI pack is not ready."
            )
        }
    }

    func unload() async {
        await CoreAIInferenceService.shared.unload()
    }

    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<TokenEvent, Error> {
        guard CoreAIInferenceService.shared.isLoaded(as: selectionID) else {
            throw RuntimeError.modelNotLoaded(selectionID)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            Task { @MainActor in
                do {
                    try await CoreAIInferenceService.shared.generate(
                        messages: messages,
                        maxTokens: options.maxTokens,
                        temperature: options.temperature,
                        thinkingEnabled: options.thinkingMode == .disabled ? false : nil,
                        onToken: { token in
                            continuation.yield(.token(token))
                        }
                    )
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancel() async {
        CoreAIInferenceService.shared.cancel()
    }
}
