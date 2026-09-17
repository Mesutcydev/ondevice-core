import SwiftUI

// MARK: - StudioAddSheet
//
// Replaces the five-icon keyboard toolbar and the top level of the sampling
// sheet. Rows, not a grid of cards. Plain language at the top level; the raw
// sampler lives behind "Answer length & wording" → Advanced.

struct StudioAddSheet: View {

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
        let S = T.studio
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header

                    StudioHairline()

                    row(symbol: "camera", title: "Photo",
                        subtitle: "Library, or take one now", chevron: true) {
                        onPhoto()
                    }
                    row(symbol: "doc.text", title: "File",
                        subtitle: "PDF, text, code — read on device", chevron: true) {
                        onFile()
                    }
                    row(symbol: "doc.on.clipboard", title: "Paste clipboard",
                        // ponytail: `hasStrings` instead of reading the string for a
                        // live character count — reading it on every sheet open fires
                        // the system paste prompt. The read happens on tap, where the
                        // user expects it.
                        subtitle: UIPasteboard.general.hasStrings
                            ? "Text ready to paste"
                            : "Nothing copied",
                        chevron: false) {
                        onPaste()
                    }
                    row(symbol: "text.badge.plus", title: "Saved text",
                        subtitle: "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")",
                        chevron: true) {
                        onSnippets()
                    }

                    StudioMonoLabel(text: "how it answers", size: 11, tracking: 0.9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, StudioSpacing.xl)
                        .padding(.top, 14)
                        .padding(.bottom, StudioSpacing.s)

                    toggleRow(title: "Think before answering",
                              subtitle: "Slower, better on hard questions",
                              isOn: $thinkingEnabled)
                    toggleRow(title: "Allow web lookups",
                              subtitle: "Asks before every search",
                              isOn: $webLookupsAllowed)
                    StudioHairline(color: S.rule2)

                    NavigationLink {
                        StudioAnswerStyleView(
                            temperature: $temperature,
                            topP: $topP,
                            topK: $topK,
                            repetitionPenalty: $repetitionPenalty,
                            defaults: samplerDefaults
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Answer length & wording")
                                    .font(S.sans(16))
                                    .foregroundStyle(S.ink)
                                Text(StudioAnswerStyle.summary)
                                    .font(S.sans(13))
                                    .foregroundStyle(S.ink3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(S.chevron)
                        }
                        .padding(.horizontal, StudioSpacing.xl)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 30)
                }
            }
            .background(S.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.hidden)
    }

    private var header: some View {
        let S = T.studio
        return HStack(alignment: .firstTextBaseline) {
            Text("Add to this message")
                .font(S.sans(21, .semibold))
                .tracking(-0.4)
                .foregroundStyle(S.ink)
            Spacer()
            Button("Close") { dismiss() }
                .font(S.sans(14, .medium))
                .foregroundStyle(S.ink3)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.top, StudioSpacing.l)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func row(symbol: String, title: String, subtitle: String,
                     chevron: Bool, action: @escaping () -> Void) -> some View {
        let S = T.studio
        Button {
            HapticManager.impact(.light)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(S.ink)
                    .frame(width: 36, height: 36)
                    .background(S.fillActive,
                                in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                                     style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(S.sans(16)).foregroundStyle(S.ink)
                    Text(subtitle).font(S.sans(13)).foregroundStyle(S.ink3)
                }
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(S.chevron)
                }
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, StudioSpacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { StudioHairline(color: S.rule2) }
    }

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        let S = T.studio
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(S.sans(16)).foregroundStyle(S.ink)
                Text(subtitle).font(S.sans(13)).foregroundStyle(S.ink3)
            }
            Spacer()
            StudioSquareToggle(isOn: isOn)
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { StudioHairline(color: S.rule2) }
        .accessibilityElement(children: .combine)
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
        let S = T.studio
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Answer length & wording")
                    .font(S.sans(21, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(S.ink)
                    .padding(.horizontal, StudioSpacing.xl)
                    .padding(.top, StudioSpacing.l)
                    .padding(.bottom, 14)

                StudioMonoLabel(text: "how long", size: 11, tracking: 0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, StudioSpacing.xl)
                    .padding(.bottom, StudioSpacing.s)
                StudioHairline(color: S.rule2)
                ForEach(StudioAnswerStyle.lengths, id: \.label) { option in
                    choiceRow(title: option.label,
                              subtitle: subtitle(forLength: option.label),
                              selected: StudioAnswerStyle.lengthLabel == option.label) {
                        settings.assistantMaxTokens = option.tokens
                    }
                }

                StudioMonoLabel(text: "how it words things", size: 11, tracking: 0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, StudioSpacing.xl)
                    .padding(.top, 18)
                    .padding(.bottom, StudioSpacing.s)
                StudioHairline(color: S.rule2)
                ForEach(StudioAnswerStyle.wordings, id: \.label) { option in
                    choiceRow(title: option.label,
                              subtitle: subtitle(forWording: option.label),
                              selected: StudioAnswerStyle.wordingLabel == option.label) {
                        settings.assistantTemperature = option.temperature
                    }
                }

                advanced
                    .padding(.top, 22)

                Spacer(minLength: 30)
            }
        }
        .background(S.paper)
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private func choiceRow(title: String, subtitle: String,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        let S = T.studio
        Button {
            HapticManager.selection()
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(S.sans(16)).foregroundStyle(S.ink)
                    Text(subtitle).font(S.sans(13)).foregroundStyle(S.ink3)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(S.accent)
                }
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { StudioHairline(color: S.rule2) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The old sampling sheet, folded into a disclosure. These values apply
    /// to the next message only.
    private var advanced: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { advancedExpanded.toggle() }
            } label: {
                HStack {
                    Text("Advanced").font(S.sans(16)).foregroundStyle(S.ink)
                    Spacer()
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13))
                        .foregroundStyle(S.chevron)
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { StudioHairline(color: S.rule2) }

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 18) {
                    slider("Temperature", value: $temperature,
                           fallback: defaults.temperature, range: 0...1.5, step: 0.05)
                    slider("Top-p", value: $topP,
                           fallback: defaults.topP, range: 0.5...1, step: 0.01)
                    VStack(alignment: .leading, spacing: 6) {
                        labelRow("Top-k", value: "\(topK ?? defaults.topK)")
                        Slider(value: Binding(get: { Double(topK ?? defaults.topK) },
                                              set: { topK = Int($0.rounded()) }),
                               in: 1...100, step: 1)
                            .tint(S.accent)
                    }
                    slider("Repetition penalty", value: $repetitionPenalty,
                           fallback: defaults.repetitionPenalty, range: 1...1.3, step: 0.01)

                    Text("These values apply only to the next message. Untouched controls use the model's saved profile.")
                        .font(S.sans(13))
                        .foregroundStyle(S.ink3)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset to model defaults") {
                        temperature = nil; topP = nil; topK = nil; repetitionPenalty = nil
                        HapticManager.selection()
                    }
                    .font(S.sans(14, .medium))
                    .foregroundStyle(S.danger)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.bottom, 18)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double?>,
                        fallback: Double, range: ClosedRange<Double>,
                        step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labelRow(title, value: String(format: "%.2f", value.wrappedValue ?? fallback))
            Slider(value: Binding(get: { value.wrappedValue ?? fallback },
                                  set: { value.wrappedValue = $0 }),
                   in: range, step: step)
                .tint(T.studio.accent)
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
