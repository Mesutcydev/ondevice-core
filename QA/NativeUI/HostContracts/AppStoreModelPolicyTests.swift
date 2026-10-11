import XCTest
@testable import NativeUIReview

final class AppStoreModelPolicyTests: XCTestCase {
    func testPublicDownloadPinsRevisionAndRejectsUnknownOrResearchSources() {
        let sha = String(repeating: "a", count: 40)
        let versions = ["review/model": sha, "apple/FastVLM": sha, "bad/model": "main"]
        XCTAssertEqual(AppStoreModelPolicy.downloadRevision(for: "review/model", publicDistribution: true, revisions: versions), sha)
        XCTAssertNil(AppStoreModelPolicy.downloadRevision(for: "unknown/model", publicDistribution: true, revisions: versions))
        XCTAssertNil(AppStoreModelPolicy.downloadRevision(for: "apple/FastVLM", publicDistribution: true, revisions: versions))
        XCTAssertNil(AppStoreModelPolicy.downloadRevision(for: "bad/model", publicDistribution: true, revisions: versions))
        XCTAssertEqual(AppStoreModelPolicy.downloadRevision(for: "unknown/model", publicDistribution: false, revisions: versions), "main")
        XCTAssertNotNil(AppStoreModelPolicy.downloadRevision(for: "stabilityai/sd-turbo", publicDistribution: true))
        XCTAssertNotNil(AppStoreModelPolicy.downloadRevision(for: "stabilityai/sdxl-turbo", publicDistribution: true))
        XCTAssertNil(AppStoreModelPolicy.downloadRevision(for: "stabilityai/stable-diffusion-2-1-base", publicDistribution: true))
        XCTAssertNil(AppStoreModelPolicy.downloadRevision(for: "mlx-community/Qwen3.5-4B-4bit", publicDistribution: true))
    }
    func testResearchModelsAreBlockedAcrossLegacyIdentityForms() {
        for id in ["fastvlm-mlx", "apple/FastVLM-0.5B", "imported:mirror/fastvithd",
                   "coreai:zoo-youtu-llm-2b", "mlboydaisuke/Youtu-LLM-2B-CoreAI"] {
            XCTAssertNotNil(AppStoreModelPolicy.restriction(for: id, publicDistribution: true))
            XCTAssertNil(AppStoreModelPolicy.restriction(for: id, publicDistribution: false))
        }
    }
    func testLegacyLensDefaultMigratesWithoutDisablingImageGeneration() {
        XCTAssertEqual(AppStoreModelPolicy.visionSelection("", publicDistribution: true), AppStoreModelPolicy.publicVisionSelectionID)
        XCTAssertEqual(AppStoreModelPolicy.visionSelection("fastvlm-mlx", publicDistribution: true), AppStoreModelPolicy.publicVisionSelectionID)
        XCTAssertEqual(AppStoreModelPolicy.visionSelection("chosen/other", publicDistribution: true), "chosen/other")
        XCTAssertNil(AppStoreModelPolicy.restriction(for: "stabilityai/sd-turbo", publicDistribution: true))
    }
}
