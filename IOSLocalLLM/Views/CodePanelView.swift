import SwiftUI

// MARK: - CodePanelView

struct CodePanelView: View {
    @Binding var code: String
    let language: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CodeBlock(language: language, code: code, expanded: true)
                    .padding()
            }
            .navigationTitle("\(language) Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
