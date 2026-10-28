import XCTest
@testable import IOSLocalLLM

final class MiniCPMConversationContextTests: XCTestCase {
    func test_requestedFormatHasPriorityInCompactAndFullPrompts() {
        for budget in [1_008, 2_032, 8_192] {
            let prompt = CodingAssistantService.composeSystemPrompt(.init(
                persona: "Answer from the supplied source.", inputBudget: budget))
            XCTAssertTrue(prompt.contains("Follow the user's requested output format"))
        }
        XCTAssertTrue(CodingAssistantService.systemPrompt.contains("omit fences when requested"))
    }

    private func transcript() -> [ChatMessage] {
        let source = "<html><head><meta name=\"viewport\" content=\"width=device-width\"></head>\n"
            + String(repeating: "button { min-height: 44px; }\n", count: 160)
            + "</html>"
        return [
            .init(role: .system, content: "Review only the supplied page."),
            .init(role: .user, content: "Create a page with twelve buttons."),
            .init(role: .assistant, content: source),
            .init(role: .user, content: "Explain its animation in 80 words."),
            .init(role: .assistant, content: "The animation changes the gradient position."),
            .init(role: .user, content: "Suggest three specific improvements."),
        ]
    }

    func test_longReplyReservationNoLongerErasesThePageOnBriefFollowups() {
        let messages = transcript()
        let profile = GGUFGenerationProfile.standard
        let previousBudget = profile.inputBudget(requestedOutputTokens: 3_072)
        let previous = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: nil, maxTokens: previousBudget)
        XCTAssertTrue(previous.didCompact)
        XCTAssertFalse(previous.messages.contains { $0.content == messages[2].content })

        let budget = profile.inputBudget(requestedOutputTokens: 3_072,
                                         retainingRecentSource: true)
        let prepared = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: nil, maxTokens: budget,
            retainingRecentSource: true)
        let trimmed = CodingAssistantService.trimToInputBudget(prepared.messages, maxTokens: budget)
        XCTAssertNil(prepared.memory)
        XCTAssertFalse(prepared.didCompact)
        XCTAssertEqual(trimmed.map(\.id), messages.map(\.id))
        XCTAssertEqual(trimmed[2].content, messages[2].content)
        XCTAssertEqual(profile.clampedOutputTokens(3_072), 3_072)

        let first = profile.prompt(from: Array(trimmed.dropLast(2)),
                                   template: .qwen3, enableThinking: false)
        let next = profile.prompt(from: trimmed, template: .qwen3, enableThinking: false)
        // Earlier code remains byte-for-byte stable before the new assistant
        // opener, making its existing native batch checkpoint reusable.
        let stable = String(first.prefix(upTo: first.range(of: "<|im_start|>assistant\n",
                                                        options: .backwards)!.lowerBound))
        XCTAssertTrue(next.hasPrefix(stable))
    }

    func test_savedCompactionCanRecoverFullSourceWhenItFitsAgain() {
        let messages = transcript()
        let old = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: nil, maxTokens: 1_008)
        XCTAssertNotNil(old.memory)
        let recovered = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: old.memory, maxTokens: 2_032,
            retainingRecentSource: true)
        XCTAssertNil(recovered.memory)
        XCTAssertEqual(recovered.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(recovered.messages[2].content, messages[2].content)
    }

    func test_sourceRetentionStillCompactsAnOverBudgetConversation() {
        let messages = transcript() + (0..<12).flatMap { index in
            [ChatMessage(role: .user, content: "Question \(index): " + String(repeating: "detail ", count: 70)),
             ChatMessage(role: .assistant, content: "Answer \(index): " + String(repeating: "result ", count: 70))]
        }
        let prepared = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: nil, maxTokens: 2_032,
            retainingRecentSource: true)
        XCTAssertTrue(prepared.didCompact)
        XCTAssertNotNil(prepared.memory)
        XCTAssertLessThan(prepared.messages.count, messages.count)
        XCTAssertEqual(prepared.messages.last?.id, messages.last?.id)
        XCTAssertTrue(prepared.messages.contains { $0.content.contains("[CONVERSATION MEMORY]") })
    }
}
