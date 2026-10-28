import XCTest
@testable import IOSLocalLLM

final class AssistantVisionPolicyTests: XCTestCase {
    func testSupportedAssistantDoesNotRequireALensSelection() {
        XCTAssertTrue(AssistantVisionPolicy.shouldLoadSharedRuntime(
            isSupportedMultimodal: true, requiredVisionBytes: 5_100_000_000, availableBytes: 6_080_000_000))
    }
    func testVisionCannotExceedTheProcessBudget() {
        XCTAssertFalse(AssistantVisionPolicy.shouldLoadSharedRuntime(
            isSupportedMultimodal: true, requiredVisionBytes: 8_700_000_000, availableBytes: 6_080_000_000))
    }
    func testTextOnlyOrUnsupportedRuntimeCannotClaimImages() {
        XCTAssertFalse(AssistantVisionPolicy.shouldLoadSharedRuntime(
            isSupportedMultimodal: false, requiredVisionBytes: 1, availableBytes: 6_080_000_000))
    }
    func testUnknownVisionFootprintIsNotAdmitted() {
        XCTAssertFalse(AssistantVisionPolicy.shouldLoadSharedRuntime(
            isSupportedMultimodal: true, requiredVisionBytes: 0, availableBytes: 6_080_000_000))
    }
    func testFullReservedEnvelopeCanFitExactly() {
        XCTAssertTrue(AssistantVisionPolicy.shouldLoadSharedRuntime(
            isSupportedMultimodal: true, requiredVisionBytes: 5_100_000_000, availableBytes: 5_100_000_000))
    }
}
