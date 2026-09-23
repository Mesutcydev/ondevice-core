import Foundation

/// Labels only. Never use these values as model identifiers or file paths.
public enum ODPresentation {
    public static func modelName(_ raw: String, compact: Bool = false) -> String {
        var name = raw
        if name.hasPrefix("local_") { name.removeFirst(6) }
        for suffix in [".gguf", ".safetensors"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        if compact {
            name = name.replacingOccurrences(of: #"\s*\((?:Q\d[^)]*|[48]-bit|GGUF)[^)]*\)"#, with: "", options: .regularExpression)
        }
        // Curated names already contain intentional punctuation and spacing.
        guard !name.contains(" ") else { return name }
        var quantization: String?
        if let range = name.range(of: "(?i)[-_](?:IQ|Q)[0-9][A-Z0-9_]*$|[-_](?:BF16|F16|F32)$", options: .regularExpression) {
            quantization = String(name[range].dropFirst())
            name.removeSubrange(range)
        }
        name = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if let quantization, !compact { return "\(name) · \(quantization)" }
        return name
    }

    /// Visible composer face. The size is shown separately only when the
    /// compact name, or the metadata’s first clause, already ends in a
    /// parameter token such as `9B` or `1.7B`. Hyphenated names (`Qwen3-4B`)
    /// and quantization clauses (`4-bit`) stay whole.
    public static func modelFace(displayName: String, metadata: String? = nil) -> (title: String, size: String?, accessibleName: String) {
        let accessible = modelName(displayName)
        let compact = modelName(displayName, compact: true)
        var parts = compact.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var size: String?
        if parts.count > 1, let last = parts.last, isParameterToken(last) {
            parts.removeLast()
            size = last
        }
        if size == nil, let clause = metadata?.components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isParameterToken(clause), clause.caseInsensitiveCompare(compact) != .orderedSame {
            size = clause
        }
        let title = parts.joined(separator: " ")
        return (title, size, accessible.isEmpty ? compact : accessible)
    }

    private static func isParameterToken(_ token: String) -> Bool {
        token.range(of: #"^\d+(?:\.\d+)?B$"#, options: .regularExpression) != nil
    }

    /// A text projection of existing content, never a generated summary.
    public static func messagePreview(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "Image: $1", options: .regularExpression)
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            text = String(attributed.characters)
        }
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|```[^\n]*)"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func conversationDate(_ date: Date, now: Date = Date(),
                                        calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return String(localized: "Today", locale: locale) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return String(localized: "Yesterday", locale: locale)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }
}
