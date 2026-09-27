import SwiftUI

enum QuickActionKind: String, CaseIterable, Identifiable {
    case continueReply, shorter, moreFormal, explain
    var id: String { rawValue }

    var label: String {
        switch self {
        case .continueReply: return "Continue"
        case .shorter: return "Shorter"
        case .moreFormal: return "More formal"
        case .explain: return "Explain"
        }
    }

    var systemImage: String {
        switch self {
        case .continueReply: return "arrow.right.to.line"
        case .shorter: return "text.redaction"
        case .moreFormal: return "graduationcap"
        case .explain: return "lightbulb"
        }
    }

    /// Menu subtitle: says what the follow-up will do before it is sent.
    var detail: String {
        switch self {
        case .continueReply: return "Pick up where it stopped"
        case .shorter: return "Trim to the essentials"
        case .moreFormal: return "Rewrite in a formal tone"
        case .explain: return "Break it down simply"
        }
    }
}

/// Quiet response actions. Technical provenance stays available in Details.
struct StudioAnswerActionRow: View {
    var provenance: String?
    var footnote: String?
    var canRegenerate: Bool = true
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    var onQuickAction: ((QuickActionKind) -> Void)? = nil
    @State private var showsDetails = false
    @State private var copied = false
    @State private var regenerations = 0

    var body: some View {
        // The three everyday actions sit in the row; the menu holds follow-ups
        // and the rarer commands, grouped so it reads as a designed surface.
        HStack(spacing: 0) {
            Button {
                onCopy()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
            rowButton("Read aloud", symbol: "speaker.wave.2", action: onSpeak)
            Button {
                regenerations += 1
                onRegenerate()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, value: regenerations)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Regenerate")
            .disabled(!canRegenerate)
            Menu {
                if let onQuickAction {
                    Section("Follow up") {
                        ForEach(QuickActionKind.allCases) { kind in
                            Button { onQuickAction(kind) } label: {
                                Label(kind.label, systemImage: kind.systemImage)
                                Text(kind.detail)
                            }
                        }
                    }
                }
                Section {
                    Button("Share response", systemImage: "square.and.arrow.up", action: onShare)
                    Button("Response details", systemImage: "info.circle") { showsDetails = true }
                }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .menuOrder(.fixed)
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

    private func rowButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

/// A measured, quiet generation-rate label shared by completed assistant
/// messages and the native presentation review host. Missing or invalid rates
/// stay hidden; the view never estimates throughput from elapsed time.
struct StudioGenerationRate: View {
    let tokensPerSecond: Double

    var body: some View {
        if tokensPerSecond.isFinite && tokensPerSecond > 0 {
            HStack(spacing: 4) {
                Image(systemName: "speedometer").accessibilityHidden(true)
                Text(tokensPerSecond, format: .number.precision(.fractionLength(0)))
                Text("tok/s")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                "Generation speed: \(tokensPerSecond, format: .number.precision(.fractionLength(1))) tokens per second",
                comment: "Measured generation speed shown below an assistant response."
            ))
            .accessibilityIdentifier("chat.response.tokensPerSecond")
        }
    }
}
