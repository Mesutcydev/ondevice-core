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

        var json: String {
            var properties: [String: Any] = [:]
            for parameter in parameters {
                var property: [String: Any] = ["type": parameter.type]
                if parameter.type == "array" { property["items"] = ["type": "string"] }
                properties[parameter.name] = property
            }
            let schema: [String: Any] = ["name": name, "description": description,
                "parameters": ["type": "object", "properties": properties,
                               "required": parameters.filter(\.required).map(\.name)]]
            guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    static func systemPrompt(includeRepositoryTools: Bool) -> String {
        var tools: [Definition] = [
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
        if includeRepositoryTools {
            tools += [
                .init("list_files", "List files in the selected repository.", [.init("path", required: false), .init("recursive", "boolean", required: false)]),
                .init("repository_info", "Inspect the selected repository."),
                .init("list_branches", "List branches.", [.init("page", "integer", required: false)]),
                .init("read_file", "Read a repository file.", [.init("path")]),
                .init("read_file_range", "Read lines from a repository file.", [.init("path"), .init("start_line", "integer"), .init("line_count", "integer")]),
                .init("write_file", "Stage file content for review.", [.init("path"), .init("content"), .init("message", required: false)]),
                .init("replace_text", "Stage an exact replacement for review.", [.init("path"), .init("oldText"), .init("newText"), .init("expectedOccurrences", "integer"), .init("expectedFileHash", required: false)]),
                .init("delete_file", "Stage file deletion for review.", [.init("path"), .init("message", required: false)]),
                .init("move_file", "Stage a file move for review.", [.init("path"), .init("destination")]),
                .init("upload_attachment", "Stage a user-provided attachment for review.", [.init("attachment_name"), .init("path"), .init("message", required: false)]),
                .init("scan_secrets", "Scan selected files for secrets.", [.init("paths", "array")]),
                .init("redact_secrets", "Stage redaction for review.", [.init("path"), .init("expectedFileHash")]),
                .init("audit_secret_history", "Audit selected paths in branch history.", [.init("paths", "array"), .init("limit", "integer", required: false)]),
                .init("search_code", "Search code in the selected repository.", [.init("query")]),
                .init("git_log", "Read repository history.", [.init("limit", "integer", required: false)]),
                .init("git_diff", "Inspect changes.", [.init("base", required: false), .init("head", required: false)]),
                .init("check_run_status", "Check commit status.", [.init("sha", required: false)]),
                .init("workflow_status", "Inspect workflow status."),
                .init("create_branch", "Request review before creating a branch.", [.init("name")]),
                .init("open_pull_request", "Request review before opening a pull request.", [.init("title"), .init("base"), .init("body", required: false), .init("head", required: false)]),
                .init("revert_last_commit", "Request review before reverting a commit.", [.init("reason", required: false)]),
                .init("request_user_approval", "Request review of staged changes.", [.init("message", required: false)])
            ]
        }
        return """

        Use an available tool only when needed. The app executes calls and returns results; never invent a result.
        Call one tool at a time. Web access, file selection, image generation, and repository changes remain subject to the app's existing permissions and review.
        <tools>
        \(tools.map(\.json).joined(separator: "\n"))
        </tools>
        """
    }

    /// Only accept a complete leading protocol block. Incomplete streamed
    /// calls and examples embedded in prose or Markdown cannot run a tool.
    static func parse(_ output: String, allowedNames: Set<String>) -> Call? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<tool_call>"),
              let block = try? NSRegularExpression(pattern:
                #"(?s)^<tool_call>\s*<function=([A-Za-z_][A-Za-z0-9_]*)>\s*(.*?)\s*</function>\s*</tool_call>"#),
              let match = block.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
        let name = String(text[nameRange])
        guard allowedNames.contains(name) else { return nil }
        let body = String(text[bodyRange])
        guard let parameter = try? NSRegularExpression(pattern:
            #"(?s)<parameter=([A-Za-z_][A-Za-z0-9_]*)>\s*(.*?)\s*</parameter>"#) else { return nil }
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

    private static func argumentValue(_ raw: String, tool: String, key: String) -> Any? {
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
