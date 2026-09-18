import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0_35BIntegrationTests
//
// Structural and policy tests for the experimental Edge0-35B family: curated
// catalog identity, exact download inventory, family-aware factory routing,
// unsupported-mode resolution, and the family memory/context admission.
//
// These do NOT execute device inference (that is the real-checkpoint harness
// and the physical-device diagnostics runner).

@MainActor
final class Edge0_35BIntegrationTests: XCTestCase {

    private var preset35B: AssistantModel {
        get throws {
            try XCTUnwrap(
                AssistantModelCatalog.presets.first {
                    $0.repoID == Edge0ModelFamily.qwen35MoERepoID
                },
                "The catalog must declare the curated Edge0-35B preset."
            )
        }
    }

    func testPresetIsCuratedExperimentalAndNotDefault() throws {
        let preset = try preset35B
        XCTAssertEqual(preset.runtime, .edge0MLX)
        XCTAssertEqual(preset.id, "edge0-35b-a3b-preview")
        XCTAssertEqual(preset.contextWindowTokens, 4_096)
        XCTAssertFalse(preset.supportsTools)
        XCTAssertTrue(preset.capabilities.contains(.thinking))
        XCTAssertTrue(preset.tags.contains("experimental"))
        XCTAssertNotEqual(
            AssistantModelCatalog.presets.first?.id, preset.id,
            "The experimental 35B entry must never become the default brain."
        )
        XCTAssertEqual(
            preset.downloadSizeBytes,
            Edge0_35BModelArtifacts.downloadSizeBytes
        )
    }

    func testDownloadInventoryIsExactBasePlusLoRA() {
        let allowlist = Set(Edge0_35BModelArtifacts.downloadAllowlist)
        XCTAssertEqual(
            allowlist, Set(Edge0_35BModelArtifacts.requiredFiles)
        )
        XCTAssertEqual(allowlist.count, 11)
        for shard in Edge0_35BModelArtifacts.weightShardNames {
            XCTAssertTrue(allowlist.contains(shard))
        }
        XCTAssertTrue(allowlist.contains("lora_edge0_35b.safetensors"))
        XCTAssertTrue(allowlist.contains("model.safetensors.index.json"))
        XCTAssertFalse(
            allowlist.contains { $0.contains("prerouter") },
            "The optional prerouter must not be required for exact-mode readiness."
        )
        XCTAssertFalse(allowlist.contains("vocab.json"))
        XCTAssertFalse(allowlist.contains { $0.hasSuffix(".gguf") })
    }

    func testDownloadSizeAndFreeSpaceAreDerivedFromInventory() {
        var expected: UInt64 = 0
        for name in Edge0_35BModelArtifacts.downloadAllowlist {
            expected += Edge0_35BModelArtifacts.pinnedFileSizes[name] ?? 0
        }
        XCTAssertEqual(UInt64(Edge0_35BModelArtifacts.downloadSizeBytes), expected)
        XCTAssertEqual(Edge0_35BModelArtifacts.downloadSizeBytes, 19_571_643_666)
        XCTAssertGreaterThan(
            Edge0_35BModelArtifacts.freeSpaceRequirementBytes,
            Edge0_35BModelArtifacts.downloadSizeBytes
        )
    }

    func testCatalogEntryCarriesInventoryAndSandboxDestination() throws {
        let preset = try preset35B
        let entry = try XCTUnwrap(
            ModelDownloadCenter.shared.models.first {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            },
            "The curated 35B preset must produce a download catalog entry."
        )
        XCTAssertEqual(entry.runtime, .edge0MLX)
        let allowlist = try XCTUnwrap(entry.downloader?.fileAllowlist)
        XCTAssertEqual(
            Set(allowlist), Set(Edge0_35BModelArtifacts.downloadAllowlist)
        )
        let destination = try XCTUnwrap(entry.downloader?.destination)
        XCTAssertTrue(ModelStoragePaths.isInsideSandbox(destination))
        XCTAssertEqual(
            destination.deletingLastPathComponent(),
            ModelStoragePaths.llmModels
        )
        XCTAssertEqual(
            destination.lastPathComponent,
            ModelStoragePaths.directoryName(forRepoID: preset.repoID)
        )
    }

    func testFactoryRoutingPerRuntimeAndFamily() throws {
        // 35B → Edge0 native runtime, resolved by curated identity.
        let model35B = LocalModel(assistantModel: try preset35B)
        XCTAssertEqual(
            Edge0ModelFamily.resolve(repoID: model35B.repoID), .qwen35MoE
        )
        XCTAssertEqual(model35B.runtime, .edge0MLX)

        // 8B → Edge0 native runtime.
        let preset8B = try XCTUnwrap(
            AssistantModelCatalog.presets.first {
                $0.repoID == Edge0ModelFamily.bailing8BRepoID
            }
        )
        XCTAssertEqual(
            Edge0ModelFamily.resolve(repoID: preset8B.repoID), .bailing8B
        )

        // Ordinary MLX → MLX backend.
        let mlx = LocalModel(
            id: "test-mlx", repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "MLX", familyID: "qwen3", runtime: .mlx
        )
        XCTAssertNil(Edge0ModelFamily.resolve(repoID: mlx.repoID))
        XCTAssertEqual(
            RuntimeEngineFactory.baselineCapabilities(for: mlx.runtime).supportsVision,
            true
        )

        // GGUF → llama.cpp backend.
        let gguf = LocalModel(
            id: "test-gguf", repoID: "local/model.gguf",
            displayName: "GGUF", familyID: "gguf", runtime: .llamaCpp
        )
        XCTAssertNil(Edge0ModelFamily.resolve(repoID: gguf.repoID))
        XCTAssertEqual(
            RuntimeEngineFactory.baselineCapabilities(for: gguf.runtime)
                .supportsPrefixCache,
            true
        )

        // An arbitrary Qwen3.5-MoE repo must never classify as Edge0-35B.
        XCTAssertNil(Edge0ModelFamily.resolve(repoID: "Qwen/Qwen3.5-MoE-A3B"))
    }

    func test35BModeResolutionSupportsExactAndBoundedPrefetch() {
        // Promoted production default (device-verified staged prefill +
        // bounded decode); explicit preferences are preserved.
        XCTAssertEqual(
            Edge0_35BEngine.defaultExecutionMode, .staged
        )
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BExecutionMode, .staged
        )
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BMicrobatchGroupSize, 4,
            "production 35B prefill uses microbatch group 4"
        )
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BStagedEvalWindow, 1
        )
        let savedMicro = Edge0EnginePreferences.edge0_35BMicrobatchGroupSize
        Edge0EnginePreferences.edge0_35BMicrobatchGroupSize = 1
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BMicrobatchGroupSize, 1,
            "explicit g1 (legacy staged) must be preserved"
        )
        Edge0EnginePreferences.edge0_35BMicrobatchGroupSize = savedMicro
        let labels = Edge0_35BEngine.modeLabels(.staged)
        XCTAssertEqual(labels.prefill, "staged")
        XCTAssertEqual(labels.decode, "boundedPrefetch")
        let saved = Edge0EnginePreferences.edge0_35BExecutionMode
        Edge0EnginePreferences.edge0_35BExecutionMode = .exact
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BExecutionMode, .exact,
            "an explicit Exact selection must be preserved"
        )
        Edge0EnginePreferences.edge0_35BExecutionMode = .boundedPrefetch
        XCTAssertEqual(
            Edge0EnginePreferences.edge0_35BExecutionMode, .boundedPrefetch,
            "an explicit Bounded selection must be preserved"
        )
        Edge0EnginePreferences.edge0_35BExecutionMode = saved

        let exact = Edge0_35BEngine.resolveExecutionMode(.exact)
        XCTAssertEqual(exact.effective, .exact)
        XCTAssertNil(exact.fallback)

        let bounded = Edge0_35BEngine.resolveExecutionMode(.boundedPrefetch)
        XCTAssertEqual(bounded.effective, .boundedPrefetch)
        XCTAssertNil(bounded.fallback)

        // Staged prefill is supported (staged prefill + bounded decode);
        // prerouter resolves to staged and reports the fallback.
        let staged = Edge0_35BEngine.resolveExecutionMode(.staged)
        XCTAssertEqual(staged.effective, .staged)
        XCTAssertNil(staged.fallback)
        let prerouter = Edge0_35BEngine.resolveExecutionMode(.stagedPrerouter)
        XCTAssertEqual(prerouter.effective, .staged)
        XCTAssertEqual(prerouter.fallback, "stagedPrerouter→staged")
    }

    func testFamilyBudgetsAreDistinctAndRefuseBelowTopK() {
        let contextCap = Edge0_35BContextBudget.experimentalMaximumInputTokens

        // 35B: rich device admits a pool; starvation refuses it. Legacy is
        // the pre-fix accounting and must reproduce its exact expectations.
        let rich = Edge0_35BMemoryBudget.resolve(
            availableBytes: 8 * 1_073_741_824,
            ceilingBytes: 16 * 1_073_741_824,
            accounting: .legacy,
            maxContextTokens: contextCap
        )
        XCTAssertTrue(rich.isPoolEnabled)
        XCTAssertEqual(
            rich.residentBaseBytes, 1_389_394_176
        )
        XCTAssertEqual(rich.loraBytes, 42_332_160)

        // High-memory devices reach the larger tiers (first device baseline
        // saturated 512 MiB with ~45% hit rate).
        let large = Edge0_35BMemoryBudget.resolve(
            availableBytes: 12 * 1_073_741_824,
            ceilingBytes: 16 * 1_073_741_824,
            accounting: .legacy,
            maxContextTokens: contextCap
        )
        XCTAssertEqual(large.expertPoolBytes, 2_048 * 1_048_576)
        XCTAssertGreaterThan(large.expertPoolSlots, 512)

        // Audit findings 1+2: the reclaimed accounting reserves only what
        // the admitted context can materialize and gains the 3 GiB tier.
        let reclaimed = Edge0_35BMemoryBudget.resolve(
            availableBytes: 12 * 1_073_741_824,
            ceilingBytes: 16 * 1_073_741_824,
            accounting: .reclaimed,
            maxContextTokens: contextCap
        )
        XCTAssertEqual(reclaimed.expertPoolBytes, 3_072 * 1_048_576)
        XCTAssertGreaterThan(
            reclaimed.expertPoolSlots, large.expertPoolSlots
        )
        XCTAssertLessThan(reclaimed.stateKVBytes, large.stateKVBytes)

        // Finding 1 arithmetic at the 8.5 GB iPhone clamp: legacy reserves
        // ceiling/8; reclaimed reserves the 256 MiB floor (the 4,096-token
        // need is 4096 × 20,480 + 64,389,120 ≈ 148 MB).
        let ceiling: UInt64 = 8_500_000_000
        XCTAssertEqual(
            Edge0_35BMemoryBudget.stateKVAllowance(
                ceilingBytes: ceiling, maxContextTokens: contextCap,
                accounting: .legacy
            ),
            ceiling / 8
        )
        XCTAssertEqual(
            Edge0_35BMemoryBudget.stateKVAllowance(
                ceilingBytes: ceiling, maxContextTokens: contextCap,
                accounting: .reclaimed
            ),
            Edge0_35BMemoryBudget.minimumStateKVBytes
        )

        // The reclaimed allowance follows a larger admitted context.
        XCTAssertEqual(
            Edge0_35BMemoryBudget.stateKVAllowance(
                ceilingBytes: ceiling, maxContextTokens: 32_768,
                accounting: .reclaimed
            ),
            32_768 * Edge0_35BMemoryBudget.kvBytesPerToken
                + Edge0_35BMemoryBudget.linearStateBytes
        )

        let baseline = Edge0_35BMemoryBudget.resolve(
            availableBytes: 0, ceilingBytes: 8 * 1_073_741_824,
            accounting: .legacy, maxContextTokens: contextCap
        )
        let committed = baseline.residentBytes + baseline.stateKVBytes
            + baseline.scratchBytes + baseline.safetyReserveBytes
        let poor = Edge0_35BMemoryBudget.resolve(
            availableBytes: committed + 3 * Edge0_35BMemoryBudget.expertBundleBytes,
            ceilingBytes: 8 * 1_073_741_824,
            accounting: .legacy, maxContextTokens: contextCap
        )
        XCTAssertFalse(poor.isPoolEnabled)

        // Context admission is clamped by the documented bring-up limit
        // under the reclaimed accounting too.
        let context = Edge0_35BContextBudget.resolve(
            availableBytes: 12 * 1_073_741_824,
            ceilingBytes: 16 * 1_073_741_824,
            outputTokens: 256,
            accounting: .reclaimed
        )
        XCTAssertEqual(
            context.maxInputTokens,
            Edge0_35BContextBudget.experimentalMaximumInputTokens
        )
        XCTAssertTrue(context.experimentalLimitApplied)

        // 8B constants are untouched by the 35B family.
        XCTAssertEqual(Edge0MemoryBudget.expertBundleBytes, 1_327_104)
        XCTAssertEqual(
            Edge0MemoryBudget.measuredResidentCommonBytes, 601_561_920
        )
    }

    func testRuntimeIdentityNamesTheActiveModelAndFamily() throws {
        let model35B = LocalModel(assistantModel: try preset35B)
        let block35B = try XCTUnwrap(AssistantRuntimeIdentity.block(
            for: try preset35B, loadedEdge0Family: .qwen35MoE
        ))
        XCTAssertTrue(block35B.contains("Edge0-35B A3B Preview"))
        XCTAssertTrue(block35B.contains("Qwen3.5-MoE"))
        XCTAssertTrue(block35B.contains("local/on-device"))
        XCTAssertTrue(block35B.contains("Edge0-35B"))

        // Switching models must change the identity block.
        let preset8B = try XCTUnwrap(
            AssistantModelCatalog.presets.first {
                $0.repoID == Edge0ModelFamily.bailing8BRepoID
            }
        )
        let block8B = try XCTUnwrap(AssistantRuntimeIdentity.block(
            for: preset8B, loadedEdge0Family: .bailing8B
        ))
        XCTAssertTrue(block8B.contains("Bailing-Ling"))
        XCTAssertFalse(block8B.contains("Qwen3.5-MoE"))

        // Non-Edge0 runtimes must not claim to be Edge0-35B.
        let mlx = AssistantModel(
            id: "qwen3-4b-2507",
            repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3-4B 2507",
            subtitle: "4-bit",
            approxRAMBytes: 0,
            tags: [],
            contextWindowTokens: 32_768,
            runtime: .mlx
        )
        let blockMLX = try XCTUnwrap(AssistantRuntimeIdentity.block(
            for: mlx, loadedEdge0Family: nil
        ))
        XCTAssertTrue(blockMLX.contains("Qwen3-4B 2507"))
        XCTAssertTrue(blockMLX.contains("MLX"))
        XCTAssertFalse(blockMLX.contains("35B"))

        // LocalModel conversion keeps the family resolvable.
        XCTAssertEqual(
            Edge0ModelFamily.resolve(repoID: model35B.repoID), .qwen35MoE
        )
    }

    func testIdentityInjectionReusesSystemMessageWithoutDuplicating() throws {
        let preset = try preset35B
        let existing = ChatMessage(
            role: .system, content: "You are a helpful persona."
        )
        let user = ChatMessage(role: .user, content: "hi")
        let injected = AssistantRuntimeIdentity.injecting(
            into: [existing, user], model: preset, loadedEdge0Family: .qwen35MoE
        )
        XCTAssertEqual(injected.filter { $0.role == .system }.count, 1)
        XCTAssertTrue(injected[0].content.contains("You are a helpful persona."))
        XCTAssertTrue(injected[0].content.contains(AssistantRuntimeIdentity.marker))
        XCTAssertEqual(
            injected[0].content
                .components(separatedBy: AssistantRuntimeIdentity.marker)
                .count - 1,
            1
        )

        // Idempotent: injecting again does not duplicate the block.
        let twice = AssistantRuntimeIdentity.injecting(
            into: injected, model: preset, loadedEdge0Family: .qwen35MoE
        )
        XCTAssertEqual(
            twice[0].content
                .components(separatedBy: AssistantRuntimeIdentity.marker)
                .count - 1,
            1
        )

        // No system message: one is inserted at the front.
        let inserted = AssistantRuntimeIdentity.injecting(
            into: [user], model: preset, loadedEdge0Family: .qwen35MoE
        )
        XCTAssertEqual(inserted.first?.role, .system)
        XCTAssertEqual(inserted.count, 2)
    }

    func testArtifactHelpersPinIdentityAndTargets() {
        XCTAssertTrue(Edge0_35BModelArtifacts.isSafeShardReference(
            "model-00001-of-00004.safetensors"
        ))
        XCTAssertFalse(Edge0_35BModelArtifacts.isSafeShardReference(
            "../escape.safetensors"
        ))
        XCTAssertFalse(Edge0_35BModelArtifacts.isSafeShardReference(
            "nested/model.safetensors"
        ))
        XCTAssertEqual(
            Edge0_35BModelArtifacts.expectedLoRATargetSet.count, 310
        )
        XCTAssertEqual(
            Edge0_35BModelArtifacts.expectedLoRATensorCount, 620
        )
        XCTAssertEqual(
            Edge0_35BModelArtifacts.canonicalModuleName(
                "language_model.model.layers.2.mlp.shared_expert.up_proj"
            ),
            "layers.2.mlp.shared_expert.up_proj"
        )
        XCTAssertTrue(
            Edge0_35BModelArtifacts.requiredLoRATargets(layer: 39)
                .contains("layers.39.self_attn.o_proj")
        )
        XCTAssertFalse(
            Edge0_35BModelArtifacts.expectedLoRATargetSet.contains {
                $0.hasSuffix(".mlp.gate")
            },
            "Router gates are 8-bit base tensors, not LoRA targets."
        )
    }

    // MARK: Phase 5J advisory prerouter

    func testAdvisoryPrerouterIsOptionalDefaultOffAndAdvisoryOnly() throws {
        // Artifact contract (release): owners 6...38, hidden + 2E features.
        XCTAssertEqual(Edge0_35BPrerouter.ownerRange, 6...38)
        XCTAssertEqual(Edge0_35BPrerouter.numExperts, 256)
        XCTAssertEqual(Edge0_35BPrerouter.topK, 4)
        XCTAssertEqual(Edge0_35BPrerouter.hidden, 2048)
        XCTAssertEqual(
            Edge0_35BPrerouter.artifactName,
            "prerouter_edge0_35b.safetensors"
        )
        // Optional artifact: absent is a non-event, never an admission bar.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge0-35b-prerouter-absent-\(UUID())")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(Edge0_35BPrerouter.isAvailable(in: empty))
        // Default OFF: production stays staged g4 until the device A/B.
        XCTAssertFalse(Edge0EnginePreferences.edge0_35BAdvisoryPrerouter)
        // The new A/B kind is wired into the counterbalanced plan.
        XCTAssertEqual(
            Edge0DiagnosticKind.prerouterAB.scoredPlan,
            [.staged, .staged, .staged, .staged]
        )
    }
}
