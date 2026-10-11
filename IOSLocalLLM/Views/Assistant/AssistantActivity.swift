import Foundation

/// Pure helpers for in-chat activity cards. Kept off SwiftUI so the
/// transcript can render streaming / approval / tool-result chrome without
/// changing the generate or ToolRunner loops.
enum AssistantActivity {
    enum Status: Equatable {
        case generating
        case reasoning
        case preparingTool(String)
        case runningTool(String)
        case awaitingApproval(String)
    }

    struct ToolResultPayload: Equatable {
        let name: String
        let result: String
    }

    enum ToolStatus: Equatable { case success, failure, cancelled }

    struct TranscriptRow: Identifiable {
        let messages: [ChatMessage]
        let isToolGroup: Bool
        var id: UUID { messages[0].id }
    }

    /// Group only adjacent tool results, preserving transcript order and IDs.
    static func transcriptRows(_ messages: [ChatMessage]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for message in messages {
            let isTool = (message.role == .user || message.role == .tool)
                && parseToolResult(message.content) != nil
            if isTool, rows.last?.isToolGroup == true {
                let last = rows.removeLast()
                rows.append(.init(messages: last.messages + [message], isToolGroup: true))
            } else {
                rows.append(.init(messages: [message], isToolGroup: isTool))
            }
        }
        return rows
    }

    /// Saved positions from before pill grouping still resolve to their visible row.
    static func transcriptRowID(for messageID: UUID, in messages: [ChatMessage]) -> UUID {
        transcriptRows(messages).first { row in
            row.messages.contains { $0.id == messageID }
        }?.id ?? messageID
    }

    static func toolStatus(result: String) -> ToolStatus {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("the user cancelled") || text.hasPrefix("the user declined")
            || text.hasPrefix("the user did not choose a readable file.") {
            return .cancelled
        }
        if text.hasPrefix("error:") || text.hasPrefix("failed") || text.hasPrefix("couldn't")
            || text.hasPrefix("could not") || text.hasPrefix("[timed out")
            || text.hasPrefix("web search failed:") || text.hasPrefix("file read failed:") {
            return .failure
        }
        return .success
    }

    static func toolPillTitle(name: String, result: String) -> String {
        switch toolStatus(result: result) {
        case .failure: return "\(name) failed"
        case .cancelled: return "\(displayName(forTool: name)) cancelled"
        case .success:
            if ["read_file", "read_file_range"].contains(name), result.hasPrefix("File: "), let line = result.split(separator: "\n").first {
                return "Read \(String(line.dropFirst(6).prefix(64)))"
            }
            if ["write_file", "replace_text", "delete_file", "upload_attachment", "redact_secrets", "move_file"].contains(name),
               result.hasPrefix("Staged ") {
                return String((result.components(separatedBy: ". ").first ?? result).prefix(80))
            }
            if toolResultKind(name: name) == .file {
                // FileAttachmentService puts metadata before the document payload.
                // Name the actual file rather than its reference-material header.
                if result.hasPrefix("ATTACHED FILES"), let file = result.split(separator: "\n")
                    .first(where: { $0.hasPrefix("File [1]: ") }) {
                    return "Read \(String(file.dropFirst("File [1]: ".count).prefix(64)))"
                }
                let firstLine = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").first.map(String.init) ?? ""
                if firstLine.hasPrefix("Read ") { return String(firstLine.prefix(80)) }
                if !firstLine.isEmpty { return "Read \(String(firstLine.prefix(64)))" }
                return "Read a local file"
            }
            let summary = toolResultSummary(name: name, result: result)
            return "\(displayName(forTool: name)) · \(String(summary.prefix(64)))"
        }
    }

    /// Timing belongs to the message, so scrolling a row offscreen cannot restart it.
    static func updateReasoningTiming(_ message: inout ChatMessage,
                                      expectsImplicitThinking: Bool, now: Date = .now) {
        let content = message.content
        let closed = content.contains("</think>") || content.contains("</analysis>")
            || content.contains("<channel|>") || content.contains("[/THINK]")
        let open = content.contains("<think>") || content.contains("<analysis>")
            || content.contains("<|channel>") || content.contains("[THINK]")
            || (expectsImplicitThinking && !closed && !content.isEmpty)
        if message.reasoningStartedAt == nil, open || (expectsImplicitThinking && closed) {
            message.reasoningStartedAt = now
        }
        if closed, message.reasoningDuration == nil, let started = message.reasoningStartedAt {
            message.reasoningDuration = max(0, now.timeIntervalSince(started))
        }
    }

    static func finishReasoningTiming(_ message: inout ChatMessage, now: Date = .now) {
        guard message.reasoningDuration == nil, let started = message.reasoningStartedAt else { return }
        message.reasoningDuration = max(0, now.timeIntervalSince(started))
    }

    static func normalizeCompletedReply(_ message: inout ChatMessage, expectsImplicitThinking: Bool) {
        var content = AssistantOutputSanitizer.normalizeReasoningMarkup(message.content)
        if expectsImplicitThinking, message.reasoningStartedAt != nil, !content.contains("<think>"), !content.isEmpty {
            content = "<think>" + content
        }
        message.content = content
    }

    /// Returns false only when this protocol-only turn has no thoughts to keep.
    static func retainReasoningForTool(_ message: inout ChatMessage) -> Bool {
        let presentation = AssistantReplyPresentation(content: message.content, isStreaming: false)
        guard presentation.hasReasoning || message.reasoningStartedAt != nil else { return false }
        message.modelContent = message.content
        message.content = "<think>" + presentation.reasoning + "</think>"
        message.isStreaming = false
        return true
    }

    static func streamingStatus(
        content: String,
        detectedToolName: String?
    ) -> Status {
        if let name = detectedToolName, !name.isEmpty {
            return .preparingTool(name)
        }
        if isOpenReasoning(content) {
            return .reasoning
        }
        return .generating
    }

    static func isOpenReasoning(_ content: String) -> Bool {
        let c = content
        if c.contains("<think>"), !c.contains("</think>") { return true }
        if !c.contains("<think>"), c.contains("</think>") { return false }
        return false
    }

    static func displayName(forTool name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func symbol(forTool name: String) -> String {
        if ["git_log", "git_diff", "create_branch", "open_pull_request", "revert_last_commit", "check_run_status", "request_user_approval"].contains(name) { return "arrow.triangle.branch" }
        let lower = name.lowercased()
        if lower.contains("web") || lower.contains("search") { return "globe" }
        if lower.contains("file") { return "doc.text" }
        if lower.contains("vision") || lower.contains("image") { return "eye" }
        if lower.contains("memory") || lower.contains("knowledge") { return "brain.head.profile" }
        if lower.contains("calc") { return "function" }
        if lower.contains("date") || lower.contains("time") { return "clock" }
        return "wrench.and.screwdriver"
    }

    static func parseToolResult(_ content: String) -> ToolResultPayload? {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```tool_result") else { return nil }
        let inner = t
            .replacingOccurrences(of: "```tool_result", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = inner.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = (obj["name"] as? String) ?? "tool"
        let result: String = {
            if let s = obj["result"] as? String { return s }
            if let r = obj["result"] { return String(describing: r) }
            return ""
        }()
        return ToolResultPayload(name: name, result: result)
    }

    static func statusTitle(_ status: Status) -> String {
        switch status {
        case .generating: return "Generating"
        case .reasoning: return "Reasoning…"
        case .preparingTool(let name): return "Preparing \(displayName(forTool: name))"
        case .runningTool(let name): return "Running \(displayName(forTool: name))"
        case .awaitingApproval(let name): return "Needs approval · \(displayName(forTool: name))"
        }
    }

    /// Stop means the user cancelled the turn. A late tool result may still
    /// land, but it must not start another generate.
    static func shouldFollowUpAfterTool(aborted: Bool) -> Bool {
        !aborted
    }

    static func canResumeTruncatedReply(
        hitTokenLimit: Bool?,
        isStreaming: Bool,
        wasInterrupted: Bool?
    ) -> Bool {
        hitTokenLimit == true && !isStreaming && wasInterrupted != true
    }

    static func continuationMessageIndex(in messages: [ChatMessage]) -> Int? {
        guard let idx = messages.lastIndex(where: { $0.role == .assistant }) else {
            return nil
        }
        let message = messages[idx]
        guard canResumeTruncatedReply(
            hitTokenLimit: message.hitTokenLimit,
            isStreaming: message.isStreaming,
            wasInterrupted: message.wasInterrupted
        ) else { return nil }
        return idx
    }

    enum ToolResultKind: Equatable {
        case web, file, calculator, image, datetime, knowledge, other
    }

    static func toolResultKind(name: String) -> ToolResultKind {
        let lower = name.lowercased()
        if lower.contains("web") || lower.contains("search") { return .web }
        if lower.contains("file") { return .file }
        if lower.contains("calc") { return .calculator }
        if lower.contains("image") || lower.contains("vision") { return .image }
        if lower.contains("date") || lower.contains("time") { return .datetime }
        if lower.contains("knowledge") || lower.contains("index") { return .knowledge }
        return .other
    }

    static func toolResultSummary(name: String, result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed
        switch toolResultKind(name: name) {
        case .calculator:
            return firstLine.isEmpty ? "Calculated on device" : firstLine
        case .file:
            if firstLine.isEmpty { return "Read a local file" }
            return "File · \(firstLine)"
        case .web:
            return firstLine.isEmpty ? "Web search finished" : String(firstLine.prefix(80))
        case .image:
            return trimmed.hasPrefix("Started generating") ? "Image generation started" : "Image tool finished"
        case .datetime:
            return firstLine.isEmpty ? "Current time" : firstLine
        case .knowledge:
            return firstLine.isEmpty ? "Knowledge Base result" : String(firstLine.prefix(80))
        case .other:
            return firstLine.isEmpty ? "Completed on device" : String(firstLine.prefix(80))
        }
    }

    static func citationTitle(visibleCount: Int) -> String {
        visibleCount == 1 ? "Used 1 web source" : "Used \(visibleCount) web sources"
    }

    enum ImageStatus: Equatable {
        case downloading(Double)
        case loading
        case generating(Double)
        case failed(String)
    }

    static func imageGenerationSubtitle(_ status: ImageStatus) -> String {
        switch status {
        case .downloading(let p):
            return "Downloading · \(Int((p * 100).rounded()))%"
        case .loading:
            return "Loading image model"
        case .generating(let p):
            return "Generating · \(Int((p * 100).rounded()))%"
        case .failed:
            return "Image generation failed"
        }
    }
}
