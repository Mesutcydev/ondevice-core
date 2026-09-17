import SwiftUI

// MARK: - HomeView
// Landing tab — on-device status as an editorial document: one flat page,
// hairline rules, mono eyebrows, a single filled primary. The Lens / Voice /
// Mac quick-action tiles and the colored icon badges are gone; every block
// below follows the Studio language.
//
// All callbacks are injected by ContentView so this view stays navigation-free
// and testable.

struct HomeView: View {
    @Environment(\.koduTheme) private var T
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var convos = ConversationStore.shared
    @ObservedObject private var loc = LocalizationService.shared

    /// Start a fresh chat (→ Assistant tab).
    var onNewChat: () -> Void
    /// Open the Models tab.
    var onOpenModels: () -> Void
    /// Present the on-device image generation studio.
    var onGenerateImage: () -> Void
    /// Present Settings.
    var onOpenSettings: () -> Void
    /// Open the Assistant tab focused on a past conversation (best-effort).
    var onOpenConversation: (StoredConversation) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                statusBlock
                    .padding(.top, 24)
                generateRow
                    .padding(.top, 28)
                recentSection
                    .padding(.top, 30)
                privacyRow
                    .padding(.top, 30)
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        .background(StudioPageBackground())
        .scrollIndicators(.hidden)
    }

    // MARK: Header — greeting + settings

    private var header: some View {
        let S = T.studio
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                StudioMonoLabel(text: greeting, size: 11, tracking: 0.9)
                Text("OnDevice Max")
                    .font(S.sans(32, .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(S.ink)
            }
            Spacer()
            StudioGlyphButton(symbol: "gearshape", size: 36, glyphSize: 16) {
                onOpenSettings()
            }
            .accessibilityLabel(loc.t("settings"))
        }
    }

    // MARK: Status — assistant ready

    private var heroState: (dot: Color, title: String) {
        let S = T.studio
        switch assistant.state {
        case .ready:      return (S.accent, loc.t("Assistant is ready"))
        case .generating: return (S.accent, loc.t("Assistant is thinking…"))
        case .loading:    return (T.warn, loc.t("Preparing model…"))
        case .failed(let e):
            // A cancelled load (tab switch, memory pressure) isn't a real
            // failure — present it as the calm idle state, not an alarm.
            if e.localizedCaseInsensitiveContains("cancel") {
                return (S.ink4, loc.t("Tap New chat to start"))
            }
            return (T.bad, loc.t("Model needs setup"))
        case .unloaded:
            return downloadInProgress
                ? (T.warn, loc.t("Preparing model…"))
                : (S.ink4, loc.t("Tap New chat to start"))
        }
    }

    /// Subtitle under the status title — shows the live load progress / error
    /// while preparing or failed, otherwise the model name + privacy tagline.
    private var heroSubtitle: String {
        if case .loading(let m) = assistant.state, !m.isEmpty { return m }
        if case .failed(let e) = assistant.state, !e.isEmpty,
           !e.localizedCaseInsensitiveContains("cancel") { return e }
        return "\(assistant.activeModel.displayName) — \(loc.t("replies stay on your iPhone"))"
    }

    /// True while any model is actively downloading — so the block reads
    /// "Preparing…" instead of a misleading "ready"/idle state.
    private var downloadInProgress: Bool {
        center.models.contains { m in
            switch m.state {
            case .downloading, .enumerating: return true
            default: return false
            }
        }
    }

    private var statusBlock: some View {
        let S = T.studio
        let state = heroState
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(state.dot)
                    .frame(width: 6, height: 6)
                StudioMonoLabel(text: loc.t("running on-device"), size: 11, tracking: 0.9)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(S.ink3)
            }

            Text(state.title)
                .font(S.sans(24, .semibold))
                .tracking(-0.4)
                .foregroundStyle(S.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Text(heroSubtitle)
                .font(S.sans(14.5))
                .lineSpacing(5)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            StudioHairline(color: S.rule2)
                .padding(.top, 18)

            StudioPrimaryButton(title: loc.t("New chat")) {
                onNewChat()
            }
            .padding(.top, 14)
        }
        .padding(StudioSpacing.l)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.action, style: .continuous)
                .stroke(S.rule, lineWidth: 1)
        )
    }

    // MARK: Generate — list row

    private var generateRow: some View {
        VStack(spacing: 0) {
            StudioHairline(color: T.studio.rule2)
            navRow(symbol: "wand.and.stars",
                   title: "Generate an image",
                   subtitle: "Create images privately with on-device models") {
                onGenerateImage()
            }
            StudioHairline(color: T.studio.rule2)
        }
        .accessibilityHint("Opens the on-device image generation studio")
    }

    // MARK: Recent

    private var recentSection: some View {
        let S = T.studio
        let recent = Array(convos.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            StudioMonoLabel(text: loc.t("recent"), size: 11, tracking: 0.9)
                .padding(.bottom, StudioSpacing.s)
            StudioHairline(color: S.rule2)

            if recent.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        glyphTile("message")
                        Text(loc.t("No recent activity yet"))
                            .font(S.sans(15))
                            .foregroundStyle(S.ink3)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    StudioHairline(color: S.rule2)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { _, convo in
                        Button {
                            HapticManager.impact(.light)
                            onOpenConversation(convo)
                        } label: {
                            recentRow(convo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentRow(_ convo: StoredConversation) -> some View {
        let S = T.studio
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                glyphTile("message")
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.title.isEmpty ? loc.t("Untitled chat") : convo.title)
                        .font(S.sans(15.5, .medium))
                        .foregroundStyle(S.ink)
                        .lineLimit(1)
                    Text("\(loc.t("assistant")) · \(Self.relative(convo.updatedAt))")
                        .font(S.sans(12.5))
                        .foregroundStyle(S.ink3)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(S.chevron)
            }
            .padding(.vertical, 13)
            StudioHairline(color: S.rule2)
        }
        .contentShape(Rectangle())
    }

    // MARK: Privacy / manage

    private var privacyRow: some View {
        let S = T.studio
        let readyCount = center.models.filter { $0.isReady }.count
        return VStack(spacing: 0) {
            StudioHairline(color: S.rule2)
            HStack(spacing: 12) {
                glyphTile("lock.fill")
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t("Private by design"))
                        .font(S.sans(15.5, .medium))
                        .foregroundStyle(S.ink)
                    Text("\(readyCount) \(loc.t("models")) · \(Self.bytes(center.totalStorageUsed)) \(loc.t("on this iPhone"))")
                        .font(S.sans(12.5))
                        .foregroundStyle(S.ink3)
                }
                Spacer(minLength: 6)
                Button {
                    HapticManager.impact(.light)
                    onOpenModels()
                } label: {
                    Text(loc.t("Manage"))
                        .font(S.sans(13.5, .medium))
                        .foregroundStyle(S.ink)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                                .stroke(S.rule, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 14)
            StudioHairline(color: S.rule2)
        }
    }

    // MARK: Reusable bits

    private func navRow(symbol: String, title: String, subtitle: String,
                        action: @escaping () -> Void) -> some View {
        let S = T.studio
        return Button {
            HapticManager.impact(.light)
            action()
        } label: {
            HStack(spacing: 14) {
                glyphTile(symbol, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(S.sans(16.5)).foregroundStyle(S.ink)
                    Text(subtitle).font(S.sans(13)).foregroundStyle(S.ink3)
                }
                Spacer(minLength: StudioSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(S.chevron)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func glyphTile(_ symbol: String, size: CGFloat = 34) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size < 36 ? 14 : 15))
            .foregroundStyle(T.studio.ink)
            .frame(width: size, height: size)
            .background(T.studio.fillActive,
                        in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous))
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return loc.t("Good morning")
        case 12..<18: return loc.t("Good afternoon")
        default:      return loc.t("Good evening")
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static func bytes(_ n: Int64) -> String {
        guard n > 0 else { return "0 MB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = n >= 1_000_000_000 ? [.useGB] : [.useMB]
        return f.string(fromByteCount: n)
    }
}
