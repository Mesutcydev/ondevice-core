import SwiftUI

// MARK: - VoiceModelPickerView
//
// THE single place to pick which engine reads replies aloud. Parallel to
// AssistantModelPickerView (chat tab) and VisualModelPickerView (camera tab).
//
// One-tap model. Tapping a row IS the whole interaction — there is no
// separate "download", "load engine", and "Done-to-commit" dance anymore:
//
//   • Apple System Voice — activates instantly (always on device).
//   • A neural engine already on disk + loaded — activates instantly.
//   • A neural engine on disk but not loaded / previously failed — the
//     tap loads it (retrying a failed load) and it activates when ready.
//   • A neural engine not yet downloaded — the tap starts the download
//     right here (no Models-tab round trip); VoiceService's
//     download-complete observer auto-loads it, and the row flips to
//     "active" on its own when the engine reports ready.
//
// Selection commits immediately to `AppSettings.voiceEngine` (+ a matching
// `voiceID`). While a freshly-picked engine is still downloading/loading,
// voice mode keeps reading through System Voice — VoiceService.resolvedEngine
// falls back automatically — so an in-progress pick never breaks playback.
// "Done" only dismisses.

struct VoiceModelPickerView: View {
    @ObservedObject private var voiceSettings = VoiceSettingsStore.shared
    @ObservedObject private var catalog = VoiceCatalogStore.shared

    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var voiceService = VoiceService.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @State private var query = ""
    @State private var selectedCatalogEntry: VoiceCatalogEntry?
    @State private var pendingEngine: VoiceEngineKind?
    @State private var pendingModel: DownloadableModel?
    @State private var pendingKittenVariant: KittenVariant?
    @State private var confirmInterruption = false
    @State private var downloadEntry: VoiceCatalogEntry?
    @State private var downloadModelCandidate: DownloadableModel?
    @State private var confirmDownload = false
    @State private var showUnavailable = false
    @ObservedObject private var loc = LocalizationService.shared

    var body: some View {
        NavigationStack {
            List {
                Group {
                    header
                    catalogSearch
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                catalogSections
                Group { hintCard }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .navigationTitle("")
            .background(StudioPageBackground())
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("Done")) { dismiss() }.foregroundColor(T.ink)
                }
            }
            .onAppear { center.refreshAllStates() }
            .onReceive(NotificationCenter.default.publisher(
                for: .hfModelDownloadCompleted)
            ) { _ in
                center.refreshAllStates()
            }
            .alert("End voice to change speech engine?", isPresented: $confirmInterruption) {
                Button("End voice and continue", role: .destructive) {
                    guard let kind = pendingEngine else { return }
                    let model = pendingModel
                    let variant = pendingKittenVariant
                    pendingEngine = nil
                    pendingModel = nil
                    pendingKittenVariant = nil
                    Task { @MainActor in
                        await VoiceConversationService.shared.stopAndRestoreSelection()
                        choose(kind, model: model, kittenVariant: variant)
                    }
                }
                Button("Keep voice conversation", role: .cancel) {
                    pendingEngine = nil
                    pendingModel = nil
                    pendingKittenVariant = nil
                }
            } message: {
                Text("This changes the speech engine used by the ongoing conversation.")
            }
            .confirmationDialog(
                downloadEntry.map { "Download \($0.name)?" } ?? "",
                isPresented: $confirmDownload, titleVisibility: .visible
            ) {
                Button(downloadEntry?.sizeLabel.map { "Download \($0)" } ?? "Download") {
                    if let entry = downloadEntry, let model = downloadModelCandidate { activate(entry, model: model) }
                    downloadEntry = nil
                    downloadModelCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    downloadEntry = nil
                    downloadModelCandidate = nil
                }
            } message: {
                Text("The model downloads once and then runs on this iPhone without a network connection.")
            }
            .sheet(item: $selectedCatalogEntry) { entry in
                VoiceCatalogDetailView(entry: entry)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "VOICE")
            KPageTitle(title: "Voice engines", size: 28)
            Text("Pick the voice that reads replies aloud, and models for hold-to-talk dictation.")
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var catalogSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(T.ink3)
            TextField("Search voice models", text: $query)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("voiceCatalogSearch")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Clear search") }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .kGlass(cornerRadius: StudioRadius.tile, fallbackFill: T.surface)
        .padding(.horizontal, 16)
    }

    private var visibleCatalogEntries: [VoiceCatalogEntry] {
        catalog.entries(query: query)
    }

    /// Runs on this iPhone: built in, or downloadable here.
    private func isUsable(_ entry: VoiceCatalogEntry) -> Bool {
        entry.id == "tts.apple.system" || entry.isDownloadEnabled
    }

    @ViewBuilder
    private var catalogSections: some View {
        switch catalog.loadState {
        case .idle, .loading:
            ProgressView("Loading voice catalog…").padding(30)
                .listRowBackground(Color.clear)
        case .loaded, .failed:
            if catalog.loadState == .failed, let error = catalog.loadError {
                VStack(spacing: 8) {
                    Text(error).font(T.sans(11)).foregroundColor(T.bad)
                    Button("Retry") { catalog.load() }
                }
                .padding()
                .listRowBackground(Color.clear)
            }
            engineSection(title: "Text to speech", task: .textToSpeech)
            engineSection(title: "Speech recognition", task: .speechRecognition)
            unavailableSection
        }
    }

    @ViewBuilder
    private func engineSection(title: String, task: VoiceCatalogTask) -> some View {
        let entries = visibleCatalogEntries.filter { $0.task == task && isUsable($0) }
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    engineCard(entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            } header: {
                KCaption(text: title.uppercased())
            }
        }
    }

    /// Families that can't run on this iPhone (catalog only, Mac only,
    /// license review) stay out of the way in one collapsed group; a search
    /// opens it.
    @ViewBuilder
    private var unavailableSection: some View {
        let entries = visibleCatalogEntries.filter { !isUsable($0) }
        if !entries.isEmpty {
            Section {
                DisclosureGroup(isExpanded: Binding(
                    get: { showUnavailable || !query.isEmpty },
                    set: { showUnavailable = $0 }
                )) {
                    ForEach(entries) { entry in
                        Button { selectedCatalogEntry = entry } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(T.sans(14, .medium)).foregroundColor(T.ink)
                                    Text(entry.statusLabel).font(T.sans(11)).foregroundColor(T.ink3)
                                }
                                Spacer()
                                Image(systemName: "info.circle").foregroundColor(T.ink3)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows details")
                    }
                } label: {
                    Text("More models · \(entries.count)")
                        .font(T.sans(14, .medium))
                        .foregroundColor(T.ink2)
                }
            } header: {
                KCaption(text: "UNAVAILABLE ON IPHONE")
            }
        }
    }

    private func engineCard(_ entry: VoiceCatalogEntry) -> some View {
        let model = entry.legacyDownloadID.flatMap(downloadModel)
        let inUse = isInUse(entry, model: model)
        let note = badge(entry, model: model, inUse: inUse)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Button { cardTapped(entry, model: model, inUse: inUse) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                                .fill(inUse ? T.accent : T.accentSoft)
                            Image(systemName: inUse ? "checkmark" : (entry.task == .textToSpeech ? "waveform" : "mic"))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(inUse ? T.bg : T.accent)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 6) {
                                Text(entry.name)
                                    .font(T.sans(17, .semibold))
                                    .foregroundColor(T.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if inUse { KActivePill(text: "in use") }
                                if entry.supportLevel == .experimental { KTag(text: "experimental", size: 9) }
                            }
                            Text(entry.summary)
                                .font(T.sans(12))
                                .foregroundColor(T.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let note {
                                Text(note.text.uppercased())
                                    .font(T.mono(9, .semibold))
                                    .tracking(0.4)
                                    .foregroundColor(note.color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(tapHint(entry, model: model, inUse: inUse))

                Button { selectedCatalogEntry = entry } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17))
                        .foregroundColor(T.ink3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(entry.name)")
            }
            cardFooter(entry, model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                .stroke(inUse ? T.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .accessibilityIdentifier("voiceCatalogCard.\(entry.id)")
    }

    /// Only when there is something to do or watch: a download (asks
    /// first), its progress, or a retry.
    @ViewBuilder
    private func cardFooter(_ entry: VoiceCatalogEntry, model: DownloadableModel?) -> some View {
        if entry.isDownloadEnabled, let model {
            switch model.state {
            case .downloading, .enumerating:
                HStack(spacing: 10) {
                    ProgressView(value: model.progress).tint(T.accent)
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(T.mono(11, .semibold))
                        .foregroundColor(T.ink2)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Downloading \(Int((model.progress * 100).rounded())) percent")
            case .paused:
                StudioCompactPrimaryButton(title: "Resume download", height: 34) { activate(entry, model: model) }
            case .failed:
                StudioCompactPrimaryButton(title: "Retry download", height: 34) { activate(entry, model: model) }
            case .idle:
                StudioCompactPrimaryButton(title: entry.sizeLabel.map { "Download \($0)" } ?? "Download", height: 34) {
                    askToDownload(entry, model: model)
                }
            case .ready:
                EmptyView()
            }
        }
    }

    private func askToDownload(_ entry: VoiceCatalogEntry, model: DownloadableModel) {
        downloadEntry = entry
        downloadModelCandidate = model
        confirmDownload = true
    }

    /// Built in or downloaded: use it. Not downloaded: ask, then download.
    /// Otherwise (in use, downloading): details.
    private func cardTapped(_ entry: VoiceCatalogEntry, model: DownloadableModel?, inUse: Bool) {
        if inUse { selectedCatalogEntry = entry; return }
        if entry.id == "tts.apple.system" { choose(.appleSystem, model: nil); return }
        guard entry.isDownloadEnabled, let model else { selectedCatalogEntry = entry; return }
        switch model.state {
        case .ready, .paused, .failed: activate(entry, model: model)
        case .idle: askToDownload(entry, model: model)
        case .downloading, .enumerating: selectedCatalogEntry = entry
        }
    }

    private func tapHint(_ entry: VoiceCatalogEntry, model: DownloadableModel?, inUse: Bool) -> String {
        if inUse { return "In use. Shows details." }
        if entry.id == "tts.apple.system" || model?.state == .ready { return "Uses this model." }
        if model?.state == .idle { return "Asks before downloading." }
        return "Shows details."
    }

    /// A status line only where it adds information; the footer covers
    /// downloads in progress and not-yet-downloaded models.
    private func badge(_ entry: VoiceCatalogEntry, model: DownloadableModel?, inUse: Bool) -> (text: String, color: Color)? {
        if inUse { return nil }
        if entry.id == "tts.apple.system" { return ("Built in · no download", T.ink3) }
        guard let model else { return nil }
        switch model.state {
        case .ready: return (["Downloaded", entry.sizeLabel].compactMap { $0 }.joined(separator: " · "), T.good)
        case .paused: return ("Download paused", T.warn)
        case .failed: return ("Download failed", T.bad)
        case .idle, .downloading, .enumerating: return nil
        }
    }

    /// Hold-to-talk provider for a speech-recognition entry. Conversations
    /// always use Apple's streaming recognizer.
    private static func sttProvider(for entry: VoiceCatalogEntry) -> String? {
        if entry.id.hasPrefix("stt.whisper") { return "whisper" }
        if entry.id.hasPrefix("stt.parakeet") { return "parakeet" }
        if entry.id.hasPrefix("stt.nemotron") { return "nemotron" }
        return nil
    }

    /// The row the app actually uses. Whisper sizes share one provider (the
    /// best installed file wins), so no single Whisper row is marked.
    private func isInUse(_ entry: VoiceCatalogEntry, model: DownloadableModel?) -> Bool {
        if entry.id == "tts.apple.system" { return voiceSettings.selectedEngine == .appleSystem }
        if let variant = KittenVariant(rawValue: entry.id) {
            return voiceSettings.selectedEngine == .kittenTTS
                && voiceSettings.selectedKittenVariant == variant
                && model?.state == .ready
        }
        if let model, let kind = LocalModelRegistry.voiceEngine(for: model) {
            return voiceSettings.selectedEngine == kind && model.state == .ready
        }
        if let provider = Self.sttProvider(for: entry), provider != "whisper" {
            return settings.sttProvider == provider && model?.state == .ready
        }
        return false
    }

    private func downloadModel(id: String) -> DownloadableModel? {
        center.models.first { $0.id == id }
    }

    private func activate(_ entry: VoiceCatalogEntry, model: DownloadableModel) {
        if let variant = KittenVariant(rawValue: entry.id) {
            // Catalog ids are the variant raw values. Selecting only the
            // engine kept the old variant, so voice could load a different
            // (maybe undownloaded) one and quietly fall back to Apple Voice.
            choose(.kittenTTS, model: model, kittenVariant: variant)
        } else if let kind = LocalModelRegistry.voiceEngine(for: model) {
            choose(kind, model: model)
        } else {
            // Speech recognition: committed now so the finished download is
            // used for hold-to-talk; "Use" on an installed model used to do nothing.
            if let provider = Self.sttProvider(for: entry) { settings.sttProvider = provider }
            if model.state != .ready { model.start() }
        }
    }

    // MARK: - One-tap action

    private func choose(_ kind: VoiceEngineKind, model: DownloadableModel?, kittenVariant: KittenVariant? = nil) {
        if VoiceConversationService.shared.hasSession {
            pendingEngine = kind
            pendingModel = model
            pendingKittenVariant = kittenVariant
            confirmInterruption = true
            return
        }
        HapticManager.impact(.light)

        // Commit immediately. VoiceService.resolvedEngine falls back to
        // System until this engine is actually ready, so selecting one
        // that's still downloading/loading never breaks playback — and the
        // download-complete observer keys off `voiceEngine`, so we must set
        // it BEFORE kicking the download.
        if let kittenVariant {
            // A loaded Kitten keeps its variant until unloaded.
            if voiceSettings.selectedKittenVariant != kittenVariant { voiceService.unloadAll() }
            voiceSettings.selectKittenVariant(kittenVariant)
        } else {
            voiceSettings.selectEngine(kind)
        }
        let voices = voiceList(for: kind)
        if !voices.contains(where: { $0.id == settings.voiceID }),
           let first = voices.first {
            let chosen = kind == .appleSystem
                ? voiceService.systemEngine.upgradedVoice(for: first)
                : first
            settings.voiceID = chosen.id
        } else if kind == .appleSystem,
                  let current = voices.first(where: { $0.id == settings.voiceID }) {
            let upgraded = voiceService.systemEngine.upgradedVoice(for: current)
            if upgraded.id != current.id {
                settings.voiceID = upgraded.id
            }
        }

        guard kind != .appleSystem else { return }   // always ready

        if !filesPresent(for: kind) {
            // Not downloaded → start it here. The download-complete
            // observer auto-loads the now-preferred engine.
            model?.start()
        } else if case .failed = engineState(for: kind) {
            // On disk but the last load failed → clear and retry.
            voiceService.unloadAll()
            Task { await voiceService.load() }
        } else if engineState(for: kind) != .ready {
            // On disk, just not loaded into memory yet.
            Task { await voiceService.load() }
        }
    }

    // MARK: - Helpers

    private func filesPresent(for kind: VoiceEngineKind) -> Bool {
        switch kind {
        case .appleSystem: return true
        case .kittenTTS:   return VoiceModelBundleValidator.isKittenTTSAvailable()
        case .kokoro:      return VoiceModelBundleValidator.isKokoroAvailable()
        case .lfm3Omni:    return LFM3Catalog.isEnabled && LFM3Catalog.omniRuntimeAvailable
        case .supertonic:  return VoiceModelBundleValidator.isSupertonicAvailable()
        case .paradee:  return VoiceModelBundleValidator.isParadeeAvailable()
        }
    }

    private func engineState(for kind: VoiceEngineKind) -> VoiceModelState {
        switch kind {
        case .appleSystem: return voiceService.systemState
        case .kittenTTS:   return voiceService.kittenState
        case .kokoro:      return voiceService.kokoroState
        case .lfm3Omni:    return voiceService.omniState
        case .supertonic:  return voiceService.supertonicState
        case .paradee:  return voiceService.paradeeState
        }
    }

    private func voiceList(for kind: VoiceEngineKind) -> [VoiceOption] {
        switch kind {
        case .appleSystem: return voiceService.systemEngine.availableVoices
        case .kittenTTS:   return KittenTTSService.kittenVoices
        case .kokoro:      return KokoroTTSService.kokoroVoices
        case .lfm3Omni:    return OmniVoiceEngine.voices
        case .supertonic:  return SupertonicTTSService.supertonicVoices
        case .paradee:  return ParadeeTTSService.paradeeVoices
        }
    }

    // MARK: - Hint

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("tip")
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.ink3)
            Text("Apple System Voice ships with iOS premium voices and works offline out of the box — it's the most reliable choice. On-device neural voices (KittenTTS, Kokoro) are smaller English voices that some people prefer; if one ever fails its self-check, the app reads replies through System Voice automatically. Pick the specific voice and speed in Voice settings. Speech recognition models here are for hold-to-talk dictation; voice conversations always use Apple's on-device recognizer.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: StudioRadius.tile, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

}

struct VoiceCatalogDetailView: View {
    let entry: VoiceCatalogEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @ObservedObject private var loc = LocalizationService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        KCaption(text: entry.task == .textToSpeech ? "TEXT TO SPEECH" : "SPEECH RECOGNITION")
                        // The model's proper name gets the serif display face
                        // like every other named thing in the product.
                        Text(entry.name).font(T.serif(24, .semibold)).foregroundColor(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.summary).font(T.sans(15)).foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    VStack(spacing: 0) {
                        detailRow("Task", entry.task == .textToSpeech ? "Text to speech" : "Speech recognition")
                        Rectangle().fill(T.rule).frame(height: 1)
                        detailRow("Support", entry.statusLabel)
                        Rectangle().fill(T.rule).frame(height: 1)
                        detailRow("Storage", entry.sizeLabel ?? (entry.id == "tts.apple.system" ? "Built in" : "—"))
                    }
                    .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface)
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label("Open Project", systemImage: "arrow.up.right.square")
                                .font(T.sans(13, .semibold))
                                .foregroundStyle(T.studio.ink)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudioRadius.action, style: .continuous)
                                        .strokeBorder(T.studio.rule2, lineWidth: 1)
                                )
                        }
                        .buttonStyle(StudioPressStyle())
                    }
                }
                .padding(20)
            }
            .background(StudioPageBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(loc.t("Done")) { dismiss() } }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(T.sans(13)).foregroundColor(T.ink3)
            Spacer()
            Text(value).font(T.sans(13, .medium)).foregroundColor(T.ink).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
