import Foundation

/// Model-supplied language labels never become paths or executable actions.
enum AssistantSourceFile {
    static func fileExtension(language: String) -> String {
        let name = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extensions = ["swift": "swift", "python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts", "jsx": "jsx", "tsx": "tsx", "html": "html", "css": "css", "json": "json", "xml": "xml", "yaml": "yaml", "yml": "yml", "markdown": "md", "md": "md", "bash": "sh", "shell": "sh", "sh": "sh", "zsh": "sh", "sql": "sql", "c": "c", "cpp": "cpp", "c++": "cpp", "java": "java", "kotlin": "kt", "rust": "rs", "go": "go", "ruby": "rb", "php": "php", "diff": "patch", "latex": "tex", "tex": "tex"]
        return extensions[name] ?? "txt"
    }
    static func filename(language: String) -> String { "code." + fileExtension(language: language) }
}
