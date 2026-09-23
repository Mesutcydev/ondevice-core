import Testing
import Foundation
@testable import NativeUIReview

@MainActor
struct ConversationPresentationTests {
    @Test func draftsAndReadingPositionsRoundTripWithoutChangingMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let store = ConversationStore(fileURL: url)
        let a = store.create(title: "First")
        let b = store.create(title: "Second")
        let message = ChatMessage(role: .user, content: "Saved message")
        store.update(id: a.id, messages: [message])
        let file = FileAttachmentService.Attachment(id: UUID(), url: directory.appendingPathComponent("notes.txt"),
            displayName: "notes.txt", byteSize: 5, extractedText: "notes", kind: .text, warning: nil)
        let draft = ConversationPresentation(text: "  draft\nsecond line  ", files: [file],
            images: [.init(data: Data([1, 2, 3]))], imageIDs: [UUID()], readingMessageID: message.id, followsLatest: false)
        store.savePresentation(id: a.id, presentation: draft)
        store.savePresentation(id: b.id, presentation: .init(text: "Different draft"))
        store.flush()
        let restored = ConversationStore(fileURL: url)
        #expect(restored.conversations.first(where: { $0.id == a.id })?.presentation == draft)
        #expect(restored.messages(for: a.id).map(\.content) == ["Saved message"])
        #expect(restored.conversations.first(where: { $0.id == b.id })?.presentation?.text == "Different draft")
    }

    @Test func olderConversationWithoutPresentationStillDecodes() throws {
        let original = StoredConversation(title: "Existing conversation")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "presentation")
        object.removeValue(forKey: "isPinned")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(StoredConversation.self, from: legacy)
        #expect(restored.id == original.id)
        #expect(restored.title == original.title)
        #expect(restored.presentation == nil)
        #expect(restored.isPinned == nil)
    }
    @Test func pinningSurvivesReloadWithoutChangingDraftOrTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let store = ConversationStore(fileURL: url)
        let conversation = store.create(title: "Pinned notes")
        store.update(id: conversation.id, messages: [ChatMessage(role: .user, content: "Original message")])
        store.savePresentation(id: conversation.id, presentation: .init(text: "Unsent draft"))
        store.setPinned(true, for: conversation.id)
        store.flush()
        let restored = ConversationStore(fileURL: url)
        #expect(restored.conversations.first?.isPinned == true)
        #expect(restored.messages(for: conversation.id).map(\.content) == ["Original message"])
        #expect(restored.conversations.first?.presentation?.text == "Unsent draft")
        restored.setPinned(false, for: conversation.id)
        restored.flush()
        #expect(ConversationStore(fileURL: url).conversations.first?.isPinned == false)
    }

}
