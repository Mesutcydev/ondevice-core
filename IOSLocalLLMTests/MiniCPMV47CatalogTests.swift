import XCTest
@testable import IOSLocalLLM

final class MiniCPMV47CatalogTests: XCTestCase {
    #if os(iOS)
    @MainActor func testDownloadedMiniCPMModelsDeclareAssistantAndLensRoles() {
        for entry in MiniCPMV47Catalog.downloadableModels {
            let model = DownloadableModel(id: entry.repoID, displayName: entry.displayName,
                subtitle: entry.repoID, sizeLabel: "", category: .vlm,
                repoID: entry.repoID, capabilities: [.vision], runtime: .llamaCpp,
                approxRAMBytes: entry.approxRAMBytes, contextWindowTokens: 4_096)
            XCTAssertTrue(model.supportsCategory(.assistant))
            XCTAssertTrue(model.supportsCategory(.vlm))
            let assistant = LocalModelRegistry.descriptor(for: model, forcedRole: .assistant).assistantModel
            XCTAssertEqual(assistant?.runtime, .llamaCpp)
            XCTAssertEqual(assistant?.repoID, entry.repoID)
            XCTAssertEqual(assistant?.contextWindowTokens, 4_096)
        }
    }
    #endif
    func test_renamingTheGGUFStillRequiresTheStreamingBackend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        func integer(_ value: UInt64, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func string(_ value: String) -> Data { integer(UInt64(value.utf8.count), bytes: 8) + Data(value.utf8) }
        var header = Data("GGUF".utf8) + integer(3, bytes: 4) + integer(0, bytes: 8) + integer(3, bytes: 8)
        for (key, value) in [("general.architecture", "qwen35moe"), ("general.type", "model"), ("general.name", "35a3_hf_v47_0923")] {
            header += string(key) + integer(8, bytes: 4) + string(value)
        }
        try header.write(to: url)
        XCTAssertEqual(MiniCPMV47Catalog.runtimeIdentity(repoID: "local/my-model", modelPath: url.path,
            hasStreamingReceipt: false), MiniCPMV47Catalog.thirtyFiveBRepoID)
        try Data("GGUF".utf8).write(to: url)
        XCTAssertNil(MiniCPMV47Catalog.embeddedRuntimeIdentity(modelPath: url.path))
    }
    func test_localAliasesCannotBypassStreamingAdmissionOrExclusiveResidency() {
        let family = MiniCPMV47Catalog.runtimeIdentity(repoID: "local/renamed-pack",
            modelPath: "/models/renamed/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf", hasStreamingReceipt: false)
        XCTAssertEqual(family, MiniCPMV47Catalog.thirtyFiveBRepoID)
        XCTAssertTrue(LlamaCppVLMExecutionProfile.resolve(repoID: family).requiresSingleResidency)
        XCTAssertEqual(MiniCPMV47Catalog.runtimeIdentity(repoID: "local/another-name", modelPath: nil, hasStreamingReceipt: true), family)
        XCTAssertEqual(MiniCPMV47Catalog.runtimeIdentity(repoID: "local/dense", modelPath: MiniCPMV47Catalog.oneB.modelFilename,
            hasStreamingReceipt: false), MiniCPMV47Catalog.oneB.repoID)
        XCTAssertEqual(MiniCPMV47Catalog.runtimeIdentity(repoID: "unchanged/SmolVLM", modelPath: "SmolVLM.gguf",
            hasStreamingReceipt: false), "unchanged/SmolVLM")
    }
    func test_downloadIsOnePinnedModelAndItsMatchingProjector() {
        let model = MiniCPMV47Catalog.oneB
        XCTAssertEqual(model.revision.count, 40)
        XCTAssertTrue(model.revision.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(model.fileAllowlist, [
            "MiniCPM-V-4_7-1B-Q4_K_M.gguf", "mmproj-model-f16.gguf", "README.md"
        ])
        XCTAssertFalse(model.fileAllowlist.contains("mmproj-model-f16-4x.gguf"))
        XCTAssertEqual(model.downloadBytes, 1_782_121_664)
        XCTAssertGreaterThan(model.approxRAMBytes, model.downloadBytes)
    }

    func test_MoEVariantDownloadsOnlyThePinnedPreparationSource() {
        XCTAssertEqual(MiniCPMV47Catalog.downloadableModels, [MiniCPMV47Catalog.oneB, MiniCPMV47Catalog.thirtyFiveB])
        XCTAssertTrue(MiniCPMV47Catalog.downloadableModels.contains {
            $0.repoID == MiniCPMV47Catalog.thirtyFiveBRepoID
        })
        XCTAssertEqual(MiniCPMV47Catalog.thirtyFiveB.downloadBytes, 16_623_520_736)
        XCTAssertEqual(MiniCPMV47Catalog.thirtyFiveB.fileAllowlist,
                       ["MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf", "mmproj-model-f16.gguf", "README.md"])
    }

    func test_MoEGuardCoversRepoIDsOriginalFilenamesAndLESSplits() {
        for identity in [
            MiniCPMV47Catalog.thirtyFiveBRepoID,
            "openbmb/MiniCPM-V-4.7-35B-A3B",
            "/models/MiniCPM-V-4_7-35B-A3B-Q4_K_M.gguf",
            "/models/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf",
            "LOCAL_MINICPM-V-4.7-35B-A3B"
        ] {
            XCTAssertTrue(MiniCPMV47Catalog.is35B(identity))
            #if canImport(ODMiniCPM)
            XCTAssertNil(MiniCPMV47Catalog.unavailableReason(for: identity))
            #else
            XCTAssertNotNil(MiniCPMV47Catalog.unavailableReason(for: identity))
            #endif
        }
    }

    func test_guardLeavesExistingModelsAndDenseMiniCPMAvailable() {
        for identity in [
            MiniCPMV47Catalog.oneB.repoID,
            MiniCPMV47Catalog.oneB.modelFilename,
            "Edge0/Edge0-35B-A3B-preview",
            "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
            "ggml-org/gemma-3-4b-it-GGUF",
            "Qwen3.5-35B-A3B-Q4_K_M.gguf",
            "openbmb/MiniCPM-V-4.6-gguf"
        ] {
            XCTAssertNil(MiniCPMV47Catalog.unavailableReason(for: identity))
        }
    }

    func test_instructTemplateIsSpecificToMiniCPMV47DenseModel() {
        XCTAssertTrue(MiniCPMV47Catalog.usesInstructVisionPrompt(for: MiniCPMV47Catalog.oneB.repoID))
        XCTAssertTrue(MiniCPMV47Catalog.usesInstructVisionPrompt(for: MiniCPMV47Catalog.oneB.modelFilename))
        for identity in ["SmolVLM2-500M.gguf", "MiniCPM-V-4_6-Q4_K_M.gguf", "Qwen3.5-0.8B.gguf"] {
            XCTAssertFalse(MiniCPMV47Catalog.usesInstructVisionPrompt(for: identity))
        }
    }

    func test_instructVisionPromptMatchesPublisherTemplateAndKeepsMarkerOnce() {
        let prompt = MiniCPMV47Catalog.instructVisionPrompt("Describe the image.", marker: "<__media__>")
        XCTAssertEqual(prompt, "<|im_start|>user\n<__media__>\nDescribe the image.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        XCTAssertEqual(prompt.components(separatedBy: "<__media__>").count, 2)
        let existing = MiniCPMV47Catalog.instructVisionPrompt("<__media__>\nRead this.", marker: "<__media__>")
        XCTAssertEqual(existing.components(separatedBy: "<__media__>").count, 2)
        XCTAssertTrue(existing.contains("Read this."))
    }

    func test_emptyPromptStillIncludesAnImageAndClosedThinkingBlock() {
        let prompt = MiniCPMV47Catalog.instructVisionPrompt(" \n ", marker: "<__media__>")
        XCTAssertTrue(prompt.contains("user\n<__media__><|im_end|>"))
        XCTAssertTrue(prompt.hasSuffix("<think>\n\n</think>\n\n"))
    }

    func test_LensProfileKeepsImageSlicesWithinABoundedContext() {
        let profile = LlamaCppVLMExecutionProfile.resolve(repoID: MiniCPMV47Catalog.oneB.repoID)
        XCTAssertEqual(profile.contextSize, 4_096)
        XCTAssertEqual(profile.maxOutputTokens, 256)
        XCTAssertTrue(profile.requiresSingleResidency)
        let smol = LlamaCppVLMExecutionProfile.resolve(repoID: "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF")
        XCTAssertEqual(smol.contextSize, 4_096)
        XCTAssertEqual(smol.maxOutputTokens, 256)
        XCTAssertFalse(smol.requiresSingleResidency)
        let gemma = LlamaCppVLMExecutionProfile.resolve(repoID: "ggml-org/gemma-3-4b-it-GGUF")
        XCTAssertEqual(gemma.contextSize, 1_024)
        XCTAssertEqual(gemma.maxOutputTokens, 192)
    }

    #if canImport(UIKit)
    @MainActor
    func test_libraryUsesPinnedExistingBackendAndPreservesDefaultAssistant() throws {
        let entry = try XCTUnwrap(ModelDownloadCenter.shared.models.first {
            $0.sourceRepoID == MiniCPMV47Catalog.oneB.repoID
        })
        XCTAssertEqual(entry.category, .vlm)
        XCTAssertEqual(entry.runtime, .llamaCpp)
        XCTAssertEqual(entry.downloader?.branch, MiniCPMV47Catalog.oneB.revision)
        XCTAssertEqual(entry.downloader?.fileAllowlist, MiniCPMV47Catalog.oneB.fileAllowlist)
        XCTAssertTrue(entry.capabilities.contains(.vision))
        XCTAssertEqual(AssistantModelCatalog.presets.first?.id, "qwen3-4b-2507")
        XCTAssertTrue(ModelDownloadCenter.shared.models.contains {
            $0.sourceRepoID == MiniCPMV47Catalog.thirtyFiveBRepoID
        })
        XCTAssertNil(Edge0ModelFamily.resolve(repoID: "openbmb/MiniCPM-V-4.7-35B-A3B"))
    }

    func test_nativeBridgeRefusesMoEBeforeOpeningMissingFiles() {
        XCTAssertThrowsError(try LlamaCppVLM(llmPath: "/missing/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf")) {
            XCTAssertEqual($0 as? LlamaCppError,
                           .unsupportedModel(MiniCPMV47Catalog.streaming35BRequirement))
        }
    }
    #endif
}
