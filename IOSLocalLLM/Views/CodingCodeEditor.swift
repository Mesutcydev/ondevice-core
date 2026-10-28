import SwiftUI
import UIKit
import OnDeviceUI

/// Native text editing, selection and undo; the workspace owns durable content and position.
struct CodingCodeEditor: UIViewRepresentable {
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 14
    let file: CodingWorkspaceFile
    let onEdit: (String) -> Void
    let onSelection: (NSRange, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CodingEditorSurface {
        let surface = CodingEditorSurface()
        surface.editor.delegate = context.coordinator
        context.coordinator.surface = surface
        let toolbar = UIToolbar(); toolbar.sizeToFit(); toolbar.tintColor = .label
        let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain,
                                   target: context.coordinator, action: #selector(Coordinator.hideKeyboard))
        hide.accessibilityLabel = String(localized: "Hide keyboard")
        let undo = UIBarButtonItem(barButtonSystemItem: .undo, target: context.coordinator, action: #selector(Coordinator.undo))
        let redo = UIBarButtonItem(barButtonSystemItem: .redo, target: context.coordinator, action: #selector(Coordinator.redo))
        let indent = UIBarButtonItem(title: String(localized: "Indent"), style: .plain,
                                     target: context.coordinator, action: #selector(Coordinator.indent))
        toolbar.items = [hide, undo, redo, .flexibleSpace(), indent]
        surface.editor.inputAccessoryView = toolbar
        surface.editor.accessibilityIdentifier = "coding.editor"
        return surface
    }
    func updateUIView(_ surface: CodingEditorSurface, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self; coordinator.updating = true
        surface.backgroundColor = UIColor(ODPalette.background)
        surface.editor.backgroundColor = UIColor(ODPalette.background)
        surface.editor.textColor = UIColor(ODPalette.text)
        surface.editor.tintColor = UIColor(ODPalette.text)
        surface.gutter.backgroundColor = UIColor(ODPalette.background)
        if surface.editor.font?.pointSize != fontSize {
            surface.editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.highlight(); surface.setNeedsLayout()
        }
        surface.editor.accessibilityLabel = file.path
        if surface.editor.text != file.text {
            surface.editor.text = file.text
            coordinator.highlight()
        }
        if surface.editor.selectedRange != file.selection {
            surface.editor.selectedRange = file.selection
            surface.editor.scrollRangeToVisible(file.selection)
        }
        if !coordinator.restoredPosition {
            coordinator.restoredPosition = true
            let lines = file.text.components(separatedBy: "\n")
            let location = lines.prefix(max(0, min(file.firstVisibleLine - 1, lines.count - 1)))
                .reduce(0) { $0 + ($1 as NSString).length + 1 }
            surface.editor.scrollRangeToVisible(NSRange(location: min(location, (file.text as NSString).length), length: 0))
        }
        surface.gutter.setNeedsDisplay(); coordinator.updating = false
    }
    static func dismantleUIView(_ uiView: CodingEditorSurface, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel(); uiView.editor.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var owner: CodingCodeEditor
        weak var surface: CodingEditorSurface?
        var updating = false
        var restoredPosition = false
        var highlightTask: Task<Void, Never>?
        init(_ owner: CodingCodeEditor) { self.owner = owner }
        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            owner.onEdit(textView.text)
            reportSelection(textView); highlight(); surface?.gutter.setNeedsDisplay()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }; reportSelection(textView)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            surface?.gutter.setNeedsDisplay()
            if let text = surface?.editor, !updating { reportSelection(text) }
        }
        private func reportSelection(_ textView: UITextView) {
            guard textView.layoutManager.numberOfGlyphs > 0 else {
                owner.onSelection(textView.selectedRange, 1); return
            }
            let point = CGPoint(x: textView.textContainerInset.left, y: max(0, textView.contentOffset.y) + textView.textContainerInset.top)
            let glyph = textView.layoutManager.glyphIndex(for: point, in: textView.textContainer)
            let boundedGlyph = min(glyph, textView.layoutManager.numberOfGlyphs - 1)
            let character = min(textView.layoutManager.characterIndexForGlyph(at: boundedGlyph), (textView.text as NSString).length)
            let line = (textView.text as NSString).substring(to: character).filter { $0 == "\n" }.count + 1
            owner.onSelection(textView.selectedRange, line)
        }
        func highlight() {
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let textView = surface?.editor,
                      textView.markedTextRange == nil else { return }
                let text = textView.text ?? "", length = (text as NSString).length
                guard length <= 80_000 else { return }
                let font = UIFont.monospacedSystemFont(ofSize: owner.fontSize, weight: .regular)
                updating = true
                textView.textStorage.beginEditing()
                textView.textStorage.setAttributes([.font: font, .foregroundColor: UIColor(ODPalette.text)], range: NSRange(location: 0, length: length))
                let patterns: [(String, UIColor)] = [
                    (#"\b(func|let|var|class|struct|enum|protocol|import|return|if|else|guard|for|while|switch|case|async|await|throw|try|def|from|function|const|export|interface|type|public|private|static|true|false|nil|null|None)\b"#, .systemIndigo),
                    (#"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#, .systemBrown),
                    (#"//[^\n]*|/\*[\s\S]*?\*/"#, .secondaryLabel)
                ]
                let plainText = ["md", "markdown", "txt", "log", "csv", ""].contains(owner.file.language)
                for (pattern, color) in plainText ? [] : patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
                        textView.textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
                textView.textStorage.endEditing()
                textView.typingAttributes = [.font: font, .foregroundColor: UIColor(ODPalette.text)]
                updating = false
            }
        }
        @objc func hideKeyboard() { surface?.editor.resignFirstResponder() }
        @objc func undo() { surface?.editor.undoManager?.undo() }
        @objc func redo() { surface?.editor.undoManager?.redo() }
        @objc func indent() { surface?.editor.insertText("    ") }
    }
}

final class CodingEditorSurface: UIView {
    let editor = UITextView(usingTextLayoutManager: false)
    let gutter = CodingLineNumbers()
    override init(frame: CGRect) {
        super.init(frame: frame)
        editor.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        editor.adjustsFontForContentSizeCategory = true
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none
        editor.smartQuotesType = .no; editor.smartDashesType = .no; editor.smartInsertDeleteType = .no
        editor.keyboardDismissMode = .interactive
        editor.alwaysBounceVertical = true
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 4, bottom: 16, right: 16)
        editor.semanticContentAttribute = .forceLeftToRight
        gutter.editor = editor; gutter.isAccessibilityElement = false
        addSubview(gutter); addSubview(editor)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(48, min(144, (editor.font?.pointSize ?? 14) * 3.2))
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        editor.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

final class CodingLineNumbers: UIView {
    weak var editor: UITextView?
    override func draw(_ rect: CGRect) {
        guard let editor, editor.layoutManager.numberOfGlyphs > 0 else { return }
        let layout = editor.layoutManager
        let visible = CGRect(origin: editor.contentOffset, size: editor.bounds.size)
        let range = layout.glyphRange(forBoundingRect: visible, in: editor.textContainer)
        let text = editor.text as NSString
        let font = UIFont.monospacedDigitSystemFont(ofSize: max(12, (editor.font?.pointSize ?? 14) * 0.8), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        layout.enumerateLineFragments(forGlyphRange: range) { _, used, _, glyphs, _ in
            let character = min(layout.characterIndexForGlyph(at: glyphs.location), text.length)
            guard character == 0 || text.substring(with: NSRange(location: character - 1, length: 1)) == "\n" else { return }
            let number = String(text.substring(to: character).filter { $0 == "\n" }.count + 1) as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: CGPoint(x: rect.width - size.width - 8,
                                    y: used.minY + editor.textContainerInset.top - editor.contentOffset.y), withAttributes: attributes)
        }
    }
}
