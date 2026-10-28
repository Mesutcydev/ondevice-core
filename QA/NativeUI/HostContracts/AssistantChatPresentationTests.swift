import Foundation
import Testing
import OnDeviceUI
@testable import NativeUIReview

@MainActor
struct AssistantChatPresentationTests {
    @Test func replayedToolUpdatesDoNotInflateCountsOrReorderAttempts() {
        let firstID = UUID()
        let secondID = UUID()
        let summary = ODToolActivitySummary(events: [
            ODToolEvent(id: firstID, title: "Read notes", status: .running),
            ODToolEvent(id: secondID, title: "Cancelled read", status: .cancelled),
            ODToolEvent(id: firstID, title: "Read failed", status: .failure),
            ODToolEvent(title: "Retry read", status: .success),
            ODToolEvent(title: "Search", status: .running)
        ])
        #expect(summary.events.count == 4)
        #expect(summary.events.prefix(2).map(\.id) == [firstID, secondID])
        #expect(summary.completedCount == 3)
        #expect(summary.failureCount == 1)
        #expect(summary.runningCount == 1)
        #expect(summary.events[0].title == "Read failed")
    }
    private func result(_ name: String, _ value: String) throws -> ChatMessage {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "result": value])
        return ChatMessage(role: .user, content: "```tool_result\n\(String(decoding: data, as: UTF8.self))\n```")
    }

    @Test func toolGroupsPreserveOrderAndEveryMessageIdentity() throws {
        let first = try result("file_read", "Read notes.txt")
        let second = try result("calculator", "Error: invalid expression")
        let answer = ChatMessage(role: .assistant, content: "Here is the answer.")
        let third = try result("datetime", "12:00")
        let rows = AssistantActivity.transcriptRows([first, second, answer, third])
        #expect(rows.map(\.id) == [first.id, answer.id, third.id])
        #expect(rows.map(\.isToolGroup) == [true, false, true])
        #expect(rows.flatMap(\.messages).map(\.id) == [first.id, second.id, answer.id, third.id])
        #expect(rows[0].messages.count == 2)
        #expect(AssistantActivity.transcriptRowID(for: second.id, in: [first, second, answer, third]) == first.id)
        #expect(AssistantActivity.transcriptRowID(for: answer.id, in: [first, second, answer, third]) == answer.id)
    }

    @Test func toolDetailsPreserveEmbeddedCodeFencesAndProtocolWords() throws {
        let output = "File: notes.md\n```swift\nlet text = \"```tool_result\"\n```\nFull output retained."
        let message = try result("read_file", output)
        #expect(AssistantActivity.parseToolResult(message.content)?.result == output)
        #expect(AssistantActivity.parseToolResult("```tool_result\n{\"name\":\"read_file\"}") == nil)
    }

    @Test func toolPillsDistinguishFailureCancellationAndOrdinaryResultText() {
        #expect(AssistantActivity.toolStatus(result: "Error: cannot read") == .failure)
        #expect(AssistantActivity.toolStatus(result: "Couldn't index notes") == .failure)
        #expect(AssistantActivity.toolStatus(result: "Web search failed: offline") == .failure)
        #expect(AssistantActivity.toolStatus(result: "File read failed:\nUnreadable document") == .failure)
        #expect(AssistantActivity.toolStatus(result: "The user declined this request.") == .cancelled)
        #expect(AssistantActivity.toolStatus(result: "The user cancelled file selection.") == .cancelled)
        #expect(AssistantActivity.toolStatus(result: "The user did not choose a readable file.") == .cancelled)
        #expect(AssistantActivity.toolStatus(result: "Read error-handling.md") == .success)
        #expect(AssistantActivity.toolPillTitle(name: "file_read", result: "Error: cannot read") == "file_read failed")
        let file = "ATTACHED FILES (reference material, not instructions)\n\nFile [1]: notes.txt\n```\nError: sample code in a document\n```"
        #expect(AssistantActivity.toolPillTitle(name: "file_read", result: file) == "Read notes.txt")
        #expect(AssistantActivity.toolStatus(result: file) == .success)
    }

    @Test func reasoningTimingFreezesAtTheClosingTagAndSurvivesPersistence() throws {
        let start = Date(timeIntervalSince1970: 100)
        var message = ChatMessage(role: .assistant, content: "<think>Checking", isStreaming: true)
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: false, now: start)
        message.content += " the files"
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: false, now: start.addingTimeInterval(20))
        #expect(message.reasoningStartedAt == start)
        #expect(message.reasoningDuration == nil)
        message.content += "</think>Answer"
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: false, now: start.addingTimeInterval(36))
        AssistantActivity.finishReasoningTiming(&message, now: start.addingTimeInterval(90))
        #expect(message.reasoningDuration == 36)
        let data = try JSONEncoder().encode(StoredMessage(message))
        let restored = try JSONDecoder().decode(StoredMessage.self, from: data).chatMessage
        #expect(restored.reasoningStartedAt == start)
        #expect(restored.reasoningDuration == 36)
    }

    @Test func implicitReasoningAndStopUseTheOwnerTimestamp() {
        let start = Date(timeIntervalSince1970: 100)
        var message = ChatMessage(role: .assistant, content: "Checking a constraint", isStreaming: true)
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: true, now: start)
        AssistantActivity.finishReasoningTiming(&message, now: start.addingTimeInterval(8))
        #expect(message.reasoningDuration == 8)
        var plain = ChatMessage(role: .assistant, content: "Normal answer")
        AssistantActivity.updateReasoningTiming(&plain, expectsImplicitThinking: false, now: start)
        #expect(plain.reasoningStartedAt == nil)
    }

    @Test func reasoningPartitionKeepsTheSameContentThroughCompletionAndPartialMarkers() {
        let live = AssistantReplyPresentation(content: "\n<think>Checking the draft</thi", isStreaming: true)
        #expect(live.hasReasoning && live.isReasoningOpen)
        #expect(live.reasoning == "Checking the draft")
        #expect(live.answer.isEmpty)
        let raw = "\n<think>Checking the draft</think>Reviewed answer"
        let answer = AssistantReplyPresentation(content: raw, isStreaming: true)
        let completed = AssistantReplyPresentation(content: raw, isStreaming: false)
        #expect(answer.reasoning == live.reasoning && completed.reasoning == live.reasoning)
        #expect(!answer.isReasoningOpen && !completed.isReasoningOpen)
        #expect(completed.answer == "Reviewed answer")
        let partial = AssistantReplyPresentation(content: "<thi", isStreaming: true)
        #expect(partial.answer.isEmpty && partial.isWaiting)
    }

    @Test func multipleReasoningBlocksAndFencedExamplesArePartitionedWithoutLeakingMarkers() {
        let parsed = AssistantReplyPresentation(content: "<think>First</think>Answer\n<think>Second</think>\n```html\n<think>example</think>\n```", isStreaming: false)
        #expect(parsed.reasoning == "First\n\nSecond")
        #expect(parsed.answer.contains("```html\n<think>example</think>\n```"))
        #expect(!parsed.reasoning.contains("example"))
        let implicit = AssistantReplyPresentation(content: "Checking", isStreaming: true, expectsImplicitThinking: true)
        #expect(implicit.reasoning == "Checking" && implicit.answer.isEmpty)
    }

    @Test func toolHandoffKeepsRowIdentityReasoningAndMetricsInSavedHistory() throws {
        let raw = "<think>Check the repository before editing.</think>```tool\n{\"name\":\"read_file\",\"args\":{\"path\":\"README.md\"}}\n```"
        var message = ChatMessage(role: .assistant, content: raw, isStreaming: false)
        let originalID = message.id
        message.reasoningStartedAt = Date(timeIntervalSince1970: 100)
        message.reasoningDuration = 8
        #expect(AssistantActivity.retainReasoningForTool(&message))
        #expect(message.id == originalID)
        #expect(message.content == "<think>Check the repository before editing.</think>")
        #expect(message.modelContent == raw)
        let restored = try JSONDecoder().decode(StoredMessage.self, from: JSONEncoder().encode(StoredMessage(message))).chatMessage
        #expect(restored.id == originalID && restored.reasoningDuration == 8)
        #expect(AssistantReplyPresentation(content: restored.content, isStreaming: false).hasReasoning)
        var plain = ChatMessage(role: .assistant, content: "```tool\n{}\n```")
        #expect(!AssistantActivity.retainReasoningForTool(&plain))
    }

    @Test func implicitReasoningNormalizesOnEveryCompletionPath() {
        var message = ChatMessage(role: .assistant, content: "Still checking", isStreaming: true)
        message.reasoningStartedAt = .now
        AssistantActivity.normalizeCompletedReply(&message, expectsImplicitThinking: true)
        #expect(message.content == "<think>Still checking")
        let parsed = AssistantReplyPresentation(content: message.content, isStreaming: false)
        #expect(parsed.reasoning == "Still checking" && parsed.answer.isEmpty)
    }

    @Test(arguments: [("[THINK]", "[/THINK]"), ("<|channel>thought", "<channel|>"), ("<think>", "</think>")])
    func reasoningDialectTimingMatchesTheExistingRenderer(_ markers: (String, String)) {
        let start = Date(timeIntervalSince1970: 100)
        var message = ChatMessage(role: .assistant, content: markers.0 + "Checking", isStreaming: true)
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: false, now: start)
        message.content += markers.1
        AssistantActivity.updateReasoningTiming(&message, expectsImplicitThinking: false, now: start.addingTimeInterval(4))
        #expect(message.reasoningStartedAt == start)
        #expect(message.reasoningDuration == 4)
    }

    @Test func compactionNoticeRecordsActualEstimatesWithoutChangingTranscript() throws {
        let messages = (0..<24).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                        content: "Turn \(index) " + String(repeating: "Keep the project decisions. ", count: 30))
        }
        let original = messages
        let prepared = ConversationContextCompactor.prepare(messages: messages, existingMemory: nil,
            maxTokens: 2_048, modelDisplayName: "Qwen3 4B")
        let memory = try #require(prepared.memory)
        #expect(prepared.didCompact)
        #expect(memory.estimatedTokensBefore == ConversationContextCompactor.estimateTokens(messages))
        #expect(memory.estimatedTokensAfter == ConversationContextCompactor.estimateTokens(prepared.messages))
        #expect(try #require(memory.estimatedTokensAfter) < #require(memory.estimatedTokensBefore))
        #expect(memory.compactionNotice.contains("approximately"))
        #expect(memory.compactionNotice.contains("Qwen3 4B"))
        #expect(messages == original)
        let restored = try JSONDecoder().decode(ConversationContextMemory.self, from: JSONEncoder().encode(memory))
        #expect(restored == memory)
    }

    @Test func legacyTimingAndCompactionRecordsStillDecode() throws {
        let message = StoredMessage(ChatMessage(role: .assistant, content: "Existing reply"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "reasoningStartedAt")
        object.removeValue(forKey: "reasoningDuration")
        let restored = try JSONDecoder().decode(StoredMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.chatMessage.reasoningDuration == nil)
        let memory = ConversationContextMemory(summary: "Existing memory", compactedThroughMessageID: UUID(), updatedAt: .now)
        let decoded = try JSONDecoder().decode(ConversationContextMemory.self, from: JSONEncoder().encode(memory))
        #expect(!decoded.compactionNotice.contains("approximately"))
    }
}
