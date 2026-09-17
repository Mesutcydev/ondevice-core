import Foundation

// MARK: - RuntimeEngineFactory
//
// Single place that turns catalog/model metadata into a runtime engine and
// its functional capabilities. Nothing else should match on `ModelRuntime`
// to decide what a runtime can do.
//
// Existing runtimes are wired through the app's established execution paths:
//   • .mlx / .llamaCpp → CodingAssistantRuntimeBackend (CodingAssistantService)
//   • .coreAI          → CoreAIRuntimeBackend (CoreAIInferenceService)
// A future `.edge0MLX` engine is added by returning a new backend here. The
// factory deliberately refuses to execute Edge0 today, so no placeholder
// inference can be reached.

enum RuntimeEngineFactory {

    // MARK: - Capabilities

    /// Model-independent baseline for a runtime. Model-level flags
    /// (vision/tools) are folded in by `capabilities(...)`.
    ///
    /// `storageBackedWeights` is true only where weights stay file-backed and
    /// iOS can reclaim clean pages (llama.cpp mmap today, Edge0 experts later).
    /// `supportsSharedVisionRuntime` marks the MLX dual-role container used by
    /// Lens — the only vision-in-chat path.
    static func baselineCapabilities(for runtime: ModelRuntime) -> RuntimeCapabilities {
        switch runtime {
        case .mlx:
            return RuntimeCapabilities(
                streamsTokens: true,
                supportsVision: true,
                supportsSharedVisionRuntime: true,
                supportsTools: true,
                supportsRAG: true,
                storageBackedWeights: false,
                supportsExpertStreaming: false,
                requiresExclusiveGPUResidency: true,
                supportsPrefixCache: false
            )
        case .llamaCpp:
            return RuntimeCapabilities(
                streamsTokens: true,
                supportsVision: true,
                supportsSharedVisionRuntime: false,
                supportsTools: true,
                supportsRAG: true,
                storageBackedWeights: true,
                supportsExpertStreaming: false,
                requiresExclusiveGPUResidency: false,
                supportsPrefixCache: true
            )
        case .coreAI:
            return RuntimeCapabilities(
                streamsTokens: true,
                supportsVision: false,
                supportsSharedVisionRuntime: false,
                supportsTools: false,
                supportsRAG: true,
                storageBackedWeights: false,
                supportsExpertStreaming: false,
                requiresExclusiveGPUResidency: true,
                supportsPrefixCache: false
            )
        case .edge0MLX:
            return RuntimeCapabilities(
                streamsTokens: true,
                supportsVision: false,
                supportsSharedVisionRuntime: false,
                supportsTools: false,
                // RAG orchestration is runtime-independent but not yet tested
                // end-to-end on Edge0; keep the claim off until it is.
                supportsRAG: false,
                storageBackedWeights: true,
                supportsExpertStreaming: true,
                requiresExclusiveGPUResidency: true,
                supportsPrefixCache: false
            )
        }
    }

    static func capabilities(
        runtime: ModelRuntime,
        modelVision: Bool = false,
        modelTools: Bool = false,
        modelRAG: Bool = true
    ) -> RuntimeCapabilities {
        baselineCapabilities(for: runtime).applying(
            modelVision: modelVision,
            modelTools: modelTools,
            modelRAG: modelRAG
        )
    }

    static func capabilities(for model: LocalModel) -> RuntimeCapabilities {
        capabilities(
            runtime: model.runtime,
            modelVision: model.capabilities.contains(.vision),
            modelTools: model.capabilities.contains(.tools)
        )
    }

    static func capabilities(for model: AssistantModel) -> RuntimeCapabilities {
        capabilities(
            runtime: model.runtime,
            modelVision: model.supportsVision,
            modelTools: model.supportsTools
        )
    }

    // MARK: - Availability

    /// Human-readable reason the runtime cannot execute in this build, or nil
    /// when an engine can be built. Edge0 now resolves to the native engine.
    static func unsupportedReason(for runtime: ModelRuntime) -> String? {
        nil
    }

    static func isSupported(_ runtime: ModelRuntime) -> Bool {
        unsupportedReason(for: runtime) == nil
    }

    // MARK: - Engine construction

    @MainActor
    static func makeEngine(for model: LocalModel) throws -> any RuntimeEngine {
        if let reason = unsupportedReason(for: model.runtime) {
            throw RuntimeError.unsupportedOperation(reason)
        }
        let capabilities = capabilities(for: model)
        switch model.runtime {
        case .mlx, .llamaCpp:
            let backend = CodingAssistantRuntimeBackend(
                model: resolvedAssistantModel(for: model)
            )
            return ManagedRuntimeEngine(
                id: model.id,
                runtime: model.runtime,
                capabilities: capabilities,
                backend: backend
            )
        case .coreAI:
            let backend = CoreAIRuntimeBackend(model: model)
            return ManagedRuntimeEngine(
                id: model.id,
                runtime: model.runtime,
                capabilities: capabilities,
                backend: backend
            )
        case .edge0MLX:
            return ManagedRuntimeEngine(
                id: model.id,
                runtime: .edge0MLX,
                capabilities: capabilities,
                backend: Edge0RuntimeBackend()
            )
        }
    }

    @MainActor
    static func makeEngine(for model: AssistantModel) throws -> any RuntimeEngine {
        try makeEngine(for: LocalModel(assistantModel: model))
    }

    /// Maps a catalog/app model onto the `AssistantModel` the chat service
    /// loads. Presets win; anything else is synthesized from the descriptor so
    /// downloaded/imported models keep working unchanged.
    @MainActor
    static func resolvedAssistantModel(for model: LocalModel) -> AssistantModel {
        if let preset = AssistantModelCatalog.presets.first(where: {
            $0.id == model.id || $0.repoID == model.repoID
        }) {
            return preset
        }
        return AssistantModel(
            id: model.id,
            repoID: model.repoID,
            displayName: model.displayName,
            subtitle: "custom · \(model.runtime.label)",
            approxRAMBytes: model.approxRAMBytes,
            tags: [],
            contextWindowTokens: model.contextWindowTokens,
            capabilities: model.capabilities,
            supportsTools: model.capabilities.contains(.tools),
            runtime: model.runtime
        )
    }
}
