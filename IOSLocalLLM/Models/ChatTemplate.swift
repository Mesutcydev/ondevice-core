import Foundation

// MARK: - Assistant output cleanup

/// Removes small prompt-boundary artifacts emitted by some converted local
/// models. Keep this deliberately narrow: normal answer text must pass through
/// unchanged.
enum AssistantOutputSanitizer {
    /// End-of-turn markers a model can print when it misses its stop token.
    static let endOfTurnMarkers = [
        "<|im_end|>", "<|endoftext|>", "<end_of_turn>", "<|eot_id|>",
        "<|end_of_text|>", "<|end|>", "</s>", "<turn|>", "<|return|>",
    ]

    /// Brings every family's reasoning delimiters to `<think>…</think>`:
    /// Gemma 4 uses `<|channel>thought … <channel|>`, Magistral `[THINK]`.
    /// When the template opened `<think>` in the prompt (Qwen 3.5, DeepSeek-R1,
    /// Qwen3 Thinking) the reply starts mid-reasoning, so a lone `</think>`
    /// gets its opener back. Empty reasoning blocks and trailing end-of-turn
    /// markers are dropped.
    static func normalizeReasoningMarkup(_ output: String) -> String {
        var text = output
            .replacingOccurrences(of: "<|channel>thought", with: "<think>")
            .replacingOccurrences(of: "<|channel>", with: "<think>")
            .replacingOccurrences(of: "<channel|>", with: "</think>")
            .replacingOccurrences(of: "[THINK]", with: "<think>")
            .replacingOccurrences(of: "[/THINK]", with: "</think>")
        if !text.contains("<think>"), text.contains("</think>") { text = "<think>" + text }
        while let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex),
              text[open.upperBound..<close.lowerBound].allSatisfy(\.isWhitespace) {
            let tail = text[close.upperBound...].drop(while: \.isWhitespace)
            text = String(text[..<open.lowerBound]) + tail
        }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var removed = false
        while let marker = endOfTurnMarkers.first(where: { body.hasSuffix($0) }) {
            body = String(body.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            removed = true
        }
        return removed ? body : text
    }

    static func clean(_ output: String) -> String {
        var lines = normalizeReasoningMarkup(output)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            return lowered == "assistant: off."
                || lowered == "assistant: off"
        }

        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        if lines.first?.trimmingCharacters(in: .whitespaces) == "." {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Foundation's full Markdown parser treats a single newline as a soft
    /// break and may collapse it without leaving visible separation. Local
    /// models frequently use single newlines for compact lists, so promote
    /// those boundaries to Markdown hard breaks while leaving blank-line
    /// paragraph boundaries unchanged.
    static func preservingLineBreaksForMarkdown(_ output: String) -> String {
        let repaired = repairingRunTogetherBoundaries(in: output)
        let lines = repaired
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.count > 1 else { return repaired }

        var result = ""
        for index in lines.indices {
            let line = lines[index]
            result += line
            guard index < lines.index(before: lines.endIndex) else { continue }

            let next = lines[lines.index(after: index)]
            if !line.isEmpty, !next.isEmpty, !line.hasSuffix("  ") {
                result += "  "
            }
            result += "\n"
        }
        return result
    }

    /// Some small converted models omit whitespace at semantic boundaries
    /// even though their token stream looked acceptable while arriving.
    /// Repair only strong prose signals here; fenced code is separated before
    /// this formatter is called, so identifiers and source code stay intact.
    private static func repairingRunTogetherBoundaries(in output: String) -> String {
        var repaired = output
        let replacements: [(String, String)] = [
            // A period inside an initialism such as U.S. is not a sentence break.
            (#"(?<![A-Z])([.!?])([A-Z])"#, "$1\n\n$2"),
            (#"([.!?])([—–]{1,3})([A-Z])"#, "$1\n\n—$3"),
            (#":([A-Z])"#, ":\n$1"),
            (#"\)([A-Z])"#, ")\n$1"),
            (
                #"([a-z0-9])((?:Any|Approximate|Based|Calculations|Chip|City|Current|Description|Document|Draft|Elements|Email|Find|Help|Important|Instagram|It|Just|Keep|Key|Let|Memory|Model|Navigation|North|Note|Once|Or|Original|Please|Pricing|Product|Prompt|Provide|Purpose|Removals|Searching|Set|Something|Step|Stock|Storage|Submit|Temperature|The|This|Uses|Visible|Website|West|What|Working|Works|Would|You|Your)\b)"#,
                "$1\n$2"
            ),
            (
                #"([A-Z]{2,})(?=(?:Chip|Description|Elements|Memory|Model|Navigation|Note|Pricing|Product|Stock|Storage|Visible|Website)\b)"#,
                "$1\n"
            ),
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(repaired.startIndex..., in: repaired)
            repaired = regex.stringByReplacingMatches(
                in: repaired,
                range: range,
                withTemplate: template
            )
        }
        return repaired
    }
}

// MARK: - Image grounding handoff cleanup

/// Cleans text produced by one local model before it is embedded inside
/// another model's chat template. Vision runtimes can occasionally surface
/// their own role/end tokens as ordinary text; passing those through verbatim
/// can close the receiving model's user turn and make it emit EOS immediately.
enum ImageGroundingSanitizer {
    static func clean(_ output: String) -> String {
        var cleaned = output
            .replacingOccurrences(of: "\r\n", with: "\n")

        let controlPatterns = [
            #"<\|[^>\n]{1,80}\|>"#,
            #"</?s>"#,
            #"<end_of_(?:utterance|turn)>"#,
            #"\[/?INST\]"#,
            #"<<\/?SYS>>"#,
        ]
        for pattern in controlPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*(?:assistant|system|user)\s*:?\s*$\n?"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*(?:assistant|system|user)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ChatTemplate
// Describes the prompt formatting rules for a specific model family.
// Used to properly format conversation history before tokenization.
// Different model families (Qwen, Llama, Gemma, Phi) use different
// control tokens and formatting conventions.

struct ChatTemplate: Codable, Hashable {
    /// Template format identifier: "chatml", "qwen35", "llama3", "gemma", "phi", "custom"
    let format: String
    /// Opening tag for a system message turn (e.g. "<|im_start|>system\n")
    let systemPrefix: String
    /// Closing tag for a system message (e.g. "<|im_end|>")
    let systemSuffix: String
    /// Opening tag for a user message turn
    let userPrefix: String
    let userSuffix: String
    /// Opening tag for the assistant message turn
    let assistantPrefix: String
    let assistantSuffix: String
    /// The prompt suffix that tells the model to start generating
    /// (e.g. "<|im_start|>assistant\n" for ChatML)
    let generationPrompt: String
    /// Whether the model supports a "thinking" mode toggle
    let supportsThinking: Bool
    /// Optional tag to suppress thinking (e.g. "/no_think" for Qwen3)
    let noThinkTag: String?
    /// Optional tag to enable thinking (e.g. "/think" for Qwen3)
    let thinkTag: String?
    /// Extra end-of-sequence tokens beyond the standard ones
    let extraEOSTokens: [String]

    // MARK: - Built-in templates

    /// ChatML without reasoning — Qwen2.5, Qwen3 *-Instruct(-2507), SmolLM2.
    /// Matches the official templates, which add nothing after the cue.
    static let chatML = ChatTemplate(
        format: "chatml",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Qwen3 hybrid models (Qwen3-0.6B…8B, Bonsai 1.7B…8B). The official
    /// template switches reasoning off with an empty think block; with it on,
    /// the model opens `<think>` itself.
    static let qwen3 = ChatTemplate(
        format: "qwen3",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: "<think>\n\n</think>\n\n",
        thinkTag: "",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Qwen3 *-Thinking models always reason; their template opens `<think>`.
    static let qwen3Thinking = ChatTemplate(
        format: "qwen3-thinking",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: "<think>\n",
        thinkTag: "<think>\n",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Qwen 3.5 hybrid-attention models use ChatML turns but start every
    /// assistant response with an explicit thinking block. Bonsai 27B keeps
    /// this tokenizer contract even though its repository name omits Qwen.
    static let qwen35 = ChatTemplate(
        format: "qwen35",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: "<think>\n\n</think>\n\n",
        thinkTag: "<think>\n",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Llama 3 — uses <|begin_of_text|> and <|eot_id|>
    static let llama3 = ChatTemplate(
        format: "llama3",
        systemPrefix: "<|start_header_id|>system<|end_header_id|>\n\n",
        systemSuffix: "<|eot_id|>",
        userPrefix: "<|start_header_id|>user<|end_header_id|>\n\n",
        userSuffix: "<|eot_id|>",
        assistantPrefix: "<|start_header_id|>assistant<|end_header_id|>\n\n",
        assistantSuffix: "<|eot_id|>",
        generationPrompt: "<|start_header_id|>assistant<|end_header_id|>\n\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|eot_id|>"]
    )

    /// Gemma — uses <bos>, user/nmodel turns
    static let gemma = ChatTemplate(
        format: "gemma",
        systemPrefix: "",
        systemSuffix: "",
        userPrefix: "<start_of_turn>user\n",
        userSuffix: "<end_of_turn>\n",
        assistantPrefix: "<start_of_turn>model\n",
        assistantSuffix: "<end_of_turn>\n",
        generationPrompt: "<start_of_turn>model\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Phi — uses <|user|>, <|assistant|>, <|system|>
    static let phi = ChatTemplate(
        format: "phi",
        systemPrefix: "<|system|>\n",
        systemSuffix: "<|end|>\n",
        userPrefix: "<|user|>\n",
        userSuffix: "<|end|>\n",
        assistantPrefix: "<|assistant|>\n",
        assistantSuffix: "<|end|>\n",
        generationPrompt: "<|assistant|>\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|end|>", "<|endoftext|>"]
    )

    /// Generic / unknown — fallback to ChatML which is the most widely used.
    static let generic = ChatTemplate(
        format: "generic",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|im_end|>"]
    )

    // MARK: - Resolution

    /// Detect the best template for a model based on its repo ID or display name.
    /// MLX models render their own shipped template; this hand-written one
    /// formats GGUF prompts. Families whose format none of these reproduce
    /// (DeepSeek-R1 distills, Gemma 4, Phi-4) get `.generic`.
    static func detect(for repoID: String) -> ChatTemplate {
        let lower = repoID.lowercased()
        if lower.contains("deepseek") || lower.contains("gemma-4") || lower.contains("gemma4") {
            return .generic
        }
        if lower.contains("qwen3.5") || lower.contains("qwen3_5")
            || lower.contains("ornith")
            || (lower.contains("bonsai") && lower.contains("27b")) {
            return .qwen35
        }
        if lower.contains("qwen3") {
            if lower.contains("thinking") { return .qwen3Thinking }
            return lower.contains("instruct") ? .chatML : .qwen3
        }
        if lower.contains("bonsai") { return .qwen3 }
        if lower.contains("qwen")   { return .chatML }
        if lower.contains("llama")  { return .llama3 }
        if lower.contains("gemma")  { return .gemma }
        if lower.contains("phi-3")  { return .phi }
        if lower.contains("smol")   { return .chatML }
        return .generic
    }

    /// Whether the chat template shipped in `directory` reads
    /// `enable_thinking`. nil when the folder carries no template.
    static func readsThinkingSwitch(in directory: URL) -> Bool? {
        var templates: [String] = []
        if let jinja = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8) {
            templates.append(jinja)
        }
        for name in ["tokenizer_config.json", "chat_template.json"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let template = json["chat_template"] as? String {
                templates.append(template)
            } else if let named = json["chat_template"] as? [[String: Any]] {
                templates += named.compactMap { $0["template"] as? String }
            }
        }
        return templates.isEmpty ? nil : templates.contains { $0.contains("enable_thinking") }
    }

    // MARK: - Formatting

    /// Format an array of ChatMessage into the model's prompt format.
    func format(
        messages: [ChatMessage],
        enableThinking: Bool = false,
        leaveLastAssistantOpen: Bool = false
    ) -> String {
        var parts: [String] = []
        var pendingSystem: [String] = []

        func flushPendingSystem(into userContent: String) -> String {
            guard !pendingSystem.isEmpty else { return userContent }
            let system = pendingSystem.joined(separator: "\n\n")
            pendingSystem.removeAll()
            let trimmedUser = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedUser.isEmpty ? system : system + "\n\n" + userContent
        }

        func emitUserTurn(_ content: String) {
            parts.append("\(userPrefix)\(content)\(userSuffix)")
        }

        let lastIndex = messages.indices.last
        let openLastAssistant = leaveLastAssistantOpen && messages.last?.role == .assistant

        for (index, msg) in messages.enumerated() {
            switch msg.role {
            case .system:
                if !systemPrefix.isEmpty {
                    parts.append("\(systemPrefix)\(msg.contentForModel)\(systemSuffix)")
                } else {
                    // Gemma (and other templates without a system role) fold
                    // instructions into the next user turn once. The previous
                    // path emitted `System: X\n\nX` as its own user turn,
                    // which duplicated a long prompt and made small models
                    // imitate or invent the instructions.
                    pendingSystem.append(msg.contentForModel)
                }
            case .user:
                emitUserTurn(flushPendingSystem(into: msg.contentForModel))
            case .assistant:
                if !pendingSystem.isEmpty {
                    emitUserTurn(flushPendingSystem(into: ""))
                }
                let content = AssistantOutputSanitizer.clean(msg.contentForModel)
                if openLastAssistant && index == lastIndex {
                    parts.append("\(assistantPrefix)\(content)")
                } else {
                    parts.append("\(assistantPrefix)\(content)\(assistantSuffix)")
                }
            case .tool:
                emitUserTurn(flushPendingSystem(into: "Tool result:\n\(msg.contentForModel)"))
            }
        }
        if !pendingSystem.isEmpty {
            emitUserTurn(flushPendingSystem(into: ""))
        }

        if openLastAssistant {
            return parts.joined()
        }

        // Build the generation prompt — the model responds after this.
        var prompt = generationPrompt
        if supportsThinking && enableThinking, let tag = thinkTag {
            prompt += tag
        } else if supportsThinking && !enableThinking, let tag = noThinkTag {
            prompt += tag
        }
        parts.append(prompt)

        return parts.joined()
    }
}

// MARK: - ChatMessage template extension

extension [ChatMessage] {
    /// Format messages using a specific chat template.
    func formattedWithTemplate(
        _ template: ChatTemplate,
        enableThinking: Bool = false,
        leaveLastAssistantOpen: Bool = false
    ) -> String {
        template.format(
            messages: self,
            enableThinking: enableThinking,
            leaveLastAssistantOpen: leaveLastAssistantOpen
        )
    }
}
