import Foundation

// The real Foundation-only ConversationTitler runs against these isolated
// in-memory dependencies; the host never loads or edits user conversations.
struct ChatMessage {
    enum Role: String { case system, user, assistant, tool }
    let id: UUID
    let role: Role
    let content: String
    var modelContent: String?
    let timestamp: Date
    var imageThumbnails: [Data] = []
    var imageThumbnailData: Data? = nil
    var contentForModel: String { modelContent ?? content }
    init(id: UUID = UUID(), role: Role, content: String,
         modelContent: String? = nil, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.modelContent = modelContent
        self.timestamp = timestamp
    }
}
struct TitleFixtureConversation {
    let id: UUID
    var title: String
}
@MainActor final class ConversationStore {
    static let shared = ConversationStore()
    var conversations: [TitleFixtureConversation] = []
    var titleWrites = 0
    func setTitle(_ title: String, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title
        titleWrites += 1
    }
}
@MainActor final class CodingAssistantService {
    enum State { case ready, unloaded }
    static let shared = CodingAssistantService()
    var state = State.ready
    var usesMiniCPMStreamingText = false
    var stopEpoch = 0
    var generationCalls = 0
    var lastPrompt = ""
    var generatedTitle = "\"Animated Gradient Background\""
    var beforeCompletion: (() -> Void)?
    func generate(messages: [ChatMessage], maxTokensOverride: Int, forceNoThinking: Bool,
                  onToken: @escaping @Sendable (String) -> Void,
                  onComplete: @escaping @Sendable (Double) -> Void) {
        precondition(maxTokensOverride == 16 && forceNoThinking)
        generationCalls += 1
        lastPrompt = messages.last?.content ?? ""
        onToken(generatedTitle)
        beforeCompletion?()
        onComplete(1)
    }
}
@MainActor final class Diagnostics {
    static let shared = Diagnostics()
    func breadcrumb(_ value: String, category: String) {}
}
