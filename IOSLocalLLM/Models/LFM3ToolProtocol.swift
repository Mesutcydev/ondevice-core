import Foundation

/// Liquid's tool format uses XML-like function and parameter tags. It is not
/// XML: `<function=name>` is the publisher's literal syntax.
nonisolated enum LFM3ToolProtocol {
    struct Call {
        let name: String
        let arguments: [String: Any]
    }

    private struct Parameter {
        let name: String
        let type: String
        let required: Bool
        init(_ name: String, _ type: String = "string", required: Bool = true) {
            self.name = name; self.type = type; self.required = required
        }
    }

    private struct Definition {
        let name: String
        let description: String
        let parameters: [Parameter]
        init(_ name: String, _ description: String, _ parameters: [Parameter] = []) {
            self.name = name; self.description = description; self.parameters = parameters
        }

        /// Liquid's template renders each tool as `tool_to_json`: OpenAI key
        /// order with `", "` and `": "` separators. Names and descriptions are
        /// quote-free literals; the definition test parses every line as JSON.
        var json: String {
            let properties = parameters.map { "\"\($0.name)\": {\"type\": \"\($0.type)\"}" }
            let required = parameters.filter(\.required).map { "\"\($0.name)\"" }
            return "{\"name\": \"\(name)\", \"description\": \"\(description)\", \"parameters\": "
                + "{\"type\": \"object\", \"properties\": {\(properties.joined(separator: ", "))}, "
                + "\"required\": [\(required.joined(separator: ", "))]}}"
        }
    }

    /// Only the app tools get schemas. The 22 repository schemas (~4,300
    /// characters) plus the GitHub contract overflowed the 4K window, so the
    /// bridge cut the start of the system prompt. The GitHub addendum's
    /// catalog names their parameters instead.
    static let systemPrompt: String = {
        let tools: [Definition] = [
            .init("calculator", "Evaluate arithmetic.", [.init("expression")]),
            .init("datetime", "Get the current date and time.", [.init("timezone", required: false)]),
            .init("unit_convert", "Convert a value between units.", [.init("value", "number"), .init("from"), .init("to")]),
            .init("web_search", "Search the web or fetch a URL, subject to user permission.", [.init("query")]),
            .init("file_read", "Ask the user to choose a file.", [.init("prompt", required: false)]),
            .init("describe_image", "Describe the latest attached image."),
            .init("knowledge_base", "Search the user's indexed documents.", [.init("query")]),
            .init("index_document", "Request permission to save text in the knowledge base.", [.init("text"), .init("name", required: false)]),
            .init("generate_image", "Request permission to generate an image.", [.init("prompt"), .init("negative_prompt", required: false), .init("steps", "integer", required: false), .init("model", required: false)])
        ]
        return """
        Use an available tool only when needed. The app executes calls and returns results; never invent a result.
        Call one tool at a time. Web access, file selection, image generation, and repository changes remain subject to the app's existing permissions and review.
        <tools>
        \(tools.map(\.json).joined(separator: "\n"))
        </tools>
        """
    }()

    /// Liquid's parser reads answer text, then the calls that end the reply.
    /// A call runs only when calls close the reply and it is not quoted as
    /// Markdown code; incomplete streamed calls and examples followed by more
    /// prose cannot run a tool. Of several calls, the first runs.
    static func parse(_ output: String, allowedNames: Set<String>) -> Call? {
        let reply = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = reply.range(of: "<tool_call>"),
              // An odd number of backticks before the call means it is inside code.
              reply[..<start.lowerBound].filter({ $0 == "`" }).count.isMultiple(of: 2) else { return nil }
        let text = String(reply[start.lowerBound...])
        guard let block = try? NSRegularExpression(pattern:
                #"(?s)^<tool_call>\s*<function=([A-Za-z_][A-Za-z0-9_]*)>\s*(.*?)\s*</function>\s*</tool_call>"#),
              let match = block.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
        let rest = text[whole.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.isEmpty || rest.hasPrefix("<tool_call>") else { return nil }
        let name = String(text[nameRange])
        guard allowedNames.contains(name) else { return nil }
        let body = String(text[bodyRange])
        guard let parameter = try? NSRegularExpression(pattern:
            #"(?s)<parameter=([A-Za-z_][A-Za-z0-9_]*)>\n?(.*?)\n?</parameter>"#) else { return nil }
        let matches = parameter.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard matches.count <= 32 else { return nil }
        var arguments: [String: Any] = [:]
        var cursor = body.startIndex
        for entry in matches {
            guard let whole = Range(entry.range, in: body),
                  body[cursor..<whole.lowerBound].allSatisfy(\.isWhitespace),
                  let keyRange = Range(entry.range(at: 1), in: body),
                  let valueRange = Range(entry.range(at: 2), in: body) else { return nil }
            let key = String(body[keyRange])
            guard arguments[key] == nil,
                  let value = argumentValue(String(body[valueRange]), tool: name, key: key) else { return nil }
            arguments[key] = value
            cursor = whole.upperBound
        }
        guard body[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        return Call(name: name, arguments: arguments)
    }

    /// The answer text written before the call, kept visible while it runs.
    static func preamble(of reply: String) -> String {
        let answer = reply.range(of: "</think>", options: .backwards).map { String(reply[$0.upperBound...]) } ?? reply
        guard let start = answer.range(of: "<tool_call>") else { return "" }
        return answer[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func argumentValue(_ raw: String, tool: String, key: String) -> Any? {
        // Like Liquid's own parser, keep file text exactly: only the newline
        // wrapping each value is removed. Trimming dropped a final newline or
        // leading indentation and changed replace_text's occurrence count.
        if ["content", "oldText", "newText"].contains(key) { return raw }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["steps", "page", "start_line", "line_count", "limit", "expectedOccurrences"].contains(key) {
            return Int(value)
        }
        if tool == "unit_convert", key == "value" {
            guard let number = Double(value), number.isFinite else { return nil }
            return number
        }
        if key == "recursive" {
            if value == "true" { return true }
            if value == "false" { return false }
            return nil
        }
        if key == "paths" {
            guard let data = value.data(using: .utf8),
                  let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
            return paths
        }
        return value
    }

    /// Protect the template's role delimiters when tool results contain
    /// untrusted web, file, or repository text.
    static func toolResponse(_ text: String) -> String {
        text.replacingOccurrences(of: "<|im_start|>", with: "&lt;|im_start|>")
            .replacingOccurrences(of: "<|im_end|>", with: "&lt;|im_end|>")
            .replacingOccurrences(of: "<tool_response>", with: "&lt;tool_response>")
            .replacingOccurrences(of: "</tool_response>", with: "&lt;/tool_response>")
    }
}
