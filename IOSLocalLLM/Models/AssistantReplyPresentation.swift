import Foundation

/// One partition for live and completed replies. Reasoning never changes its
/// position in the view hierarchy, and fenced examples remain ordinary code.
struct AssistantReplyPresentation: Equatable {
    let reasoning: String
    let answer: String
    let hasReasoning: Bool
    let isReasoningOpen: Bool
    let isWaiting: Bool

    init(content: String, isStreaming: Bool, expectsImplicitThinking: Bool = false) {
        var source = AssistantOutputSanitizer.clean(content)
        if expectsImplicitThinking, !source.contains("<think>"), !source.contains("</think>"), !source.isEmpty {
            source = "<think>" + source
        }
        if isStreaming {
            // Delimiters arrive over several tokens. Hold incomplete markers
            // instead of briefly rendering them as answer or reasoning text.
            for marker in ["<think>", "</think>", "[THINK]", "[/THINK]", "<|channel>thought", "<channel|>"] {
                for count in stride(from: marker.count - 1, through: 1, by: -1) {
                    if source.hasSuffix(String(marker.prefix(count))) {
                        source.removeLast(count)
                        break
                    }
                }
            }
        }
        var thoughts: [String] = []
        var prose = ""
        var open = false
        for block in StudioTextBlocks.parse(source) {
            switch block {
            case .thinking(let text, let isOpen): thoughts.append(text); open = isOpen
            case .text(let text): prose += text
            case .code(let language, let code): prose += "```" + language + "\n" + code + "```"
            case .math(let math): prose += "$$" + math + "$$"
            }
        }
        reasoning = thoughts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        answer = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        hasReasoning = !thoughts.isEmpty
        isWaiting = isStreaming && thoughts.isEmpty && prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isReasoningOpen = isStreaming && open
    }

    var liveReasoningTail: String {
        reasoning.count > 1_200 ? "…\n" + String(reasoning.suffix(1_200)) : reasoning
    }
}
