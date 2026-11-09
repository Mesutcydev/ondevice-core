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
    @ObservedObject private var loc = LocalizationService.shared

    var body: some View {
        NavigationStack {
            List {
                    catalogSearch
                    catalogSections
                    hintCard

            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .navigationTitle("Voice engines")
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
            KPageTitle(title: "model catalog", size: 28)
            KMono(text: "all speech model families — unavailable runtimes remain visible",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private var catalogSections: some View {
        switch catalog.loadState {
        case .idle, .loading:
            ProgressView("Loading complete voice catalog…").padding(30)
        case .loaded, .failed:
            if catalog.loadState == .failed, let error = catalog.loadError {
                VStack(spacing: 8) {
                    Text(error).font(T.sans(11)).foregroundColor(T.bad)
                    Button("Retry") { catalog.load() }
                }.padding()
            }
            catalogSection(title: "text to speech", task: .textToSpeech)
            catalogSection(title: "speech recognition", task: .speechRecognition)
        }
    }

    private func catalogSection(title: String, task: VoiceCatalogTask) -> some View {
        let entries = visibleCatalogEntries.filter { $0.task == task }
        return Group {
            if !entries.isEmpty {
                KSection(title: title) {
                    ForEach(entries) { entry in
                        catalogCard(entry)
                        if entry.id != entries.last?.id {
                            Rectangle().fill(T.rule).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func catalogCard(_ entry: VoiceCatalogEntry) -> some View {
        let downloadable = entry.legacyDownloadID.flatMap(downloadModel)
        let inUse = isInUse(entry, model: downloadable)
        let rowStatus = status(entry, model: downloadable, inUse: inUse)
        return VStack(alignment: .leading, spacing: 9) {
            Button { selectedCatalogEntry = entry } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.task == .textToSpeech ? "waveform" : "mic")
                        .frame(width: 32, height: 32)
                        .foregroundColor(T.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(T.mono(13, .semibold)).foregroundColor(T.ink)
                        Text(entry.summary).font(T.sans(11)).foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([rowStatus.text, entry.sizeLabel].compactMap { $0 }.joined(separator: " · ").uppercased())
                            .font(T.mono(9, .semibold))
                            .foregroundColor(rowStatus.color)
                    }
                    Spacer()
                    Image(systemName: inUse ? "checkmark.circle.fill" : "info.circle")
                        .foregroundColor(inUse ? T.good : T.ink3)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows details")

            primaryAction(entry, model: downloadable, inUse: inUse)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityIdentifier("voiceCatalogCard.\(entry.id)")
    }

    @ViewBuilder
    private func primaryAction(_ entry: VoiceCatalogEntry, model: DownloadableModel?, inUse: Bool) -> some View {
        if inUse {
            StudioCompactSecondaryButton(title: "In use", enabled: false, height: 32) {}
        } else if entry.id == "tts.apple.system" {
            StudioCompactPrimaryButton(title: "Use", height: 32) { choose(.appleSystem, model: nil) }
        } else if entry.isDownloadEnabled, let model {
            switch model.state {
            case .ready:
                StudioCompactPrimaryButton(title: "Use", height: 32) { activate(entry, model: model) }
            case .downloading, .enumerating:
                StudioCompactSecondaryButton(title: "Downloading…", enabled: false, height: 32) {}
            case .paused:
                StudioCompactPrimaryButton(title: "Resume download", height: 32) { activate(entry, model: model) }
            case .idle, .failed:
                StudioCompactPrimaryButton(title: entry.sizeLabel.map { "Download \($0)" } ?? "Download", height: 32) {
                    downloadEntry = entry
                    downloadModelCandidate = model
                    confirmDownload = true
                }
            }
        } else {
            StudioCompactSecondaryButton(title: entry.statusLabel, enabled: false, height: 32) {}
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

    private func status(_ entry: VoiceCatalogEntry, model: DownloadableModel?, inUse: Bool) -> (text: String, color: Color) {
        if inUse { return ("In use", T.good) }
        if entry.id == "tts.apple.system" { return ("Built in", T.ink3) }
        guard entry.isDownloadEnabled, let model else { return (entry.statusLabel, T.warn) }
        switch model.state {
        case .ready: return ("Installed", T.ink2)
        case .downloading, .enumerating: return ("Downloading", T.accent)
        case .paused: return ("Paused", T.warn)
        case .failed: return ("Download failed", T.bad)
        case .idle: return ("Not downloaded", T.ink3)
        }
    }

    private func downloadModel(id: String) -> DownloadableModel? {
        center.models.first { $0.id == id }
    }

    private func primaryTitle(for model: DownloadableModel) -> String {
        switch model.state {
        case .ready: return "Select"
        case .downloading, .enumerating: return "Downloading…"
        case .paused: return "Resume"
        case .idle, .failed: return "Download"
        }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The voice's proper name — editorial content, so it gets
                    // the serif display face like every other named thing in
                    // the product (model names, voice names, session titles).
                    Text(entry.name).font(T.serif(24, .semibold)).foregroundColor(T.ink)
                    Text(entry.summary).font(T.sans(15)).foregroundColor(T.ink2)
                    LabeledContent("Task", value: entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition")
                    LabeledContent("Support", value: entry.statusLabel)
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Text("Open Project")
                                .font(T.sans(13, .medium))
                                .foregroundStyle(T.studio.ink)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
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
            .navigationTitle("Model Details")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
