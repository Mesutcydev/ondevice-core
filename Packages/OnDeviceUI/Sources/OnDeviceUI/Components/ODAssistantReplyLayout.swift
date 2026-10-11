import SwiftUI

/// The reasoning disclosure occupies the same structural slot across waiting,
/// tokens, tools, completion and interruption. Only the answer renderer changes.
public struct ODAssistantReplyLayout<Answer: View>: View {
    private let reasoning: String
    private let showsReasoning: Bool
    private let isReasoningOpen: Bool
    private let seconds: Int?
    private let startedAt: Date?
    private let answer: Answer

    public init(reasoning: String, showsReasoning: Bool, isReasoningOpen: Bool,
                seconds: Int?, startedAt: Date?, @ViewBuilder answer: () -> Answer) {
        self.reasoning = reasoning
        self.showsReasoning = showsReasoning
        self.isReasoningOpen = isReasoningOpen
        self.seconds = seconds
        self.startedAt = startedAt
        self.answer = answer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsReasoning {
                ODReasoningBlock(content: reasoning, isOpen: isReasoningOpen,
                                 seconds: seconds, startedAt: startedAt)
            }
            answer
        }
    }
}
