import SwiftUI
import OnDeviceUI

/// The same block identities remain mounted while an answer streams and completes.
struct AssistantStructuredAnswer: View {
    let content: String
    var showsThinking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(StudioTextBlocks.parse(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text): AssistantProseView(content: text)
                case .code(let language, let code):
                    if language.lowercased() == "diff" { DiffView(diffText: code) }
                    else { CodeBlock(language: language, code: code) }
                case .math(let latex): MathBlock(latex: latex)
                case .thinking(let text, let open):
                    if showsThinking { ODReasoningBlock(content: text, isOpen: open) }
                }
            }
        }
    }
}

/// Completed answers keep Markdown's block structure. SwiftUI Text renders
/// inline emphasis well, but a single Text made from full Markdown joins
/// headings and table cells into run-on prose on iPhone.
private struct AssistantProseView: View {
    let content: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(content)
        let blocks = StudioMarkdownLayout.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let title):
                    Text(Self.inline(title))
                        .font(T.studio.sans(level == 1 ? 23 : level == 2 ? 20 : 18, .semibold))
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .font(T.conversationBody)
                        .foregroundStyle(T.ink)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let items):
                    AssistantProseList(items: items)
                case .quote(let text):
                    AssistantProseQuote(text: text)
                case .table(let headers, let rows):
                    AssistantProseTable(headers: headers, rows: rows)
                case .rule:
                    Rectangle().fill(T.rule).frame(height: 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)
    }
}

private struct AssistantProseList: View {
    let items: [StudioMarkdownLayout.ListItem]
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(item.marker)
                        .font(T.conversationBody.weight(.medium))
                        .foregroundStyle(T.ink2)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(AssistantProseView.inline(item.text))
                        .font(T.conversationBody)
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 16)
            }
        }
    }
}

private struct AssistantProseQuote: View {
    let text: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(AssistantProseView.inline(text))
            .font(T.conversationBody)
            .foregroundStyle(T.ink2)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(T.rule).frame(width: 2)
            }
    }
}

/// A compact row per record reads better than squeezing four columns into a
/// phone-width grid. Every value keeps its original column label.
private struct AssistantProseTable: View {
    let headers: [String]
    let rows: [[String]]
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text(headers.joined(separator: " · "))
                    .font(T.studio.sans(14))
                    .foregroundStyle(T.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(T.surface, in: RoundedRectangle(cornerRadius: StudioRadius.tile))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 8) {
                    if let first = row.first {
                        Text(headers.first ?? "Item")
                            .font(T.studio.sans(12, .medium))
                            .foregroundStyle(T.ink3)
                        Text(AssistantProseView.inline(first))
                            .font(T.studio.sans(16, .semibold))
                            .foregroundStyle(T.ink)
                    }
                    if row.count > 1 {
                        ForEach(1..<row.count, id: \.self) { column in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(column < headers.count ? headers[column] : "Column \(column + 1)")
                                    .font(T.studio.sans(12, .medium))
                                    .foregroundStyle(T.ink3)
                                    .frame(minWidth: 48, alignment: .leading)
                                Text(AssistantProseView.inline(row[column]))
                                    .font(T.studio.sans(14))
                                    .foregroundStyle(T.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(T.surface, in: RoundedRectangle(cornerRadius: StudioRadius.tile))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioRadius.tile)
                        .stroke(T.rule, lineWidth: 1)
                }
            }
        }
    }
}

