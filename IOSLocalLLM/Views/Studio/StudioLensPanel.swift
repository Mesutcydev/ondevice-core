import SwiftUI

// MARK: - StudioLensPanel
//
// The Lens half of the composer/chat rethink: the mode bar is TYPE, not
// coloured tabs — the per-mode blue/purple/green/orange accents are dropped
// from it — and one panel climbs through its states in place instead of six
// separate cards. Functions preserved from LensTaskPanel + LiveOCROverlayView.

enum LensPanelState: Equatable {
    case collapsed
    case composing
    case captured
    case analyzing
    case result
    case error
}

/// Type mode bar — white on the camera. Selected reads weight 600 with an
/// 18×2 underline; unselected is white at 55%. No fills, no accents.
struct StudioLensModeBar: View {
    @Binding var selection: LensMode
    let onSelection: (LensMode) -> Void

    // Colours stay white here — this sits over a live camera feed, not over
    // the themed page — but the FONT still comes from the theme so the labels
    // follow Dynamic Type.
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 22) {
            ForEach(LensMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = mode }
                    onSelection(mode)
                } label: {
                    VStack(spacing: 6) {
                        Text(mode.label)
                            .font(T.sans(15, selection == mode ? .semibold : .regular))
                            .foregroundStyle(selection == mode ? .white : .white.opacity(0.55))
                        Rectangle()
                            .fill(selection == mode ? Color.white : .clear)
                            .frame(width: 18, height: 2)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One panel that climbs through idle → composing → analyzing → result →
/// error in place. Flush paper surface, 22pt top corners, padding 16/20/30.
struct StudioLensPanel: View {
    @Binding var state: LensPanelState
    @Binding var prompt: String
    @FocusState.Binding var promptFocused: Bool

    let mode: LensMode
    let thumbnail: UIImage?
    let resultText: String
    let errorText: String?
    let canAnalyze: Bool

    let onOpenPresets: () -> Void
    let onAnalyze: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    let onFollowUp: () -> Void
    let onRetake: () -> Void
    let onExpand: () -> Void
    let onSendToAssistant: () -> Void

    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let S = T.studio
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .collapsed:  idle
            case .composing:  composing
            case .captured, .analyzing: analyzing
            case .result:     result
            case .error:      errorView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.top, StudioSpacing.l)
        .padding(.bottom, 30)
        .background(S.paper)
        .clipShape(.rect(topLeadingRadius: StudioRadius.sheet,
                         topTrailingRadius: StudioRadius.sheet))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state)
        .accessibilityElement(children: .contain)
    }

    // MARK: - States

    private var idle: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            Text(mode.instruction)
                .font(S.sans(19, .semibold))
                .tracking(-0.3)
                .foregroundStyle(S.ink)
            Text("The frame is read here and thrown away. Nothing is uploaded.")
                .font(S.sans(14.5))
                .lineSpacing(14.5 * 0.45)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack(spacing: 14) {
                StudioGlyphButton(symbol: "text.badge.plus", size: 44, glyphSize: 16) {
                    onOpenPresets()
                }
                .accessibilityLabel("Prompt presets")
                StudioPrimaryButton(title: mode.primaryAction) {
                    state = .composing
                    promptFocused = true
                }
            }
            .padding(.top, 18)
        }
    }

    private var composing: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 14) {
            TextField(mode.promptPlaceholder, text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(S.sans(17))
                .foregroundStyle(S.ink)
                .tint(S.accent)
                .focused($promptFocused)
                .submitLabel(.go)
                .onSubmit { if canAnalyze { onAnalyze() } }

            HStack(spacing: StudioSpacing.xs) {
                StudioGlyphButton(symbol: "text.badge.plus", glyphSize: 15) {
                    onOpenPresets()
                }
                .accessibilityLabel("Prompt presets")
                Spacer(minLength: StudioSpacing.s)
                StudioPrimaryButton(title: mode.primaryAction, action: onAnalyze)
                    .frame(width: 140)
                    .opacity(canAnalyze ? 1 : 0.45)
                    .disabled(!canAnalyze)
            }
        }
    }

    private var analyzing: some View {
        let S = T.studio
        let captured = state == .captured
        return HStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle()
                        .fill(S.fillActive)
                        .overlay(
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 16))
                                .foregroundStyle(S.ink3)
                        )
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous))
            .accessibilityLabel("Captured frame")

            VStack(alignment: .leading, spacing: StudioSpacing.s) {
                StudioMonoLabel(text: captured ? "frame captured" : "reading frame · on device")
                StudioLensProgressBar(active: !captured && !reduceMotion)
            }

            Spacer(minLength: 0)

            Button("Cancel", action: onCancel)
                .font(S.sans(13.5, .medium))
                .foregroundStyle(S.ink3)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var result: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            StudioMonoLabel(text: "read on device · frame discarded")

            ScrollView {
                AssistantMarkdownView(content: resultText, isStreaming: false)
                    .font(S.sans(17))
                    .lineSpacing(17 * 0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(.top, 10)
            .scrollDismissesKeyboard(.interactively)

            StudioHairline(color: S.rule2)
                .padding(.vertical, 12)

            HStack(spacing: 2) {
                StudioGlyphButton(symbol: "doc.on.doc", glyphSize: 14, action: onCopy)
                    .accessibilityLabel("Copy")
                StudioGlyphButton(symbol: "arrow.clockwise", glyphSize: 14, action: onFollowUp)
                    .accessibilityLabel("Ask again")
                StudioGlyphButton(symbol: "square.and.arrow.up", glyphSize: 14, action: onShare)
                    .accessibilityLabel("Share")
                if mode == .translate {
                    StudioGlyphButton(symbol: "speaker.wave.2", glyphSize: 14, action: onSpeak)
                        .accessibilityLabel("Read aloud")
                }
                StudioGlyphButton(symbol: "camera", glyphSize: 14, action: onRetake)
                    .accessibilityLabel("Retake")
                StudioGlyphButton(symbol: "arrow.up.left.and.arrow.down.right", glyphSize: 13) {
                    onExpand()
                }
                .accessibilityLabel("Expand result")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            StudioPrimaryButton(title: "Send to Assistant", action: onSendToAssistant)
                .padding(.top, 12)
        }
    }

    private var errorView: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(S.danger).frame(width: 5, height: 5)
                StudioMonoLabel(text: "couldn't read that", size: 11, tracking: 0.9)
            }
            Text(errorText ?? "The selected model could not analyze this frame.")
                .font(S.sans(15.5))
                .lineSpacing(15.5 * 0.45)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: StudioSpacing.s) {
                StudioPrimaryButton(title: "Try again", action: onAnalyze)
                StudioOutlineButton(title: "Retake", action: onRetake)
            }
            .padding(.top, 14)
        }
        .padding(.leading, StudioSpacing.m)
    }
}

// MARK: - Indeterminate reading bar

/// 2px track with a 90pt accent segment sliding across it. Static at the
/// leading edge under Reduce Motion.
private struct StudioLensProgressBar: View {
    let active: Bool

    @Environment(\.koduTheme) private var T
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(T.studio.ink.opacity(0.10))
                Rectangle()
                    .fill(T.studio.accent)
                    .frame(width: 90)
                    .offset(x: active ? phase * max(0, geo.size.width - 90) : 0)
            }
        }
        .frame(height: 2)
        .onAppear {
            guard active else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - LensMode copy (moved from LensTaskPanel)

extension LensMode {
    /// The filled primary button's label in the panel (type bar uses `label`).
    var primaryAction: String { label }

    var promptTitle: String {
        switch self {
        case .ask: "Ask Lens"
        case .translate: "Translate with Lens"
        case .scan: "Scan with Lens"
        case .solve: "Solve with Lens"
        }
    }

    var promptPlaceholder: String {
        switch self {
        case .ask: "Ask about what the camera sees"
        case .translate: "Choose or enter the target language"
        case .scan: "Capture text or a document"
        case .solve: "Capture a problem to solve"
        }
    }

    var instruction: String {
        switch self {
        case .ask: "Point your camera"
        case .translate: "Frame text to translate"
        case .scan: "Frame text or a document"
        case .solve: "Frame a problem to solve"
        }
    }

    var resultTitle: String {
        switch self {
        case .ask: "Lens Answer"
        case .translate: "Translation"
        case .scan: "Recognized Text"
        case .solve: "Suggested Solution"
        }
    }

    var accent: Color {
        switch self {
        case .ask: .blue
        case .translate: .purple
        case .scan: .green
        case .solve: .orange
        }
    }

    var emptyStateSymbol: String {
        switch self {
        case .ask: "camera.viewfinder"
        case .translate: "character.bubble"
        case .scan: "doc.viewfinder"
        case .solve: "function"
        }
    }
}
