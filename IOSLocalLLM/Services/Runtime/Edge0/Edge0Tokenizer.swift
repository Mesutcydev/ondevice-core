import Foundation
import Hub
import Tokenizers

// MARK: - Edge0Tokenizer
//
// Thin adapter over swift-transformers' `AutoTokenizer`, which loads the real
// Edge0 `tokenizer.json` / `tokenizer_config.json` / `chat_template.jinja`.
// No tokenizer engine is implemented in this repository.

struct Edge0Tokenizer: @unchecked Sendable {
    let tokenizer: Tokenizer

    static func load(from directory: URL) async throws -> Edge0Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return Edge0Tokenizer(tokenizer: tokenizer)
    }

    func encode(_ text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    func decode(_ ids: [Int], skipSpecialTokens: Bool = false) -> String {
        tokenizer.decode(tokens: ids, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    /// Applies the model's real chat template with the generation prompt
    /// (the Edge0 template appends its assistant role plus the thinking cue).
    ///
    /// transformers renders chat templates with `trim_blocks` and
    /// `lstrip_blocks` enabled; swift-jinja does not apply those settings to
    /// this template's comment blocks, which adds stray newline tokens. The
    /// template text is therefore normalized with the same semantics before
    /// rendering.
    func applyChatTemplate(
        messages: [[String: String]],
        templateDirectory: URL? = nil,
        additionalContext: [String: any Sendable]? = nil
    ) throws -> [Int] {
        let processed = templateDirectory
            .flatMap(Self.normalizedChatTemplate(at:))
        // Full-control overload so family template variables
        // (`enable_thinking`, …) reach the real Jinja renderer.
        return try tokenizer.applyChatTemplate(
            messages: messages.map { $0 as Message },
            chatTemplate: processed.map { ChatTemplateArgument.literal($0) },
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: nil,
            additionalContext: additionalContext
        )
    }

    /// Emulates Jinja `trim_blocks` + `lstrip_blocks` (and strips comments)
    /// the way transformers renders `chat_template.jinja`.
    static func normalizedChatTemplate(at directory: URL) -> String? {
        let candidates = [
            directory.appendingPathComponent("chat_template.jinja"),
            directory.appendingPathComponent("chat_template.json"),
        ]
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), var text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        // Comments: apply the `-` whitespace control on both sides before
        // dropping them, then remove the comment text.
        text = text.replacingOccurrences(
            of: "[ \\t\\n]*\\{#-", with: "{#", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "-#\\}[ \\t\\n]*", with: "#}", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\{#.*?#\\}\\n?",
            with: "",
            options: .regularExpression
        )
        // Jinja whitespace control (`-`): swift-jinja does not apply it, so
        // apply it to the template text before rendering.
        text = text.replacingOccurrences(
            of: "[ \\t\\n]*\\{\\{-", with: "{{", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "[ \\t\\n]*\\{%-", with: "{%", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "-%\\}[ \\t\\n]*", with: "%}", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "-\\}\\}[ \\t\\n]*", with: "}}", options: .regularExpression)
        // lstrip_blocks: leading whitespace before a block tag.
        text = text.replacingOccurrences(
            of: "(?m)^[ \\t]*(\\{%|\\{#)",
            with: "$1",
            options: .regularExpression
        )
        // trim_blocks: the newline right after a statement/comment tag.
        text = text.replacingOccurrences(
            of: "(%}|#})\\n",
            with: "$1",
            options: .regularExpression
        )
        return text
    }
}
