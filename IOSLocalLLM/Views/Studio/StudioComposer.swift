import SwiftUI

// MARK: - StudioComposer
//
// A contained composer: a raised card on the paper page, with a hairline
// boundary that brightens on focus and two shadows for separation. It was
// previously flush-to-edge with a single hairline and no depth at all, which
// read as unfinished rather than restrained — the thread is the flat surface
// in this design, the composer is the object sitting on it.
//
// The paste / photo / snippet / file actions live in StudioAddSheet, reached
// from the `＋` glyph.
//
// Six states, all in this one view: resting · typing · attachments ·
// dictating · generating · blocked (no model).

struct StudioComposer: View {

    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    // Attachments — the app's own models, unchanged.
    @Binding var images: [ChatMessage.ImageAttachment]
    /// Legacy single-image slot kept in sync by the host.
    @Binding var legacyImage: Data?
    @Binding var files: [FileAttachmentService.Attachment]

    // Modes
    @Binding var thinkingEnabled: Bool
    let supportsThinking: Bool

    // Runtime
    let isGenerating: Bool
    let isPreparingImageContext: Bool
    let canGenerate: Bool          // false → blocked state
    let canSend: Bool
    let tokensPerSecond: Double?
    let tokenBudget: (used: Int, max: Int)?
    let thermalWarning: String?

    var placeholder: String = "Ask anything"

    let onAdd: () -> Void
    let onPhoto: () -> Void
    let onSnippet: () -> Void
    let onToggleThinking: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onChooseModel: () -> Void

    @AppStorage("recentPromptsBlob") private var recentPromptsBlob: String = ""
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var dictation = SpeechDictationService()
    @State private var dictationBaseline = ""
    @State private var dictationPermissionsRequested = false
    @State private var showDictationDenied = false

    private var recents: [String] {
        recentPromptsBlob
            .split(separator: "\u{1F}")
            .map(String.init)
            .filter { !$0.isEmpty }
            .suffix(8)
            .reversed()
    }

    private var hasAttachments: Bool {
        !images.isEmpty || legacyImage != nil || !files.isEmpty
    }

    /// How far the card is inset from the screen edge.
    private static let cardInset: CGFloat = 12
    /// The card's own internal padding.
    private static let cardPadding: CGFloat = 14
    /// Where text inside the card actually starts, measured from the screen
    /// edge. Rows that sit OUTSIDE the card (the generating rule) use this so
    /// they stay optically aligned with the field.
    private static let contentInset: CGFloat = cardInset + cardPadding

    var body: some View {
        let S = T.studio
        VStack(spacing: 0) {
            // Metrics / thermal / Stop sit on the paper band ABOVE the card, so
            // the field never shifts when generation starts or ends.
            if isGenerating || isPreparingImageContext || thermalWarning != nil {
                generatingRule
            }

            VStack(alignment: .leading, spacing: 12) {
                if isFocused && !recents.isEmpty { recentsStrip }
                if hasAttachments { attachmentRow }

                if canGenerate {
                    if dictation.isRecording { dictationRow } else { field }
                    controlRow
                } else {
                    blockedRow
                }
            }
            .padding(.horizontal, Self.cardPadding)
            .padding(.vertical, 12)
            // The composer is a contained surface: it sits ON the page rather
            // than being a band cut out of it. Fill lifts above `paper`, a
            // hairline draws the boundary, and two shadows (wide ambient +
            // tight contact) do the separating that a full-bleed hairline
            // used to do on its own.
            .background(
                S.surfaceRaised,
                in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                    .strokeBorder(isFocused ? S.strokeFocus : S.strokeRest, lineWidth: 1)
            )
            .shadow(color: S.shadowAmbient, radius: isFocused ? 22 : 16, y: isFocused ? 8 : 5)
            .shadow(color: S.shadowKey, radius: 2, y: 1)
            .padding(.horizontal, Self.cardInset)
            // The app's floating tab bar already owns the home-indicator band,
            // so the card stops short of it rather than sitting on it.
            .padding(.bottom, 10)
        }
        .background(S.paper)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: canSend)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isGenerating)
        .alert("Microphone access needed", isPresented: $showDictationDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable microphone and speech recognition for OnDevice in Settings → Privacy.")
        }
    }

    // MARK: - Field

    private var field: some View {
        let S = T.studio
        return TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .font(S.sans(17))
            .foregroundStyle(S.ink)
            .tint(S.accent)
            .focused($isFocused)
            .submitLabel(.return)
            .accessibilityLabel(placeholder)
    }

    // MARK: - Control row

    private var controlRow: some View {
        // Zero spacing: each glyph button now carries its own 44pt tap box, so
        // the visible gap between the 34pt chips is already 10pt.
        HStack(spacing: 0) {
            StudioGlyphButton(symbol: "plus", glyphSize: 19, action: onAdd)
                .accessibilityLabel("Add photo, file, snippet or paste")
            StudioGlyphButton(symbol: "camera", glyphSize: 16, action: onPhoto)
                .accessibilityLabel("Photo")
            StudioGlyphButton(symbol: "chevron.left.forwardslash.chevron.right",
                              glyphSize: 15, action: onSnippet)
                .accessibilityLabel("Saved text")

            if supportsThinking { modeReadouts }

            Spacer(minLength: StudioSpacing.xs)

            if canSend {
                sendButton
            } else {
                StudioGlyphButton(symbol: "waveform", glyphSize: 16) {
                    Task { await toggleDictation() }
                }
                .accessibilityLabel("Dictate")
            }
        }
        // Pull the row back so the first glyph sits flush with the field's
        // text, not 5pt in from it.
        .padding(.horizontal, -StudioGlyphButton.opticalInset)
    }

    private var sendButton: some View {
        let S = T.studio
        return Button {
            saveRecent(text)
            HapticManager.impact(.medium)
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(S.paper)
                .frame(width: 36, height: 36)
                .background(S.ink, in: RoundedRectangle(cornerRadius: StudioRadius.send,
                                                        style: .continuous))
        }
        .buttonStyle(StudioPressStyle())
        // Grows in rather than fading — the one moment in the composer that
        // earns a bit of motion, since it marks the message becoming sendable.
        .transition(.scale(scale: 0.82).combined(with: .opacity))
        .accessibilityLabel("Send")
    }

    /// THINKS label-over-value stack — the composer's single mode control.
    /// The model picker lives in the nav pill only, so there is exactly one
    /// model affordance on screen. Hidden when the loaded model advertises
    /// no reasoning support.
    private var modeReadouts: some View {
        let S = T.studio
        return Button(action: onToggleThinking) {
            VStack(alignment: .leading, spacing: 1) {
                StudioMonoLabel(text: "thinks", size: 9, tracking: 1.0)
                Text(thinkingEnabled ? "First" : "Off")
                    .font(S.sans(13, .medium))
                    .foregroundStyle(thinkingEnabled ? S.accent : S.ink3)
                    .overlay(alignment: .bottom) {
                        if thinkingEnabled {
                            Rectangle()
                                .fill(S.accent.opacity(0.35))
                                .frame(height: 2)
                                .offset(y: 2)
                        }
                    }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Think before answering")
        .accessibilityValue(thinkingEnabled ? "on" : "off")
    }

    // MARK: - Rows

    private var recentsStrip: some View {
        let S = T.studio
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                StudioMonoLabel(text: "recent", size: 9, tracking: 1.0)
                ForEach(Array(recents.enumerated()), id: \.offset) { _, prompt in
                    Button {
                        text += (text.isEmpty || text.hasSuffix(" ")) ? prompt : " " + prompt
                        HapticManager.impact(.light)
                    } label: {
                        Text(prompt.prefix(48))
                            .font(S.sans(13))
                            .foregroundStyle(S.ink3)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous)
                                    .stroke(S.ink.opacity(0.11), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 30)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                    StudioImageTile(data: img.data) {
                        images.remove(at: idx)
                        if images.isEmpty { legacyImage = nil }
                        HapticManager.impact(.light)
                    }
                }
                if let legacy = legacyImage, images.isEmpty {
                    StudioImageTile(data: legacy) {
                        legacyImage = nil
                        HapticManager.impact(.light)
                    }
                }
                ForEach(files) { file in
                    StudioFileTile(attachment: file, removable: true) {
                        files.removeAll { $0.id == file.id }
                        HapticManager.impact(.light)
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private var dictationRow: some View {
        let S = T.studio
        return HStack(spacing: StudioSpacing.m) {
            StudioDictationBars(animating: !reduceMotion)
            Text("Listening — speak now")
                .font(S.sans(16))
                .foregroundStyle(S.ink)
            Spacer()
            Button("Done") {
                dictation.stop()
                HapticManager.impact(.light)
            }
            .font(S.sans(13, .medium))
            .foregroundStyle(S.ink3)
            .buttonStyle(.plain)
        }
        .frame(minHeight: 34)
    }

    private var blockedRow: some View {
        let S = T.studio
        return HStack(spacing: StudioSpacing.m) {
            Text("No model loaded yet — pick one to start asking.")
                .font(S.sans(14))
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: StudioSpacing.s)
            Button(action: onChooseModel) {
                Text("Choose")
                    .font(S.sans(13, .medium))
                    .foregroundStyle(S.paper)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 34)
                    .background(S.ink, in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                                            style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// Metrics + Stop. Lives above the composer hairline so the field never
    /// moves when generation starts or ends.
    private var generatingRule: some View {
        let S = T.studio
        return HStack(spacing: StudioSpacing.m) {
            Text(isPreparingImageContext ? "Reading image" : "Writing")
                .font(S.sans(14))
                .foregroundStyle(S.ink2)

            if let thermalWarning {
                // Thermal supersedes the throughput readout.
                StudioMonoLabel(text: thermalWarning, color: S.danger)
                    .lineLimit(1)
            } else if !metricsText.isEmpty {
                StudioMonoLabel(text: metricsText)
                    .lineLimit(1)
            }

            Spacer(minLength: StudioSpacing.s)

            Button {
                HapticManager.impact(.medium)
                onStop()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                    Text("Stop").font(S.sans(13, .medium))
                }
                .foregroundStyle(S.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(S.fillActive, in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                                               style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop generating")
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var metricsText: String {
        var parts: [String] = []
        if let tokensPerSecond, tokensPerSecond > 0 {
            parts.append(String(format: "%.0f w/s", tokensPerSecond))
        }
        if let tokenBudget, tokenBudget.used > 0 {
            parts.append("\(tokenBudget.used) of \(tokenBudget.max)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Dictation

    private func toggleDictation() async {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        if !dictationPermissionsRequested {
            dictationPermissionsRequested = true
            let ok = await dictation.requestAuthorization()
            if !ok { showDictationDenied = true; return }
        } else if !dictation.isAuthorized {
            showDictationDenied = true
            return
        }
        guard dictation.isAvailable else {
            ToastCenter.shared.error("Speech recognition unavailable",
                                     detail: dictation.lastError ?? "Try again in a moment.")
            return
        }
        dictationBaseline = text
        do {
            try dictation.start { transcript, isFinal in
                let glue = dictationBaseline.isEmpty
                    ? ""
                    : (dictationBaseline.hasSuffix(" ") ? "" : " ")
                text = dictationBaseline + glue + transcript
                if isFinal { HapticManager.impact(.light) }
            }
        } catch {
            ToastCenter.shared.error("Couldn't start dictation",
                                     detail: error.localizedDescription)
        }
    }

    // MARK: - Recents

    /// Same UNIT-SEPARATOR blob the keyboard toolbar used, so existing
    /// history survives the redesign.
    private func saveRecent(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return }
        var all = recentPromptsBlob.split(separator: "\u{1F}").map(String.init)
        all.removeAll { $0 == trimmed }
        all.append(trimmed)
        recentPromptsBlob = all.suffix(8).joined(separator: "\u{1F}")
    }
}

// MARK: - Tiles

/// 48pt photo square with an 18pt ✕ badge on the corner.
struct StudioImageTile: View {
    let data: Data
    var size: CGFloat = 48
    let onRemove: (() -> Void)?

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        thumbnail
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(S.paper)
                            .frame(width: 18, height: 18)
                            .background(S.ink, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Remove image")
                }
            }
            .accessibilityLabel("Attached image")
    }

    @ViewBuilder private var thumbnail: some View {
        if let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            Rectangle().fill(T.studio.fillActive)
        }
    }
}

/// Bordered file tile — doc glyph + name + mono byte count.
struct StudioFileTile: View {
    let attachment: FileAttachmentService.Attachment
    var height: CGFloat = 48
    var removable: Bool = false
    var onRemove: (() -> Void)? = nil

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(S.ink3)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(S.sans(12, .medium))
                    .foregroundStyle(S.ink)
                    .lineLimit(1)
                StudioMonoLabel(text: Int64(attachment.byteSize).formattedBytes,
                                size: 11, tracking: 0.4)
            }
            if removable, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(S.ink3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.displayName)")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous)
                .stroke(S.ink.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Four 2×16 bars, 0.9s ease-in-out with a 0.12s stagger. Static at 50%
/// under Reduce Motion.
struct StudioDictationBars: View {
    let animating: Bool
    @State private var phase = false
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(T.studio.accent)
                    .frame(width: 2, height: 16)
                    .scaleEffect(y: animating ? (phase ? 1.0 : 0.25) : 0.5, anchor: .center)
                    .animation(
                        animating
                            ? .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.12)
                            : nil,
                        value: phase
                    )
            }
        }
        .frame(height: 20)
        .onAppear { phase = true }
        .accessibilityHidden(true)
    }
}
