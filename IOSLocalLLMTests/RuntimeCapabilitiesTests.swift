import XCTest
@testable import IOSLocalLLM

// MARK: - RuntimeCapabilitiesTests
//
// Semantics of the pure capability value: model-level flags may only refine
// what the runtime already supports.

final class RuntimeCapabilitiesTests: XCTestCase {

    func testDefaultInitIsConservative() {
        let capabilities = RuntimeCapabilities()
        XCTAssertTrue(capabilities.streamsTokens)
        XCTAssertFalse(capabilities.supportsVision)
        XCTAssertFalse(capabilities.supportsSharedVisionRuntime)
        XCTAssertFalse(capabilities.supportsTools)
        XCTAssertTrue(capabilities.supportsRAG)
        XCTAssertFalse(capabilities.storageBackedWeights)
        XCTAssertFalse(capabilities.supportsExpertStreaming)
        XCTAssertTrue(capabilities.requiresExclusiveGPUResidency)
        XCTAssertFalse(capabilities.supportsPrefixCache)
    }

    func testModelCannotAddVisionToTextOnlyRuntime() {
        let textOnly = RuntimeCapabilities(supportsVision: false)
        XCTAssertFalse(textOnly.applying(modelVision: true).supportsVision)
    }

    func testModelVisionPropagatesToSharedVisionRuntime() {
        let visionRuntime = RuntimeCapabilities(
            supportsVision: true,
            supportsSharedVisionRuntime: true
        )
        let withModelVision = visionRuntime.applying(modelVision: true)
        XCTAssertTrue(withModelVision.supportsVision)
        XCTAssertTrue(withModelVision.supportsSharedVisionRuntime)

        let withoutModelVision = visionRuntime.applying(modelVision: false)
        XCTAssertFalse(withoutModelVision.supportsVision)
        XCTAssertFalse(withoutModelVision.supportsSharedVisionRuntime)
    }

    func testToolsAndRAGFoldWithORAndANDSemantics() {
        let runtime = RuntimeCapabilities(supportsTools: false, supportsRAG: true)
        let withModelTools = runtime.applying(modelTools: true)
        XCTAssertTrue(withModelTools.supportsTools)
        XCTAssertTrue(withModelTools.supportsRAG)

        let noRAG = runtime.applying(modelRAG: false)
        XCTAssertFalse(noRAG.supportsRAG)
    }

    func testApplyingDoesNotMutateRuntimeStorageFacts() {
        let runtime = RuntimeCapabilities(
            storageBackedWeights: true,
            supportsExpertStreaming: true,
            requiresExclusiveGPUResidency: false,
            supportsPrefixCache: true
        )
        let refined = runtime.applying(modelVision: true, modelTools: true)
        XCTAssertTrue(refined.storageBackedWeights)
        XCTAssertTrue(refined.supportsExpertStreaming)
        XCTAssertFalse(refined.requiresExclusiveGPUResidency)
        XCTAssertTrue(refined.supportsPrefixCache)
    }
}
