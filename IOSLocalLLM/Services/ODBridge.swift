import Combine
import Foundation
import SwiftUI
import OnDeviceUI

// MARK: - ODBridge
//
// The single adapter between the OnDeviceUI presentation layer and this app's
// real services. One `ODStore` lives here, on the main actor, and every
// `ODAction` is dispatched into an existing service or route.
//
// Rules this file exists to enforce:
//
//   • The runtime is the source of truth. Snapshots are published FROM
//     services; the UI never assumes an action succeeded. `loadModel` starts
//     a load, it does not set `.ready`.
//   • Selection and residency are distinct. `selectedModelID` is what the
//     user picked; `loadedModelID` is what is actually in memory. They differ
//     while preparing, and the Models screen reads both.
//   • Capabilities reflect real availability, so a control is enabled only
//     when the operation behind it can actually run.
//   • Nothing starts because a view was constructed. Camera, audio and
//     inference lifecycles stay owned by the host exactly as before.
//
// Navigation is injected as `routes` by ContentView, which still owns the
// sheets and covers. The bridge does not present anything itself.

@MainActor
final class ODBridge: ObservableObject {
    static let shared = ODBridge()

    let store = ODStore(appearanceDefaults: nil)
    var chatAction: ((ODAction) -> Void)?
    var routesInstalled = false
    private var previewVoiceID: String?
    private var startingVoice = false
    private var voiceStartTask: Task<Void, Never>?

    /// Host-owned navigation. ContentView fills these in; the bridge only
    /// calls them. Keeping presentation out of here means the adapter never
    /// competes with the app's existing sheet/cover state.
    struct Routes {
        var openSettings: () -> Void = {}
        var openModelPicker: () -> Void = {}
        var openModelsTab: () -> Void = {}
        var openDiscovery: () -> Void = {}
        var importModel: () -> Void = {}
        var showModelDownloads: () -> Void = {}
        var openCoreAIPacks: () -> Void = {}
        var manageStorage: () -> Void = {}
        var openImageGeneration: () -> Void = {}
        var openHistory: () -> Void = {}
        var openMacBridge: () -> Void = {}
        var openConversation: (UUID) -> Void = { _ in }
        var startNewChat: () -> Void = {}
        var quickStart: (ODQuickAction) -> Void = { _ in }
        var addAttachment: () -> Void = {}
        var selectEngine: () -> Void = {}
        var cancelLensAnalysis: () -> Void = {}
        var selectAudioRoute: () -> Void = {}
        var beginVoiceSession: () -> Void = {}
        var endVoiceSession: () -> Void = {}
        var analyzeLens: () -> Void = {}
        var retakeLens: () -> Void = {}
        var capture: (ODLensMode, String) -> Void = { _, _ in }
        var openPhotoLibrary: () -> Void = {}
        var switchCamera: () -> Void = {}
        var openCameraSettings: () -> Void = {}
        var showLensOptions: () -> Void = {}
        var showLensHistory: () -> Void = {}
        var selectLensModel: () -> Void = {}
        var modelCommand: (String, ODModelCommand) -> Void = { _, _ in }
    }

    var routes = Routes()

    private var bag = Set<AnyCancellable>()
    private var refreshScheduled = false

    // Change signatures. `refresh()` runs on every service notification — and
    // during a generation `CodingAssistantService` notifies per token — so the
    // expensive collections are only rebuilt when their source actually
    // changed. Without this, a streaming reply rebuilt 35 models, 54 voices and
    // scanned every stored conversation on every runloop turn.
    private var modelsSignature = ""
    private var voicesSignature = ""
    private var conversationsSignature = ""

    // Free space needs a filesystem stat. Re-running it per token is wasteful
    // and the number cannot meaningfully change that fast.
    private var diskFreeCache: Int64?
    private var lensInstallSignature = ""
    private var diskFreeStamp: Date = .distantPast
    private static let diskFreeInterval: TimeInterval = 5

    private init() {
        // The store holds the closure; the closure must not hold the store's
        // owner strongly or the pair never deallocates.
        store.onAction = { [weak self] action in
            self?.handle(action)
        }
        store.endVoiceBeforeOperation = { [weak self] operation in
            guard let self else { return }
            self.voiceStartTask?.cancel()
            self.voiceStartTask = nil
            self.startingVoice = false
            self.store.voiceSessionPresented = false
            Task { @MainActor [weak self] in
                await VoiceConversationService.shared.stopAndRestoreSelection()
                guard let self else { return }
                self.refresh()
                self.store.requestExclusiveOperation(self.store.interruptionReason, perform: operation)
            }
        }
        observeServices()
        refresh()
    }

    // MARK: - Observation

    /// Mirror the services the six screens read. Each `objectWillChange` is
    /// coalesced into one refresh per runloop turn so a streaming generation
    /// does not republish the whole snapshot per token.
    private func observeServices() {
        let publishers: [ObservableObjectPublisher] = [
            CodingAssistantService.shared.objectWillChange,
            ModelDownloadCenter.shared.objectWillChange,
            CoreAIModelStore.shared.objectWillChange,
            ConversationStore.shared.objectWillChange,
            VoiceService.shared.objectWillChange,
            VoiceSettingsStore.shared.objectWillChange,
            VoiceConversationService.shared.objectWillChange,
            VoiceAudioSessionManager.shared.objectWillChange,
            AppSettings.shared.objectWillChange,
            ImageGenerationService.shared.objectWillChange,
            PersonaStore.shared.objectWillChange,
        ]
        for publisher in publishers {
            publisher
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &bag)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    // MARK: - Snapshot

    /// Publish the app's real state onto the presentation store.
    func refresh() {
        let assistant = CodingAssistantService.shared
        let center = ModelDownloadCenter.shared
        let coreAIInstallations = CoreAIModelStore.shared.installations
        let loc = LocalizationService.shared

        store.appearance = ODAppearancePreference(rawValue: AppSettings.shared.appearance)
            ?? .system
        store.appSubtitle = loc.t("Your private AI workspace")
        store.editionLabel = "MAX"
        store.executionLabel = assistant.activeExecutionLocation == .applePrivateCloud
            ? loc.t("Private Cloud")
            : loc.t("On-device")

        // ── Models ───────────────────────────────────────────────────────
        let modelsSig = center.models
            .map { "\($0.id):\($0.state):\($0.progress):\($0.totalBytes):\($0.declaredCategories.contains(.assistant)):\($0.declaredCategories.contains(.vlm)):\($0.supportsCategory(.assistant)):\($0.supportsCategory(.vlm))" }
            .joined(separator: "|") + "#" + coreAIInstallations
            .map { "\($0.assistantSelectionID):\($0.manifest.version):\($0.manifest.totalDownloadBytes)" }
            .joined(separator: "|") + "#\(assistant.activeSelectionID)#\(AppSettings.shared.assistantModelID)#\(assistant.canGenerateSelectedTarget)"
        if modelsSig != modelsSignature {
            modelsSignature = modelsSig
            store.models = center.models.map { model in
                let interrupted = model.state == .idle
                    && model.downloader?.hasResumableDownloadReceipt == true
                let supportedKinds = Self.supportedKinds(for: model)
                let unsupported = model.isReady && supportedKinds.isEmpty
                    ? model.downloader.flatMap {
                        LocalModelRegistry.unsupportedTextRuntimeReason(in: $0.destination)
                            ?? LocalModelRegistry.unsupportedVisionRuntimeReason(in: $0.destination)
                    } : nil
                let unavailable = unsupported
                    ?? (model.platformCompatibility?.supportsCurrentPlatform == false
                        ? model.platformCompatibility?.detail : nil)
                return ODModel(
                    id: model.id,
                    name: model.displayName,
                    metadata: model.subtitle,
                    byteCount: model.totalBytes > 0 ? model.totalBytes : nil,
                    kind: Self.kind(for: model),
                    supportedKinds: supportedKinds,
                    declaredKinds: Self.declaredKinds(for: model),
                    isInstalled: model.isReady,
                    isDefault: model.supportsCategory(.assistant)
                        && LocalModelRegistry.assistantSelectionID(for: model) == AppSettings.shared.assistantModelID,
                    isSelectable: unavailable == nil && !supportedKinds.isEmpty,
                    unavailableReason: unavailable,
                    availableCommands: [.details, .configure] + (model.isReady ? [.delete] : [])
                        + (model.isReady && model.downloader?.destination != nil ? [.export] : [])
                        + (model.state.isActive ? [.pauseDownload, .cancelDownload] : [])
                        + (model.state == .paused ? [.download, .cancelDownload] : [])
                        + (!model.isReady && !model.state.isActive && model.state != .paused && model.downloader != nil ? [.download] : []),
                    downloadStatus: {
                        switch model.state {
                        case .paused: return "Paused"
                        case .enumerating: return "Preparing download"
                        case .downloading: return "Downloading"
                        case .failed: return "Download failed"
                        case .idle:
                            return interrupted ? "Interrupted" : nil
                        case .ready: return nil
                        }
                    }(),
                    downloadProgress: model.state == .downloading || model.state == .paused
                        || interrupted
                        ? (model.progress.isFinite ? min(1, max(0, model.progress)) : nil)
                        : nil,
                    estimatedMemoryBytes: model.approxRAMBytes.flatMap { $0 > 0 ? $0 : nil },
                    isDownloadPaused: model.state == .paused || interrupted,
                    summary: model.longDescription ?? Self.modelSummary(for: model),
                    vendor: model.vendor.rawValue,
                    badges: Self.modelBadges(for: model),
                    downloadSizeLabel: model.sizeLabel
                )
            }
            store.models += coreAIInstallations.map { installed in
                let catalog = CoreAIZooCatalog.model(forSelectionID: installed.assistantSelectionID)
                let isChatModel = installed.assistantModel != nil
                let kind: ODModelKind
                switch catalog?.category {
                case .vision: kind = .vision
                case .utility: kind = .utility
                case .officialRecipe, .chat: kind = .language
                case nil: kind = isChatModel ? .language : (installed.manifest.capabilities.imageInput ? .vision : .utility)
                }
                return ODModel(
                    id: installed.assistantSelectionID,
                    name: installed.manifest.displayName,
                    metadata: "Core AI · installed on this device",
                    byteCount: installed.manifest.totalDownloadBytes > 0 ? installed.manifest.totalDownloadBytes : nil,
                    kind: kind,
                    isDefault: isChatModel && installed.assistantSelectionID == AppSettings.shared.assistantModelID,
                    isSelectable: isChatModel,
                    availableCommands: [.details],
                    estimatedMemoryBytes: installed.assistantModel?.approxRAMBytes,
                    summary: catalog?.subtitle ?? "On-device Core AI pack",
                    vendor: installed.manifest.modelFamily,
                    badges: isChatModel ? ["Core AI"] : ["Core AI", kind.title]
                )
            }
        }

        // Selection is the user's pick; residency is what the runtime holds.
        // They are deliberately different values and the Models screen shows
        // both, so neither may be derived from the other.
        let activePresentationID = center.models.first {
            $0.supportsCategory(.assistant) && LocalModelRegistry.assistantSelectionID(for: $0) == assistant.activeSelectionID
        }?.id ?? assistant.activeSelectionID
        if !store.models.contains(where: { $0.id == activePresentationID }) {
            store.models.append(ODModel(id: activePresentationID, name: assistant.activeDisplayName,
                metadata: assistant.activeExecutionLocation == .applePrivateCloud ? "Apple Private Cloud" : "Selected assistant",
                kind: .language, isInstalled: assistant.canGenerateSelectedTarget,
                isDefault: assistant.activeSelectionID == AppSettings.shared.assistantModelID,
                availableCommands: [.configure], isLibraryEntry: false))
        }
        store.selectedModelID = activePresentationID
        // The composer's reasoning switch exists only when the local model's
        // own template reads it; the value is the per-model/app preference.
        store.thinkingEnabled = assistant.activeExecutionLocation != .applePrivateCloud
            && assistant.activeThinkingSwitch
            ? assistant.effectiveGenerationSettings.thinkingEnabled : nil
        // Refresh runs per token while streaming; publish only real changes.
        let personaStore = PersonaStore.shared
        let personas = personaStore.personas.map {
            ODPersona(id: $0.id, name: $0.name, subtitle: $0.subtitle, symbol: $0.icon)
        }
        if store.personas != personas { store.personas = personas }
        if store.selectedPersonaID != personaStore.active.id {
            store.selectedPersonaID = personaStore.active.id
        }
        store.loadedModelID = Self.isResident(assistant.state) ? activePresentationID : nil
        store.modelPhase = Self.phase(for: assistant)

        // ── Metrics — measured, never invented ───────────────────────────
        store.metrics = ODDeviceMetrics(
            memoryLabel: Self.memoryLabel(),
            thermalLabel: Self.thermalLabel(loc),
            modelStorageBytes: center.totalStorageUsed + coreAIInstallations.reduce(0) { $0 + max(0, $1.manifest.totalDownloadBytes) },
            diskFreeBytes: cachedDiskFree(),
            diskTotalBytes: Self.totalDiskBytes
        )

        // ── Conversations ────────────────────────────────────────────────
        let allConversations = ConversationStore.shared.conversations
        let convSig = "\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)#\(allConversations.count)#"
            + allConversations.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970):\($0.isPinned == true)" }.joined(separator: "|")
        if convSig != conversationsSignature {
            conversationsSignature = convSig
            store.recentConversations = allConversations
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { convo in
                    ODRecentConversation(
                        id: convo.id.uuidString,
                        title: convo.title.isEmpty ? loc.t("Untitled") : convo.title,
                        subtitle: Self.lastLine(convo) ?? "",
                        dateLabel: ODPresentation.conversationDate(convo.updatedAt),
                        isPinned: convo.isPinned ?? false
                    )
                }
        }

        // ── Voice ────────────────────────────────────────────────────────
        let voice = VoiceService.shared
        let voiceSettings = VoiceSettingsStore.shared
        // `availableVoicesForCurrentEngine` enumerates the system voice table,
        // so it is not something to call per token either.
        let engineKey = voice.currentEngineKind.rawValue
        if engineKey != voicesSignature {
            voicesSignature = engineKey
            store.voices = voice.availableVoicesForCurrentEngine.map { option in
                ODVoice(
                    id: option.id,
                    name: option.name,
                    locale: Self.regionLabel(option.locale),
                    language: Self.languageLabel(option.locale)
                )
            }
        }
        store.selectedVoiceID = voiceSettings.selectedVoiceID
        store.voiceEngineName = voice.currentEngineKind.displayName
        store.voicePreviewID = voice.isPlaying ? previewVoiceID : nil
        if !voice.isPlaying { previewVoiceID = nil }

        let conversation = VoiceConversationService.shared
        store.voicePhase = (startingVoice || conversation.isStarting) ? .preparing : conversation.isInterrupted ? .interrupted : Self.voicePhase(conversation.phase)
        // Existence, not presentation. Minimising must not end the session and
        // returning must not start a second one, so `voiceSessionPresented` is
        // owned by the UI and only cleared when the runtime really ends.
        let sessionRunning = conversation.hasSession
        store.voiceSessionActive = sessionRunning
        if !sessionRunning && conversation.phase == .idle && !startingVoice { store.voiceSessionPresented = false }

        store.speakerEnabled = AppSettings.shared.voiceAnswerEnabled
        store.microphoneEnabled = sessionRunning && !conversation.microphoneMuted
        store.microphoneCapturing = conversation.isCapturingInput
        store.voiceTranscript = conversation.presentationMessages.map {
            ODMessage(id: $0.id, role: $0.role == .user ? .user : .assistant, text: $0.content)
        }
        // Not resident does not mean not installed. Start performs the existing
        // engine load and permission preflight; do not mislabel a cold engine.
        let preferredVoiceState: VoiceModelState = switch voiceSettings.selectedEngine {
        case .appleSystem: .ready
        case .kittenTTS: voice.kittenState
        case .kokoro: voice.kokoroState
        }
        switch preferredVoiceState {
        case .ready: store.voiceAvailabilityMessage = nil
        case .unloaded:
            store.voiceAvailabilityMessage = "Start to prepare your voice engine. Manage its download in Voice setup."
        case .loading:
            store.voiceAvailabilityMessage = "Preparing your selected voice engine."
        case .failed:
            store.voiceAvailabilityMessage = "The voice engine couldn’t load. Start to retry, or check Voice setup."
        }
        store.audioRouteName = VoiceAudioSessionManager.shared.route.displayName

        // ── Lens ─────────────────────────────────────────────────────────
        store.lensModelName = Self.lensModelName(loc)
        let visionID = AppSettings.shared.cameraVisualModelID
        let selectedVision = center.models.first { $0.id == visionID || $0.sourceRepoID == visionID }
        let lensSignature = "\(visionID)#\(modelsSig)"
        if lensSignature != lensInstallSignature {
            lensInstallSignature = lensSignature
            // FastVLM requires both decoder weights and its separate Core ML encoder.
            // Installation is independent from whether the runtime has been loaded.
            if LocalModelRegistry.isDefaultVisionSelection(visionID) {
                let installation = FastVLMService.installStatus()
                store.lensModelInstalled = installation.isFullyInstalled
                store.lensModelStatus = installation.isFullyInstalled
                    ? "Installed vision model" : "FastVLM · \(installation.shortLabel)"
            } else {
                // Use the same strict per-backend runnability check the
                // vision picker uses. `DownloadableModel.isReady` only
                // reflects the HF downloader's own file heuristic, so a
                // staged GGUF pair (or any layout the downloader reads
                // differently) showed "active" in the picker while Lens
                // still claimed no model was installed.
                let runStatus = selectedVision.map { VisualModelInstallStatus.runStatus(for: $0) }
                store.lensModelInstalled = runStatus?.isReady == true
                if store.lensModelInstalled {
                    store.lensModelStatus = "Installed vision model"
                } else if case .partial(let why) = runStatus {
                    store.lensModelStatus = why
                } else {
                    store.lensModelStatus = "Vision model required · Choose a model"
                }
            }
        }

        let imageService = ImageGenerationService.shared
        store.imageResultURL = imageService.resultURL
        store.imageResultPrompt = imageService.resultPrompt
        store.selectedImageModelID = imageService.selectedModelID
        if imageService.isWorking {
            store.imagePhase = .generating(step: imageService.statusMessage)
        } else if case .failed(let message) = imageService.state {
            store.imagePhase = .failed(message: message)
        } else {
            store.imagePhase = .idle
        }

        // ── Capabilities — real availability only ────────────────────────
        var caps = ODCapabilities()
        caps.canGenerateImages = routesInstalled && !imageService.isWorking
        caps.canCancelImageGeneration = imageService.isWorking && !imageService.isCancelling
        caps.canManageStorage = routesInstalled
        caps.canConfigureApp = routesInstalled
        caps.canSelectLensModel = routesInstalled
        caps.canMinimizeVoiceSession = true
        caps.canControlMicrophone = true
        caps.canControlSpeaker = true
        caps.canStopGeneration = chatAction != nil
        caps.canRemoveAttachments = chatAction != nil
        caps.canSendAttachments = chatAction != nil && assistant.canGenerateSelectedTarget
        caps.canLoadModels = routesInstalled && !center.models.isEmpty
        caps.canSendMessages = chatAction != nil && assistant.canGenerateSelectedTarget
        caps.canAddAttachments = chatAction != nil
        caps.canStartVoice = routesInstalled && !store.voices.isEmpty && !startingVoice
        caps.canPreviewVoices = !store.voices.isEmpty && !sessionRunning
        caps.canSelectEngine = routesInstalled
        // AVRoutePickerView can only be presented by its own tap; there is no
        // programmatic entry. The route is shown as state, not offered as a
        // control that would do nothing.
        caps.canSelectAudioRoute = false
        // A still can be reviewed before choosing/installing its analysis model.
        caps.canCapture = routesInstalled && !store.cameraNeedsSettings && !store.lensIsAnalyzing
        caps.canCancelLensAnalysis = routesInstalled && store.lensIsAnalyzing
        caps.canChoosePhoto = routesInstalled && !store.lensIsAnalyzing
        // No front/back flip exists in CameraService; the affordance stays
        // disabled rather than appearing and doing nothing.
        caps.canSwitchCamera = false
        caps.canConfigureLens = routesInstalled
        caps.canViewLensHistory = routesInstalled
        caps.canShowHistory = routesInstalled && !ConversationStore.shared.conversations.isEmpty
        caps.canPinConversations = routesInstalled
        caps.canOpenMacBridge = false
        caps.canOpenAPIServer = routesInstalled
        caps.modelCommands = [.details, .configure, .export, .delete]
        store.capabilities = caps
    }

    /// Closing a session while permission or engine preparation is pending
    /// must not leave a later task free to open the microphone.
    func cancelPendingVoiceStart() {
        guard startingVoice else { return }
        voiceStartTask?.cancel()
        voiceStartTask = nil
        startingVoice = false
        VoiceConversationService.shared.stop()
        store.voiceSessionPresented = false
        refresh()
    }

    private func cachedDiskFree() -> Int64? {
        if let cached = diskFreeCache,
           Date().timeIntervalSince(diskFreeStamp) < Self.diskFreeInterval {
            return cached
        }
        let value = HFModelDownloadManager.freeDiskBytes()
        diskFreeCache = value
        diskFreeStamp = Date()
        return value
    }

    // MARK: - Intent

    /// The lens preview can fail in ways only the host can see: camera access
    /// denied, no capture device, or a session that refused to configure.
    /// `CameraService` is created by ContentView rather than being a singleton,
    /// so this adapter cannot pull the state — the host pushes it, and
    /// capabilities carry the result to the Lens.
    func noteCameraState(_ error: CameraError?) {
        let loc = LocalizationService.shared
        switch error {
        case .permissionDenied:
            store.lensStatusMessage = loc.t(
                "Camera access is off. Turn it on to use the Lens."
            )
            store.cameraNeedsSettings = true
        case .deviceUnavailable:
            store.lensStatusMessage = loc.t(
                "No camera is available on this device."
            )
            store.cameraNeedsSettings = false
        case .configurationFailed:
            store.lensStatusMessage = loc.t(
                "The camera could not start. Close other apps using it and try again."
            )
            store.cameraNeedsSettings = false
        case nil:
            store.lensStatusMessage = nil
            store.cameraNeedsSettings = false
        }
    }

    private func handle(_ action: ODAction) {
        switch action {
        case .setConversationPinned(let id, let pinned):
            guard let uuid = UUID(uuidString: id) else { return }
            ConversationStore.shared.setPinned(pinned, for: uuid)
            refresh()
        case .openMacBridge:
            routes.openMacBridge()
        case .openSettings:
            routes.openSettings()

        case .openModelPicker:
            routes.openModelPicker()

        case .openDiscovery:
            routes.openDiscovery()

        case .importModel:
            routes.importModel()

        case .showModelDownloads:
            routes.showModelDownloads()

        case .openCoreAIPacks:
            routes.openCoreAIPacks()

        case .manageStorage:
            routes.manageStorage()

        case .loadModel(let id):
            loadModel(id, in: nil)

        case .selectPersona(let id):
            // Applies from the next reply: the system prompt is rebuilt per reply.
            PersonaStore.shared.setActive(id)
            refresh()

        case .setThinking(let enabled):
            // Same persistence as the model settings sheet: a saved per-model
            // profile wins, otherwise the app-wide preference.
            let assistant = CodingAssistantService.shared
            let repoID = assistant.activeModel.repoID
            if var profile = AssistantModelSettingsStore.shared.settings(for: repoID) {
                profile.thinkingEnabled = enabled
                AssistantModelSettingsStore.shared.save(
                    profile, for: repoID, supportsThinking: assistant.activeThinkingSwitch
                )
            } else {
                AppSettings.shared.assistantThinking = enabled
            }
            refresh()

        case .loadModelInWorkspace(let id, let kind):
            loadModel(id, in: kind)

        case .modelAction(let modelID, let command):
            routes.modelCommand(modelID, command)

        case .quickStart(let quick):
            if quick == .createImage {
                routes.openImageGeneration()
            } else {
                routes.quickStart(quick)
            }

        case .openConversation(let id):
            guard let uuid = UUID(uuidString: id) else { return }
            routes.openConversation(uuid)

        case .showHistory:
            routes.openHistory()

        case .newConversation:
            routes.startNewChat()

        case .sendMessage, .sendMessageWithAttachments, .removeAttachment, .stopGeneration, .addAttachment:
            chatAction?(action)

        case .openImageModelPicker:
            routes.openImageGeneration()
        case .generateImage(let prompt, let modelID):
            let service = ImageGenerationService.shared
            guard !service.isWorking else { return }
            service.select(modelID)
            service.generate(prompt: prompt)
        case .cancelImageGeneration:
            ImageGenerationService.shared.cancel()

        case .selectVoice(let id):
            VoiceSettingsStore.shared.selectVoice(id)

        case .previewVoice(let id):
            guard !store.voiceSessionActive else { return }
            previewVoiceID = id
            let name = store.voices.first { $0.id == id }?.name ?? ""
            VoiceService.shared.speak(
                String(format: LocalizationService.shared.t("Hi, I'm %@. This is how I sound."), name),
                previewVoiceID: id
            )

        case .stopVoicePreview:
            guard previewVoiceID != nil else { return }
            VoiceService.shared.stop()
            previewVoiceID = nil

        case .selectEngine:
            routes.selectEngine()

        case .beginVoiceSession:
            guard !startingVoice else { return }
            if store.voiceSessionActive { store.voiceSessionPresented = true; return }
            VoiceService.shared.stop()
            previewVoiceID = nil
            startingVoice = true
            store.voicePhase = .preparing
            store.voiceSessionPresented = true
            voiceStartTask = Task {
                _ = await VoiceConversationService.shared.start()
                guard !Task.isCancelled else { return }
                voiceStartTask = nil
                startingVoice = false
                refresh()
            }

        case .endVoiceSession:
            cancelPendingVoiceStart()
            routes.endVoiceSession()
            refresh()

        case .setSpeakerEnabled(let enabled):
            // Output and capture are independent: muting the speaker must not
            // stop the microphone.
            AppSettings.shared.voiceAnswerEnabled = enabled
            SpeechPlaybackCoordinator.shared.setMuted(!enabled)

        case .setMicrophoneEnabled(let enabled):
            VoiceConversationService.shared.setMicrophoneMuted(!enabled)

        case .selectAudioRoute:
            routes.selectAudioRoute()

        case .capture(let mode, let question):
            routes.capture(mode, question)

        case .analyzeLens: routes.analyzeLens()
        case .retakeLens: routes.retakeLens()
        case .cancelLensAnalysis:
            routes.cancelLensAnalysis()

        case .openCameraSettings:
            routes.openCameraSettings()

        case .openPhotoLibrary:
            routes.openPhotoLibrary()

        case .switchCamera:
            routes.switchCamera()

        case .showLensOptions:
            routes.showLensOptions()
        case .showLensHistory:
            routes.showLensHistory()

        case .selectLensModel:
            routes.selectLensModel()
        }
    }

    private func loadModel(_ id: String, in requestedKind: ODModelKind?) {
        if let installed = CoreAIModelStore.shared.installedModel(id: id) {
            guard requestedKind == nil || requestedKind == .language,
                  let selection = installed.assistantModel else {
                routes.openCoreAIPacks()
                return
            }
            store.secondaryRoute = nil
            store.selectedTab = .chat
            Task { await CodingAssistantService.shared.switchTo(selection, persistAsDefault: true) }
            return
        }

        guard let model = ModelDownloadCenter.shared.models.first(where: { $0.id == id }) else {
            routes.openModelPicker()
            return
        }
        guard model.isReady else { model.start(); return }
        guard model.platformCompatibility?.supportsCurrentPlatform ?? true else {
            ToastCenter.shared.error("Model not supported on this device",
                                     detail: model.platformCompatibility?.detail ?? "")
            return
        }
        let kind = requestedKind ?? Self.kind(for: model)
        switch kind {
        case .language:
            guard model.supportsCategory(.assistant) else { routes.openModelPicker(); return }
            let presetID = AssistantModelCatalog.presets.first {
                $0.repoID.caseInsensitiveCompare(model.sourceRepoID) == .orderedSame
            }?.id
            guard let selection = AssistantModelCatalog.selection(
                forStoredID: presetID ?? LocalModelRegistry.assistantSelectionID(for: model)
            ) else {
                routes.openModelPicker()
                return
            }
            store.secondaryRoute = nil
            store.selectedTab = .chat
            Task { await CodingAssistantService.shared.switchTo(selection, persistAsDefault: true) }
        case .vision:
            guard model.supportsCategory(.vlm) else { routes.selectLensModel(); return }
            if let reason = model.downloader.flatMap({
                LocalModelRegistry.unsupportedVisionRuntimeReason(in: $0.destination)
            }) {
                ToastCenter.shared.error("Model runtime unavailable", detail: reason)
                return
            }
            let repoID = model.sourceRepoID.isEmpty ? model.id : model.sourceRepoID
            Task { @MainActor in
                if await VisualModelPickerView.applySelection(repoID) {
                    store.secondaryRoute = nil
                    store.selectedTab = .lens
                }
            }
        case .voice:
            routes.selectEngine()
        case .image:
            ImageGenerationService.shared.select(
                model.sourceRepoID.isEmpty ? model.id : model.sourceRepoID
            )
            store.secondaryRoute = .imageStudio
        case .utility:
            routes.openCoreAIPacks()
        }
    }

    // MARK: - Derivations

    private static func isResident(_ state: CodingAssistantService.ServiceState) -> Bool {
        switch state {
        case .ready, .generating: return true
        default: return false
        }
    }

    private static func phase(for assistant: CodingAssistantService) -> ODModelPhase {
        switch assistant.state {
        case .ready, .generating:
            return .ready
        case .loading(let message):
            return .preparing(step: message.isEmpty
                              ? LocalizationService.shared.t("Staging model weights")
                              : message)
        case .failed(let message):
            // A cancelled load is not a fault; it reports as `.failed` but must
            // not be surfaced as one.
            return assistant.isFailed ? .failed(message: message) : .unloaded
        case .unloaded:
            return .unloaded
        }
    }

    private static func voicePhase(_ phase: VoiceConversationService.Phase) -> ODVoicePhase {
        switch phase {
        case .idle:                return .idle
        case .listening:           return .listening
        case .thinking:            return .thinking
        case .speaking:            return .speaking
        case .failed(let message): return .failed(message: message)
        }
    }

    private static func isListening(_ phase: VoiceConversationService.Phase) -> Bool {
        phase == .listening
    }

    /// Chat first. A unified text+vision pack is filed under `.vlm` whenever
    /// its config.json carries a vision tower, but a pack that can chat is an
    /// Assistant model that can also see: "Use", "Open Chat" and Chat's
    /// readiness all key off this kind. Lens stays reachable via
    /// `supportedKinds`. A pack declaring text it cannot run yet (Bonsai 2)
    /// still reads as an Assistant model, so it never lands in Lens.
    static func kind(for model: DownloadableModel) -> ODModelKind {
        if model.supportsCategory(.assistant) { return .language }
        if model.supportsCategory(.vlm) { return .vision }
        if model.declaredCategories.contains(.assistant) { return .language }
        return kind(for: model.category)
    }

    private static func kind(for category: DownloadableModel.Category) -> ODModelKind {
        switch category {
        case .assistant: return .language
        case .vlm:       return .vision
        case .voice:     return .voice
        case .imageGen:  return .image
        }
    }

    private static func declaredKinds(for model: DownloadableModel) -> Set<ODModelKind> {
        Set(model.declaredCategories.map(kind(for:)))
    }

    private static func supportedKinds(for model: DownloadableModel) -> Set<ODModelKind> {
        Set(model.supportedCategories.map(kind(for:)))
    }

    private static func modelSummary(for model: DownloadableModel) -> String {
        switch model.id {
        case "qwen2.5-coder-1.5b": return "Fast for chat and code. A reliable first model."
        case "qwen3-4b": return "Stronger reasoning for chat and code."
        case "llama-3.2-3b": return "A versatile, general-purpose chat model."
        default: return model.subtitle
        }
    }

    private static func modelBadges(for model: DownloadableModel) -> [String] {
        let priority: [ModelCapability] = [.recommended, .best, .vision, .thinking, .fast, .coder, .multilingual, .newRelease]
        return priority.filter { model.capabilities.contains($0) }.prefix(2).map(\.label)
    }

    private static func memoryLabel() -> String? {
        let used = MemoryAdvisor.physFootprint
        guard used > 0 else { return nil }
        return used.formattedBytes
    }

    private static func thermalLabel(_ loc: LocalizationService) -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return loc.t("Normal")
        case .fair:     return loc.t("Fair")
        case .serious:  return loc.t("Elevated")
        case .critical: return loc.t("Critical")
        @unknown default: return nil
        }
    }

    private static func lensModelName(_ loc: LocalizationService) -> String {
        let stored = AppSettings.shared.cameraVisualModelID
        guard !stored.isEmpty else { return loc.t("Choose vision model") }
        if let match = ModelDownloadCenter.shared.models.first(where: {
            $0.id == stored || $0.sourceRepoID == stored
        }) {
            return ODPresentation.modelName(match.displayName)
        }
        return ODPresentation.modelName(stored.split(separator: "/").last.map(String.init) ?? stored)
    }

    private static func lastLine(_ convo: StoredConversation) -> String? {
        guard let last = convo.messages.last(where: {
            ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
        }) else { return nil }
        let flat = ODPresentation.messagePreview(last.content)
        return flat.isEmpty ? nil : flat
    }

    private static func regionLabel(_ locale: String) -> String {
        let parts = locale.split(separator: "-")
        guard parts.count >= 2 else { return locale.uppercased() }
        return Locale.current.localizedString(forRegionCode: String(parts[1]))
            ?? String(parts[1]).uppercased()
    }

    private static func languageLabel(_ locale: String) -> String {
        let code = String(locale.prefix(2))
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// Volume capacity, read once — it cannot change while the app runs.
    /// `URLResourceValues.volumeTotalCapacity` returns nil from the sandbox
    /// container, so this uses the older API that reports it reliably.
    private static let totalDiskBytes: Int64? = {
        let attrs = try? FileManager.default
            .attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemSize] as? NSNumber)?.int64Value
    }()

}
