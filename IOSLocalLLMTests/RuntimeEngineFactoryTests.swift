import XCTest
@testable import IOSLocalLLM

// MARK: - RuntimeEngineFactoryTests
//
// Selection + capability mapping for every declared runtime. These are the
// pure decision points a third runtime must pass through.

final class RuntimeEngineFactoryTests: XCTestCase {

    // MARK: - Selection

    @MainActor
    func testMLXModelResolvesToMLXEngine() throws {
        let engine = try RuntimeEngineFactory.makeEngine(
            for: makeModel(runtime: .mlx)
        )
        XCTAssertEqual(engine.runtime, .mlx)
        XCTAssertFalse(engine.capabilities.storageBackedWeights)
        XCTAssertFalse(engine.capabilities.supportsExpertStreaming)
        XCTAssertTrue(engine.capabilities.streamsTokens)
    }

    @MainActor
    func testGGUFModelResolvesToLlamaCppEngine() throws {
        let engine = try RuntimeEngineFactory.makeEngine(
            for: makeModel(runtime: .llamaCpp)
        )
        XCTAssertEqual(engine.runtime, .llamaCpp)
        XCTAssertTrue(engine.capabilities.storageBackedWeights)
        XCTAssertTrue(engine.capabilities.supportsPrefixCache)
        XCTAssertFalse(engine.capabilities.supportsSharedVisionRuntime)
    }

    @MainActor
    func testCoreAIModelResolvesToCoreAIEngine() throws {
        let engine = try RuntimeEngineFactory.makeEngine(
            for: makeModel(runtime: .coreAI)
        )
        XCTAssertEqual(engine.runtime, .coreAI)
        XCTAssertFalse(engine.capabilities.supportsTools)
        XCTAssertTrue(engine.capabilities.requiresExclusiveGPUResidency)
    }

    @MainActor
    func testEdge0DeclarationResolvesToNativeEngine() throws {
        let model = makeModel(runtime: .edge0MLX)
        XCTAssertTrue(RuntimeEngineFactory.isSupported(.edge0MLX))
        XCTAssertNil(RuntimeEngineFactory.unsupportedReason(for: .edge0MLX))

        let engine = try RuntimeEngineFactory.makeEngine(for: model)
        XCTAssertEqual(engine.runtime, .edge0MLX)
        XCTAssertTrue(engine.capabilities.storageBackedWeights)
        XCTAssertTrue(engine.capabilities.supportsExpertStreaming)
        XCTAssertFalse(engine.capabilities.supportsVision)
        XCTAssertFalse(engine.capabilities.supportsTools)
        XCTAssertFalse(engine.capabilities.supportsRAG)
    }

    // MARK: - Capabilities

    @MainActor
    func testVisionCapabilityRequiresASupportingRuntimeAndModel() {
        let mlxVision = RuntimeEngineFactory.capabilities(
            for: makeModel(runtime: .mlx, capabilities: [.vision])
        )
        XCTAssertTrue(mlxVision.supportsVision)
        XCTAssertTrue(mlxVision.supportsSharedVisionRuntime)

        let ggufVision = RuntimeEngineFactory.capabilities(
            for: makeModel(runtime: .llamaCpp, capabilities: [.vision])
        )
        XCTAssertTrue(ggufVision.supportsVision, "mtmd GGUF VLMs support vision")
        XCTAssertFalse(ggufVision.supportsSharedVisionRuntime)

        let coreAIVision = RuntimeEngineFactory.capabilities(
            for: makeModel(runtime: .coreAI, capabilities: [.vision])
        )
        XCTAssertFalse(coreAIVision.supportsVision, "runtime policy wins over model metadata")

        let mlxText = RuntimeEngineFactory.capabilities(for: makeModel(runtime: .mlx))
        XCTAssertFalse(mlxText.supportsVision)
    }

    func testToolPolicyMatchesExistingBehavior() {
        // MLX/GGUF keep the tolerant text protocol regardless of model flag.
        XCTAssertTrue(RuntimeEngineFactory.capabilities(runtime: .mlx).supportsTools)
        XCTAssertTrue(RuntimeEngineFactory.capabilities(runtime: .llamaCpp).supportsTools)
        // Core AI only advertises tools for curated models.
        XCTAssertFalse(RuntimeEngineFactory.capabilities(runtime: .coreAI).supportsTools)
        XCTAssertTrue(
            RuntimeEngineFactory.capabilities(runtime: .coreAI, modelTools: true).supportsTools
        )
        // Edge0 is declaration-only and must require explicit model support.
        XCTAssertFalse(RuntimeEngineFactory.capabilities(runtime: .edge0MLX).supportsTools)
        XCTAssertTrue(
            RuntimeEngineFactory.capabilities(runtime: .edge0MLX, modelTools: true).supportsTools
        )
    }

    func testStorageBackingIsReservedForStreamingRuntimes() {
        XCTAssertTrue(RuntimeEngineFactory.capabilities(runtime: .llamaCpp).storageBackedWeights)
        XCTAssertTrue(RuntimeEngineFactory.capabilities(runtime: .edge0MLX).storageBackedWeights)
        XCTAssertFalse(RuntimeEngineFactory.capabilities(runtime: .mlx).storageBackedWeights)
        XCTAssertFalse(RuntimeEngineFactory.capabilities(runtime: .coreAI).storageBackedWeights)
    }

    func testEdge0IsTheOnlyExpertStreamingRuntime() {
        for runtime in ModelRuntime.allCases where runtime != .edge0MLX {
            XCTAssertFalse(
                RuntimeEngineFactory.capabilities(runtime: runtime).supportsExpertStreaming,
                "\(runtime) must not claim Edge0 expert streaming"
            )
        }
        XCTAssertTrue(
            RuntimeEngineFactory.capabilities(runtime: .edge0MLX).supportsExpertStreaming
        )
    }

    @MainActor
    func testAssistantModelCapabilitiesUseModelToolFlag() {
        let coreAISelection = AssistantModel(
            id: "coreai:test",
            repoID: "coreai:test",
            displayName: "Test Core AI",
            subtitle: "test",
            approxRAMBytes: 0,
            tags: [],
            contextWindowTokens: 1_024,
            capabilities: [],
            supportsTools: false,
            runtime: .coreAI
        )
        XCTAssertFalse(
            RuntimeEngineFactory.capabilities(for: coreAISelection).supportsTools
        )

        let toolCapable = AssistantModel(
            id: "coreai:tools",
            repoID: "coreai:tools",
            displayName: "Tool Core AI",
            subtitle: "test",
            approxRAMBytes: 0,
            tags: [],
            contextWindowTokens: 1_024,
            capabilities: [],
            supportsTools: true,
            runtime: .coreAI
        )
        XCTAssertTrue(RuntimeEngineFactory.capabilities(for: toolCapable).supportsTools)
    }

    @MainActor
    func testEdge0CatalogPresetRoutesToNativeBackend() throws {
        guard let preset = AssistantModelCatalog.presets.first(where: {
            $0.runtime == .edge0MLX
        }) else {
            return XCTFail("The curated catalog must declare an Edge0 preset.")
        }
        XCTAssertEqual(preset.repoID, "Edge0/Edge0-8B-A1B-preview")

        // The AssistantModel overload must resolve through the same seam as
        // the LocalModel overload — never the MLX package loader.
        let engine = try RuntimeEngineFactory.makeEngine(for: preset)
        XCTAssertEqual(engine.runtime, .edge0MLX)
        XCTAssertTrue(engine.capabilities.storageBackedWeights)
        XCTAssertTrue(engine.capabilities.supportsExpertStreaming)
        XCTAssertFalse(engine.capabilities.supportsRAG)
    }

    // MARK: - Helpers

    private func makeModel(
        runtime: ModelRuntime,
        capabilities: Set<ModelCapability> = []
    ) -> LocalModel {
        let id = "selection-\(runtime.rawValue)"
        return LocalModel(
            id: id,
            repoID: "example/\(id)",
            displayName: id,
            familyID: ModelFamily.inferID(from: "example/\(id)"),
            runtime: runtime,
            capabilities: capabilities
        )
    }
}
