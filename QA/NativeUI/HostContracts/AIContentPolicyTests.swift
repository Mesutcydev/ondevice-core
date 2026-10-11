import XCTest
@testable import NativeUIReview

final class AIContentPolicyTests: XCTestCase {
    func testExplicitImageRequestsAreRejectedAfterNormalization() {
        for prompt in ["Pornographic scene", "ＮＳＦＷ photo", "naked---child", "graphic violence", "ÇIPLAK kadın"] {
            XCTAssertNotNil(AIContentPolicy.imageRequestRestriction(prompt), prompt)
        }
    }

    func testOrdinaryArtAndEducationalDescriptionsRemainAvailable() {
        for prompt in ["A forest beside a lake", "A portrait of Al Gore", "A nude color palette",
                       "Stars visible to the naked eye", "A non-graphic history illustration",
                       "An educational heart anatomy diagram", "An LGBT pride festival",
                       "A watercolor mountain landscape, no text"] {
            XCTAssertNil(AIContentPolicy.imageRequestRestriction(prompt), prompt)
        }
    }

    func testUserNegativePromptIsPreservedAlongsideAppExclusions() {
        let result = AIContentPolicy.negativePrompt(including: "  blurry, extra fingers  ")
        XCTAssertTrue(result.contains("explicit sexual content"))
        XCTAssertTrue(result.hasSuffix("blurry, extra fingers"))
        XCTAssertFalse(AIContentPolicy.negativePrompt(including: " \n ").hasSuffix(", "))
    }

    func testAPIPolicyKeepsHistoryAndFormattingWithOneLeadingSystemMessage() {
        let user = ChatMessage(role: .user, content: "Write a sorting function.")
        let history = [user, ChatMessage(role: .system, content: "Respond with JSON."),
                       ChatMessage(role: .assistant, content: "Which language?"),
                       ChatMessage(role: .system, content: "Use Swift.")]
        let protected = AIContentPolicy.applyingTextInstructions(to: history)
        XCTAssertEqual(protected.filter { $0.role == .system }.count, 1)
        XCTAssertEqual(protected.first?.role, .system)
        XCTAssertTrue(protected[0].content.contains("Respond with JSON."))
        XCTAssertTrue(protected[0].content.contains("Use Swift."))
        XCTAssertTrue(protected[0].content.contains(AIContentPolicy.textInstructions))
        XCTAssertEqual(protected[1].id, user.id)
        XCTAssertEqual(protected[1].content, user.content)
        XCTAssertEqual(protected.last?.role, .assistant)
        XCTAssertEqual(AIContentPolicy.applyingTextInstructions(to: protected).map(\.content), protected.map(\.content))
    }

    @MainActor
    func testSupportDestinationContainsNoUserContentOrTrackingQuery() throws {
        let url = try XCTUnwrap(URL(string: LegalDocuments.supportURL))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ondevice.fun")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }
}
