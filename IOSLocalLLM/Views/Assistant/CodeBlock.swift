import SwiftUI
import UniformTypeIdentifiers

/// A bounded preview and an expanded reader use exactly the same source and controls.
struct CodeBlock: View {
    let language: String
    let code: String
    var expanded = false
    var displayMath = false
    @Environment(\.koduTheme) private var T
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingReader = false
    @State private var exporting = false
    @State private var exportDocument = AssistantSourceDocument(text: "")
    @State private var exportName = "code.txt"
    @State private var exportType: UTType = .plainText
    @State private var exportFailed = false
    @State private var copied = false
    @State private var copyRevision = 0

    private var lines: [String] { code.components(separatedBy: "\n") }
    private var previewLineLimit: Int { typeSize.isAccessibilitySize ? 8 : 24 }
    private var needsExpansion: Bool { lines.count > previewLineLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Label(language.isEmpty ? "code" : language.lowercased(), systemImage: displayMath ? "function" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(T.studio.codeInk.opacity(0.8))
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    copyRevision += 1
                    if !displayMath { LegalAcceptanceManager.shared.markCodeCopiedAndWarnIfNeeded() }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(copied ? "Copied" : "Copy code"))
                .accessibilityIdentifier("response.code.copy")
                Button {
                    // Freeze the exact current source. Generation can continue while Files is open.
                    exportDocument = AssistantSourceDocument(text: code)
                    exportName = AssistantSourceFile.filename(language: language)
                    exportType = UTType(filenameExtension: AssistantSourceFile.fileExtension(language: language)) ?? .plainText
                    exporting = true
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Save to Files")
                .accessibilityIdentifier("response.code.save")
            }
            .buttonStyle(.plain)
            .foregroundStyle(T.studio.codeInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Rectangle().fill(T.studio.codeInk.opacity(0.15)).frame(height: 1)
            if displayMath {
                Text(code)
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(T.studio.codeInk)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    SourceLines(lines: expanded ? lines : Array(lines.prefix(previewLineLimit)), language: language)
                        .padding(16)
                }
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("response.code.content")
                SourceFooter(allowsExpansion: !expanded, needsExpansion: needsExpansion) {
                    showingReader = true
                }
                .foregroundStyle(T.studio.codeInk)
                .padding(.horizontal, 12)
            }
        }
        .background(T.studio.codeBg, in: RoundedRectangle(cornerRadius: StudioRadius.panel))
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel))
        .task(id: copyRevision) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)); copied = false } catch {}
        }
        .sheet(isPresented: $showingReader) {
            SourceReader(language: language, code: code)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure = result { exportFailed = true }
        }
        .alert("Couldn’t save file", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Please try saving again or choose another location.") }
    }
}

private struct SourceFooter: View {
    let allowsExpansion: Bool
    let needsExpansion: Bool
    let expand: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Label("Scroll sideways for long lines", systemImage: "arrow.left.and.right")
                .font(.caption2)
                .opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if allowsExpansion {
                Button(action: expand) {
                    Label(LocalizedStringKey(needsExpansion ? "Show all code" : "Expand code"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("response.code.expand")
            }
        }
        .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
    }
}

private struct SourceReader: View {
    let language: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                CodeBlock(language: language, code: code, expanded: true).padding(12)
            }
            .navigationTitle("Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SourceLines: View {
    let lines: [String]
    let language: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    let number = String(index + 1)
                    Text(String(repeating: " ", count: max(0, String(lines.count).count - number.count)) + number)
                        .foregroundStyle(.white.opacity(0.4))
                        .textSelection(.disabled)
                        .accessibilityHidden(true)
                    SourceLine(text: line, language: language)
                        .equatable()
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Highlight only visible lines; unchanged lines do not re-run highlighting on each token.
private struct SourceLine: View, Equatable {
    let text: String
    let language: String
    var body: some View { Text(highlighted) }
    private var highlighted: AttributedString {
        var result = AttributedString(text.isEmpty ? " " : text)
        result.foregroundColor = Color(red: 0.91, green: 0.91, blue: 0.93)
        if language.lowercased() == "diff" {
            if text.hasPrefix("+") { result.foregroundColor = .green }
            else if text.hasPrefix("-") { result.foregroundColor = Color(red: 1, green: 0.55, blue: 0.55) }
            else if text.hasPrefix("@@") { result.foregroundColor = .cyan }
            return result
        }
        // Restrained lexical hints, never rewriting source or executing generated content.
        let patterns: [(String, Color)] = [
            (#"\b(?:func|let|var|if|else|return|class|struct|import|const|function|def|for|while|public|private|true|false|null|nil|async|await)\b"#, Color(red: 0.79, green: 0.64, blue: 0.96)),
            (#"\b\d+(?:\.\d+)?\b"#, Color(red: 0.95, green: 0.76, blue: 0.52)),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, Color(red: 0.56, green: 0.75, blue: 0.66))
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      let start = AttributedString.Index(range.lowerBound, within: result),
                      let end = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[start..<end].foregroundColor = color
            }
        }
        return result
    }
}

struct MathBlock: View {
    let latex: String
    var body: some View { CodeBlock(language: "latex", code: latex, displayMath: true) }
}

struct AssistantSourceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = source
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
