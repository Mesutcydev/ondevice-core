import Testing
import Foundation
@testable import NativeUIReview

@MainActor
struct RequestOwnershipTests {
    @Test func generationFailureIsAvailableBeforeCompletionAndKeepsFirstCause() async {
        let successful = ChatGenerationFailure()
        #expect(successful.detail == nil)
        let failure = ChatGenerationFailure()
        failure.record("The model stayed busy; retry shortly")
        await Task.yield()
        failure.record("A later cleanup error")
        #expect(failure.detail == "The model stayed busy; retry shortly")
        // Completion uses this result to show Retry instead of entering the
        // successful tool/reasoning continuation with an empty answer.
        let shouldRunSuccessfulCompletion = failure.detail == nil
        #expect(!shouldRunSuccessfulCompletion)
    }
    @Test func cancelledImageCannotBeReplacedUntilCleanupFinishes() throws {
        var lifetime = PresentationRequestLifetime()
        let firstCandidate = lifetime.begin()
        let first = try #require(firstCandidate)
        let duplicate = lifetime.begin()
        #expect(duplicate == nil) // rapid second Create cannot start another job
        lifetime.cancel()
        #expect(!lifetime.accepts(first)) // late progress/image publication is rejected
        #expect(lifetime.isRunning)
        let duringCancellation = lifetime.begin()
        #expect(duringCancellation == nil) // cancellation has not drained the GPU gate
        let finished = lifetime.finish(first)
        #expect(finished)
        let secondCandidate = lifetime.begin()
        let second = try #require(secondCandidate)
        let staleFinished = lifetime.finish(first)
        #expect(!staleFinished) // old cleanup cannot release the new task
        #expect(lifetime.accepts(second))
    }

    @Test func delayedAcknowledgementDoesNotClearNewerOrRetypedDraft() async throws {
        let original = ConversationPresentation(text: "  İlk soru 👋\nlet value = 1  ")
        let request = ChatPresentationRequest(id: UUID(), conversationID: UUID(), draftRevision: 4,
            modelID: "local/model-a", draft: original, attachmentIDs: [])
        var current = original
        #expect(request.matchesDraft(current, revision: 4))
        current.text = "Yeni taslak"
        await Task.yield() // simulate the host acknowledgement arriving after editing
        if request.matchesDraft(current, revision: 5) { current.text = "" }
        #expect(current.text == "Yeni taslak")
        current.text = original.text // delete and retype the same text is still a newer revision
        #expect(!request.matchesDraft(current, revision: 6))
        #expect(request.draft.text == "  İlk soru 👋\nlet value = 1  ")
    }

    @Test func conversationSwitchAndModelSwitchRejectStaleWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let a = store.create(title: "A"), b = store.create(title: "B")
        let request = ChatPresentationRequest(id: UUID(), conversationID: a.id, draftRevision: 1,
            modelID: "model-a", draft: .init(text: "Request A"), attachmentIDs: ["file-a"])
        store.update(id: a.id, messages: [.init(role: .user, content: request.draft.text)])
        store.savePresentation(id: b.id, presentation: .init(text: "Unsent B"))
        await Task.yield()
        #expect(!request.belongsTo(requestID: UUID(), conversationID: b.id, modelID: "model-a"))
        #expect(!request.belongsTo(requestID: request.id, conversationID: a.id, modelID: "model-b"))
        #expect(request.belongsTo(requestID: request.id, conversationID: a.id, modelID: "model-a"))
        #expect(store.messages(for: a.id).first?.content == "Request A")
        #expect(store.messages(for: b.id).isEmpty)
        #expect(store.conversations.first(where: { $0.id == b.id })?.presentation?.text == "Unsent B")
    }

    @Test func changedAttachmentDraftCannotBeConsumedByOldSubmission() {
        let image = ChatMessage.ImageAttachment(data: Data([1, 2, 3]))
        let original = ConversationPresentation(text: "", images: [image], imageIDs: [UUID()])
        let request = ChatPresentationRequest(id: UUID(), conversationID: UUID(), draftRevision: 1,
            modelID: "vision", draft: original, attachmentIDs: original.imageIDs.map(\.uuidString))
        var current = original
        current.images = [.init(data: Data([4, 5, 6]))]
        current.imageIDs = [UUID()]
        #expect(!request.matchesDraft(current, revision: 2))
        #expect(request.draft.images == [image])
    }

    @Test func failedPreparationKeepsNewDraftAndRecoverableOriginalAcrossLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let store = ConversationStore(fileURL: url)
        let conversation = store.create()
        let original = ConversationPresentation(text: "Original request", images: [.init(data: Data([1, 2]))], imageIDs: [UUID()])
        let newer = ConversationPresentation(text: "Newer draft")
        store.savePresentation(id: conversation.id, presentation: newer)
        store.preserveUnsentDraft(id: conversation.id, draft: original)
        store.preserveUnsentDraft(id: conversation.id, draft: original)
        store.flush()
        let restored = ConversationStore(fileURL: url)
        #expect(restored.conversations[0].presentation == newer)
        #expect(restored.conversations[0].unsentDrafts?.count == 1)
        let recovered = restored.takeUnsentDraft(id: conversation.id, at: 0)
        #expect(recovered == original)
        restored.preserveUnsentDraft(id: conversation.id, draft: newer)
        #expect(restored.conversations[0].unsentDrafts == [newer])
    }
}
