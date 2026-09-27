import Foundation

// MARK: - RuntimeCapabilities
//
// Functional description of what a runtime + model pairing can actually do.
//
// The rest of the app should ask "does this runtime support X?" through this
// value instead of matching on `ModelRuntime` identity. The mapping from a
// catalog model to these flags lives in `RuntimeEngineFactory` so a new
// runtime is added in one place.
//
// This type is intentionally free of app types (no SwiftUI, no services) so it
// stays portable and unit-testable on its own.

struct RuntimeCapabilities: Sendable, Equatable, Hashable {
    /// The runtime produces an incremental token stream (required by chat).
    let streamsTokens: Bool
    /// The runtime + model pairing can process image input.
    let supportsVision: Bool
    /// Image-in-chat can reuse the shared Lens vision container. Vision models
    /// loaded through a dedicated vision service (Lens/VLM services) do not
    /// set this even when `supportsVision` is true.
    let supportsSharedVisionRuntime: Bool
    /// The pairing can emit/consume the app's tool-call protocol.
    let supportsTools: Bool
    /// The pairing can answer from retrieved context (RAG).
    let supportsRAG: Bool
    /// Weights are memory-mapped/file-backed, so iOS can reclaim clean pages
    /// under memory pressure instead of the process owning every byte.
    let storageBackedWeights: Bool
    /// The runtime can stream weights from storage instead of materializing
    /// the whole model (future Edge0 expert streaming).
    let supportsExpertStreaming: Bool
    /// Only one GPU residency may exist at a time for this runtime.
    let requiresExclusiveGPUResidency: Bool
    /// The runtime keeps a reusable KV prefix cache (continuation).
    let supportsPrefixCache: Bool

    init(
        streamsTokens: Bool = true,
        supportsVision: Bool = false,
        supportsSharedVisionRuntime: Bool = false,
        supportsTools: Bool = false,
        supportsRAG: Bool = true,
        storageBackedWeights: Bool = false,
        supportsExpertStreaming: Bool = false,
        requiresExclusiveGPUResidency: Bool = true,
        supportsPrefixCache: Bool = false
    ) {
        self.streamsTokens = streamsTokens
        self.supportsVision = supportsVision
        self.supportsSharedVisionRuntime = supportsSharedVisionRuntime
        self.supportsTools = supportsTools
        self.supportsRAG = supportsRAG
        self.storageBackedWeights = storageBackedWeights
        self.supportsExpertStreaming = supportsExpertStreaming
        self.requiresExclusiveGPUResidency = requiresExclusiveGPUResidency
        self.supportsPrefixCache = supportsPrefixCache
    }

    /// Returns a copy with the model-level capability flags folded in.
    /// Runtime policy wins where a runtime never supports a feature:
    /// a model cannot add vision to a text-only executor.
    func applying(
        modelVision: Bool = false,
        modelTools: Bool = false,
        modelRAG: Bool = true
    ) -> RuntimeCapabilities {
        RuntimeCapabilities(
            streamsTokens: streamsTokens,
            supportsVision: supportsVision && modelVision,
            supportsSharedVisionRuntime: supportsSharedVisionRuntime && modelVision,
            supportsTools: supportsTools || modelTools,
            supportsRAG: supportsRAG && modelRAG,
            storageBackedWeights: storageBackedWeights,
            supportsExpertStreaming: supportsExpertStreaming,
            requiresExclusiveGPUResidency: requiresExclusiveGPUResidency,
            supportsPrefixCache: supportsPrefixCache
        )
    }
}
