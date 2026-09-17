import SwiftUI

// MARK: - VoiceLibraryView
// The Voice tab, in the Studio grammar.
//
// One page surface (paper), blocks in the order the questions get asked —
// the same structure as Home:
//
//   1. Masthead — mono eyebrow + 32pt title
//   2. Active voice — raised hero with mono facts, the one filled Play
//      button, and the equalizer as a live instrument
//   3. Talk — the primary action of the tab (start a conversation)
//   4. Engine + Library — hairline rows like Home's Continue section
//
// The prior version read as a different product: accent eyebrow, bold
// display title, tinted glass hero card, filled accent chips, pink
// equalizer. Voice is a *utility* tab — the Studio language (ink
// hierarchy, mono facts, hairline separation, one filled action) is what
// "the speech part of the same app" should look like.
//
// The live voice conversation is NOT removed — it is the tab's primary
// action. Engine switching, per-voice preview, locale filters, search,
// and the Clone-your-voice coming-soon row are all preserved.
struct VoiceLibraryView: View {
    /// True only while the Voice tab is the selected tab. Threaded in from
    /// ContentView (`selectedTab == .voice`) because iOS 18 `TabView` does NOT
    /// reliably fire `.onDisappear` on a tab swap — so the hero equalizer's
    /// display-link timeline must freeze off this reliable signal, not just
    /// `.onDisappear`, or it keeps ticking at ~24fps behind the active tab.
    var isActive: Bool = true

    @Environment(\.koduTheme) private var T
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var loc = LocalizationService.shared

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var showConversation = false
    @State private var showCloneSoon = false
    @State private var showEnginePicker = false
    // Drives the hero equalizer animation — frozen while the tab is offscreen.
    @State private var tabVisible = true
    // Cached so we don't re-enumerate AVSpeechSynthesisVoice.speechVoices()
    // (100+ system voices) on every body evaluation.
    @State private var allVoices: [VoiceOption] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all, english, multilingual, cloned
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .english: return "English"
            case .multilingual: return "Multilingual"
            case .cloned: return "Cloned"
            }
        }
    }

    private var voices: [VoiceOption] { allVoices }

    private func reloadVoices() {
        allVoices = voice.availableVoicesForCurrentEngine
    }

    private var current: VoiceOption? {
        voices.first { $0.id == settings.voiceID } ?? voices.first
    }

    private func matches(_ v: VoiceOption) -> Bool {
        switch filter {
        case .all:          return true
        case .english:      return v.locale.lowercased().hasPrefix("en")
        case .multilingual: return !v.locale.lowercased().hasPrefix("en")
        case .cloned:       return false   // no cloned voices yet — see Coming soon
        }
    }

    private var filtered: [VoiceOption] {
        voices.filter { v in
            (query.isEmpty || v.name.localizedCaseInsensitiveContains(query)
                || (v.description ?? "").localizedCaseInsensitiveContains(query))
                && matches(v)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                if let c = current {
                    activeHero(c).padding(.top, 22)
                }
                talkSection.padding(.top, 26)
                engineRow.padding(.top, 22)
                filterRow.padding(.top, 26)
                library.padding(.top, 8)
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(StudioPageBackground())
        .scrollIndicators(.hidden)
        .onAppear { tabVisible = true }
        .onDisappear { tabVisible = false }
        .task {
            await voice.load()
            reloadVoices()
        }
        .onChange(of: settings.voiceEngine) { _, _ in reloadVoices() }
        .sheet(isPresented: $showConversation,
               onDismiss: { VoiceConversationService.shared.stop() }) {
            VoiceConversationView()
        }
        .sheet(isPresented: $showEnginePicker, onDismiss: { reloadVoices() }) {
            VoiceModelPickerView()
        }
        .alert(loc.t("Coming soon"), isPresented: $showCloneSoon) {
            Button(loc.t("Done"), role: .cancel) {}
        } message: {
            Text(loc.t("Voice cloning — record 30 seconds and train a voice that runs entirely on-device — is coming in a future update."))
        }
    }

    // MARK: - 1 · Masthead

    private var masthead: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 6) {
            StudioMonoLabel(text: loc.t("on-device speech"), size: 11, tracking: 0.9)
            Text(loc.t("Voices"))
                .font(S.sans(32, .semibold))
                .tracking(-0.8)
                .foregroundStyle(S.ink)
        }
    }

    // MARK: - 2 · Active hero
    //
    // The voice you're using, stated as a fact block: mono eyebrow, the name
    // as the headline, the engine + locale as mono facts between hairlines.
    // The Play button is the one filled control. The equalizer is the
    // instrument's live meter — monochrome ink at rest, energised into the
    // accent only while a preview is actually playing.

    private func activeHero(_ v: VoiceOption) -> some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: StudioSpacing.m) {
                // Same identity tile as the rows, scaled up — so the voice you
                // are using looks like the one you picked out of the list.
                VStack(spacing: 1) {
                    Text(monogram(for: v))
                        .font(S.mono(18, .semibold))
                        .foregroundStyle(S.ink)
                    Text(regionCode(v.locale))
                        .font(S.mono(8, .medium))
                        .tracking(0.4)
                        .foregroundStyle(S.ink3)
                }
                .frame(width: 46, height: 46)
                .background(S.fillActive,
                            in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    StudioMonoLabel(text: loc.t("now using"), size: 11, tracking: 0.9)
                    Text(v.name)
                        .font(S.sans(21, .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(S.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: StudioSpacing.s)
            }

            EqualizerBars(playing: voice.isPlaying, active: isActive && tabVisible)
                .padding(.top, 14)
                .accessibilityHidden(true)

            StudioHairline(color: S.rule2).padding(.top, 14)

            HStack(spacing: 0) {
                metric(loc.t("engine"), voice.currentEngineKind.displayName)
                metric(loc.t("locale"), localeLabel(v.locale))
                Spacer(minLength: 0)
                previewButton
            }
            .padding(.vertical, 13)
        }
        .padding(StudioSpacing.l)
        // The same raised-card treatment as the Home hero and the composer:
        // the one object on this page the user acts on.
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

    /// Mono label-over-value stack — the Home device-strip metric grammar.
    private func metric(_ label: String, _ value: String) -> some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 3) {
            StudioMonoLabel(text: label, size: 9, tracking: 1.0)
            Text(value)
                .font(S.mono(13, .medium))
                .foregroundStyle(S.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.trailing, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var previewButton: some View {
        let S = T.studio
        return Button {
            if let c = current { preview(c) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: voice.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(voice.isPlaying ? loc.t("Stop") : loc.t("Preview"))
                    .font(S.sans(13, .medium))
            }
            .foregroundStyle(S.paper)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(S.ink, in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                                    style: .continuous))
        }
        .buttonStyle(StudioPressStyle())
        .accessibilityLabel(voice.isPlaying ? loc.t("Stop preview") : loc.t("Preview voice"))
    }

    // MARK: - 3 · Talk
    //
    // The tab's primary action, in Home's create-row grammar: glyph tile,
    // title + subtitle, one filled button.

    private var talkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(loc.t("talk"))
            HStack(spacing: StudioSpacing.m) {
                glyphTile("waveform")
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("Start a voice conversation"))
                        .font(T.studio.sans(15, .medium))
                        .foregroundStyle(T.studio.ink)
                    Text(loc.t("Hands-free · listens and answers on device"))
                        .font(T.studio.sans(13))
                        .foregroundStyle(T.studio.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: StudioSpacing.s)
                StudioPrimaryButton(title: loc.t("Start"), action: startConversation)
                    .frame(width: 104)
            }
            .padding(.vertical, 12)
            StudioHairline(color: T.studio.rule2)
        }
    }

    private func startConversation() {
        HapticManager.impact(.medium)
        showConversation = true
    }

    // MARK: Engine row

    // Lets the user switch the speech engine (Apple System / KittenTTS /
    // Kokoro) — the library below shows that engine's voices. Opens the
    // existing one-tap engine picker.
    private var engineRow: some View {
        Button {
            HapticManager.impact(.light)
            showEnginePicker = true
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: StudioSpacing.m) {
                    glyphTile("slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc.t("Voice engine"))
                            .font(T.studio.sans(15, .medium))
                            .foregroundStyle(T.studio.ink)
                        StudioMonoLabel(text: voice.currentEngineKind.displayName,
                                        size: 11, tracking: 0.4)
                    }
                    Spacer(minLength: StudioSpacing.s)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(T.studio.chevron)
                }
                .padding(.vertical, 12)
                StudioHairline(color: T.studio.rule2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter row + search
    //
    // Studio chip grammar: hairline outline at rest, ink fill + paper text
    // when selected. The search field is a hairline-bounded field, not a card.

    private var filterRow: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(loc.t("library"))
            HStack(spacing: 6) {
                ForEach(Filter.allCases) { f in
                    let on = filter == f
                    Button {
                        HapticManager.impact(.light)
                        withAnimation(.easeOut(duration: 0.15)) { filter = f }
                    } label: {
                        Text(loc.t(f.label))
                            .font(S.sans(13, on ? .medium : .regular))
                            .foregroundStyle(on ? S.paper : S.ink3)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 32)
                            .background(
                                on ? S.ink : .clear,
                                in: RoundedRectangle(cornerRadius: StudioRadius.chip,
                                                      style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioRadius.chip,
                                                  style: .continuous)
                                    .strokeBorder(on ? S.ink : S.ink.opacity(0.14), lineWidth: 1)
                            )
                    }
                    .buttonStyle(StudioPressStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, StudioSpacing.m)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(S.ink3)
                TextField(loc.t("Search voices"), text: $query)
                    .font(S.sans(15))
                    .foregroundStyle(S.ink)
                    .tint(S.accent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(S.ink4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc.t("Clear search"))
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous)
                    .strokeBorder(S.ink.opacity(0.14), lineWidth: 1)
            )
        }
    }

    // MARK: - Library list

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filter == .cloned {
                clonedEmptyRow
            } else if filtered.isEmpty {
                emptyLibraryRow
            } else {
                ForEach(filtered, id: \.id) { v in
                    voiceRow(v, isCurrent: v.id == current?.id)
                }
            }
            cloneRow   // always the last row
        }
    }

    private func voiceRow(_ v: VoiceOption, isCurrent: Bool) -> some View {
        let S = T.studio
        return Button {
            preview(v)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: StudioSpacing.m) {
                    voiceThumbnail(v, isCurrent: isCurrent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(v.name)
                            .font(S.sans(15, isCurrent ? .medium : .regular))
                            .foregroundStyle(S.ink)
                            .lineLimit(1)
                        Text(voiceSubtitle(v))
                            .font(S.sans(13))
                            .foregroundStyle(S.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if isCurrent {
                        StudioMonoLabel(text: loc.t("in use"), size: 10, tracking: 0.5,
                                        color: S.ink2)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(S.ink4)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 12)
                StudioHairline(color: S.rule2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(v.name), \(voiceSubtitle(v))")
        .accessibilityHint(loc.t("Preview voice"))
    }

    // "Clone your voice" — Coming soon (big feature, no on-device backend yet)
    private var cloneRow: some View {
        let S = T.studio
        return Button {
            HapticManager.impact(.light)
            showCloneSoon = true
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: StudioSpacing.m) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(S.ink2)
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                              style: .continuous)
                                .strokeBorder(S.rule2, lineWidth: 1)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Clone your voice"))
                            .font(S.sans(15, .medium))
                            .foregroundStyle(S.ink)
                        Text(loc.t("Record 30s · trained on-device"))
                            .font(S.sans(13))
                            .foregroundStyle(S.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    StudioMonoLabel(text: loc.t("soon"), size: 10, tracking: 0.5)
                }
                .padding(.vertical, 12)
                StudioHairline(color: S.rule2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyLibraryRow: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            HStack(spacing: StudioSpacing.m) {
                glyphTile("waveform.slash")
                Text(loc.t("No voices match."))
                    .font(S.sans(15))
                    .foregroundStyle(S.ink2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            StudioHairline(color: S.rule2)
        }
    }

    private var clonedEmptyRow: some View {
        let S = T.studio
        return VStack(spacing: 0) {
            HStack(spacing: StudioSpacing.m) {
                glyphTile("mic.badge.plus")
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("No cloned voices yet"))
                        .font(S.sans(15))
                        .foregroundStyle(S.ink2)
                    Text(loc.t("Clone your voice to add one — coming soon."))
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

    // MARK: Reusable bits

    /// Mono eyebrow above a hairline — the section marker used throughout.
    private func sectionHeader(_ title: String) -> some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: StudioSpacing.s) {
            StudioMonoLabel(text: title, size: 11, tracking: 0.9)
            StudioHairline(color: S.rule2)
        }
        .padding(.bottom, 2)
    }

    private func glyphTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(T.studio.ink)
            .frame(width: 34, height: 34)
            .background(T.studio.fillActive,
                        in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                             style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: Helpers

    private func preview(_ v: VoiceOption) {
        HapticManager.impact(.light)
        // Tapping the voice that's CURRENTLY playing = stop. Tapping a
        // DIFFERENT voice switches to it (speak() stops any current playback
        // internally) — previously a tap while playing only stopped and never
        // selected the new voice, so selection silently failed mid-preview.
        if voice.isPlaying && v.id == settings.voiceID {
            voice.stop()
            return
        }
        settings.voiceID = v.id
        // Localize the TEMPLATE then interpolate — interpolating first made the
        // lookup key include the voice name, so it never matched a translation
        // and the phrase was always English.
        voice.speak(String(format: loc.t("Hi, I'm %@. This is how I sound."), v.name))
    }

    /// Identity tile for a voice row.
    ///
    /// A voice has no artwork to show, so the tile carries what it does have:
    /// its initial, plus the region code underneath so two voices sharing a
    /// letter stay distinguishable. The selected voice reads as ink + a
    /// hairline emphasis rather than an accent fill; unselected tiles sit on
    /// the quiet `fillActive` like every other glyph in the app.
    private func voiceThumbnail(_ v: VoiceOption, isCurrent: Bool) -> some View {
        let S = T.studio
        let shape = RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
        return VStack(spacing: 1) {
            Text(monogram(for: v))
                .font(S.mono(14, .semibold))
                .foregroundStyle(S.ink)
            Text(regionCode(v.locale))
                .font(S.mono(7, .medium))
                .tracking(0.4)
                .foregroundStyle(S.ink3)
        }
        .frame(width: 34, height: 34)
        .background(isCurrent ? S.ink.opacity(0.16) : S.fillActive, in: shape)
        .overlay(shape.strokeBorder(isCurrent ? S.ink.opacity(0.3) : .clear, lineWidth: 1))
        // The name and locale are already announced by the row's title and
        // subtitle; repeating them here would make VoiceOver read each row
        // twice.
        .accessibilityHidden(true)
    }

    /// First letter of the voice name, uppercased. Falls back to the engine's
    /// initial for an unnamed voice so the tile is never blank.
    private func monogram(for v: VoiceOption) -> String {
        let trimmed = v.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = trimmed.first(where: { $0.isLetter || $0.isNumber }) {
            return String(c).uppercased()
        }
        return String(v.engineKind.rawValue.prefix(1)).uppercased()
    }

    /// "en-US" -> "US", "fr" -> "FR". Region when present, language otherwise.
    private func regionCode(_ locale: String) -> String {
        let parts = locale.split(separator: "-")
        if parts.count >= 2 { return parts[1].uppercased() }
        return String(locale.prefix(2)).uppercased()
    }

    private func voiceSubtitle(_ v: VoiceOption) -> String {
        let desc = v.description?.isEmpty == false ? v.description! : ""
        let locale = localeLabel(v.locale)
        return [desc, locale].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func localeLabel(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: String(code.prefix(2)))
            ?? code
    }
}

// MARK: - EqualizerBars
// The hero's live meter. Monochrome ink bars at rest (Studio grammar: colour
// is reserved for state, and playback IS the state — the bars energise into
// the accent while a preview plays rather than cycling pink permanently).
// Uses TimelineView so it animates continuously while the Voice tab is on
// screen (SwiftUI pauses the timeline when the tab is hidden, so there's no
// background cost).
private struct EqualizerBars: View {
    var playing: Bool = false
    /// False when the Voice tab is offscreen — freezes the animation. iOS 18
    /// TabView keeps hidden tabs alive, so an always-on TimelineView(.animation)
    /// burned CPU/GPU/battery behind whatever tab the user was actually on.
    var active: Bool = true
    @Environment(\.koduTheme) private var T
    var body: some View {
        let S = T.studio
        let speed = playing ? 6.0 : 3.2
        let floor = playing ? 0.22 : 0.30
        let amp   = playing ? 0.78 : 0.55
        // ~24 fps when visible (vs .animation's 60–120 fps display link), and a
        // 1-hour schedule (effectively frozen) + static bars when offscreen.
        let schedule: PeriodicTimelineSchedule = active
            ? .periodic(from: Date(), by: 1.0 / 24.0)
            : .periodic(from: Date(), by: 3600)
        return TimelineView(schedule) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<13, id: \.self) { i in
                    let phase = Double(i) * 0.55
                    let h = active ? floor + amp * (0.5 + 0.5 * sin(t * speed + phase)) : 0.5
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(playing ? S.accent : S.ink.opacity(0.55))
                        .frame(width: 3, height: CGFloat(30 * h))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30, alignment: .center)
        }
    }
}
