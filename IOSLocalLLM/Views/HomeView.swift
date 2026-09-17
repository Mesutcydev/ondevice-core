import SwiftUI

// MARK: - HomeView
//
// The launch tab. Four blocks, in the order the questions actually get asked:
//
//   1. What's loaded, and is it ready       → hero, with the model as headline
//   2. What is this machine doing           → device strip (memory/storage/models/speed)
//   3. What was I working on                → continue
//   4. What else can it do                  → create
//
// The previous version was a status card and three list rows, which read as a
// settings screen. The change in substance is block 2: this app knows things a
// cloud assistant cannot — how much RAM is free for inference, what the weights
// weigh, how fast the last answer came back — and none of it was on screen.
// Machine facts are set in mono, which is what the Studio language reserves it
// for.
//
// All navigation is injected by ContentView so this view stays testable.

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
    /// Switch to the Lens (camera) tab.
    var onOpenLens: () -> Void = {}
    /// Switch to the Voice tab.
    var onOpenVoice: () -> Void = {}
    /// Present the full, searchable conversation list.
    var onOpenHistory: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                hero.padding(.top, 20)
                deviceStrip.padding(.top, 22)
                continueSection.padding(.top, 30)
                createSection.padding(.top, 30)
                privacyFooter.padding(.top, 30)
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(StudioPageBackground())
        .scrollIndicators(.hidden)
    }

    // MARK: - 1 · Masthead

    private var masthead: some View {
        let S = T.studio
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                StudioMonoLabel(text: greeting, size: 11, tracking: 0.9)
                Text("OnDevice Max")
                    .font(S.sans(32, .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(S.ink)
            }
            Spacer(minLength: StudioSpacing.s)
            StudioGlyphButton(symbol: "gearshape", glyphSize: 16) {
                onOpenSettings()
            }
            .accessibilityLabel(loc.t("settings"))
        }
        // The glyph button carries a 44pt tap box; pull the row back so the
        // gear sits flush with the right margin rather than 5pt inside it.
        .padding(.trailing, -StudioGlyphButton.opticalInset)
    }

    // MARK: - 2 · Hero
    //
    // The model's name is the headline. "Assistant is ready" told the user
    // nothing they couldn't infer from the app having opened; which model is
    // loaded is the fact that actually varies.

    private var hero: some View {
        let S = T.studio
        let state = heroState
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 6, height: 6)
                StudioMonoLabel(text: state.eyebrow, size: 11, tracking: 0.9)
                Spacer(minLength: StudioSpacing.s)
                Image(systemName: isPrivateCloud ? "icloud.fill" : "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(S.ink3)
                    .accessibilityHidden(true)
            }

            Text(assistant.activeModel.displayName)
                .font(S.sans(26, .semibold))
                .tracking(-0.5)
                .foregroundStyle(S.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Text(heroSubtitle)
                .font(S.sans(14.5))
                .lineSpacing(5)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)

            StudioHairline(color: S.rule2).padding(.top, 16)

            StudioPrimaryButton(title: loc.t("New chat")) { onNewChat() }
                .padding(.top, 14)
        }
        .padding(StudioSpacing.l)
        // Same raised-card treatment as the composer, so the one object on the
        // page that you act on looks like an object in both places.
        .background(
            S.surfaceRaised,
            in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                .strokeBorder(S.strokeRest, lineWidth: 1)
        )
        .shadow(color: S.shadowAmbient, radius: 16, y: 5)
        .shadow(color: S.shadowKey, radius: 2, y: 1)
        .accessibilityElement(children: .contain)
    }

    private var isPrivateCloud: Bool {
        assistant.activeExecutionLocation == .applePrivateCloud
    }

    private var heroState: (tint: Color, eyebrow: String) {
        let S = T.studio
        if isPrivateCloud { return (S.accent, loc.t("apple private cloud")) }
        switch assistant.state {
        case .ready:      return (T.good, loc.t("on-device · ready"))
        case .generating: return (T.good, loc.t("on-device · working"))
        case .loading:    return (T.warn, loc.t("on-device · loading"))
        case .failed(let e):
            // A cancelled load (tab switch, memory pressure) isn't a real
            // failure — present it as the calm idle state, not an alarm.
            if e.localizedCaseInsensitiveContains("cancel") {
                return (S.ink4, loc.t("on-device · idle"))
            }
            return (T.bad, loc.t("needs setup"))
        case .unloaded:
            return downloadInProgress
                ? (T.warn, loc.t("on-device · preparing"))
                : (S.ink4, loc.t("on-device · idle"))
        }
    }

    private var heroSubtitle: String {
        if case .loading(let m) = assistant.state, !m.isEmpty { return m }
        if case .failed(let e) = assistant.state, !e.isEmpty,
           !e.localizedCaseInsensitiveContains("cancel") { return e }
        if isPrivateCloud {
            return loc.t("Runs through Apple Private Cloud Compute. Needs a connection.")
        }
        return loc.t("Runs entirely on this iPhone. Works in airplane mode.")
    }

    private var downloadInProgress: Bool {
        center.models.contains { m in
            switch m.state {
            case .downloading, .enumerating: return true
            default: return false
            }
        }
    }

    // MARK: - 3 · Device strip
    //
    // Four machine facts between hairlines. This is the block the old Home was
    // missing: an on-device app can answer "what is this thing actually doing"
    // in a way a cloud client never can, and the answer changes as you use it.

    private var deviceStrip: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            StudioHairline(color: S.rule2)
            HStack(alignment: .top, spacing: 0) {
                metric(loc.t("memory"), MemoryAdvisor.availableRAM.formattedBytes)
                metric(loc.t("weights"), center.totalStorageUsed.formattedBytes)
                metric(loc.t("ready"), "\(readyModelCount)")
                metric(loc.t("last run"), lastThroughput)
            }
            .padding(.vertical, 13)
            StudioHairline(color: S.rule2)
        }
        .accessibilityElement(children: .contain)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 3) {
            StudioMonoLabel(text: label, size: 9, tracking: 1.0)
            Text(value)
                .font(S.mono(13.5, .medium))
                .foregroundStyle(S.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var readyModelCount: Int {
        center.models.filter(\.isReady).count
    }

    /// Throughput of the most recent answer that recorded one. Honest "—" when
    /// nothing has been generated yet rather than a fabricated zero.
    private var lastThroughput: String {
        let rate = convos.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(4)
            .flatMap(\.messages)
            .compactMap(\.generationTokensPerSecond)
            .last
        guard let rate, rate > 0 else { return "—" }
        return String(format: "%.0f w/s", rate)
    }

    // MARK: - 4 · Continue

    private var continueSection: some View {
        let all = convos.conversations.sorted { $0.updatedAt > $1.updatedAt }
        let recent = Array(all.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            // The full, searchable history used to be reachable ONLY from a
            // clock glyph in the Assistant toolbar — which is itself hidden
            // while generating, and hidden entirely when the list is empty. So
            // the only list view of past work was behind a button that
            // disappeared. This is the durable entry point.
            sectionHeader(
                loc.t("continue"),
                trailing: all.count > recent.count ? loc.t("All \(all.count)") : nil,
                action: onOpenHistory
            )

            if recent.isEmpty {
                emptyContinueRow
            } else {
                ForEach(recent) { convo in
                    Button {
                        HapticManager.impact(.light)
                        onOpenConversation(convo)
                    } label: {
                        conversationRow(convo)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func conversationRow(_ convo: StoredConversation) -> some View {
        let S = T.studio
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                glyphTile("bubble.left.and.text.bubble.right")
                VStack(alignment: .leading, spacing: 3) {
                    Text(convo.title.isEmpty ? loc.t("Untitled chat") : convo.title)
                        .font(S.sans(15.5, .medium))
                        .foregroundStyle(S.ink)
                        .lineLimit(1)
                    if let preview = convoPreview(convo) {
                        Text(preview)
                            .font(S.sans(13))
                            .foregroundStyle(S.ink3)
                            .lineLimit(1)
                    }
                    StudioMonoLabel(text: convoMeta(convo), size: 10, tracking: 0.5)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(S.chevron)
            }
            .padding(.vertical, 12)
            StudioHairline(color: S.rule2)
        }
        .contentShape(Rectangle())
    }

    /// First line of the opening question — enough to recognise the thread
    /// without reading the title, which is often auto-generated.
    private func convoPreview(_ convo: StoredConversation) -> String? {
        guard let first = convo.messages.first(where: {
            $0.role == "user" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return first.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func convoMeta(_ convo: StoredConversation) -> String {
        let turns = convo.messages.filter { $0.role == "user" || $0.role == "assistant" }.count
        let count = turns == 1 ? loc.t("1 message") : "\(turns) \(loc.t("messages"))"
        return "\(count) · \(Self.relative(convo.updatedAt))"
    }

    private var emptyContinueRow: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                glyphTile("bubble.left.and.text.bubble.right")
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("No conversations yet"))
                        .font(S.sans(15))
                        .foregroundStyle(S.ink2)
                    Text(loc.t("Anything you ask stays on this device."))
                        .font(S.sans(13))
                        .foregroundStyle(S.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            StudioHairline(color: S.rule2)
        }
    }

    // MARK: - 5 · Create
    //
    // The three capabilities that aren't a text chat. Image generation used to
    // be the only row on this page and the other two were reachable only from
    // the tab bar, which meant nothing on Home said the app could see or speak.

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(loc.t("create"))
            navRow(symbol: "wand.and.stars",
                   title: loc.t("Generate an image"),
                   subtitle: loc.t("Text to image, on this device"),
                   action: onGenerateImage)
            navRow(symbol: "camera.viewfinder",
                   title: loc.t("Look at something"),
                   subtitle: loc.t("Point the camera and ask about it"),
                   action: onOpenLens)
            navRow(symbol: "waveform",
                   title: loc.t("Talk it through"),
                   subtitle: loc.t("Hands-free voice conversation"),
                   action: onOpenVoice)
        }
    }

    // MARK: - 6 · Privacy footer

    private var privacyFooter: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            StudioHairline(color: S.rule2)
            HStack(spacing: 12) {
                glyphTile("lock.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("Private by design"))
                        .font(S.sans(15.5, .medium))
                        .foregroundStyle(S.ink)
                    Text("\(readyModelCount) \(loc.t("models")) · \(center.totalStorageUsed.formattedBytes) \(loc.t("on this iPhone"))")
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
                                .stroke(S.rule2, lineWidth: 1)
                        )
                }
                .buttonStyle(StudioPressStyle())
            }
            .padding(.vertical, 14)
            StudioHairline(color: S.rule2)
        }
    }

    // MARK: - Reusable bits

    /// Mono eyebrow above a hairline — the section marker used throughout.
    /// `trailing` adds a quiet action on the same baseline (e.g. "All 12").
    private func sectionHeader(_ title: String,
                               trailing: String? = nil,
                               action: (() -> Void)? = nil) -> some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: StudioSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                StudioMonoLabel(text: title, size: 11, tracking: 0.9)
                Spacer(minLength: StudioSpacing.s)
                if let trailing, let action {
                    Button {
                        HapticManager.impact(.light)
                        action()
                    } label: {
                        HStack(spacing: 3) {
                            Text(trailing)
                                .font(S.sans(13, .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(S.ink2)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressStyle())
                }
            }
            StudioHairline(color: S.rule2)
        }
    }

    private func navRow(symbol: String, title: String, subtitle: String,
                        action: @escaping () -> Void) -> some View {
        let S = T.studio
        return Button {
            HapticManager.impact(.light)
            action()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    glyphTile(symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(S.sans(15.5, .medium))
                            .foregroundStyle(S.ink)
                        Text(subtitle)
                            .font(S.sans(13))
                            .foregroundStyle(S.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: StudioSpacing.s)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(S.chevron)
                }
                .padding(.vertical, 12)
                StudioHairline(color: S.rule2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func glyphTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(T.studio.ink)
            .frame(width: 34, height: 34)
            .background(T.studio.fillActive,
                        in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous))
            .accessibilityHidden(true)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
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
}
