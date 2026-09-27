import Foundation
import Combine

/// A main-actor presentation model. Update it from the existing app's real services.
/// No downloads, inference, permission requests or device capture happen in this package.
@MainActor
public final class ODStore: ObservableObject {
    @Published public var selectedTab: ODTab = .home {
        didSet { if selectedTab == .chat { hasOpenChat = true } }
    }
    @Published public private(set) var hasOpenChat = false
    @Published public var conversationsPresented = false
    @Published public var chatSearchRequested = false
    @Published public var secondaryRoute: ODSecondaryRoute?
    @Published public var appearance: ODAppearancePreference = .system {
        didSet { appearanceDefaults?.set(appearance.rawValue, forKey: Self.appearancePreferenceKey) }
    }
    @Published public var appSubtitle = "Your AI workspace"
    @Published public var editionLabel: String?
    @Published public var executionLabel: String?
    @Published public var models: [ODModel] = []
    @Published public var selectedModelID: String?
    @Published public var loadedModelID: String?
    @Published public var modelPhase: ODModelPhase = .unloaded
    @Published public var metrics = ODDeviceMetrics()
    @Published public var recentConversations: [ODRecentConversation] = []
    @Published public var selectedConversationID: String?
    @Published public var messages: [ODMessage] = []
    @Published public var composerText = ""
    /// The host updates this list after accepting add/remove/send operations.
    @Published public var draftAttachments: [ODAttachment] = []
    @Published public var isResponding = false
    /// Reasoning for the next reply. nil hides the switch: the selected model
    /// answers the same either way.
    @Published public var thinkingEnabled: Bool?
    /// Empty hides the persona picker.
    @Published public var personas: [ODPersona] = []
    @Published public var selectedPersonaID: String?
    @Published public var imagePrompt = ""
    @Published public var selectedImageModelID: String?
    @Published public var imagePhase: ODImagePhase = .idle
    /// Local file URL or a host-controlled remote result. This package does not save or upload it.
    @Published public var imageResultURL: URL?
    /// The prompt that produced imageResultURL, independent from the next editable draft.
    @Published public var imageResultPrompt: String?
    @Published public var voices: [ODVoice] = []
    @Published public var selectedVoiceID: String?
    @Published public var voiceEngineName = "Choose an engine"
    @Published public var voicePreviewID: String?
    @Published public var voiceSessionActive = false
    @Published public var voiceSessionPresented = false
    @Published public private(set) var voiceSessionReturnPending = false
    @Published public var voicePhase: ODVoicePhase = .idle
    @Published public var voiceTranscript: [ODMessage] = []
    @Published public var voiceAvailabilityMessage: String?
    @Published public var voiceSessionNotice: String?
    @Published public var speakerEnabled = true
    @Published public var microphoneCapturing = false
    @Published public var microphoneEnabled = false
    @Published public var audioRouteName = "Audio output"
    @Published public var lensModelInstalled = true
    @Published public var lensModelStatus = "Vision model"
    @Published public var lensModelName = "Choose vision model"
    @Published public var cameraMode: ODLensMode = .ask
    @Published public var lensHasSelectedImage = false
    @Published public var lensQuestion = ""
    @Published public var lensStatusMessage: String?
    @Published public var lensResultPresented = false
    @Published public var lensResultText: String?
    @Published public var lensIsAnalyzing = false
    @Published public var lensResultIsPartial = false
    @Published public var cameraNeedsSettings = false
    @Published public var capabilities = ODCapabilities()
    @Published public var onAction: ((ODAction) -> Void)?

    public static let appearancePreferenceKey = "com.ondevice.hermesui.appearance"
    private let appearanceDefaults: UserDefaults?

    /// Pass nil for appearanceDefaults when the host already owns appearance persistence.
    public init(appearanceDefaults: UserDefaults? = .standard,
                onAction: ((ODAction) -> Void)? = nil) {
        self.appearanceDefaults = appearanceDefaults
        self.onAction = onAction
        if let rawValue = appearanceDefaults?.string(forKey: Self.appearancePreferenceKey),
           let preference = ODAppearancePreference(rawValue: rawValue) {
            self.appearance = preference
        }
    }
    public var canPerformActions: Bool { onAction != nil }
    public var selectedModel: ODModel? { models.first { $0.id == selectedModelID } }
    public var selectedConversation: ODRecentConversation? { recentConversations.first { $0.id == selectedConversationID } }
    public var selectedVoice: ODVoice? { voices.first { $0.id == selectedVoiceID } }
    public var imageModels: [ODModel] { models.filter { $0.kind == .image && $0.isInstalled } }
    public var selectedImageModel: ODModel? { imageModels.first { $0.id == selectedImageModelID } }
    public var isReady: Bool {
        guard let selectedModel, selectedModel.isInstalled,
              selectedModel.kind == .language else { return false }
        return selectedModel.id == loadedModelID && modelPhase.isReady
    }
    public func phase(for model: ODModel) -> ODModelPhase {
        guard model.isInstalled else { return .unloaded }
        if model.id == selectedModelID {
            // A selected entry is not ready until the runtime identifies it as loaded.
            if modelPhase.isReady && model.id != loadedModelID { return .unloaded }
            return modelPhase
        }
        if model.id == loadedModelID { return .ready }
        return .unloaded
    }
    @Published public var interruptionConfirmationPresented = false
    @Published public private(set) var interruptionReason = "This action"
    public var endVoiceBeforeOperation: ((@escaping () -> Void) -> Void)?
    private var pendingExclusiveOperation: (() -> Void)?

    public func requestExclusiveOperation(_ reason: String, perform: @escaping () -> Void) {
        guard voiceSessionActive else { perform(); return }
        interruptionReason = reason
        pendingExclusiveOperation = perform
        interruptionConfirmationPresented = true
    }
    public func confirmInterruption() {
        let operation = pendingExclusiveOperation
        pendingExclusiveOperation = nil
        interruptionConfirmationPresented = false
        guard let operation else { return }
        if let endVoiceBeforeOperation { endVoiceBeforeOperation(operation) }
        else { onAction?(.endVoiceSession); operation() }
    }
    public func cancelInterruption() {
        pendingExclusiveOperation = nil
        interruptionConfirmationPresented = false
    }
    public func returnToVoiceSession() {
        guard voiceSessionActive else { return }
        conversationsPresented = false
        if secondaryRoute != nil {
            voiceSessionReturnPending = true
            secondaryRoute = nil
        } else {
            voiceSessionPresented = true
        }
    }

    func completeVoiceReturnAfterSheetDismissal() {
        guard voiceSessionReturnPending else { return }
        if voiceSessionActive { voiceSessionPresented = true }
        voiceSessionReturnPending = false
    }

    public func send(_ action: ODAction) {
        let reason: String?
        switch action {
        case .loadModel, .loadModelInWorkspace, .modelAction(_, .configure), .modelAction(_, .delete):
            reason = "Changing the active model"
        case .sendMessage, .sendMessageWithAttachments: reason = "Sending a chat message"
        case .generateImage: reason = "Creating an image"
        case .analyzeLens: reason = "Analyzing an image"
        case .selectLensModel, .openModelPicker: reason = "Changing the active model"
        default: reason = nil
        }
        if let reason {
            requestExclusiveOperation(reason) { [weak self] in self?.onAction?(action) }
        } else { onAction?(action) }
    }

    /// Explicit fixtures for the sample app and previews; never use as production telemetry.
    public static func demo() -> ODStore {
        let store = ODStore()
        store.appSubtitle = "Your local AI workspace"
        store.editionLabel = "UI preview"
        store.executionLabel = "On-device"
        store.models = [
            ODModel(id: "local/local_Ornith-1.5-9B-Q5_K_M", name: "Ornith 1.5",
                    metadata: "9B · Q5_K_M", byteCount: 6_470_000_000,
                    kind: .language, isDefault: true,
                    summary: "A capable local assistant for chat and code.", vendor: "qwen"),
            ODModel(id: "smolvlm2500m", name: "SmolVLM", metadata: "Vision model", kind: .vision,
                    summary: "Compact on-device visual understanding.", vendor: "huggingFace",
                    badges: ["Vision"])
        ]
        store.selectedModelID = store.models.first?.id
        store.loadedModelID = store.selectedModelID
        store.modelPhase = .ready
        store.metrics = ODDeviceMetrics(thermalLabel: "Normal", modelStorageBytes: 7_350_000_000,
                                        diskFreeBytes: 22_410_000_000, diskTotalBytes: 255_360_000_000)
        store.recentConversations = [
            ODRecentConversation(id: "demo-focus", title: "A focused workday", subtitle: "Plan three priorities", dateLabel: "Today"),
            ODRecentConversation(id: "demo-code", title: "Review a Swift function", subtitle: "Code review", dateLabel: "Earlier")
        ]
        store.voices = ["Alloy", "Aoede", "Bella", "Heart", "Jessica", "Nicole"].map {
            ODVoice(id: $0.lowercased(), name: $0, locale: "United States")
        }
        store.selectedVoiceID = "nicole"
        store.voiceEngineName = "Kokoro Neural"
        store.voiceAvailabilityMessage = "UI preview. Start opens a visual session; no audio service is connected."
        store.voiceSessionNotice = "UI preview. No microphone or audio service is running."
        store.lensStatusMessage = "UI preview. No camera session is connected."
        store.audioRouteName = "iPhone speaker"
        store.lensModelName = "SmolVLM"
        store.speakerEnabled = false
        store.microphoneEnabled = true
        store.capabilities.canLoadModels = false
        store.capabilities.canSelectEngine = true
        store.capabilities.canStartVoice = true
        store.capabilities.canSelectAudioRoute = false
        store.capabilities.canControlMicrophone = true
        store.capabilities.canControlSpeaker = true
        store.capabilities.canSelectLensModel = true
        store.capabilities.canShowHistory = true
        store.capabilities.modelCommands = [.details]
        return store
    }
}
