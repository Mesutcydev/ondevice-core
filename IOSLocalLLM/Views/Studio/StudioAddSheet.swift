import SwiftUI
import OnDeviceUI

// MARK: - StudioAddSheet
//
// Replaces the five-icon keyboard toolbar and the top level of the sampling
// sheet. Rows, not a grid of cards. Plain language at the top level; the raw
// sampler lives behind "Answer length & wording" → Advanced.

struct StudioAddSheet: View {

    @Binding var draft: String
    @Binding var thinkingEnabled: Bool
    @Binding var webLookupsAllowed: Bool

    // Per-send sampler overrides, handed straight through to Advanced.
    @Binding var temperature: Double?
    @Binding var topP: Double?
    @Binding var topK: Int?
    @Binding var repetitionPenalty: Double?
    let samplerDefaults: AssistantModelGenerationSettings

    let snippetCount: Int

    let onPhoto: () -> Void
    let onFile: () -> Void
    let onPaste: () -> Void
    let onSnippets: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            List {
                Section("Add to this message") {
                    NavigationLink {
                        DictationDraftView(text: $draft)
                    } label: {
                        Label("Dictate text", systemImage: "mic")
                    }
                    .accessibilityIdentifier("chat.tools.dictate")
                    action("Photo", symbol: "photo", detail: "Choose from your library", run: onPhoto)
                    action("File", symbol: "doc", detail: "PDF, text, or code", run: onFile)
                    action("Paste clipboard", symbol: "doc.on.clipboard", detail: UIPasteboard.general.hasStrings ? "Text ready to paste" : "Nothing copied", run: onPaste)
                        .disabled(!UIPasteboard.general.hasStrings)
                    action("Saved text", symbol: "text.badge.plus", detail: "\(snippetCount) saved snippets", run: onSnippets)
                }
                Section("Response") {
                    Toggle("Think before answering", isOn: $thinkingEnabled)
                    Toggle("Allow web lookups", isOn: $webLookupsAllowed)
                    NavigationLink {
                        StudioAnswerStyleView(temperature: $temperature, topP: $topP, topK: $topK,
                            repetitionPenalty: $repetitionPenalty, defaults: samplerDefaults)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Answer length & wording")
                            Text(StudioAnswerStyle.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Message options").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func action(_ title: String, symbol: String, detail: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(ODPalette.text)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
            .padding(.vertical, 4)
        }
    }
}

/// Dictation edits the existing draft and ends when this screen is dismissed.
private struct DictationDraftView: View {
    @Binding var text: String
    var body: some View {
        Form {
            Section {
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...8)
            } footer: {
                Text("Dictation adds words to your draft. Review them before sending.")
            }
            Section {
                MicDictationButton(text: $text, showsTitle: true)
            }
        }
        .navigationTitle("Dictate text")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Answer length & wording

/// Plain language on top, the raw sampler behind an Advanced disclosure —
/// the old SamplingSettingsSheet's controls, re-housed.
enum StudioAnswerStyle {
    static let lengths: [(label: String, tokens: Int)] = [
        ("Brief", 512), ("Medium", 2_048), ("Detailed", 4_096)
    ]
    static let wordings: [(label: String, temperature: Double)] = [
        ("Precise", 0.3), ("Balanced", 0.6), ("Playful", 0.9)
    ]

    static var lengthLabel: String {
        let value = AppSettings.shared.assistantMaxTokens
        return lengths.min { abs($0.tokens - value) < abs($1.tokens - value) }?.label ?? "Medium"
    }

    static var wordingLabel: String {
        let value = AppSettings.shared.assistantTemperature
        return wordings.min { abs($0.temperature - value) < abs($1.temperature - value) }?.label
            ?? "Balanced"
    }

    static var summary: String { "\(lengthLabel) · \(wordingLabel.lowercased())" }
}

struct StudioAnswerStyleView: View {
    @Binding var temperature: Double?
    @Binding var topP: Double?
    @Binding var topK: Int?
    @Binding var repetitionPenalty: Double?
    let defaults: AssistantModelGenerationSettings

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.koduTheme) private var T
    @State private var advancedExpanded = false

    var body: some View {
        Form {
            Section("Length") {
                ForEach(StudioAnswerStyle.lengths, id: \.label) { option in
                    choiceRow(title: option.label, subtitle: subtitle(forLength: option.label),
                              selected: StudioAnswerStyle.lengthLabel == option.label) {
                        settings.assistantMaxTokens = option.tokens
                    }
                }
            }
            Section("Wording") {
                ForEach(StudioAnswerStyle.wordings, id: \.label) { option in
                    choiceRow(title: option.label, subtitle: subtitle(forWording: option.label),
                              selected: StudioAnswerStyle.wordingLabel == option.label) {
                        settings.assistantTemperature = option.temperature
                    }
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    slider("Temperature", value: $temperature, fallback: defaults.temperature, range: 0...1.5, step: 0.05)
                    slider("Top-p", value: $topP, fallback: defaults.topP, range: 0.5...1, step: 0.01)
                    VStack(alignment: .leading, spacing: 8) {
                        labelRow("Top-k", value: "\(topK ?? defaults.topK)")
                        Slider(value: Binding(get: { Double(topK ?? defaults.topK) }, set: { topK = Int($0.rounded()) }), in: 1...100, step: 1)
                            .accessibilityLabel("Top-k")
                    }
                    slider("Repetition penalty", value: $repetitionPenalty, fallback: defaults.repetitionPenalty, range: 1...1.3, step: 0.01)
                    Button("Reset to model defaults") {
                        temperature = nil; topP = nil; topK = nil; repetitionPenalty = nil
                    }
                }
            } footer: { Text("Advanced values apply only to the next message. Untouched controls use the model’s saved profile.") }
        }
        .scrollContentBackground(.hidden).background { ODPageBackground().ignoresSafeArea() }
        .navigationTitle("Answer style").navigationBarTitleDisplayMode(.inline)
    }

    private func subtitle(forLength label: String) -> String {
        switch label {
        case "Brief": return "A few sentences"
        case "Detailed": return "Long answers, slower to finish"
        default: return "Default"
        }
    }

    private func subtitle(forWording label: String) -> String {
        switch label {
        case "Precise": return "Sticks to the safest phrasing"
        case "Playful": return "More variety, more risk"
        default: return "Default"
        }
    }

    private func choiceRow(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(ODPalette.text)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(ODPalette.text) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func slider(_ title: String, value: Binding<Double?>,
                        fallback: Double, range: ClosedRange<Double>,
                        step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labelRow(title, value: String(format: "%.2f", value.wrappedValue ?? fallback))
            Slider(value: Binding(get: { value.wrappedValue ?? fallback },
                                  set: { value.wrappedValue = $0 }),
                   in: range, step: step)
                .accessibilityLabel(title)
        }
    }

    private func labelRow(_ title: String, value: String) -> some View {
        let S = T.studio
        return HStack {
            Text(title).font(S.sans(14)).foregroundStyle(S.ink)
            Spacer()
            StudioMonoLabel(text: value, size: 11, tracking: 0.4)
        }
    }
}
