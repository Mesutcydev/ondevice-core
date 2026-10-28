import SwiftUI

/// Exercises production formatting with deterministic chunks; no inference or network.
struct ResponseRenderingReview: View {
    @State private var phase = 0
    private var answer: String {
        if phase == 0 { return "```html" }
        let source = (1...35).map { "<p>Line \($0): İstanbul & 東京</p>" }.joined(separator: "\n")
        if phase == 1 { return "```html\n" + source }
        let controls = "<button id=\"counter\">Generate: 0</button><script>let count = 0; document.getElementById('counter').onclick = () => { document.getElementById('counter').textContent = 'Generate: ' + ++count; }; window.addEventListener('securitypolicyviolation', event => console.warn('Blocked by policy: ' + event.violatedDirective)); fetch('https://example.invalid/chat-preview-test').catch(() => {});</script>"
        return "```html\n" + controls + "\n" + source + "\n```\n\n## Result\n\n- First item\n- Second item\n\n| Name | Value |\n| --- | --- |\n| Token | Ready |\n\n```diff\n-old\n+new\n```\n\n$$x^2 + y^2$$"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                AssistantStructuredAnswer(content: answer, showsThinking: true, allowsHTMLPreview: phase == 2).padding(16)
            }
            .navigationTitle("Response preview")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Next chunk") { phase = min(phase + 1, 2) }
                        .accessibilityIdentifier("review.nextChunk")
                }
            }
        }
    }
}
