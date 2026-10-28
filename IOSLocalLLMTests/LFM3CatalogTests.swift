import XCTest
@testable import IOSLocalLLM

final class LFM3CatalogTests: XCTestCase {
    func test_oldRuntimeRejectsLFM3WithoutBlockingExistingFamilies() {
        XCTAssertEqual(LFM3Catalog.unavailableReason(for: LFM3Catalog.text.repoID) != nil, !LFM3Catalog.isEnabled)
        XCTAssertEqual(LFM3Catalog.unavailableReason(for: LFM3Catalog.vision.modelFilename) != nil, !LFM3Catalog.isEnabled)
        XCTAssertNil(LFM3Catalog.unavailableReason(for: "LiquidAI/LFM2.5-1.2B"))
        XCTAssertNil(LFM3Catalog.unavailableReason(for: "ggml-org/SmolVLM2-500M-GGUF"))
    }
    func test_pinnedDownloadsContainOnlyTheMatchingArtifactsAndLicense() {
        XCTAssertEqual(LFM3Catalog.text.fileAllowlist,
                       ["LFM3-1.7B-QAD-Q4_0.gguf", "README.md", "LICENSE"])
        XCTAssertEqual(LFM3Catalog.vision.fileAllowlist,
                       ["LFM3-VL-2B-QAD-Q4_0.gguf", "mmproj-LFM3-VL-2B-Q8_0.gguf", "README.md", "LICENSE"])
        XCTAssertEqual(LFM3Catalog.text.downloadBytes, 1_049_615_680)
        XCTAssertEqual(LFM3Catalog.vision.downloadBytes, 1_252_647_520)
        for model in [LFM3Catalog.text, LFM3Catalog.vision] {
            XCTAssertEqual(model.revision.count, 40)
            XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit))
        }
    }

    func test_visionPromptUsesOneMtmdMarkerAndTheNonThinkingCue() {
        let marker = "<__media__>"
        XCTAssertEqual(LFM3Catalog.visionPrompt("Describe this.", marker: marker),
                       "<|im_start|>user\n<__media__>\nDescribe this.<|im_end|>\n<|im_start|>assistant\n<think></think>")
        let existing = LFM3Catalog.visionPrompt("Read \(marker)", marker: marker)
        XCTAssertEqual(existing.components(separatedBy: marker).count, 2)
        XCTAssertTrue(LFM3Catalog.visionPrompt("  ", marker: marker).contains("user\n<__media__><|im_end|>"))
        XCTAssertTrue(LFM3Catalog.isVision(LFM3Catalog.vision.modelFilename))
        XCTAssertFalse(LFM3Catalog.isVision(LFM3Catalog.text.modelFilename))
    }

    func test_textTemplateFollowsLiquidThinkingAndHistoryRules() {
        let template = ChatTemplate.detect(for: LFM3Catalog.text.repoID)
        XCTAssertEqual(template.format, "lfm3")
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "<think>private reasoning</think>Hi"),
            ChatMessage(role: .user, content: "Again"),
        ]
        let prompt = template.format(messages: messages, enableThinking: false)
        XCTAssertTrue(prompt.contains("<|im_start|>system\nBe brief.<|im_end|>\n"))
        XCTAssertTrue(prompt.contains("<|im_start|>assistant\n<think></think>Hi<|im_end|>\n"))
        XCTAssertFalse(prompt.contains("private reasoning"))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think></think>"))
        XCTAssertTrue(template.format(messages: messages, enableThinking: true).hasSuffix("<|im_start|>assistant\n<think>"))
    }

    func test_continuationKeepsAnOpenReasoningBlock() {
        let messages = [ChatMessage(role: .user, content: "Hello"),
                        ChatMessage(role: .assistant, content: "<think>Let me consider")]
        let prompt = ChatTemplate.lfm3.format(messages: messages, leaveLastAssistantOpen: true)
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think>Let me consider"))
    }

    func test_visionExecutionKeepsABoundedExclusiveContext() {
        let profile = LlamaCppVLMExecutionProfile.resolve(repoID: LFM3Catalog.vision.repoID)
        XCTAssertEqual(profile.contextSize, 4_096)
        XCTAssertEqual(profile.maxOutputTokens, 256)
        XCTAssertTrue(profile.requiresSingleResidency)
    }

    #if canImport(UIKit)
    @MainActor
    func test_catalogIsVisibleOnlyInTheExperimentalBuild() {
        let text = ModelDownloadCenter.shared.models.first { $0.sourceRepoID == LFM3Catalog.text.repoID }
        let vision = ModelDownloadCenter.shared.models.first { $0.sourceRepoID == LFM3Catalog.vision.repoID }
        XCTAssertEqual(text != nil, LFM3Catalog.isEnabled)
        XCTAssertEqual(vision != nil, LFM3Catalog.isEnabled)
        if !LFM3Catalog.isEnabled {
            XCTAssertNil(AssistantModelCatalog.selection(forStoredID: "lfm3-1.7b-qad"))
            XCTAssertNil(AssistantModelCatalog.selection(forStoredID: "downloaded:LiquidAI/LFM3-VL-2B-GGUF"))
        }
        if let text, let vision {
            XCTAssertEqual(text.runtime, .llamaCpp)
            XCTAssertEqual(text.downloader?.branch, LFM3Catalog.text.revision)
            XCTAssertEqual(text.downloader?.fileAllowlist, LFM3Catalog.text.fileAllowlist)
            XCTAssertEqual(vision.downloader?.branch, LFM3Catalog.vision.revision)
            XCTAssertEqual(vision.downloader?.fileAllowlist, LFM3Catalog.vision.fileAllowlist)
            XCTAssertTrue(vision.supportsCategory(.assistant))
            XCTAssertTrue(vision.supportsCategory(.vlm))
        }
        XCTAssertEqual(AssistantModelCatalog.presets.first?.id, "qwen3-4b-2507")
    }
    #endif
}
