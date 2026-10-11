import SwiftUI

/// Reporting is user initiated. Opening support attaches no conversation,
/// prompt, generated media, identifiers, or diagnostics.
struct ContentConcernView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Report a content concern") {
                    Text("Use the support website to report unsafe or inappropriate AI output. Include the model name and a brief description of the issue. Avoid posting private prompts, images, credentials, or personal information in public issues.")
                    Text("Nothing from your conversation or generated image is attached automatically. You choose what to share on the support website.")
                    if let url = URL(string: LegalDocuments.supportURL) {
                        Link("Open support website", destination: url)
                            .accessibilityIdentifier("content.report.support")
                    }
                }
                Section("AI safeguards") {
                    Text("Chat models receive safety instructions. Image requests are checked for some explicit-content phrases, and models that support negative prompts receive additional exclusions. These precautions cannot reliably detect every unsafe request or generated image. If output concerns you, stop generation, delete the content, and report the issue.")
                }
            }
            .navigationTitle("Content concern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
