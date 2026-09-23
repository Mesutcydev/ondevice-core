import XCTest
@testable import IOSLocalLLM

final class LegalDocumentScrollGateTests: XCTestCase {
    func testLongDocumentDoesNotUnlockBeforeVisibleEnd() {
        XCTAssertFalse(
            LegalDocumentScrollGate.hasReachedEnd(
                visibleMaxY: 790,
                contentHeight: 1_000
            )
        )
    }

    func testLongDocumentUnlocksAtActualEnd() {
        XCTAssertTrue(
            LegalDocumentScrollGate.hasReachedEnd(
                visibleMaxY: 999,
                contentHeight: 1_000
            )
        )
    }

    func testShortDocumentUnlocksWhenViewportContainsContent() {
        XCTAssertTrue(
            LegalDocumentScrollGate.hasReachedEnd(
                visibleMaxY: 600,
                contentHeight: 400
            )
        )
    }
}
