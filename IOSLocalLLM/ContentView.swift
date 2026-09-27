import SwiftUI
import PhotosUI
import OnDeviceUI

// MARK: - ContentView

struct ContentView: View {
    // App opens on the Home dashboard. Assistant / Lens are one tap away.
    @State private var selectedTab: Tab = .home
    @StateObject private var bridge = AppBridge.shared
    @ObservedObject private var odBridge = ODBridge.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var legal = LegalAcceptanceManager.shared
    @ObservedObject private var loc = LocalizationService.shared

    @StateObject private var camera: CameraService
    @StateObject private var analysis: AnalysisService
    @StateObject private var reviewPrompt = ReviewPromptService.shared

    @State private var showSettings = false
    /// Full searchable conversation list, opened from Home. The Assistant tab
    /// has its own copy behind a toolbar glyph; this is the entry point that
    /// does not vanish while a generation is running.
    @State private var showHistory = false
    // Destinations for workbench actions that previously had nowhere to go.
    @State private var showAssistantPicker = false
    @State private var showVoiceEnginePicker = false
    @State private var showVisualModelPicker = false
    @State private var showLensPresets = false
    @State private var showLensHistory = false
    @State private var openLensResultAfterHistory = false
    // Destinations for the Models screen. Each of these used to route at the
    // tab bar only, so from the Models tab the button did nothing visible:
    // "Find your next model", "Core AI packs", "Manage" storage, and every
    // per-model command (details / configure / export / delete) were all dead,
    // including the delete confirmation.
    @State private var showDiscovery = false
    @State private var showStorageCleanup = false
    @State private var showCoreAIPacks = false
    @State private var showModelImport = false
    @State private var showModelDownloads = false
    @State private var modelImportError: String?
    @State private var modelSettingsTarget: AssistantModelSettingsTarget?
    @State private var exportingModel: DownloadableModel?
    /// Lens gallery import. The workbench asks for the library; the host owns
    /// the picker and feeds the result into the existing analysis pipeline.
    @State private var lensPhotoOperationID = UUID()
    @State private var lensPhotoItem: PhotosPickerItem?
    @State private var showLensPhotoPicker = false
    // Legacy selection values bridge retained sidebar workspaces to runtime lifecycle.
    enum Tab: CaseIterable, Hashable {
        case home, assistant, camera, voice, models
    }

    init() {
        let cam = CameraService()
        _camera = StateObject(wrappedValue: cam)
        _analysis = StateObject(wrappedValue: AnalysisService(camera: cam))
    }

    var body: some View {
        // The redesigned six-screen workbench. The host keeps ownership of
        // every service; the package supplies presentation and returns intent.
        //
        // Chat is INJECTED rather than rendered by the package. This app's
        // conversation state, attachments, tool turns and streaming all live
        // inside CodingAssistantView as view state, so driving them from
        // ODStore would mean lifting several thousand lines out of that view.
        // The integration guide rules out that kind of restructuring, and
        // dropping the capabilities is explicitly worse. So the workbench owns
        // the shell and the host owns the transcript.
        OnDeviceWorkbench(
            store: odBridge.store,
            // Host-owned preview. Passing it does not hand the package the
            // capture session: start/stop stays with CameraService and the
            // tab lifecycle below.
            cameraPreview: AnyView(
                Group {
                    if let image = analysis.selectedImage {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityLabel("Selected image for analysis")
                    } else { CameraPreviewView(session: camera.captureSession).ignoresSafeArea() }
                }
            ),
            chatContent: AnyView(
                CodingAssistantView(
                    isActive: selectedTab == .assistant,
                    onClose: { odBridge.store.conversationsPresented = true }
                )
            ),
            settingsContent: AnyView(SettingsView(assistant: CodingAssistantService.shared)),
            imageContent: AnyView(ImageGenerationView(onOpenMenu: { odBridge.store.conversationsPresented = true })),
            deviceContent: AnyView(NativeDeviceView(onOpenMenu: { odBridge.store.conversationsPresented = true })),
            voiceContent: AnyView(VoiceConversationView(startOnAppear: false)),
            apiServerContent: AnyView(LocalAPIServerView(onOpenMenu: { odBridge.store.conversationsPresented = true })),
            lensResultContent: { presented in
                AnyView(Group {
                    if let result = analysis.activeResult {
                        AnalysisPanelView(result: result, analysis: analysis, isPresented: presented)
                    } else {
                        ContentUnavailableView("No capture selected", systemImage: "camera")
                    }
                })
            }
        )
        .onAppear { installBridgeRoutes() }
        // Lens result + reading state. The concept board has no result
        // surface; the app does, so it is published into the store and drawn
        // by ODLensView rather than lost.
        // Mode changes apply immediately, not only at capture — otherwise the
        // preset and the visibly-selected mode disagree until the shutter.
        .modifier(WorkbenchSelectionObserver(
            store: odBridge.store,
            onTabSelection: { tab in
                let mapped = Self.hostTab(for: tab)
                if selectedTab != mapped { selectedTab = mapped }
            },
            onCameraModeSelection: { mode in
                guard let lens = LensMode(rawValue: mode.rawValue) else { return }
                settings.lensPromptPresetID = lens.preset.rawValue
                settings.lensCustomPrompt = odBridge.store.lensQuestion
                analysis.cancelCurrentAnalysis()
                analysis.dismissActiveResult()
                odBridge.store.lensResultText = nil
            },
            onLensVisibility: { visible in updateLensCaptureVisibility(workspaceVisible: visible) }
        ))
        .onChange(of: analysis.selectedImage, initial: true) { _, image in
            odBridge.store.lensHasSelectedImage = image != nil
            updateLensCaptureVisibility()
        }
        .onChange(of: lensHostSheetPresented) { _, _ in updateLensCaptureVisibility() }
        .onChange(of: analysis.isAnalyzing) { _, busy in
            odBridge.store.lensIsAnalyzing = busy
        }
        // A camera that cannot run (access denied, no device, failed
        // configuration) is only visible to the host. Push it into the
        // workbench so the Lens explains the black rectangle and, when the user
        // can fix it, points at Settings.
        .onChange(of: camera.error) { _, error in
            odBridge.noteCameraState(error)
        }
        .onChange(of: analysis.activeResult?.extractedCode) { _, text in
            odBridge.store.lensResultText = text
        }
        // CameraRootView used to own this. The capture pipeline still has to be
        // configured before a capture can succeed, and it must start only when
        // Lens is actually on screen — never because a view was constructed.
        .task(id: selectedTab) {
            guard selectedTab == .camera else { return }
            // Configuration/metadata are independent of capture demand. The
            // visibility observer is the sole owner of live camera use.
            await analysis.start()
            odBridge.noteCameraState(camera.error)
        }
        // WorkbenchSelectionObserver mirrors UI-store selection into the
        // host tab above. Keep all existing camera/runtime cleanup keyed on
        // that host state, including programmatic navigation in both directions.
        // And back, so programmatic navigation (Siri intents, the share
        // extension, the camera bridge) still moves the visible tab.
        .onChange(of: selectedTab) { _, newValue in
            let mapped = Self.workbenchTab(for: newValue)
            if Self.hostTab(for: odBridge.store.selectedTab) != newValue {
                odBridge.store.selectedTab = mapped
            }
        }
        // Refresh file-backed inventory on navigation. Runtime replacement is
        // reserved for explicit operations through the residency coordinator.
        .onChange(of: selectedTab) { oldTab, newTab in
            updateToastLane(for: newTab)
            // Tactile feedback on every tab change. iOS 18+ tab bar has
            // its own subtle system haptic; this layers our brand selection
            // tap on top so it feels consistent with the rest of the app's
            // haptic vocabulary (capture, send, success). The programmatic
            // bridge-driven path below also fires HapticManager.tabSwitch();
            // a double-fire is benign — the generators dedupe at the
            // Core Haptics layer when triggered within a few ms.
            HapticManager.tabSwitch()
            ModelDownloadCenter.shared.refreshAllStates()

            // Lens narration belongs to its workspace. Voice conversations
            // have independent ownership and may intentionally stay minimized.
            switch oldTab {
            case .voice:
                break
            case .camera:
                LensVoiceNarrator.shared.deactivate()
                // Stop the capture session — it otherwise keeps the sensor
                // + ISP running (and draining battery / making heat) behind
                // every other tab. `start()`/`stop()` are idempotent.
                camera.stop()
            case .assistant, .home, .models:
                break
            }
            // Browsing never claims an inference runtime or terminates voice.
            // Actual analysis/generation uses the existing residency coordinator.
        }
        // Same idea for cold-launch + foreground resumes.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            ModelDownloadCenter.shared.refreshAllStates()
        }
        .onAppear {
            updateToastLane(for: selectedTab)
            // Setup ordering matters here.
            //
            // 1. DeviceTierAdvisor.apply*IfNeeded MUST run synchronously on
            //    .onAppear because they set cameraVisualModelID and
            //    assistantModelID — the user can tap capture (or send a
            //    message) within a few hundred ms of launch and those
            //    settings must already reflect the right defaults, or the
            //    capture path falls into the no-model branch and nothing
            //    streams. They're cheap (settings + a couple of
            //    ModelCacheProbe walks that short-circuit on the first
            //    config + weights file found).
            //
            // 2. BundledVLMInstaller.installIfNeeded() is the actually
            //    expensive piece on a fresh install — it copies ~1 GB of
            //    bundled SmolVLM2 weights into the HubApi cache. Even
            //    `isInstalled` does a fileExists on a multi-level path.
            //    Move only this off the main thread to keep launch snappy.
            //
            // 3. ModelDownloadCenter.refreshAllStates() iterates the full
            //    catalog and does a fileExists check per model — fast,
            //    but bundled with the installer for symmetry.
            DeviceTierAdvisor.applyDefaultIfNeeded()
            DeviceTierAdvisor.applyDefaultVisualModelIfNeeded()
            // Begin watching the kernel memory-pressure signal: dump model
            // weights on .critical (imminent Jetsam) and shed them when
            // backgrounded with low headroom. Idempotent.
            MemoryPressureCoordinator.shared.start()
            Task.detached(priority: .userInitiated) {
                BundledVLMInstaller.installIfNeeded()
                await MainActor.run {
                    ModelDownloadCenter.shared.refreshAllStates()
                }
            }
            // A Siri/Shortcuts App Intent can set `requestedTab` before this
            // view mounts on a cold launch — `.onChange` won't fire for a
            // value already present at first render, so apply it here too.
            if bridge.requestedTab != nil { applyRequestedTab(bridge.requestedTab) }
            // Seed the Spotlight index with existing chats on launch (the
            // per-save reindex in ConversationStore.persist keeps it fresh
            // thereafter).
            SpotlightIndexer.reindexAll(ConversationStore.shared.conversations)
        }
        // colorScheme is set by IOSLocalLLMApp root via AppSettings.appearance
        // Switch tabs when the camera bridge requests it. Use a no-animation
        // transaction so the previous tab's subtree is torn down before the
        // new one mounts — a spring animation here used to keep both subtrees
        // resident and bleed the assistant's cream T.bg onto the lens.
        .onChange(of: bridge.requestedTab) { _, newTab in
            applyRequestedTab(newTab)
        }
        // Settings sheet
        .sheet(isPresented: $showSettings) {
            SettingsView(assistant: CodingAssistantService.shared)
                // FastVLM status is now observed live inside SettingsView via FastVLMService.shared
        }
        .sheet(isPresented: $showAssistantPicker) {
            AssistantModelPickerView(downloadedOnly: true)
        }
        .sheet(isPresented: $showVoiceEnginePicker) {
            VoiceModelPickerView()
        }
        .sheet(isPresented: $showVisualModelPicker) {
            VisualModelPickerView()
        }
        .sheet(isPresented: $showLensHistory, onDismiss: {
            if openLensResultAfterHistory {
                openLensResultAfterHistory = false
                odBridge.store.lensResultPresented = true
            }
        }) {
            AnalysisHistoryView(analysis: analysis, openPanel: $openLensResultAfterHistory)
        }
        .sheet(isPresented: $showLensPresets) {
            LensPromptPresetSheet()
        }
        // The Models screen's destinations. All four are the app's own screens —
        // nothing new was written for them, they simply had no entry point from
        // the redesigned shell.
        .sheet(isPresented: $showDiscovery) {
            HFSearchView()
        }
        .sheet(isPresented: $showStorageCleanup) {
            ModelStorageCleanupView()
        }
        .sheet(isPresented: $showCoreAIPacks) {
            // CoreAIModelsSectionView is a *section*, not a screen: it is used
            // inline inside the model manager, so it brings no nav bar of its
            // own. Wrapping it here gives the sheet a title and a way out.
            NavigationStack {
                ScrollView {
                    CoreAIModelsSectionView(showsCatalog: true, query: "")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
                .background(StudioPageBackground())
                .navigationTitle("Core AI packs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showCoreAIPacks = false }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        .localModelImportFlow(isPresented: $showModelImport) { urls in
            Task { await importModel(from: urls) }
        }
        .sheet(isPresented: $showModelDownloads) {
            ModelDownloadCenterView()
        }
        .alert("Import failed", isPresented: Binding(
            get: { modelImportError != nil },
            set: { if !$0 { modelImportError = nil } }
        )) {
            Button("OK", role: .cancel) { modelImportError = nil }
        } message: {
            Text(modelImportError ?? "The model could not be imported.")
        }
        .sheet(item: $modelSettingsTarget) { target in
            AssistantModelSettingsView(target: target)
        }
        .sheet(item: $exportingModel) { model in
            if let directory = model.downloader?.destination {
                LocalModelExportPicker(
                    modelDirectory: directory,
                    onComplete: {
                        exportingModel = nil
                        ToastCenter.shared.success("Model exported",
                                                    detail: "\(model.displayName) is available in Files.")
                    },
                    onCancel: { exportingModel = nil }
                )
            }
        }
        .photosPicker(isPresented: $showLensPhotoPicker,
                      selection: $lensPhotoItem,
                      matching: .images,
                      photoLibrary: .shared())
        .onChange(of: lensPhotoItem) { _, item in
            let operation = UUID()
            lensPhotoOperationID = operation
            guard let item else { return }
            Task {
                defer { if lensPhotoOperationID == operation { lensPhotoItem = nil } }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    guard lensPhotoOperationID == operation else { return }
                    // Same entry the Lens gallery button always used, so the
                    // imported image runs the real analysis path.
                    analysis.selectImageForReview(image)
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            ConversationPickerView(store: ConversationStore.shared) { conv in
                showHistory = false
                AppBridge.shared.openConversation(id: conv.id)
            }
        }
        // Legal acceptance is the FIRST gate — must accept before anything else.
        // Gate on ANY outstanding acceptance (EULA version, AI disclaimer, or
        // device-safety notice), not just the version, so each can re-prompt.
        .fullScreenCover(isPresented: Binding(
            get: { legal.needsAnyAcceptance },
            set: { _ in }
        )) {
            LegalAcceptanceView { /* dismiss when accepted */ }
        }
        // First-run capability one-pager — the single onboarding page,
        // shown once the legal gate is accepted. Replaces the retired
        // multi-page tour.
        .fullScreenCover(isPresented: Binding(
            get: { !legal.needsAnyAcceptance && !settings.hasSeenOnboarding },
            set: { if !$0 { settings.hasSeenOnboarding = true } }
        )) {
            OnboardingOnePager { settings.hasSeenOnboarding = true }
        }
        // Rate-the-app pre-prompt — service decides when (≥5 turns,
        // ≥3 days installed, ≥30 days cooldown). Mounted at the root so
        // it surfaces regardless of which tab is active when the
        // threshold is hit. Suppressed during the legal gate so we
        // never stack sheets.
        .sheet(isPresented: Binding(
            get: { reviewPrompt.shouldShowPrompt
                    && !legal.needsAnyAcceptance },
            set: { newValue in
                if !newValue { reviewPrompt.userDeferred() }
            }
        )) {
            ReviewPromptSheet()
        }
    }

    // MARK: - Workbench bridge

    private func importModel(from urls: [URL]) async {
        do {
            // The service posts the success toast with the model's name.
            _ = try await LocalModelImportService.shared.importModel(from: urls)
            ModelDownloadCenter.shared.refreshAllStates()
            odBridge.refresh()
            HapticManager.impact(.medium)
        } catch {
            modelImportError = error.localizedDescription
        }
    }

    /// The package identifies a model by the download center's own `id`; the
    /// hub's rows also carry the canonical Hugging Face repo id. They agree for
    /// curated entries and differ for imported ones, so match on both.
    private static func downloadableModel(matching modelID: String) -> DownloadableModel? {
        ModelDownloadCenter.shared.models.first {
            $0.id == modelID || $0.sourceRepoID == modelID
        }
    }

    /// The package's destination enum and the app's are deliberately separate: the
    /// app's drives memory lifecycle and predates the redesign.
    private static func hostTab(for tab: ODTab) -> Tab {
        switch tab {
        case .home, .imageStudio, .device, .apiServer: return .home
        case .chat:   return .assistant
        case .lens:   return .camera
        case .voice:  return .voice
        case .models: return .models
        }
    }

    private static func workbenchTab(for tab: Tab) -> ODTab {
        switch tab {
        case .home:      return .home
        case .assistant: return .chat
        case .camera:    return .lens
        case .voice:     return .voice
        case .models:    return .models
        }
    }

    private var lensHostSheetPresented: Bool {
        showLensPhotoPicker || showVisualModelPicker || showLensPresets || showLensHistory
            || showSettings || showHistory || showAssistantPicker || showVoiceEnginePicker
            || showDiscovery || showStorageCleanup || showCoreAIPacks || showModelImport || showModelDownloads
            || modelSettingsTarget != nil || exportingModel != nil
    }

    private func updateLensCaptureVisibility(workspaceVisible: Bool? = nil) {
        let store = odBridge.store
        let workspace = workspaceVisible ?? (store.selectedTab == .lens && !store.conversationsPresented
            && !store.voiceSessionPresented && store.secondaryRoute == nil && !store.lensResultPresented && !store.voiceSessionReturnPending)
        let visible = workspace && !lensHostSheetPresented && analysis.selectedImage == nil
        if visible {
            camera.configure()
            camera.start()
        } else { camera.stop() }
    }

    /// Point every ODAction at a real route. Presentation stays here — the
    /// bridge never presents anything itself, so the app's existing sheet and
    /// cover state remains the only navigation authority.
    private func installBridgeRoutes() {
        var routes = ODBridge.Routes()

        routes.openSettings = { odBridge.store.secondaryRoute = .settings }
        routes.openModelPicker = { showAssistantPicker = true }
        routes.openModelsTab = { odBridge.store.selectedTab = .models }
        // The Models hub owns discovery, Core AI packs and storage; its
        // sections are assistant/lens/voice/image.
        // Each of these now opens a real screen. They used to set the tab to
        // `.models` — which, from the Models tab, did nothing at all.
        routes.openDiscovery = { showDiscovery = true }
        routes.importModel = { showModelImport = true }
        routes.showModelDownloads = { showModelDownloads = true }
        routes.openCoreAIPacks = { showCoreAIPacks = true }
        routes.manageStorage = { showStorageCleanup = true }
        routes.openImageGeneration = { odBridge.store.secondaryRoute = .imageStudio }
        routes.openHistory = { showHistory = true }
        // Legacy callers land on the supported server workspace; Mac pairing stays hidden.
        routes.openMacBridge = { odBridge.store.selectedTab = .apiServer }
        routes.openConversation = { id in
            AppBridge.shared.openConversation(id: id)
            odBridge.store.selectedTab = .chat
        }
        routes.startNewChat = {
            AppBridge.shared.startNewChat()
            odBridge.store.selectedTab = .chat
        }
        // Quick actions prefill the real composer rather than sending blind,
        // so the user still edits before anything is generated.
        routes.quickStart = { action in
            AppBridge.shared.askAssistant(Self.prompt(for: action), autoSend: false)
            odBridge.store.selectedTab = .chat
        }
        // The composer owns attachments; move to it and let the user use the
        // real picker rather than opening a second one behind its back.
        routes.addAttachment = { odBridge.store.selectedTab = .chat }
        routes.selectEngine = { showVoiceEnginePicker = true }
        // AVRoutePickerView can only be raised by its own tap, so there is no
        // programmatic route to open. `canSelectAudioRoute` is false and the
        // control reads as a status line instead of pretending to be a button.
        routes.selectAudioRoute = {}
        // Session existence belongs to the service; presentation is the flag.
        // Returning to a live session must not begin a second one.
        routes.beginVoiceSession = {
            odBridge.store.voiceSessionPresented = true
            guard !odBridge.store.voiceSessionActive else { return }
            Task { _ = await VoiceConversationService.shared.start() }
        }
        routes.endVoiceSession = {
            VoiceConversationService.shared.stop()
            odBridge.store.voiceSessionPresented = false
        }
        routes.capture = { mode, question in
            lensPhotoOperationID = UUID()
            // Mirror the workbench's mode onto the app's preset so the capture
            // runs the right prompt — the job the old mode bar did.
            if let lens = LensMode(rawValue: mode.rawValue) {
                settings.lensPromptPresetID = lens.preset.rawValue
            }
            settings.lensCustomPrompt = question
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.analysisMode != AnalysisMode.visual.rawValue {
                settings.analysisMode = AnalysisMode.visual.rawValue
            }
            analysis.captureForReview()
        }
        routes.analyzeLens = {
            settings.lensCustomPrompt = odBridge.store.lensQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mode = LensMode(rawValue: odBridge.store.cameraMode.rawValue) { settings.lensPromptPresetID = mode.preset.rawValue }
            settings.analysisMode = AnalysisMode.visual.rawValue
            analysis.analyzeSelectedImage()
        }
        routes.retakeLens = { lensPhotoOperationID = UUID(); analysis.retakeSelectedImage() }
        routes.openPhotoLibrary = { showLensPhotoPicker = true }
        // CameraService exposes no front/back flip, so this route is inert and
        // `canSwitchCamera` is false — the control stays disabled rather than
        // pretending to do something. See ODBridge capabilities.
        routes.switchCamera = {}
        routes.showLensOptions = { showLensPresets = true }
        routes.cancelLensAnalysis = { analysis.cancelCurrentAnalysis() }
        routes.showLensHistory = { showLensHistory = true }
        routes.selectLensModel = { showVisualModelPicker = true }
        routes.openCameraSettings = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        // Details / configure / export / delete. The comment here used to claim
        // all four "live in the Models hub" while routing to a tab switch, which
        // made every one of them a dead end — including the destructive one the
        // user had already confirmed.
        routes.modelCommand = { modelID, command in
            switch command {
            case .details:
                odBridge.store.selectedTab = .models
            case .download:
                // Discover-tab cards start the transfer in place. Routing
                // this through "configure" used to just open a picker sheet
                // (Vision models for VLMs) without downloading anything.
                if let downloadable = Self.downloadableModel(matching: modelID) {
                    if downloadable.isReady {
                        ToastCenter.shared.info("\(downloadable.displayName) is already installed")
                    } else if downloadable.state.isActive {
                        // Already transferring — the card shows live progress.
                    } else {
                        downloadable.start()
                        HapticManager.impact(.medium)
                    }
                } else {
                    ToastCenter.shared.error("Model unavailable",
                                             detail: "This catalog entry has no downloader. Browse the Model Center instead.")
                }
            case .pauseDownload:
                Self.downloadableModel(matching: modelID)?.pause()
            case .cancelDownload:
                Self.downloadableModel(matching: modelID)?.cancel()
            case .configure:
                if let downloadable = Self.downloadableModel(matching: modelID) {
                    // Same chat-first role the Models list shows.
                    switch ODBridge.kind(for: downloadable) {
                    case .language:
                        if let model = AssistantModelCatalog.selection(forStoredID: LocalModelRegistry.assistantSelectionID(for: downloadable)) {
                            modelSettingsTarget = AssistantModelSettingsTarget(model: model)
                        } else { showAssistantPicker = true }
                    case .vision: showVisualModelPicker = true
                    case .voice: showVoiceEnginePicker = true
                    case .image, .utility: odBridge.store.secondaryRoute = .imageStudio
                    }
                } else if let model = AssistantModelCatalog.selection(forStoredID: modelID) {
                    modelSettingsTarget = AssistantModelSettingsTarget(model: model)
                } else {
                    showAssistantPicker = true
                }
            case .export:
                if let model = Self.downloadableModel(matching: modelID),
                   model.downloader?.destination != nil {
                    exportingModel = model
                } else {
                    ToastCenter.shared.error("Nothing to export",
                                             detail: "This model has no file on disk yet.")
                }
            case .delete:
                if let model = Self.downloadableModel(matching: modelID) {
                    // Same entry point the model manager's own confirmation
                    // uses: it resets active selections and unloads services
                    // before the files go, and surfaces failures as a toast.
                    ModelDownloadCenter.shared.handleDeletion(of: model)
                }
            }
        }

        odBridge.routes = routes
        odBridge.routesInstalled = true
        odBridge.refresh()
    }

    private static func prompt(for action: ODQuickAction) -> String {
        switch action {
        case .explain:     return "Explain something simply: "
        case .reviewCode:  return "Review this code for bugs and improvements:\n\n"
        case .translate:   return "Translate the following:\n\n"
        case .createImage: return ""
        }
    }

    /// Applies a tab navigation request (from the camera bridge, share
    /// extension, or a Siri/Shortcuts App Intent) and clears it. No-animation
    /// transaction so the previous tab's subtree tears down before the new one
    /// mounts — a spring here used to keep both resident and bleed the
    /// assistant's cream background onto the lens.
    private func applyRequestedTab(_ newTab: Int?) {
        guard let tab = newTab else { return }
        // 0 = camera, 1 = assistant, 2 = models, 3 = mac, 4 = voice.
        // The legacy index now opens the API server workspace. Mac pairing is hidden.
        if tab == 3 {
            odBridge.store.selectedTab = .apiServer
            HapticManager.tabSwitch()
            bridge.requestedTab = nil
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            switch tab {
            case 1: selectedTab = .assistant
            case 2: selectedTab = .models
            case 4: selectedTab = .voice
            default: selectedTab = .camera
            }
        }
        HapticManager.tabSwitch()
        bridge.requestedTab = nil
    }

    /// Keeps transient notifications below each tab's top chrome. Assistant's
    /// two-line model picker is taller than a standard navigation row.
    private func updateToastLane(for tab: Tab) {
        switch tab {
        case .assistant:
            ToastCenter.shared.setTopPadding(96)
        case .models:
            ToastCenter.shared.setTopPadding(8)
        case .home, .camera, .voice:
            ToastCenter.shared.setTopPadding(52)
        }
    }

    // MARK: - Tabs


    @Environment(\.koduTheme) private var T
}

// MARK: - CameraRootView


// MARK: - Live Lens question composer


// MARK: - LensMode (design-03 mode switcher)
// The four camera "modes" map onto LensPromptPreset values so the existing
// VLM pipeline drives them unchanged — selecting a mode just swaps the prompt.
enum LensMode: String, CaseIterable, Identifiable {
    case ask, translate, scan, solve
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .translate: return "Translate"
        case .scan: return "Scan"
        case .solve: return "Solve"
        }
    }
    var question: String {
        switch self {
        case .ask: return "What am I looking at?"
        case .translate: return "What does this say in English?"
        case .scan: return "Transcribe the text"
        case .solve: return "Solve what's shown"
        }
    }
    var preset: LensPromptPreset {
        switch self {
        case .ask: return .describe
        case .translate: return .translate
        case .scan: return .extractCode
        case .solve: return .solve
        }
    }
    static func from(preset: LensPromptPreset) -> LensMode {
        switch preset {
        case .translate: return .translate
        case .extractCode, .reviewCode, .findErrors, .explainUI: return .scan
        case .solve: return .solve
        default: return .ask
        }
    }
}

// MARK: - ScanCornersShape
// Four rounded L-brackets forming the centered viewfinder frame (design 03).

// MARK: - CaptureAura
//
// Pulsing concentric rings behind the capture disc while inference is in
// flight. Each ring scales 0.85 → 1.45 and fades to zero opacity over its
// cycle, staggered so the eye reads a continuous outward sonar wave.
//
// Lives in its own subview so the repeat-forever animation isolates from
// the parent's redraw cycle — otherwise every analysis-state change in
// CameraRootView would reinstall the animation and the rings would jitter.


// MARK: - StreamingGradientEdge
//
// 1px conic-gradient edge that rotates around the host card while the
// VLM is streaming. Animating the AngularGradient's `angle` parameter
// re-rasterizes the gradient texture every frame, which jittered when
// stacked on top of the live camera + token-stream redraws. Instead,
// the gradient is built once and rotated via `.rotationEffect`, which
// the render server handles as a transform on the cached layer. No
// `.drawingGroup()` — the offscreen Metal pass that forces crashes
// the app if the gradient is still animating while the app drops to
// the background (Metal won't accept GPU submissions from a
// background process).


// MARK: - CaptionSkeleton
//
// Three pulsing skeleton lines, used as the empty-streaming state of the
// caption pill. Each line pulses on a staggered delay so the eye reads a
// rolling "still working" rhythm rather than three lines breathing in
// unison.


// MARK: - StreamSafeTextSelection
// Toggles `.textSelection(.enabled)` only when the stream has settled.
// Selection support forces CoreText to retain selection-anchor state across
// every layout pass — combined with rapid token-by-token updates from the
// VLM, that pushes Futhark's line-segment allocator (the one in the crash
// report) over its capacity and the next store SIGABRTs. Disabling
// selection while streaming, then re-enabling once the result is final,
// gives users the copy-from-text affordance without the crash risk.
//
// `.textSelection(.enabled)` and `.textSelection(.disabled)` return
// different opaque types, so the conditional has to branch at the type
// level via @ViewBuilder.

struct StreamSafeTextSelection: ViewModifier {
    let streaming: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if streaming {
            content.textSelection(.disabled)
        } else {
            content.textSelection(.enabled)
        }
    }
}

// MARK: - FocusReticle
// Small animated square shown briefly at the user's tap-to-focus point.


#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
