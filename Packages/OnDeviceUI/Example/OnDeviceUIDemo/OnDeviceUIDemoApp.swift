import Foundation
import OnDeviceUI
import SwiftUI

/// A review host with explicit fixtures. Real inference, audio and capture stay in the app.
@main
@MainActor
struct OnDeviceUIDemoApp: App {
    @StateObject private var demo = DemoSession()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("UI preview · Sample data")
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 8)
                        Button("Preview controls") { demo.controlsPresented = true }
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .padding(.horizontal, 20)
                    .background(.thinMaterial)
                    .accessibilityElement(children: .contain)
                OnDeviceWorkbench(store: demo.store)
            }
                .sheet(isPresented: $demo.controlsPresented, onDismiss: {
                    demo.finishControlsDismissal()
                }) {
                    DemoControls(demo: demo)
                }
                .alert(item: $demo.notice) { notice in
                    Alert(title: Text(notice.title), message: Text(notice.message),
                          dismissButton: .default(Text("OK")))
                }
        }
    }
}

private struct DemoNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum DemoModelScenario: String, CaseIterable, Identifiable {
    case ready = "Ready"
    case unloaded = "Not loaded"
    case preparing = "Preparing — static fixture"
    case failed = "Example failure"
    case empty = "Empty catalog"
    var id: String { rawValue }
}

private enum DemoVoiceScenario: String, CaseIterable, Identifiable {
    case idle = "Idle"
    case listening = "Listening — visual only"
    case thinking = "Thinking — visual only"
    case speaking = "Speaking — visual only"
    case failed = "Example failure"
    var id: String { rawValue }
}

@MainActor
private final class DemoSession: ObservableObject {
    @Published var store: ODStore
    @Published var controlsPresented = false
    @Published var notice: DemoNotice?
    @Published private(set) var modelScenario: DemoModelScenario = .ready
    @Published private(set) var voiceScenario: DemoVoiceScenario = .idle
    private var pendingDestination: ODSecondaryRoute?
    private var pendingTab: ODTab?
    private var pendingNotice: DemoNotice?

    init() {
        store = ODStore.demo()
        store.microphoneEnabled = false
        connectActions()
    }

    private func connectActions() {
        store.onAction = { [weak self] action in self?.handle(action) }
    }

    func reset() {
        store = ODStore.demo()
        store.microphoneEnabled = false
        modelScenario = .ready
        voiceScenario = .idle
        notice = nil
        pendingDestination = nil
        pendingTab = nil
        pendingNotice = nil
        connectActions()
    }

    /// Present only after the preview-controls sheet has actually dismissed.
    func finishControlsDismissal() {
        if let tab = pendingTab {
            pendingTab = nil
            store.selectedTab = tab
        }
        if let destination = pendingDestination {
            pendingDestination = nil
            store.secondaryRoute = destination
        }
        if let queuedNotice = pendingNotice {
            pendingNotice = nil
            notice = queuedNotice
        }
    }

    func showImageResult() {
        pendingTab = nil
        guard let sampleURL = Bundle.main.url(forResource: "studio-example", withExtension: "png") else {
            pendingNotice = DemoNotice(title: "Sample image unavailable",
                                       message: "The example image is missing from this app bundle. Check the example target's Copy Bundle Resources phase.")
            controlsPresented = false
            return
        }
        let prompt = "A quiet house beside a mountain lake."
        store.imageResultURL = sampleURL
        store.imageResultPrompt = prompt
        store.imagePrompt = prompt
        store.selectedImageModelID = nil
        store.imagePhase = .idle
        pendingDestination = .imageStudio
        controlsPresented = false
    }

    func showAttachedDraft() {
        store.selectedConversationID = nil
        store.messages = []
        store.composerText = "Use these notes to draft a summary."
        store.draftAttachments = [ODAttachment(id: "demo-notes", name: "notes.txt", kind: .file)]
        pendingDestination = nil
        pendingTab = .chat
        controlsPresented = false
    }

    func chooseModelScenario(_ scenario: DemoModelScenario) {
        modelScenario = scenario
        if scenario == .empty {
            store.models = []
            store.selectedModelID = nil
            store.loadedModelID = nil
            store.modelPhase = .unloaded
            store.metrics.modelStorageBytes = 0
            return
        }
        if store.models.isEmpty {
            let fixtures = ODStore.demo()
            store.models = fixtures.models
            store.metrics = fixtures.metrics
        }
        if store.selectedModel == nil {
            store.selectedModelID = store.models.first?.id
        }
        store.loadedModelID = nil
        switch scenario {
        case .ready:
            store.loadedModelID = store.selectedModelID
            store.modelPhase = .ready
        case .unloaded:
            store.modelPhase = .unloaded
        case .preparing:
            store.modelPhase = .preparing(step: "Staging weights · preview state")
        case .failed:
            store.modelPhase = .failed(message: "Example preparation failure. Change the preview state to continue.")
        case .empty:
            break
        }
    }

    func chooseVoiceScenario(_ scenario: DemoVoiceScenario) {
        voiceScenario = scenario
        store.microphoneEnabled = scenario == .listening
        store.speakerEnabled = scenario == .speaking
        switch scenario {
        case .idle: store.voicePhase = .idle
        case .listening: store.voicePhase = .listening
        case .thinking: store.voicePhase = .thinking
        case .speaking: store.voicePhase = .speaking
        case .failed:
            store.voicePhase = .failed(message: "Example voice error. No audio service is connected.")
        }
    }

    func showConversation() {
        store.composerText = ""
        store.draftAttachments = []
        store.selectedConversationID = "demo-focus"
        store.messages = [
            ODMessage(role: .user, text: "Help me plan a focused workday."),
            ODMessage(role: .assistant, text: "Let's keep it simple.\n\n1. Start with one priority.\nChoose the task that matters most.\n\n2. Work in two focused blocks.\nLeave a short break between them.\n\n3. Leave room to reset.\nKeep the last hour flexible.")
        ]
        store.selectedTab = .chat
    }

    func newConversation() {
        store.selectedConversationID = nil
        store.messages = []
        store.composerText = ""
        store.draftAttachments = []
        store.selectedTab = .chat
    }

    private func showNotice(_ title: String, _ message: String) {
        notice = DemoNotice(title: title, message: message)
    }

    private func handle(_ action: ODAction) {
        switch action {
        case .openCameraSettings:
            showNotice("Camera settings", "The demo does not own a camera session.")
        case .openSettings:
            showNotice("Host settings", "Connect this intent to the app's existing configuration. Appearance already works in the supplied Settings screen.")
        case .openModelPicker:
            store.selectedTab = .models
        case .openDiscovery:
            showNotice("Model discovery", "This UI preview contains only fixture models. Connect the app's existing model catalog here.")
        case .openCoreAIPacks:
            showNotice("Core AI packs", "Connect this intent to the existing pack browser. The preview does not download or install models.")
        case .manageStorage:
            showNotice("Sample storage figures", "Storage values are fixtures. Connect the existing storage manager; no files are changed by this preview.")
        case .loadModel:
            showNotice("Model runtime is not connected", "Use Preview controls to inspect ready, preparing and failure states. This sample never loads model weights.")
        case .modelAction(let modelID, let command):
            if command == .details, let model = store.models.first(where: { $0.id == modelID }) {
                showNotice(model.name, "Sample model\n\(model.metadata)\n\(model.id)")
            } else {
                showNotice(command.title, "Connect this intent to the host model service. This preview has not changed any model or file.")
            }
        case .quickStart(let shortcut):
            if shortcut == .createImage {
                store.secondaryRoute = .imageStudio
            } else {
                store.selectedTab = .chat
                switch shortcut {
                case .explain: store.composerText = "Explain "
                case .reviewCode: store.composerText = "Review this code: "
                case .translate: store.composerText = "Translate "
                case .createImage: break
                }
            }
        case .newConversation:
            newConversation()
        case .openConversation(let id):
            if id == "demo-focus" {
                showConversation()
            } else {
                store.selectedConversationID = id
                store.composerText = ""
                store.draftAttachments = []
                store.messages = [ODMessage(role: .user, text: "Review this Swift function.")]
                store.selectedTab = .chat
            }
        case .showHistory:
            store.conversationsPresented = true
        case .sendMessageWithAttachments:
            showNotice("Attached messages are not connected", "This sample contains attachment metadata only. The host should resolve the stable attachment IDs and accept the submission before clearing the draft.")
        case .removeAttachment:
            showNotice("Sample attachment", "The attachment row is a metadata fixture. No file is opened or removed by this preview.")
        case .sendMessage:
            showNotice("Inference is not connected", "The sample does not send prompts or generate responses. The real app should handle this intent.")
        case .stopGeneration:
            store.isResponding = false
        case .addAttachment:
            showNotice("Attachments", "Connect the host app's attachment picker. The preview does not read your files.")
        case .openImageModelPicker:
            store.secondaryRoute = nil
            store.selectedTab = .models
        case .generateImage:
            showNotice("Image generation is not connected", "Choose an installed image model and connect the real generator in the host before enabling Generate.")
        case .cancelImageGeneration:
            showNotice("No generation is running", "This preview never starts image generation.")
        case .selectVoice(let id):
            if store.voices.contains(where: { $0.id == id }) { store.selectedVoiceID = id }
        case .previewVoice:
            showNotice("Audio preview is not connected", "Connect the host's preview service. The sample does not play audio.")
        case .stopVoicePreview:
            store.voicePreviewID = nil
        case .selectEngine:
            showNotice("Voice engine", "Kokoro Neural is a fixture label. Connect the app's engine selector here.")
        case .beginVoiceSession:
            store.voiceSessionActive = true
            store.voiceSessionPresented = true
        case .endVoiceSession:
            store.voiceSessionActive = false
            store.voiceSessionPresented = false
            chooseVoiceScenario(.idle)
        case .setSpeakerEnabled(let enabled):
            store.speakerEnabled = enabled
        case .setMicrophoneEnabled(let enabled):
            store.microphoneEnabled = enabled
            store.voicePhase = enabled ? .listening : .idle
        case .selectAudioRoute:
            showNotice("Audio output", "This is a visual session only. Connect the native route picker in the real app.")
        case .capture, .analyzeLens, .retakeLens, .cancelLensAnalysis, .openPhotoLibrary, .switchCamera:
            showNotice("Camera is not connected", "The sample does not open a camera or photo library. Supply the host preview and handlers to enable these controls.")
        case .showLensOptions, .showLensHistory:
            showNotice("Lens options", "Connect the app's current Lens options and permission flow here.")
        case .selectLensModel:
            store.selectedTab = .models
        }
    }
}

@MainActor
private struct DemoControls: View {
    @ObservedObject var demo: DemoSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sample data") {
                    Text("This preview uses fixture models, messages, and storage values. It never performs inference, downloads models, records audio, opens a camera, or changes user files.")
                    Text("Appearance is a real local preference; the remaining backend states below are for visual review.")
                        .foregroundStyle(.secondary)
                }
                Section("Conversation") {
                    Button("Show example conversation") { demo.showConversation(); dismiss() }
                    Button("Show new chat") { demo.newConversation(); dismiss() }
                    Button("Show attached draft") { demo.showAttachedDraft() }
                    Text("The attached-draft preview shows notes.txt metadata only. No file is read, added, removed or sent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Image studio") {
                    Button("Show image result") { demo.showImageResult() }
                    Text("Shows a bundled example image. No image model or generator runs; Generate stays disabled.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Model presentation") {
                    Picker("State", selection: Binding(
                        get: { demo.modelScenario }, set: { demo.chooseModelScenario($0) }
                    )) {
                        ForEach(DemoModelScenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Preparing is a static presentation state. No timer, progress estimate, or real load runs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Voice presentation") {
                    Picker("State", selection: Binding(
                        get: { demo.voiceScenario }, set: { demo.chooseVoiceScenario($0) }
                    )) {
                        ForEach(DemoVoiceScenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Choose a state here, then open Voice and Start conversation. The full-screen view is labeled as a preview; it never activates audio.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Reset sample data") { demo.reset() }
                }
            }
            .navigationTitle("Preview controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
