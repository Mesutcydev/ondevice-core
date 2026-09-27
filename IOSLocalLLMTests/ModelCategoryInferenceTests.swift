import XCTest
import OnDeviceUI
@testable import IOSLocalLLM

// MARK: - ModelCategoryInferenceTests
//
// Pins the category inference that decides whether a model is an assistant,
// a vision/VLM, a voice, or an image-generation (diffusion) model — the logic
// behind "recognize image models at download and when downloaded" and the
// per-category headers in the Models tab.

final class ModelCategoryInferenceTests: XCTestCase {
    @MainActor
    func test_interruptedDownloadDoesNotBecomeReadyFromWeightsAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"model_type":"prism_hadamard_qwen35"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
        let expected = [
            "config.json": Int64(try Data(contentsOf: directory.appendingPathComponent("config.json")).count),
            "model.safetensors": Int64(1),
            "tokenizer.json": Int64(2),
        ]
        try JSONEncoder().encode(expected)
            .write(to: directory.appendingPathComponent(".hf-expected.json"))

        XCTAssertTrue(HFModelDownloadManager.looksReady(in: directory))
        let downloader = HFModelDownloadManager(
            repoID: "test/interrupted-model",
            destination: directory
        )
        downloader.checkIfReady()
        XCTAssertEqual(downloader.state, .idle)
        XCTAssertEqual(downloader.progress, Double(expected["config.json"]! + 1)
            / Double(expected.values.reduce(0, +)), accuracy: 0.001)
        XCTAssertFalse(downloader.hasResumableDownloadReceipt)
        try Data("test/interrupted-model".utf8)
            .write(to: directory.appendingPathComponent(".repoID"))
        XCTAssertTrue(downloader.hasResumableDownloadReceipt)

        try Data([1, 2]).write(to: directory.appendingPathComponent("tokenizer.json"))
        downloader.checkIfReady()
        XCTAssertEqual(downloader.state, .ready)
        XCTAssertEqual(downloader.progress, 1)
    }

    func test_savedEdge0SelectionWinsOverPreviouslyActiveMLXModel() throws {
        let activeMLX = AssistantModelCatalog.presets[0]
        let edge0 = try XCTUnwrap(AssistantModelCatalog.presets.first {
            $0.runtime == .edge0MLX
        })

        let resolved = CodingAssistantService.loadTarget(
            activeModel: activeMLX,
            savedDefault: edge0,
            reselectFromSettings: true
        )

        XCTAssertEqual(resolved.runtime, .edge0MLX)
        XCTAssertEqual(resolved.id, edge0.id)
        XCTAssertEqual(AssistantModelCatalog.presets[0].id, "qwen3-4b-2507")
    }

    func test_explicitConversationSwitchPreservesItsLoadTarget() {
        let savedDefault = AssistantModel(
            id: "downloaded:MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            repoID: "MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            displayName: "Nanbeige 3B",
            subtitle: "4-bit",
            approxRAMBytes: 3_000_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )
        let conversationSelection = AssistantModel(
            id: "downloaded:Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            repoID: "Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            displayName: "Qwen3.5 9B",
            subtitle: "4-bit",
            approxRAMBytes: 6_500_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )

        let resolved = CodingAssistantService.loadTarget(
            activeModel: conversationSelection,
            savedDefault: savedDefault,
            reselectFromSettings: false
        )

        XCTAssertEqual(resolved.id, conversationSelection.id)
        XCTAssertNotEqual(resolved.id, savedDefault.id)
    }

    func test_normalLoadStillUsesSavedDefault() {
        let savedDefault = AssistantModel(
            id: "downloaded:MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            repoID: "MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            displayName: "Nanbeige 3B",
            subtitle: "4-bit",
            approxRAMBytes: 3_000_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )
        let currentSelection = AssistantModel(
            id: "downloaded:Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            repoID: "Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            displayName: "Qwen3.5 9B",
            subtitle: "4-bit",
            approxRAMBytes: 6_500_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )

        let resolved = CodingAssistantService.loadTarget(
            activeModel: currentSelection,
            savedDefault: savedDefault,
            reselectFromSettings: true
        )

        XCTAssertEqual(resolved.id, savedDefault.id)
    }

    @MainActor
    func test_installedRegistryModelIsReconciledIntoModelsTabSource() throws {
        let repoID = "Jackrong/test-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            ModelDownloadCenter.shared.unregisterCustom(repoID: repoID)
        }
        try Data(#"{"architectures":["Qwen3ForCausalLM"]}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"model_max_length":4096}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        try Data([0x01])
            .write(to: directory.appendingPathComponent("model.safetensors"))

        let record = try XCTUnwrap(
            InstalledModelRegistry.validateDirectory(directory, repoID: repoID)
        )
        XCTAssertTrue(record.validationState.isActivatable)

        ModelDownloadCenter.shared.reconcileInstalledRegistry(records: [record])

        let installed = ModelDownloadCenter.shared.models.first {
            $0.sourceRepoID.caseInsensitiveCompare(repoID) == .orderedSame
        }
        XCTAssertNotNil(installed)
        XCTAssertTrue(installed?.isReady == true)
        XCTAssertEqual(installed?.category, .assistant)
    }


    private func cat(_ repo: String, pipeline: String? = nil, tags: [String] = []) -> DownloadableModel.Category {
        LocalModelRegistry.category(repoID: repo, pipelineTag: pipeline, tags: tags)
    }

    // MARK: Pipeline tags are authoritative

    func test_textToImagePipeline_isImageGen() {
        XCTAssertEqual(cat("some/repo", pipeline: "text-to-image"), .imageGen)
        XCTAssertEqual(cat("some/repo", pipeline: "image-to-image"), .imageGen)
        XCTAssertEqual(cat("some/repo", pipeline: "unconditional-image-generation"), .imageGen)
    }

    func test_visionPipeline_isVLM() {
        XCTAssertEqual(cat("some/repo", pipeline: "image-text-to-text"), .vlm)
        XCTAssertEqual(cat("some/repo", pipeline: "image-to-text"), .vlm)
        XCTAssertEqual(cat("some/repo", pipeline: "visual-question-answering"), .vlm)
    }

    func test_speechPipeline_isVoice() {
        XCTAssertEqual(cat("some/repo", pipeline: "text-to-speech"), .voice)
        XCTAssertEqual(cat("some/repo", pipeline: "automatic-speech-recognition"), .voice)
    }

    // MARK: Keyword / tag fallback when pipeline is missing

    func test_diffusionKeywords_isImageGen() {
        XCTAssertEqual(cat("stabilityai/stable-diffusion-2-1-base"), .imageGen)
        XCTAssertEqual(cat("stabilityai/sdxl-turbo"), .imageGen)
        XCTAssertEqual(cat("black-forest-labs/FLUX.1-schnell"), .imageGen)
    }

    func test_diffusersTag_isImageGen() {
        XCTAssertEqual(cat("anyorg/anymodel", tags: ["diffusers"]), .imageGen)
    }

    func test_visionKeywords_isVLM() {
        XCTAssertEqual(cat("Qwen/Qwen2.5-VL-3B-Instruct"), .vlm)
        XCTAssertEqual(cat("HuggingFaceTB/SmolVLM-Instruct"), .vlm)
    }

    func test_voiceKeywords_isVoice() {
        XCTAssertEqual(cat("openai/whisper-base"), .voice)
        XCTAssertEqual(cat("KittenML/kitten-tts"), .voice)
    }

    func test_plainLLM_isAssistant() {
        XCTAssertEqual(cat("Qwen/Qwen2.5-Coder-1.5B-Instruct"), .assistant)
        XCTAssertEqual(cat("meta-llama/Llama-3.2-1B-Instruct"), .assistant)
    }

    func test_edge0RecoveryArtifactsOverrideVisionConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"architectures":["Qwen3_5MoeForConditionalGeneration"],"vision_config":{},"image_token_id":42}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(LocalModelRegistry.category(in: dir), .vlm)
        try Data([1]).write(to: dir.appendingPathComponent("lora_edge0_35b.safetensors"))
        XCTAssertEqual(LocalModelRegistry.category(in: dir), .assistant)
    }

    @MainActor
    func test_bonsai2TextComponentDoesNotBypassRequiredLoader() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"prism_hadamard_qwen35","components":{"text":true,"vision":true},"vision_config":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data([1]).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data([1]).write(to: dir.appendingPathComponent("tokenizer.json"))

        XCTAssertEqual(LocalModelRegistry.category(in: dir), .vlm)
        XCTAssertTrue(LocalModelRegistry.hasDeclaredTextComponent(in: dir))
        XCTAssertFalse(LocalModelRegistry.supportsAssistant(in: dir))
        XCTAssertNotNil(LocalModelRegistry.unsupportedTextRuntimeReason(in: dir))
        XCTAssertNotNil(LocalModelRegistry.unsupportedVisionRuntimeReason(in: dir))
        let model = DownloadableModel(
            id: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit",
            displayName: "Ternary Bonsai 2 27B",
            subtitle: "Prism ML",
            sizeLabel: "8.6 GB",
            category: .vlm,
            downloader: HFModelDownloadManager(
                repoID: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit",
                destination: dir
            )
        )
        XCTAssertEqual(model.declaredCategories, [.assistant, .vlm])
        XCTAssertTrue(model.supportedCategories.isEmpty)
        XCTAssertFalse(model.supportsCategory(.assistant))
        XCTAssertFalse(model.supportsCategory(.vlm))
        // Unrunnable text still reads as an Assistant pack, never Lens.
        XCTAssertEqual(ODBridge.kind(for: model), .language)
        XCTAssertEqual(
            LocalModelRegistry.publishedBonsai2TextWeightBytes(for: model.sourceRepoID),
            7_670_000_000
        )
        XCTAssertEqual(VisualModelInstallStatus.ramEstimate(for: model), 0)
        XCTAssertNil(VisualModelInstallStatus.memoryVerdict(for: model))
        let record = try XCTUnwrap(InstalledModelRegistry.validateDirectory(
            dir, repoID: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"
        ))
        XCTAssertFalse(record.validationState.isActivatable)
    }

    @MainActor
    func test_supportedDualRolePackAppearsInAssistant() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"qwen3_5","components":{"text":true,"vision":true},"vision_config":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data([1]).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data([1]).write(to: dir.appendingPathComponent("tokenizer.json"))

        XCTAssertEqual(LocalModelRegistry.category(in: dir), .vlm)
        XCTAssertTrue(LocalModelRegistry.supportsAssistant(in: dir))
        XCTAssertNil(LocalModelRegistry.unsupportedTextRuntimeReason(in: dir))
        let model = DownloadableModel(
            id: "test/dual-role-model",
            displayName: "Dual Role Model",
            subtitle: "Test",
            sizeLabel: "1 GB",
            category: .vlm,
            downloader: HFModelDownloadManager(repoID: "test/dual-role-model", destination: dir)
        )
        XCTAssertEqual(model.declaredCategories, [.assistant, .vlm])
        XCTAssertEqual(model.supportedCategories, [.assistant, .vlm])
        XCTAssertTrue(model.supportsCategory(.assistant))
        XCTAssertTrue(model.supportsCategory(.vlm))
        // Vision-primary on disk, but "Use" and Chat treat it as Assistant.
        XCTAssertEqual(ODBridge.kind(for: model), .language)
    }

    @MainActor
    func test_edge0WithVisionConfigIsAssistantOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"qwen3_5_moe","architectures":["Qwen3_5MoeForConditionalGeneration"],"vision_config":{},"image_token_id":248056}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data([1]).write(to: dir.appendingPathComponent("lora_edge0_35b.safetensors"))
        // Same model type as a unified Qwen 3.5 MoE pack, but never Lens.
        XCTAssertFalse(LocalModelRegistry.isUnifiedTextVisionPack(in: dir))
        let model = DownloadableModel(
            id: "edge0-35b-a3b-preview",
            displayName: "Edge0-35B A3B Preview",
            subtitle: "native runtime",
            sizeLabel: "19.6 GB",
            category: .assistant,
            downloader: HFModelDownloadManager(
                repoID: "Edge0/Edge0-35B-A3B-preview",
                destination: dir
            ),
            repoID: "Edge0/Edge0-35B-A3B-preview"
        )
        XCTAssertEqual(model.supportedCategories, [.assistant])
        XCTAssertEqual(ODBridge.kind(for: model), .language)
    }

    @MainActor
    func test_unifiedQwen35PackServesAssistantAndLens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"qwen3_5","architectures":["Qwen3_5ForConditionalGeneration"],"vision_config":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        let model = DownloadableModel(
            id: "mlx-community/Qwen3.5-9B-MLX-4bit", displayName: "Qwen3.5 9B",
            subtitle: "HF", sizeLabel: "6 GB", category: .vlm,
            downloader: HFModelDownloadManager(repoID: "mlx-community/Qwen3.5-9B-MLX-4bit", destination: dir)
        )
        XCTAssertEqual(model.supportedCategories, [.assistant, .vlm])
        XCTAssertEqual(ODBridge.kind(for: model), .language)
        // Qwen3-VL has no text-only loader in mlx-swift-lm: Lens only.
        try Data(#"{"model_type":"qwen3_vl","vision_config":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertFalse(LocalModelRegistry.isUnifiedTextVisionPack(in: dir))
    }

    func test_weightBitsAndFootprintFollowTheQuantization() {
        func bits(_ repo: String) -> Double? { OnDeviceCompatibility.weightBits(tags: [], repoID: repo) }
        XCTAssertEqual(bits("mlx-community/Qwen3.5-9B-MLX-4bit"), 4)
        XCTAssertEqual(bits("mlx-community/Llama-3.2-3B-Instruct-4bit"), 4)
        XCTAssertEqual(bits("mlx-community/Qwen3-4B-Instruct-2507-8bit"), 8)
        XCTAssertEqual(bits("prism-ml/Ternary-Bonsai-8B-mlx-2bit"), 2)
        XCTAssertEqual(bits("prism-ml/Bonsai-27B-mlx-1bit"), 1)
        XCTAssertEqual(bits("mlx-community/gpt-oss-20b-MXFP4-Q8"), 4.25)
        XCTAssertEqual(bits("unsloth/Qwen3-8B-GGUF-Q4_K_M"), 4.5)
        XCTAssertEqual(bits("mlx-community/Qwen3-VL-8B-Instruct-bf16"), 16)
        XCTAssertNil(bits("Qwen/Qwen3-8B"))
        let q4 = OnDeviceCompatibility.estimatedFootprint(params: 9_000_000_000, tags: [], repoID: "x/Qwen3.5-9B-4bit")
        let q8 = OnDeviceCompatibility.estimatedFootprint(params: 9_000_000_000, tags: [], repoID: "x/Qwen3.5-9B-8bit")
        XCTAssertGreaterThan(q4, 6_000_000_000)
        XCTAssertLessThan(q4, 7_000_000_000)
        XCTAssertGreaterThan(q8, q4 * 18 / 10)
    }

    func test_currentFamiliesAreRecognized() {
        for repo in ["mlx-community/Qwen3.5-4B-MLX-4bit", "mlx-community/gemma-3n-E4B-it-lm-4bit",
                     "mlx-community/Phi-4-mini-instruct-4bit", "mlx-community/SmolLM3-3B-4bit",
                     "mlx-community/LFM2.5-1.2B-Instruct-4bit", "mlx-community/granite-4.0-h-micro-4bit",
                     "mlx-community/Ministral-3-3B-Instruct-2512-4bit", "mlx-community/exaone-4.0-1.2b-4bit"] {
            XCTAssertNotNil(OnDeviceCompatibility.recognizedFamily(repoID: repo, kind: .text), repo)
        }
        for repo in ["mlx-community/Qwen3.5-9B-MLX-4bit", "mlx-community/LFM2.5-VL-1.6B-4bit",
                     "mlx-community/gemma-4-e4b-it-4bit"] {
            XCTAssertNotNil(OnDeviceCompatibility.recognizedFamily(repoID: repo, kind: .vlm), repo)
        }
    }

    @MainActor
    func test_multiFileImportIsNamedFromTheModelItself() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        try Data(#"{"model_type":"qwen3_5"}"#.utf8).write(to: config)
        XCTAssertEqual(LocalModelImportService.metadataName(forFiles: [config]), "qwen3.5")

        let readme = dir.appendingPathComponent("README.md")
        try Data("---\ntags:\n- mlx\n---\n\n# mlx-community/Qwen3.5-9B-4bit\nConverted.\n## Use with mlx\n".utf8)
            .write(to: readme)
        XCTAssertEqual(LocalModelImportService.metadataName(forFiles: [config, readme]), "Qwen3.5-9B-4bit")

        let gguf = dir.appendingPathComponent("Qwen3-8B-Q4_K_M.gguf")
        let projector = dir.appendingPathComponent("mmproj-Qwen3-8B-f16.gguf")
        XCTAssertEqual(LocalModelImportService.metadataName(forFiles: [projector, gguf]), "Qwen3-8B-Q4_K_M")
    }

    @MainActor
    func test_incompleteEdge0SelectionNamesTheMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model_type":"qwen3_5_moe","architectures":["Qwen3_5MoeForConditionalGeneration"],"vision_config":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        // No LoRA selected: still recognized, so it is refused rather than
        // imported as a generic vision model.
        XCTAssertTrue(LocalModelImportService.isEdge0ImportCandidate(in: dir))
        let missing = LocalModelImportService.missingEdge0Files(in: dir)
        XCTAssertTrue(missing.contains("lora_edge0_35b.safetensors"))
        XCTAssertFalse(missing.contains("config.json"))
        XCTAssertFalse(LocalModelRegistry.isUnifiedTextVisionPack(in: dir))
    }

    func test_textWeightsSkipVisionAndMTPTensors() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = try JSONSerialization.data(withJSONObject: [
            "__metadata__": ["format": "mlx"],
            "language_model.model.layers.0.mlp.weight": ["dtype": "U32", "shape": [10], "data_offsets": [0, 700]],
            "lm_head.weight": ["dtype": "U32", "shape": [10], "data_offsets": [700, 1_000]],
            "vision_tower.blocks.0.attn.qkv.weight": ["dtype": "F16", "shape": [10], "data_offsets": [1_000, 1_900]],
            "mtp.layers.0.weight": ["dtype": "F16", "shape": [10], "data_offsets": [1_900, 2_000]],
        ])
        var file = Data()
        withUnsafeBytes(of: UInt64(header.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(header)
        file.append(Data(count: 2_000))
        try file.write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))
        XCTAssertEqual(LocalModelRegistry.textWeightBytes(in: dir), 1_000)
    }

    func test_renamedQwen35FinetunesGetTheBoundedProfile() {
        // MiMo's name carries no "qwen3.5"; its config.json declares qwen3_5.
        let byName = MLXAssistantExecutionProfile.resolve(repoID: "mlx-community/MiMo-V2.6-Distill-Qwen-9B-OptiQ-4bit")
        let byArchitecture = MLXAssistantExecutionProfile.resolve(
            repoID: "mlx-community/MiMo-V2.6-Distill-Qwen-9B-OptiQ-4bit", architecture: "qwen3_5"
        )
        XCTAssertNil(byName.maxKVSize)
        XCTAssertEqual(byArchitecture.maxKVSize, 2_048)
        XCTAssertEqual(byArchitecture.kvBits, 4)
        // Build 70 measured a ~6.5 GB kernel limit on an iPhone 17 Pro Max:
        // MiMo's 7.10 GB of text weights cannot fit, and must be refused.
        let kernelLimit: Int64 = 6_390_000_000 + 110_000_000
        XCTAssertGreaterThan(7_100_000_000 + MemoryAdvisor.boundedKVRuntimeReserve, kernelLimit)
    }

    @MainActor
    func test_visionOnlyPackStaysInLens() {
        let model = DownloadableModel(
            id: "example/vision-only",
            displayName: "Vision only",
            subtitle: "Vision",
            sizeLabel: "1 GB",
            category: .vlm,
            repoID: "example/vision-only"
        )
        XCTAssertEqual(ODBridge.kind(for: model), .vision)
    }

    @MainActor
    func test_assistantPresetWithVisionUsesOneDownloadForBothRoles() {
        let model = DownloadableModel(
            id: "prism-ml/Bonsai-27B-mlx-1bit",
            displayName: "Bonsai 27B",
            subtitle: "Prism ML",
            sizeLabel: "5.2 GB",
            category: .assistant,
            capabilities: [.vision]
        )
        XCTAssertEqual(model.declaredCategories, [.assistant, .vlm])
        XCTAssertEqual(model.supportedCategories, [.assistant, .vlm])
    }

    // MARK: Image-gen must not be misread as a vision (VLM) model

    func test_imageGenDoesNotCollideWithVision() {
        // A diffusion repo must land in imageGen, never vlm — the bug this fixes.
        XCTAssertNotEqual(cat("stabilityai/stable-diffusion-2-1-base"), .vlm)
        XCTAssertNotEqual(cat("stabilityai/stable-diffusion-2-1-base"), .assistant)
    }

    // MARK: Role mapping stays consistent

    func test_roleMapping() {
        XCTAssertEqual(LocalModelRegistry.role(for: .assistant), .assistant)
        XCTAssertEqual(LocalModelRegistry.role(for: .vlm), .vision)
        XCTAssertEqual(LocalModelRegistry.role(for: .voice), .voice)
        XCTAssertEqual(LocalModelRegistry.role(for: .imageGen), .image)
    }

    // MARK: - Capability inference (Tools / Coder / Fast / Multilingual pills)

    func test_inferred_supportsTools_addsToolsPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Qwen3-4B-4bit",
                                            supportsTools: true)
        XCTAssertTrue(caps.contains(.tools))
    }

    func test_inferred_withoutTools_omitsToolsPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
                                            supportsTools: false)
        XCTAssertFalse(caps.contains(.tools))
    }

    func test_inferred_coderRepo_addsCoderPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertTrue(caps.contains(.coder))
    }

    func test_inferred_codeTag_addsCoderPill() {
        let caps = ModelCapability.inferred(repoID: "some/model", tags: ["code"])
        XCTAssertTrue(caps.contains(.coder))
    }

    func test_inferred_fastTag_addsFastPill() {
        XCTAssertTrue(ModelCapability.inferred(repoID: "some/model", tags: ["fast"]).contains(.fast))
        XCTAssertTrue(ModelCapability.inferred(repoID: "some/model", tags: ["light"]).contains(.fast))
    }

    func test_inferred_multilingualFamilies() {
        XCTAssertTrue(ModelCapability.inferred(repoID: "Qwen/Qwen3-4B").contains(.multilingual))
        XCTAssertTrue(ModelCapability.inferred(repoID: "prism-ml/Bonsai-27B-mlx-1bit").contains(.multilingual))
        XCTAssertTrue(ModelCapability.inferred(repoID: "google/gemma-2-2b-it").contains(.multilingual))
    }

    func test_bonsaiCatalog_containsAllPublishedMLXVariants() {
        let bonsai = AssistantModelCatalog.presets.filter { $0.repoID.lowercased().contains("bonsai") }
        XCTAssertEqual(bonsai.count, 8)
        XCTAssertEqual(Set(bonsai.map(\.id)), [
            "bonsai-27b-1bit", "bonsai-27b-ternary",
            "bonsai-8b-1bit", "bonsai-8b-ternary",
            "bonsai-4b-1bit", "bonsai-4b-ternary",
            "bonsai-1.7b-1bit", "bonsai-1.7b-ternary",
        ])
        XCTAssertTrue(bonsai.allSatisfy { $0.downloadSizeBytes != nil })
        XCTAssertTrue(bonsai.allSatisfy { $0.supportsThinking })
    }

    @MainActor
    func test_downloadedUnifiedBonsaiKeepsAssistantAndLensRoles() {
        let unified = DownloadableModel(
            id: "prism-ml/Ternary-Bonsai-27B-mlx-2bit",
            displayName: "Ternary Bonsai 27B",
            subtitle: "Downloaded from Hugging Face",
            sizeLabel: "8.5 GB",
            category: .vlm,
            repoID: "prism-ml/Ternary-Bonsai-27B-mlx-2bit"
        )
        XCTAssertTrue(unified.supportsCategory(.assistant))
        XCTAssertTrue(unified.supportsCategory(.vlm))
        XCTAssertTrue(unified.capabilities.contains(.vision))
        XCTAssertEqual(unified.platformCompatibility, .macOnly)

        let textOnly = DownloadableModel(
            id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
            displayName: "Ternary Bonsai 8B",
            subtitle: "Downloaded from Hugging Face",
            sizeLabel: "2.3 GB",
            category: .assistant,
            repoID: "prism-ml/Ternary-Bonsai-8B-mlx-2bit"
        )
        XCTAssertTrue(textOnly.supportsCategory(.assistant))
        XCTAssertFalse(textOnly.supportsCategory(.vlm))

        let visionOnly = DownloadableModel(
            id: "example/vision-only",
            displayName: "Vision only",
            subtitle: "Vision",
            sizeLabel: "1 GB",
            category: .vlm,
            repoID: "example/vision-only"
        )
        XCTAssertFalse(visionOnly.supportsCategory(.assistant))
    }

    func test_ornithIsAFirstClassHighMemoryAssistantPreset() throws {
        let ornith = try XCTUnwrap(
            AssistantModelCatalog.model(forID: "ornith-1.0-9b-4bit")
        )
        XCTAssertEqual(ornith.repoID, "mlx-community/Ornith-1.0-9B-4bit")
        XCTAssertEqual(ornith.platformCompatibility, .highMemoryMobileAndMac)
        XCTAssertEqual(ornith.contextWindowTokens, 4_096)
        XCTAssertLessThanOrEqual(
            ornith.approxRAMBytes + MemoryAdvisor.loadHeadroomReserve,
            MemoryAdvisor.maximumHighMemoryIPhoneProcessCeiling
        )
    }

    func test_bonsaiMetadata_resolvesVendorFamilyAndTemplates() {
        XCTAssertEqual(ModelVendor.infer(from: "prism-ml/Bonsai-27B-mlx-1bit"), .prism)
        XCTAssertEqual(ModelFamily.inferID(from: "prism-ml/Ternary-Bonsai-8B-mlx-2bit"), "bonsai")
        XCTAssertEqual(ModelFamily.displayName(forID: "bonsai"), "Bonsai")
        XCTAssertEqual(ChatTemplate.detect(for: "prism-ml/Bonsai-27B-mlx-1bit").format, "qwen35")
        XCTAssertEqual(ChatTemplate.detect(for: "prism-ml/Bonsai-4B-mlx-1bit").format, "chatml")
    }

    func test_chatTemplateUsesModelContextWithoutExposingItAsDisplayText() {
        let message = ChatMessage(
            role: .user,
            content: "Summarize this.",
            modelContent: "[FILE]\nSource text\nSummarize this."
        )

        let prompt = ChatTemplate.chatML.format(messages: [message])

        XCTAssertTrue(prompt.contains("[FILE]\nSource text\nSummarize this."))
        XCTAssertEqual(message.content, "Summarize this.")
    }

    func test_gemmaTemplate_foldsSystemIntoFirstUserTurnOnce() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = ChatTemplate.gemma.format(messages: messages)
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nBe brief.\n\nHello<end_of_turn>"))
        XCTAssertEqual(prompt.components(separatedBy: "Be brief.").count - 1, 1)
        XCTAssertFalse(prompt.contains("System: Be brief."))
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    func test_chatMLTemplate_keepsDedicatedSystemTurn() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = ChatTemplate.chatML.format(messages: messages)
        XCTAssertTrue(prompt.contains("<|im_start|>system\nBe brief.<|im_end|>"))
        XCTAssertTrue(prompt.contains("<|im_start|>user\nHello<|im_end|>"))
        XCTAssertFalse(prompt.contains("Be brief.\n\nHello"))
    }

    func test_chatMLTemplate_leaveLastAssistantOpen_skipsGenerationCue() {
        let messages = [
            ChatMessage(role: .user, content: "Write a story"),
            ChatMessage(role: .assistant, content: "Once upon a time"),
        ]
        let open = ChatTemplate.chatML.format(
            messages: messages,
            leaveLastAssistantOpen: true
        )
        XCTAssertEqual(open, "<|im_start|>user\nWrite a story<|im_end|>\n<|im_start|>assistant\nOnce upon a time")
        let closed = ChatTemplate.chatML.format(messages: messages)
        XCTAssertTrue(closed.hasSuffix("<|im_end|>\n<|im_start|>assistant\n"))
    }

    /// Expected strings are the official Hugging Face chat-template renders.
    func test_detectedTemplatesMatchOfficialThinkingContracts() {
        let messages = [ChatMessage(role: .user, content: "Hi")]
        let hybrid = ChatTemplate.detect(for: "mlx-community/Qwen3-8B-4bit")
        XCTAssertTrue(hybrid.format(messages: messages, enableThinking: false)
            .hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        XCTAssertTrue(hybrid.format(messages: messages, enableThinking: true)
            .hasSuffix("<|im_start|>assistant\n"))
        XCTAssertTrue(ChatTemplate.detect(for: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
            .format(messages: messages).hasSuffix("<|im_start|>assistant\n"))
        XCTAssertTrue(ChatTemplate.detect(for: "mlx-community/Qwen3-4B-Thinking-2507-4bit")
            .format(messages: messages, enableThinking: false).hasSuffix("<|im_start|>assistant\n<think>\n"))
        XCTAssertEqual(ChatTemplate.detect(for: "prism-ml/Bonsai-8B-mlx-1bit").format, "qwen3")
        // Formats the hand-written templates cannot reproduce.
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit").format, "generic")
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/gemma-4-31b-it-4bit").format, "generic")
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/Phi-4-mini-instruct-4bit").format, "generic")
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/Phi-3.5-mini-instruct-4bit").format, "phi")
    }

    func test_thinkingSwitchIsReadFromTheShippedTemplate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(ChatTemplate.readsThinkingSwitch(in: dir))
        try Data(#"{"chat_template":"{% if enable_thinking is defined and enable_thinking is false %}x{% endif %}"}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer_config.json"))
        XCTAssertEqual(ChatTemplate.readsThinkingSwitch(in: dir), true)
        try Data("{{ messages }}".utf8).write(to: dir.appendingPathComponent("chat_template.jinja"))
        try Data(#"{"chat_template":"{{ messages }}"}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer_config.json"))
        XCTAssertEqual(ChatTemplate.readsThinkingSwitch(in: dir), false)
    }

    func test_reasoningMarkupFromEveryFamilyBecomesThinkBlocks() {
        let normalize = AssistantOutputSanitizer.normalizeReasoningMarkup
        // Gemma 4 channel and Magistral delimiters.
        XCTAssertEqual(normalize("<|channel>thought\nplan<channel|>Answer"), "<think>\nplan</think>Answer")
        XCTAssertEqual(normalize("[THINK]x[/THINK]y"), "<think>x</think>y")
        // Template opened <think> in the prompt (Qwen 3.5, DeepSeek-R1).
        XCTAssertEqual(normalize("reasoning</think>\n\nAnswer"), "<think>reasoning</think>\n\nAnswer")
        // Empty reasoning renders nothing.
        XCTAssertEqual(normalize("<think>\n\n</think>\n\nAnswer"), "Answer")
        // Missed stop tokens are dropped.
        XCTAssertEqual(normalize("Answer<|im_end|>"), "Answer")
        XCTAssertEqual(normalize("Answer <end_of_turn>\n"), "Answer")
        XCTAssertEqual(normalize("Plain answer."), "Plain answer.")
        let blocks = StudioTextBlocks.parse(AssistantOutputSanitizer.clean("why</think>Because."))
        XCTAssertEqual(blocks.first, .thinking("why", false))
    }

    func test_assistantOutputSanitizer_removesKnownQwenBoundaryLeaks() {
        XCTAssertEqual(
            AssistantOutputSanitizer.clean("\nassistant: off.\n\n### Result\n**Done**"),
            "### Result\n**Done**"
        )
        XCTAssertEqual(
            AssistantOutputSanitizer.clean(".\n\nThis is the answer."),
            "This is the answer."
        )
    }

    func test_assistantOutputSanitizer_preservesNormalAnswerText() {
        let answer = "Assistant: configure the setting to off.\n\nThen retry."
        XCTAssertEqual(AssistantOutputSanitizer.clean(answer), answer)
    }

    func test_assistantMarkdown_preservesSingleLineBreaks() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Whether it's:\nSolving a problem\nCalculations\n\nDone"
        )
        XCTAssertEqual(
            source,
            "Whether it's:  \nSolving a problem  \nCalculations\n\nDone"
        )

        let rendered = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )
        XCTAssertTrue(
            String(rendered?.characters ?? AttributedString().characters)
                .hasPrefix("Whether it's:\nSolving a problem\nCalculations")
        )
    }

    func test_assistantMarkdown_repairsRunTogetherProseBoundaries() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Please provide:Your name (full name)Any other detail.Ask again"
        )

        XCTAssertEqual(
            source,
            "Please provide:  \nYour name (full name)  \nAny other detail.\n\nAsk again"
        )
    }

    func test_assistantMarkdown_doesNotSplitInitialisms() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Columbus Day is a Federal Holiday in the U.S."
        )
        XCTAssertEqual(source, "Columbus Day is a Federal Holiday in the U.S.")
    }

    func test_assistantMarkdown_repairsRunTogetherHeadingsFromLocalModels() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Document Title: OpusJakePurpose: A workflowDraft Removals — instructionsSubmit Them For MeKeep Me Gone"
        )

        XCTAssertEqual(
            source,
            "Document Title: OpusJake  \nPurpose: A workflow  \nDraft Removals — instructions  \nSubmit Them For Me  \nKeep Me Gone"
        )
    }

    func test_assistantMarkdown_repairsImageDescriptionLabels() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Image DescriptionThis appears to be a listing.What's Visible:Product: Apple Mac Studio M4 MaxModel number: MU963Chip: 14-core CPU / 32-core GPUMemory: 36GB RAMStorage: 512GB SSDPricing:Original price: EGP 320,600Current price: EGP 153,950 (52% off)Stock Status: 1 item in stockWebsite Elements:Instagram iconNavigation menu: Home.Note: No reviews yet.——The image shows an online store."
        )

        XCTAssertFalse(source.contains("DescriptionThis"))
        XCTAssertFalse(source.contains("MaxModel"))
        XCTAssertFalse(source.contains("MU963Chip"))
        XCTAssertFalse(source.contains("GPUMemory"))
        XCTAssertFalse(source.contains("RAMStorage"))
        XCTAssertFalse(source.contains("SSDPricing"))
        XCTAssertFalse(source.contains("stockWebsite"))
        XCTAssertTrue(source.contains("Description  \nThis"))
        XCTAssertTrue(source.contains("RAM  \nStorage"))
        XCTAssertTrue(source.contains("yet.\n\n—The image"))
    }

    func test_assistantMarkdownLayout_keepsHeadingsParagraphsAndTableCellsSeparate() {
        let response = """
        # October 2026 Calendar Dates

        Based on the sources provided, here are three dates.

        | Date | Day | Event | Type |
        | --- | --- | --- | --- |
        | Oct 9 | Friday | Leif Erikson Day | Observance |
        | Oct 12 | Monday | Columbus Day | Federal Holiday |

        ## Additional Notes

        **Columbus Day** is marked as a federal holiday.
        """
        let blocks = StudioMarkdownLayout.parse(response)
        XCTAssertEqual(blocks, [
            .heading(1, "October 2026 Calendar Dates"),
            .paragraph("Based on the sources provided, here are three dates."),
            .table(
                ["Date", "Day", "Event", "Type"],
                [
                    ["Oct 9", "Friday", "Leif Erikson Day", "Observance"],
                    ["Oct 12", "Monday", "Columbus Day", "Federal Holiday"]
                ]
            ),
            .heading(2, "Additional Notes"),
            .paragraph("**Columbus Day** is marked as a federal holiday.")
        ])
    }

    func test_assistantMarkdownLayout_keepsListAndQuoteStructure() {
        XCTAssertEqual(
            StudioMarkdownLayout.parse("Steps:\n- Check the date\n- Check the source\n\n> Verify before sharing"),
            [
                .paragraph("Steps:"),
                .list([
                    .init(marker: "•", depth: 0, text: "Check the date"),
                    .init(marker: "•", depth: 0, text: "Check the source")
                ]),
                .quote("Verify before sharing")
            ]
        )
    }

    func test_assistantMarkdownLayout_preservesPipesInsideTableCells() {
        let response = "| Name | Example |\n| --- | --- |\n| A\\|B | `x|y` |"
        XCTAssertEqual(
            StudioMarkdownLayout.parse(response),
            [.table(["Name", "Example"], [["A|B", "`x|y`"]])]
        )
    }

    func test_assistantMarkdownLayout_supportsUnderlinedHeadingsAndEmptyTables() {
        let response = "Calendar dates\n==============\n\n| Date | Day |\n| --- | --- |"
        XCTAssertEqual(
            StudioMarkdownLayout.parse(response),
            [.heading(1, "Calendar dates"), .table(["Date", "Day"], [])]
        )
        XCTAssertEqual(
            StudioMarkdownLayout.parse("| Date |\n| --- |\n| Sep 23 |"),
            [.table(["Date"], [["Sep 23"]])]
        )
    }

    func test_dateOnlyQuestion_usesDeviceDateWithoutWebPermission() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z"))
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(
            LocalDateAnswer.answer(
                for: "Whats todays date?", now: date,
                locale: Locale(identifier: "en_US"), timeZone: timeZone
            ),
            "Today is Wednesday, September 23, 2026."
        )

        let decision = WebToolDecisionEngine().decide(
            message: "Whats todays date?", settings: WebToolSettings()
        )
        guard case .noWebNeeded = decision else {
            return XCTFail("A date-only question should not request web access")
        }
        XCTAssertNil(LocalDateAnswer.answer(for: "What's today's weather?"))
    }

    func test_imageGroundingSanitizer_removesCrossModelControlTokens() {
        let raw = """
        <|im_start|>assistant
        Assistant: The image shows a magnetic phone holder.<end_of_utterance>
        It includes a product listing.<|im_end|>
        """

        XCTAssertEqual(
            ImageGroundingSanitizer.clean(raw),
            "The image shows a magnetic phone holder.\nIt includes a product listing."
        )
    }

    func test_bonsai27_isTheOnlyDualTextAndVisionBonsaiFamily() throws {
        let binary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-1bit"))
        let ternary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-ternary"))
        let smaller = AssistantModelCatalog.presets.filter {
            $0.id.hasPrefix("bonsai-") && !$0.id.hasPrefix("bonsai-27b")
        }

        XCTAssertTrue(binary27.capabilities.contains(.vision))
        XCTAssertTrue(ternary27.capabilities.contains(.vision))
        XCTAssertTrue(DualRoleModelPolicy.isTextAndVision(repoID: binary27.repoID))
        XCTAssertTrue(DualRoleModelPolicy.isTextAndVision(repoID: ternary27.repoID))
        XCTAssertTrue(smaller.allSatisfy { !$0.capabilities.contains(.vision) })
        XCTAssertTrue(smaller.allSatisfy {
            !DualRoleModelPolicy.isTextAndVision(repoID: $0.repoID)
        })
    }

    @MainActor
    func test_bonsai27_downloadEntry_keepsOnePackageForBothCatalogRoles() throws {
        let model = try XCTUnwrap(ModelDownloadCenter.shared.models.first {
            $0.id == "bonsai-27b-1bit"
        })
        XCTAssertEqual(model.sourceRepoID, "prism-ml/Bonsai-27B-mlx-1bit")
        XCTAssertTrue(model.supportsCategory(.assistant))
        XCTAssertTrue(model.supportsCategory(.vlm))
    }

    func test_bonsaiCatalog_declaresPublishedPlatformCompatibility() throws {
        let binary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-1bit"))
        let ternary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-ternary"))
        let smaller = AssistantModelCatalog.presets.filter {
            $0.id.hasPrefix("bonsai-") && !$0.id.hasPrefix("bonsai-27b")
        }

        XCTAssertEqual(binary27.platformCompatibility, .highMemoryMobileAndMac)
        XCTAssertEqual(ternary27.platformCompatibility, .macOnly)
        XCTAssertTrue(smaller.allSatisfy { $0.platformCompatibility == .mobileAndMac })

        #if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertTrue(ModelPlatformCompatibility.macOnly.supportsCurrentPlatform)
        #else
        XCTAssertFalse(ModelPlatformCompatibility.macOnly.supportsCurrentPlatform)
        #endif
    }

    func test_inferred_plainRepo_noFalsePositives() {
        // A bare non-coder, non-multilingual repo with no tools should get
        // no inferred capability pills at all.
        let caps = ModelCapability.inferred(repoID: "meta-llama/Llama-3.2-1B-Instruct")
        XCTAssertTrue(caps.isEmpty, "Expected no inferred pills, got \(caps)")
    }

    func test_displayCapabilities_surfacesToolsForToolModel() {
        // The default flagship supports tools → the picker row should show
        // the Tools pill without the preset literal listing it.
        let flagship = AssistantModelCatalog.presets.first { $0.supportsTools }
        let model = try? XCTUnwrap(flagship)
        XCTAssertTrue(model?.displayCapabilities.contains(.tools) ?? false)
    }

    func test_displayCapabilities_orderingStatusBeforeCapabilityBeforeGated() {
        // Synthetic model carrying a status, a capability, and gated — the
        // ordering contract: status → capability markers → gated last.
        let m = AssistantModel(
            id: "t", repoID: "Qwen/Qwen2.5-Coder-7B", displayName: "t", subtitle: "t",
            approxRAMBytes: 0, tags: ["fast"], contextWindowTokens: 0,
            capabilities: [.best, .gated, .vision], supportsTools: true
        )
        let order = m.displayCapabilities
        let idxBest = order.firstIndex(of: .best)
        let idxVision = order.firstIndex(of: .vision)
        let idxGated = order.firstIndex(of: .gated)
        XCTAssertNotNil(idxBest); XCTAssertNotNil(idxVision); XCTAssertNotNil(idxGated)
        XCTAssertLessThan(idxBest!, idxVision!)   // status before capability
        XCTAssertLessThan(idxVision!, idxGated!)  // capability before gated
        // Inferred markers present too.
        XCTAssertTrue(order.contains(.tools))
        XCTAssertTrue(order.contains(.coder))
        XCTAssertTrue(order.contains(.fast))
    }

    func test_allCapabilities_haveLabelAndSymbol() {
        for cap in ModelCapability.allCases {
            XCTAssertFalse(cap.label.isEmpty, "\(cap) missing label")
            XCTAssertFalse(cap.symbol.isEmpty, "\(cap) missing symbol")
        }
    }
}
