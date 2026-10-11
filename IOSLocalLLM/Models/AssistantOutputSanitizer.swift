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
