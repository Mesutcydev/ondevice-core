import Foundation

/// A conservative local check, not a complete secret detector. It reports
/// locations and kinds only; values never enter tool results or diagnostics.
nonisolated enum RepositorySecretScanner {
    struct Finding: Equatable, Sendable {
        let line: Int
        let kind: String
    }
    struct Scan: Sendable {
        let findings: [Finding]
        let redacted: String
    }

    static func scan(_ text: String) -> Scan {
        let source = text as NSString
        var replacements: [(NSRange, String, String)] = []
        var known: [String: String] = [:]
        func add(_ range: NSRange, replacement: String, kind: String, remember: Bool = false) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            let value = source.substring(with: range)
            guard !placeholder(value) else { return }
            let lineBreaks = value.filter { $0 == "\n" }.count
            replacements.append((range, replacement + String(repeating: "\n", count: lineBreaks), kind))
            if remember, value.count >= 4 { known[value] = replacement }
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        }
        // Xtream/M3U links: a username is sensitive when paired with a password.
        for url in matches(#"https?://[^\s\"'`<>]+"#) {
            let value = source.substring(with: url.range)
            guard let query = try? NSRegularExpression(pattern: #"(?i)[?&](username|password)=([^&\s]+)"#) else { continue }
            let fields = query.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
            let names = Set(fields.map { (value as NSString).substring(with: $0.range(at: 1)).lowercased() })
            if names.contains("username"), names.contains("password") {
                for field in fields {
                    let name = (value as NSString).substring(with: field.range(at: 1)).lowercased()
                    let part = field.range(at: 2)
                    add(NSRange(location: url.range.location + part.location, length: part.length),
                        replacement: name == "username" ? "YOUR_USER" : "YOUR_PASS", kind: "Playlist credential", remember: true)
                }
            }
        }
        for match in matches(#"(?i)/(?:live|movie|series)/([^/\s\"'`?]+)/([^/\s\"'`?]+)/[0-9]+(?:\.[a-z0-9]+)?"#) {
            add(match.range(at: 1), replacement: "YOUR_USER", kind: "Stream credential", remember: true)
            add(match.range(at: 2), replacement: "YOUR_PASS", kind: "Stream credential", remember: true)
        }
        for match in matches(#"(?i)https?://([^:/\s]+):([^@/\s]+)@"#) {
            add(match.range(at: 1), replacement: "YOUR_USER", kind: "URL credential", remember: true)
            add(match.range(at: 2), replacement: "YOUR_PASS", kind: "URL credential", remember: true)
        }
        for match in matches(#"\b(?:gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255}|sk-(?:proj-)?[A-Za-z0-9_-]{20,255}|AKIA[A-Z0-9]{16})\b"#) {
            add(match.range, replacement: "YOUR_TOKEN", kind: "Access key", remember: true)
        }
        for match in matches(#"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#) {
            add(match.range, replacement: "[PRIVATE KEY REMOVED]", kind: "Private key")
        }
        for match in matches(#"(?im)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|client[_-]?secret)\s*[:=]\s*[\"']([^\"'\r\n]{4,512})[\"']"#) {
            add(match.range(at: 1), replacement: "YOUR_SECRET", kind: "Credential assignment", remember: true)
        }
        // Repeated copies in prose/examples are removed without asking the
        // model to repeat the original credential in replace_text arguments.
        for (value, replacement) in known {
            var range = NSRange(location: 0, length: source.length)
            while range.length > 0 {
                let found = source.range(of: value, range: range)
                guard found.location != NSNotFound else { break }
                replacements.append((found, replacement, "Repeated credential"))
                let next = found.location + found.length
                range = NSRange(location: next, length: source.length - next)
            }
        }
        // Prefer the outer range (private keys) over overlapping detections.
        var selected: [(NSRange, String, String)] = []
        for item in replacements.sorted(by: { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }) {
            if let last = selected.last, NSMaxRange(last.0) > item.0.location { continue }
            selected.append(item)
        }
        let findings = selected.map { item in
            Finding(line: source.substring(to: item.0.location).filter { $0 == "\n" }.count + 1, kind: item.2)
        }
        let output = NSMutableString(string: text)
        for item in selected.reversed() { output.replaceCharacters(in: item.0, with: item.1) }
        return Scan(findings: findings, redacted: String(output))
    }

    private static func placeholder(_ value: String) -> Bool {
        let upper = value.uppercased()
        return value.isEmpty || upper.contains("YOUR_") || upper.contains("REDACTED")
            || upper.contains("EXAMPLE") || upper.contains("PLACEHOLDER") || upper.contains("CHANGEME")
            || upper.contains("REMOVED") || value.contains("${") || value.contains("{{")
            || value.hasPrefix("<") || value.hasPrefix("process.env.")
    }
}
