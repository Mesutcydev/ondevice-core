import Foundation

/// One tokenizer for chat, Lens, and code review. Fenced code is opaque.
enum StudioTextBlocks {
    enum Block: Equatable, Sendable {
        case text(String)
        case code(String, String)
        case thinking(String, Bool)
        case math(String)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var remaining = source[...]
        while !remaining.isEmpty {
            let candidates = ["```", "<think>", "$$"].compactMap { marker in
                remaining.range(of: marker).map { (marker, $0) }
            }
            guard let (marker, range) = candidates.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else {
                blocks.append(.text(String(remaining)))
                break
            }
            if range.lowerBound > remaining.startIndex {
                blocks.append(.text(String(remaining[..<range.lowerBound])))
            }
            remaining = remaining[range.upperBound...]
            if marker == "```" {
                guard let newline = remaining.firstIndex(of: "\n") else {
                    // Incomplete opening fence: preserve it until a language/body arrives.
                    blocks.append(.text("```" + remaining))
                    break
                }
                let language = String(remaining[..<newline]).trimmingCharacters(in: .whitespaces)
                remaining = remaining[remaining.index(after: newline)...]
                if let end = remaining.range(of: "```") {
                    blocks.append(.code(language, String(remaining[..<end.lowerBound])))
                    remaining = remaining[end.upperBound...]
                } else {
                    blocks.append(.code(language, String(remaining)))
                    break
                }
            } else {
                let closing = marker == "<think>" ? "</think>" : "$$"
                if let end = remaining.range(of: closing) {
                    let body = String(remaining[..<end.lowerBound])
                    blocks.append(marker == "<think>" ? .thinking(body, false) : .math(body))
                    remaining = remaining[end.upperBound...]
                } else {
                    blocks.append(marker == "<think>" ? .thinking(String(remaining), true) : .text(marker + remaining))
                    break
                }
            }
        }
        return blocks
    }
}

/// Block layout for assistant prose. `AttributedString(markdown: .full)` keeps
/// inline emphasis but drops visual block boundaries when placed in one Text:
/// headings, paragraphs and table cells run together. Keep those boundaries
/// as separate SwiftUI views, and parse only inline markup inside each block.
enum StudioMarkdownLayout {
    struct ListItem: Equatable, Sendable {
        let marker: String
        let depth: Int
        let text: String
    }

    enum Block: Equatable, Sendable {
        case heading(Int, String)
        case paragraph(String)
        case list([ListItem])
        case quote(String)
        case table([String], [[String]])
        case rule
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                index += 1
                continue
            }
            if index + 1 < lines.count,
               let headers = tableCells(line),
               let separator = tableCells(lines[index + 1]),
               headers.count == separator.count,
               separator.allSatisfy({ isTableRule($0) }) {
                flushParagraph()
                flushList()
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      let cells = tableCells(lines[index]),
                      !cells.allSatisfy({ $0.isEmpty }) {
                    rows.append(cells)
                    index += 1
                }
                blocks.append(.table(headers, rows))
                continue
            }
            if index + 1 < lines.count,
               heading(line) == nil,
               listItem(line) == nil,
               !trimmed.hasPrefix(">"),
               let level = setextLevel(lines[index + 1]) {
                flushList()
                let title = (paragraph + [line]).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                paragraph.removeAll()
                blocks.append(.heading(level, title))
                index += 2
                continue
            }
            if let heading = heading(line) {
                flushParagraph()
                flushList()
                blocks.append(.heading(heading.0, heading.1))
            } else if isRule(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                list.append(item)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoted.append(String(quoteLine.dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            } else {
                flushList()
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        flushList()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first?.isWhitespace == true else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes.count, title)
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        guard !body.isEmpty else { return nil }
        let marker: String
        let rest: Substring
        if let first = body.first, "-*+".contains(first),
           body.dropFirst().first?.isWhitespace == true {
            marker = "•"
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix(while: { $0.isNumber })
            guard !digits.isEmpty,
                  let punctuation = body.dropFirst(digits.count).first,
                  punctuation == "." || punctuation == ")",
                  body.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
            marker = String(digits) + "."
            rest = body.dropFirst(digits.count + 2)
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ListItem(marker: marker, depth: min(indent / 2, 2), text: text)
    }

    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var codeDelimiter = 0
        var sawSeparator = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex, text[next] == "|" {
                cell.append("|")
                index = text.index(after: next)
                continue
            }
            if character == "`" {
                var end = next
                while end < text.endIndex, text[end] == "`" {
                    end = text.index(after: end)
                }
                let count = text.distance(from: index, to: end)
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                cell.append(contentsOf: text[index..<end])
                index = end
                continue
            }
            if character == "|", codeDelimiter == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                sawSeparator = true
            } else {
                cell.append(character)
            }
            index = next
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        guard sawSeparator else { return nil }
        if text.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if text.hasSuffix("|"), cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func setextLevel(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, let first = text.first,
              first == "=" || first == "-",
              text.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func isTableRule(_ cell: String) -> Bool {
        let dashes = cell.filter { $0 == "-" }.count
        return dashes >= 3 && cell.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func isRule(_ line: String) -> Bool {
        let characters = line.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first,
              "-* _".contains(first) else { return false }
        return characters.allSatisfy { $0 == first }
    }
}

/// A reset invalidates work already running; capacity is checked again at commit.
struct StudioImportGate {
    private(set) var generation: UInt64 = 0
    mutating func reset() { generation &+= 1 }
    func accepts(_ ticket: UInt64, existing: Int, incoming: Int, limit: Int) -> Bool {
        ticket == generation && incoming > 0 && existing <= limit && incoming <= limit - existing
    }
}

struct StudioTranscriptSegment: Identifiable, Equatable {
    let id: Int // UTF-16 offset, stable as the transcript grows
    let range: NSRange
    let text: String

    static func make(_ text: String) -> [Self] {
        var result: [Self] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: 360, limitedBy: text.endIndex) ?? text.endIndex
            let candidate = text[start..<limit]
            let boundary = candidate.lastIndex(where: { $0.isWhitespace || $0 == "." })
            let end = limit == text.endIndex ? limit : boundary.map { text.index(after: $0) } ?? limit
            let range = NSRange(start..<end, in: text)
            result.append(.init(id: range.location, range: range, text: String(text[start..<end])))
            start = end
        }
        return result
    }

    static func activeID(in segments: [Self], utf16Offset: Int) -> Int? {
        segments.first { NSLocationInRange(max(0, utf16Offset), $0.range) }?.id ?? segments.last?.id
    }
}
