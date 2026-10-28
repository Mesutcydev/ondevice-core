import Foundation

nonisolated struct ToolCall: Equatable {
    let name: String
    let args: [String: Any]

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.name == rhs.name
    }
}

/// Shared text-tool parser. The host normalizes model-specific reasoning markers first.
nonisolated enum AssistantToolCallParser {
    static func extractCall(from reply: String) -> ToolCall? {
        // Reasoning may draft or weigh a call; only the answer after it acts.
        let normalized = reply
        let text: String
        if let close = normalized.range(of: "</think>", options: .backwards) {
            text = String(normalized[close.upperBound...])
        } else if normalized.contains("<think>") {
            return nil
        } else {
            text = normalized
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("<function=") {
            guard trimmed.hasPrefix("<tool_call>") else { return nil }
            guard let call = LFM3ToolProtocol.parse(trimmed, allowedNames: knownToolNames) else { return nil }
            return ToolCall(name: call.name, args: call.arguments)
        }
        // Tolerate the closing fence on the same line as the JSON, and the JSON
        // on the same line as the opener — small models routinely emit
        // ```tool\n{json}``` or ```tool {json}``` without the newlines the old
        // pattern required, which silently dropped the call and left a raw
        // ```tool block in the chat. `\s*` around the capture absorbs either.
        //
        // The `(?![A-Za-z0-9_])` guard anchors the keyword so ```tool does NOT
        // match the prefix of a ```tool_result fence. Without it, a model that
        // echoes a tool_result block before emitting its next tool call had the
        // tool_result matched first (capturing "_result\n{…}", which fails JSON
        // parse) and the real chained call was silently dropped.
        let pattern = #"```tool(?![A-Za-z0-9_])\s*([\s\S]*?)\s*```"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text),
               let call = parseCallJSON(String(text[r])) {
                return call
            }
        }

        // Balanced-object scanning avoids greedy regex failures with nested
        // argument dictionaries and tolerates reasoning text around the JSON.
        for data in candidateJSONObjects(in: text) {
            if let call = parseCallJSON(data) { return call }
        }
        return nil
    }

    private static let knownToolNames: Set<String> = Set([
        "calculator", "datetime", "unit_convert", "web_search", "file_read",
        "describe_image", "knowledge_base", "index_document", "generate_image"
    ]).union(GitHubWorkspaceService.toolNames)

    private static func parseCallJSON(_ string: String) -> ToolCall? {
        guard let data = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else { return nil }
        return parseCallJSON(data)
    }

    private static func parseCallJSON(_ data: Data) -> ToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else { return nil }
        let raw: [String: Any]
        if let calls = object["tool_calls"] as? [[String: Any]],
           let first = calls.first {
            raw = first
        } else {
            raw = object
        }
        let function = raw["function"] as? [String: Any] ?? raw
        guard let name = function["name"] as? String,
              knownToolNames.contains(name) else { return nil }
        let value = function["args"]
            ?? function["arguments"]
            ?? function["parameters"]
        let args: [String: Any]
        if let dictionary = value as? [String: Any] {
            args = dictionary
        } else if let encoded = value as? String,
                  let data = encoded.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] {
            args = dictionary
        } else if value == nil {
            args = [:]
        } else {
            return nil
        }
        return ToolCall(name: name, args: args)
    }

    private static func candidateJSONObjects(in text: String) -> [Data] {
        let bytes = Array(text.utf8)
        var candidates: [Data] = []
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == 0x7D, depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    candidates.append(Data(bytes[start...index]))
                }
            }
        }
        return candidates
    }
}
