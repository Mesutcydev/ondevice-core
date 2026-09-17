import SwiftUI

// MARK: - Studio chat pieces
//
// The thread reads as a document: user turns are blocks with a spine, answers
// are full-measure prose with no bubble and no avatar. These are the parts
// that aren't a restyle of something that already existed.

/// Four glyphs under the last answer, above a 1px divider, with the mono
/// footnote right-aligned. The long-press context menu on the message stays.
struct StudioAnswerActionRow: View {
    /// e.g. "searched once · 2 pages · nothing stored"
    var provenance: String?
    /// e.g. "qwen3 · 1.2s"
    var footnote: String?
    var canRegenerate: Bool = true
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(alignment: .leading, spacing: StudioSpacing.s) {
            if let provenance {
                StudioMonoLabel(text: provenance, size: 11)
            }
            StudioHairline(color: S.rule2)
            // Zero spacing: the glyph buttons carry their own 44pt tap boxes.
            HStack(spacing: 0) {
                StudioGlyphButton(symbol: "doc.on.doc", glyphSize: 14, action: onCopy)
                    .accessibilityLabel("Copy")
                if canRegenerate {
                    StudioGlyphButton(symbol: "arrow.clockwise", glyphSize: 14, action: onRegenerate)
                        .accessibilityLabel("Regenerate")
                }
                StudioGlyphButton(symbol: "square.and.arrow.up", glyphSize: 14, action: onShare)
                    .accessibilityLabel("Share response")
                StudioGlyphButton(symbol: "speaker.wave.2", glyphSize: 14, action: onSpeak)
                    .accessibilityLabel("Read aloud")
                Spacer(minLength: StudioSpacing.s)
                if let footnote {
                    StudioMonoLabel(text: footnote, size: 11)
                        .lineLimit(1)
                }
            }
            // Keeps the first glyph flush with the prose above it.
            .padding(.leading, -StudioGlyphButton.opticalInset)
        }
    }
}

// MARK: - Web permission

/// Approval card for `web_search`. Names exactly what leaves the device;
/// neutral hairline card — no colored spine, no danger tint. The mono
/// eyebrow + the explicit copy carry the caution.
struct StudioWebPermissionCard: View {
    /// The words that would actually be sent.
    let query: String
    /// Optional extra sentence from the caller (the tool's own reason).
    var reason: String?
    var onAllowOnce: () -> Void
    var onAlwaysAllow: (() -> Void)?
    var onDeny: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(S.ink3)
                StudioMonoLabel(text: "needs the internet", size: 11, tracking: 0.9)
            }

            Text("I can't answer this without looking it up.")
                .font(S.sans(17.5, .semibold))
                .lineSpacing(17.5 * 0.35)
                .foregroundStyle(S.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            Text("Only the words “\(query)” would leave your phone. The chat itself stays here.")
                .font(S.sans(14.5))
                .lineSpacing(14.5 * 0.5)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, StudioSpacing.s)

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(S.sans(13))
                    .foregroundStyle(S.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            StudioHairline().padding(.top, 14)

            StudioPrimaryButton(title: "Look it up once", action: onAllowOnce)
                .padding(.top, 13)

            HStack(spacing: StudioSpacing.s) {
                if let onAlwaysAllow {
                    StudioOutlineButton(title: "Always allow", action: onAlwaysAllow)
                }
                Button {
                    HapticManager.impact(.light)
                    onDeny()
                } label: {
                    Text("Never mind")
                        .font(S.sans(14.5, .medium))
                        .foregroundStyle(S.ink3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, StudioSpacing.s)
        }
        .padding(StudioSpacing.l)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.action, style: .continuous)
                .stroke(S.rule, lineWidth: 1)
        )
    }
}

// MARK: - Starter list

/// One suggested opening. `label` is what the row reads; `prompt` is what
/// actually lands in the composer — they differ because a good row label
/// ("Explain something") is not a good prompt ("Explain in simple terms: ").
struct StudioStarter: Identifiable {
    let label: String
    let prompt: String
    var id: String { label }

    init(_ label: String, prompt: String) {
        self.label = label
        self.prompt = prompt
    }
}

/// Full-width starter rows with 1px separators. No cards.
struct StudioStarterList: View {
    let starters: [StudioStarter]
    let onPick: (StudioStarter) -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(spacing: 0) {
            StudioHairline(color: S.rule2)
            ForEach(starters) { starter in
                Button {
                    HapticManager.impact(.light)
                    onPick(starter)
                } label: {
                    HStack {
                        Text(starter.label)
                            .font(S.sans(16))
                            .foregroundStyle(S.ink)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(S.chevron)
                    }
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                StudioHairline(color: S.rule2)
            }
        }
    }
}
