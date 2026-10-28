import SwiftUI
import OnDeviceUI

struct CodingFileDiffView: View {
    let before: String
    let after: String
    @State private var version = 0
    @State private var lines: [CodingDiffLine] = []
    @State private var comparing = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("File version", selection: $version) {
                Text("Diff").tag(0); Text("Before").tag(1); Text("After").tag(2)
            }.pickerStyle(.segmented).padding(ODLayout.pageInset)
            if version == 0 {
                if comparing { ProgressView("Comparing changes…").frame(maxHeight: .infinity) }
                else if lines.isEmpty {
                    ContentUnavailableView("Use Before and After to review this file", systemImage: "doc.text.magnifyingglass",
                                           description: Text("This file exceeds the inline diff limit. Its complete content is available in both tabs."))
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(line.oldLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                                    Text(line.newLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 12)
                                    Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }.font(.caption.monospaced()).padding(.vertical, 3).padding(.horizontal, 8)
                                    .foregroundStyle(line.kind == .context ? ODPalette.secondary : ODPalette.text)
                                    .background(line.kind == .added ? ODPalette.accentSoft : line.kind == .removed ? ODPalette.red.opacity(0.10) : .clear)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Unchanged"), line \(line.newLine ?? line.oldLine ?? 1): \(line.text)")
                            }
                        }
                    }.accessibilityIdentifier("github.review.diff")
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text((version == 1 ? before : after).isEmpty ? String(localized: "[Empty file]") : (version == 1 ? before : after))
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(ODLayout.pageInset)
                        .accessibilityIdentifier("github.review.content")
                }
            }
        }.background(ODPalette.background).foregroundStyle(ODPalette.text)
            .task(id: Input(before: before, after: after)) {
                comparing = true
                let original = before, updated = after
                let result = await Task.detached(priority: .userInitiated) { CodingDiffLine.compare(before: original, after: updated) }.value
                guard !Task.isCancelled else { return }
                lines = result; comparing = false
            }
    }
    private struct Input: Hashable { let before: String; let after: String }
}
