import Foundation

/// Workspace identifiers retained for the host's camera/audio residency lifecycle.
/// Navigation is now provided by the sidebar, not a tab bar.
public enum ODTab: String, CaseIterable, Identifiable, Hashable {
    case home, chat, lens, voice, models, imageStudio, device, apiServer
    public var id: String { rawValue }
    public var title: String { self == .apiServer ? "API server" : self == .home ? "Chats" : self == .imageStudio ? "Image studio" : rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .home: return "bubble.left.and.bubble.right"
        case .chat: return "bubble.left"
        case .lens: return "camera"
        case .voice: return "waveform"
        case .models: return "cube"
        case .imageStudio: return "photo"
        case .device: return "iphone"
        case .apiServer: return "network"
        }
    }
}

public enum ODModelKind: String, CaseIterable, Identifiable {
    case language, vision, voice, image
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .language: return "Assistant"
        case .vision: return "Lens"
        case .voice: return "Voice"
        case .image: return "Image"
        }
    }
    public var symbol: String {
        switch self {
        case .language: return "brain"
        case .vision: return "eye"
        case .voice: return "waveform"
        case .image: return "photo"
        }
    }
}

public struct ODModel: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var metadata: String
    public var byteCount: Int64?
    public var kind: ODModelKind
    public var isLibraryEntry: Bool
    public var isInstalled: Bool
    public var isDefault: Bool
    public var estimatedMemoryBytes: Int64?
    public var downloadStatus: String?
    public var downloadProgress: Double?
    public var availableCommands: [ODModelCommand]?
    public init(id: String, name: String, metadata: String, byteCount: Int64? = nil,
                kind: ODModelKind, isInstalled: Bool = true, isDefault: Bool = false,
                availableCommands: [ODModelCommand]? = nil, isLibraryEntry: Bool = true,
                downloadStatus: String? = nil, downloadProgress: Double? = nil, estimatedMemoryBytes: Int64? = nil) {
        self.id = id
        self.name = ODPresentation.modelName(name)
        self.metadata = metadata.hasPrefix("local/") ? "Imported on this device" : metadata
        self.byteCount = byteCount
        self.kind = kind; self.isInstalled = isInstalled; self.isDefault = isDefault
        self.isLibraryEntry = isLibraryEntry
        self.availableCommands = availableCommands
        self.downloadStatus = downloadStatus
        self.downloadProgress = downloadProgress
        self.estimatedMemoryBytes = estimatedMemoryBytes
    }
    public var sizeLabel: String? { byteCount.map(ODFormat.bytes) }
}

public enum ODModelPhase: Equatable {
    case unloaded
    case preparing(step: String)
    case ready
    case failed(message: String)
    public var isReady: Bool { if case .ready = self { return true }; return false }
    public var isPreparing: Bool { if case .preparing = self { return true }; return false }
    public var title: String {
        switch self {
        case .unloaded: return "Not loaded"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }
}

public struct ODDeviceMetrics: Equatable {
    public var memoryLabel: String?
    public var thermalLabel: String?
    public var modelStorageBytes: Int64?
    public var diskFreeBytes: Int64?
    public var diskTotalBytes: Int64?
    public init(memoryLabel: String? = nil, thermalLabel: String? = nil,
                modelStorageBytes: Int64? = nil, diskFreeBytes: Int64? = nil,
                diskTotalBytes: Int64? = nil) {
        self.memoryLabel = memoryLabel; self.thermalLabel = thermalLabel
        self.modelStorageBytes = modelStorageBytes; self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
    }
}

public struct ODRecentConversation: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var dateLabel: String
    public var isPinned: Bool
    public init(id: String, title: String, subtitle: String, dateLabel: String, isPinned: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.dateLabel = dateLabel
        self.isPinned = isPinned
    }
}

public enum ODQuickAction: String, CaseIterable, Identifiable {
    case explain, reviewCode, translate, createImage
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .explain: return "Explain"
        case .reviewCode: return "Review code"
        case .translate: return "Translate"
        case .createImage: return "Create image"
        }
    }
    public var subtitle: String {
        switch self {
        case .explain: return "Get a clear answer"
        case .reviewCode: return "Find bugs & improve"
        case .translate: return "Across languages"
        case .createImage: return "Create with local AI"
        }
    }
    public var symbol: String {
        switch self {
        case .explain: return "doc.text"
        case .reviewCode: return "chevron.left.forwardslash.chevron.right"
        case .translate: return "globe"
        case .createImage: return "photo"
        }
    }
}

/// Presentation metadata for a draft attachment already managed by the host.
/// This record never reads a file, starts an upload or claims a processing result.
public struct ODAttachment: Identifiable, Equatable {
    public enum Kind: String { case file, image }
    public let id: String
    public var name: String
    public var kind: Kind

    /// Host-provided local thumbnail bytes. Never downloaded or persisted by the UI.
    public var previewData: Data?

    public init(id: String, name: String, kind: Kind = .file, previewData: Data? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.previewData = previewData
    }
}

public struct ODMessage: Identifiable, Equatable {
    public enum Role: String { case user, assistant }
    public let id: UUID
    public var role: Role
    public var text: String
    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public struct ODVoice: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var locale: String
    public var language: String
    public var isMultilingual: Bool
    public var isCloned: Bool
    public init(id: String, name: String, locale: String, language: String = "English",
                isMultilingual: Bool = false, isCloned: Bool = false) {
        self.id = id; self.name = name; self.locale = locale; self.language = language
        self.isMultilingual = isMultilingual; self.isCloned = isCloned
    }
}

public enum ODVoicePhase: Equatable {
    case idle, preparing, listening, thinking, speaking, interrupted
    case failed(message: String)
    public var title: String {
        switch self {
        case .idle: return "Ready to talk"
        case .interrupted: return "Interrupted"
        case .preparing: return "Preparing voice"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .failed: return "Session paused"
        }
    }
    public var subtitle: String {
        switch self {
        case .idle: return "Your conversation is ready."
        case .interrupted: return "Audio was interrupted. Return to your session to continue."
        case .preparing: return "Getting your voice session ready."
        case .listening: return "Go ahead, I’m listening."
        case .thinking: return "Working on your response."
        case .speaking: return "Responding with your selected voice."
        case .failed(let message): return message
        }
    }
    public var isActive: Bool {
        switch self { case .listening, .thinking, .speaking: return true; default: return false }
    }
}

public enum ODLensMode: String, CaseIterable, Identifiable {
    case ask, translate, scan, solve
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var instruction: String {
        switch self {
        case .ask: return "Ask about what you see"
        case .translate: return "Point at text to translate"
        case .scan: return "Capture text or a document"
        case .solve: return "Frame the problem to solve"
        }
    }
}

public enum ODModelCommand: String, CaseIterable, Identifiable {
    case details, download, configure, export, delete
    public var id: String { rawValue }
    public var title: String {
        switch self { case .details: return "Model details"; case .download: return "Download"
        case .configure: return "Configure"
        case .export: return "Export to Files"; case .delete: return "Delete model" }
    }
}

/// Host capabilities govern enabled controls. They do not start any services.
public struct ODCapabilities {
    public var canPinConversations = false
    public var canOpenMacBridge = false
    public var canOpenAPIServer = false
    public var canManageStorage = false
    public var canConfigureApp = false
    public var canLoadModels = false
    public var canStopGeneration = false
    public var canGenerateImages = false
    public var canCancelImageGeneration = false
    public var canSendMessages = false
    public var canAddAttachments = false
    public var canRemoveAttachments = false
    public var canSendAttachments = false
    public var canStartVoice = false
    public var canMinimizeVoiceSession = false
    public var canControlMicrophone = false
    public var canControlSpeaker = false
    public var canPreviewVoices = false
    public var canSelectEngine = false
    public var canSelectAudioRoute = false
    public var canCapture = false
    public var canCancelLensAnalysis = false
    public var canChoosePhoto = false
    public var canSwitchCamera = false
    public var canConfigureLens = false
    public var canViewLensHistory = false
    public var canSelectLensModel = false
    public var canShowHistory = false
    public var modelCommands: [ODModelCommand] = [.details]
    public init() {}
}

/// Intent-only bridge. The host owns inference, files, audio, camera and lifecycle state.
public enum ODAction {
    case setConversationPinned(String, Bool), openMacBridge
    case openSettings, openModelPicker, openDiscovery, openCoreAIPacks, manageStorage
    case loadModel(String)
    case modelAction(modelID: String, command: ODModelCommand)
    case quickStart(ODQuickAction)
    case newConversation, openConversation(String), showHistory
    case sendMessage(String), stopGeneration, addAttachment
    case removeAttachment(String)
    case sendMessageWithAttachments(text: String, attachmentIDs: [String])
    case openImageModelPicker
    case generateImage(prompt: String, modelID: String), cancelImageGeneration
    case selectVoice(String), previewVoice(String), stopVoicePreview, selectEngine
    case beginVoiceSession, endVoiceSession
    case setSpeakerEnabled(Bool), setMicrophoneEnabled(Bool), selectAudioRoute
    case capture(mode: ODLensMode, question: String)
    case analyzeLens, retakeLens
    case cancelLensAnalysis
    case openPhotoLibrary, switchCamera, showLensOptions, showLensHistory, selectLensModel, openCameraSettings
}

public enum ODFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .decimal)
    }
}

/// Secondary workspaces are presented without adding more primary tabs.
public enum ODSecondaryRoute: String, Identifiable {
    case imageStudio, device, settings
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .imageStudio: return "Image studio"
        case .device: return "Device"
        case .settings: return "Settings"
        }
    }
}

/// The host supplies generation state. No timers or percentages are inferred by the UI.
public enum ODImagePhase: Equatable {
    case idle
    case generating(step: String)
    case failed(message: String)

    public var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }
}
