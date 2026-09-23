import SwiftUI

/// Quiet response actions. Technical provenance stays available in Details.
struct StudioAnswerActionRow: View {
    var provenance: String?
    var footnote: String?
    var canRegenerate: Bool = true
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Copy")
            Menu {
                Button("Share response", systemImage: "square.and.arrow.up", action: onShare)
                Button("Read aloud", systemImage: "speaker.wave.2", action: onSpeak)
                Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                    .disabled(!canRegenerate)
                Button("Response details", systemImage: "info.circle") { showsDetails = true }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More response actions")
            Spacer(minLength: 0)
        }
        .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
        .sheet(isPresented: $showsDetails) {
            NavigationStack {
                Form {
                    if let footnote { Section("Model and generation") { Text(footnote).textSelection(.enabled) } }
                    if let provenance { Section("Sources") { Text(provenance) } }
                }
                .navigationTitle("Response details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsDetails = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
