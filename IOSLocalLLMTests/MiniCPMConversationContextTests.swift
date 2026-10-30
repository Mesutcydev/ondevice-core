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
        // The old GGUF budget reserved the whole 3072-token reply.
        let previousBudget = 1_008
        let previous = ConversationContextCompactor.prepare(
            messages: messages, existingMemory: nil, maxTokens: previousBudget)
        XCTAssertTrue(previous.didCompact)
        XCTAssertFalse(previous.messages.contains { $0.content == messages[2].content })

        let budget = profile.inputBudget(requestedOutputTokens: 3_072)
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

    func test_largeSystemPromptStillLeavesTheCompactedPromptInsideTheWindow() {
        let system = ChatMessage(role: .system, content: String(repeating: "rule ", count: 960))
        let dialog = (0..<12).flatMap { index in
            [ChatMessage(role: .user, content: "Question \(index): " + String(repeating: "detail ", count: 70)),
             ChatMessage(role: .assistant, content: "Answer \(index): " + String(repeating: "result ", count: 70))]
        }
        let prepared = ConversationContextCompactor.prepare(
            messages: [system] + dialog, existingMemory: nil, maxTokens: 2_032)
        XCTAssertTrue(prepared.didCompact)
        XCTAssertEqual(prepared.messages.first?.id, system.id)
        XCTAssertEqual(prepared.messages.last?.id, dialog.last?.id)
        XCTAssertLessThanOrEqual(ConversationContextCompactor.estimateTokens(prepared.messages), 2_032)
    }

    func test_overLongPromptKeepsTheFirstTurnAndWholeNewestTurns() {
        // 0 ends a turn; 1 is BOS; 2 the system turn; 3...5 later turns.
        let tokens = [1, 2, 2, 2, 0, 3, 3, 3, 3, 0, 4, 4, 4, 0, 5, 5]
        XCTAssertEqual(PromptWindow.trim(tokens, limit: 10) { $0 == 0 }, [1, 2, 2, 2, 0, 5, 5])
        XCTAssertEqual(PromptWindow.trim(tokens, limit: 16) { $0 == 0 }, tokens)
        let plain = [1, 2, 2, 2, 2, 2, 0, 3, 3]
        XCTAssertEqual(PromptWindow.trim(plain, limit: 6) { $0 == 0 }, [1, 2, 2, 0, 3, 3])
    }
}
