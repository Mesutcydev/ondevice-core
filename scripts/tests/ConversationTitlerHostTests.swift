import XCTest
@testable import IOSLocalLLM

@MainActor final class ConversationTitlerHostTests: XCTestCase {
    private let request = "Create an animated gradient background for a web page"
    private func fixture(title: String? = nil) -> UUID {
        let id = UUID()
        ConversationStore.shared.conversations = [.init(id: id, title: title ?? String(request.prefix(40)))]
        ConversationStore.shared.titleWrites = 0
        CodingAssistantService.shared.state = .ready
        CodingAssistantService.shared.usesMiniCPMStreamingText = false
        CodingAssistantService.shared.stopEpoch = 0
        CodingAssistantService.shared.generationCalls = 0
        CodingAssistantService.shared.generatedTitle = "\"Animated Gradient Background\""
        CodingAssistantService.shared.beforeCompletion = nil
        return id
    }
    func testMiniCPMRetainsTheExistingTitleWithoutClaimingInference() async {
        let id = fixture()
        CodingAssistantService.shared.usesMiniCPMStreamingText = true
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(CodingAssistantService.shared.generationCalls, 0)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 0)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, String(request.prefix(40)))
        XCTAssertEqual(CodingAssistantService.shared.state, .ready)
    }
    func testOrdinaryModelStillGeneratesAndCleansItsTitle() async {
        let id = fixture()
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(CodingAssistantService.shared.generationCalls, 1)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 1)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, "animated gradient background")
    }
    func testManuallyNamedConversationIsPreserved() async {
        let id = fixture(title: "My website")
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(CodingAssistantService.shared.generationCalls, 0)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, "My website")
    }
    func testUnloadedModelDoesNotGenerate() async {
        let id = fixture()
        CodingAssistantService.shared.state = .unloaded
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(CodingAssistantService.shared.generationCalls, 0)
    }
    func testDeletedConversationIsNotRecreated() async {
        let id = fixture()
        CodingAssistantService.shared.beforeCompletion = { ConversationStore.shared.conversations = [] }
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertTrue(ConversationStore.shared.conversations.isEmpty)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 0)
    }
    func testStopDuringTitlingKeepsTheOriginal() async {
        let id = fixture()
        CodingAssistantService.shared.beforeCompletion = { CodingAssistantService.shared.stopEpoch += 1 }
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 0)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, String(request.prefix(40)))
    }
    func testRenameDuringTitlingIsPreserved() async {
        let id = fixture()
        CodingAssistantService.shared.beforeCompletion = { ConversationStore.shared.conversations[0].title = "Renamed" }
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 0)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, "Renamed")
    }
    func testLongRequestIsBoundedInThePrompt() async {
        let long = request + String(repeating: " and more detail", count: 2_000)
        let id = fixture()
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: long)
        XCTAssertLessThan(CodingAssistantService.shared.lastPrompt.count, ConversationTitler.maximumRequestCharacters + 200)
        XCTAssertTrue(CodingAssistantService.shared.lastPrompt.contains(request))
    }
    func testEmptyGeneratedTitlePreservesTheOriginal() async {
        let id = fixture()
        CodingAssistantService.shared.generatedTitle = "<think>"
        await ConversationTitler.titleIfNeeded(conversationID: id, firstUserMessage: request)
        XCTAssertEqual(ConversationStore.shared.titleWrites, 0)
        XCTAssertEqual(ConversationStore.shared.conversations.first?.title, String(request.prefix(40)))
    }
}
