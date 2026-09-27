import SwiftUI
import OnDeviceUI

@main
struct NativeUIReviewApp: App {
    @StateObject private var fixture = ReviewFixture()
    @State private var hostTab: ODTab = .chat
    private var argsLargeType: Bool { ProcessInfo.processInfo.arguments.contains("-large-type") }
    var body: some Scene {
        WindowGroup {
            Group {
                if fixture.screen == "home-concept" {
                    OnDeviceWorkbench(store: fixture.store, chatContent: AnyView(HomeConceptReview(variant: fixture.homeVariant)))
                } else if fixture.screen == "appearance" {
                    AppearanceReview(store: fixture.store)
                } else if fixture.screen == "onboarding" {
                    OnboardingOnePager(onFinish: {}).preferredColorScheme(fixture.dark ? .dark : .light)
                } else if fixture.screen == "splash" {
                    // Static hold (no-op finish) so renders capture the lockup.
                    BootSplashView(onFinished: {})
                        .preferredColorScheme(fixture.dark ? .dark : .light)
                } else if fixture.screen == "import-picker" {
                    ModelImportPickerReview()
                } else {
                    OnDeviceWorkbench(store: fixture.store,
                        cameraPreview: AnyView(LensReviewFixture().environmentObject(fixture.store)),
                        chatContent: fixture.screen == "composer" || fixture.screen == "welcome" ? AnyView(ComposerContractView(welcome: fixture.screen == "welcome").dynamicTypeSize(argsLargeType ? .accessibility5 : .large)) : nil,
                        imageContent: AnyView(ImageGenerationView(onOpenMenu: { fixture.store.conversationsPresented = true })),
                        deviceContent: AnyView(NativeDeviceView(onOpenMenu: { fixture.store.conversationsPresented = true })),
                        // A presented UIKit host does not inherit a preview-only
                        // Dynamic Type override; set it at this fixture boundary.
                        voiceContent: AnyView(ODVoiceSessionView().dynamicTypeSize(argsLargeType ? .accessibility3 : .large)),
                        apiServerContent: AnyView(LocalAPIServerView(onOpenMenu: { fixture.store.conversationsPresented = true })))
                }
            }
            .modifier(WorkbenchSelectionObserver(
                store: fixture.store,
                onTabSelection: { hostTab = $0 },
                onCameraModeSelection: { _ in }
            ))
            .overlay(alignment: .topTrailing) {
                if ProcessInfo.processInfo.arguments.contains("-host-selection-probe") {
                    Text(hostTab.rawValue)
                        .accessibilityIdentifier("host.selection")
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if ProcessInfo.processInfo.arguments.contains("-action-probe") {
                    Text(fixture.lastAction).accessibilityIdentifier("fixture.action").allowsHitTesting(false)
                }
            }
            .dynamicTypeSize(argsLargeType ? .accessibility3 : .large)
            .frame(width: fixture.probeWidth)
        }
    }
}

private struct ModelImportPickerReview: View {
    @State private var showsImport = false
    @State private var selectedName = "None"

    var body: some View {
        NavigationStack {
            Button("Import model") { showsImport = true }
                .accessibilityIdentifier("import.review.open")
                .navigationTitle("Models")
                .overlay(alignment: .bottom) {
                    Text(selectedName).accessibilityIdentifier("import.review.selected")
                        .offset(y: 80)
                }
                .localModelImportFlow(isPresented: $showsImport) { urls in
                    selectedName = urls.count == 1
                        ? (urls.first?.lastPathComponent ?? "None")
                        : "\(urls.count) files"
                }
        }
        .task {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SampleModel", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "{}".write(to: directory.appendingPathComponent("config.json"),
                            atomically: true, encoding: .utf8)
        }
    }
}

final class ReviewFixture: ObservableObject {
    let store = ODStore.demo()
    @Published var lastAction = "None"
    let screen: String
    let homeVariant: String
    let dark: Bool
    let compact: Bool
    let probeWidth: CGFloat?
    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
        screen = value("-screen") ?? "composer"
        homeVariant = value("-home-variant") ?? "focus"
        dark = args.contains("-dark")
        compact = args.contains("-compact")
        probeWidth = value("-width").flatMap(Double.init).map { CGFloat($0) } ?? (compact ? 320 : nil)
        store.appearance = args.contains("-oled") ? .oled : (dark ? .dark : .light)
        store.selectedTab = screen == "home" ? .home : .chat
        store.capabilities.canPinConversations = true
        store.capabilities.canOpenAPIServer = true
        ODBridge.shared.store = store
        store.voiceAvailabilityMessage = nil
        if screen == "home" {
            store.recentConversations = [
                .init(id: "day", title: "Plan a focused workday", subtitle: "Choose three priorities", dateLabel: "Today", isPinned: true),
                .init(id: "notes", title: "Notes from this week", subtitle: "Review and organize", dateLabel: "Today", isPinned: true),
                .init(id: "swift", title: "Review a Swift function", subtitle: "A small code review", dateLabel: "Yesterday", isPinned: true),
                .init(id: "weekend", title: "A quiet weekend", subtitle: "Ideas for Saturday", dateLabel: "Yesterday"),
                .init(id: "outline", title: "Make an outline from these notes", subtitle: "Writing", dateLabel: "Yesterday"),
                .init(id: "translate", title: "Translate this paragraph", subtitle: "English and Turkish", dateLabel: "Earlier"),
                .init(id: "reading", title: "My reading list", subtitle: "Books for autumn", dateLabel: "Earlier"),
                .init(id: "ideas", title: "Ideas for the next update", subtitle: "A short checklist", dateLabel: "Earlier"),
                .init(id: "email", title: "Draft a reply", subtitle: "Keep it concise", dateLabel: "Earlier")
            ]
        }
        if screen == "home", args.contains("-short-history") {
            store.recentConversations = Array(store.recentConversations.prefix(3)).map {
                var conversation = $0; conversation.isPinned = false; return conversation
            }
        }
        if screen == "api" {
            store.selectedTab = .apiServer
            // Explicit API-server fixtures. No socket is ever opened.
            if args.contains("-api-running") {
                AppSettings.shared.localAPIEnabled = true
                LocalAPIManager.shared.state = .running(UInt16(AppSettings.shared.localAPIPort))
            }
            if args.contains("-api-starting") { LocalAPIManager.shared.state = .starting }
            if let index = args.firstIndex(of: "-api-failed"), args.indices.contains(index + 1) {
                LocalAPIManager.shared.state = .failed(args[index + 1])
            }
            if args.contains("-api-no-address") { LocalAPIManager.shared.addresses = [] }
            if args.contains("-api-model-loading") { CodingAssistantService.shared.state = .loading("Preparing weights") }
            if args.contains("-api-model-unloaded") { CodingAssistantService.shared.state = .unloaded }
            if args.contains("-api-generating") {
                CodingAssistantService.shared.state = .generating
                CodingAssistantService.shared.tokenRate = 18.4
            }
            if args.contains("-api-no-model") {
                CodingAssistantService.shared.activeDisplayName = ""
                CodingAssistantService.shared.state = .unloaded
            }
        }
        if screen == "settings" { store.secondaryRoute = .settings }
        if screen == "device" { store.selectedTab = .device }
        if screen == "image" { store.selectedTab = .imageStudio }
        if args.contains("-image-empty") {
            ImageGenerationService.shared.image = nil
            ImageGenerationService.shared.resultPrompt = nil
        }
        ODBridge.shared.store = store
        if screen == "voice" { store.selectedTab = .voice }
        if screen == "models" { store.selectedTab = .models }
        if screen == "lens" { store.selectedTab = .lens }
        if args.contains("-drawer-open") { store.conversationsPresented = true }
        store.capabilities.canCapture = true
        store.capabilities.canChoosePhoto = true
        if screen == "conversation" {
            store.messages = [.init(role: .user, text: "Help me plan a focused workday."),
                              .init(role: .assistant, text: "Start with one important task.\n\nGive it your first uninterrupted hour. Keep the next block for calls and small decisions.\n\nLeave a little space at the end of the day to review what moved forward.")]
            if args.contains("-long-conversation") {
                let paragraph = "A readable answer should use the full conversation width without adding a blank band above the composer."
                store.messages = [
                    .init(role: .assistant, text: Array(repeating: paragraph, count: 14).joined(separator: "\n\n")),
                    .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000057")!, role: .user, text: "Latest question")
                ]
            }
        }
        if args.contains("-model-unloaded") { store.loadedModelID = nil; store.modelPhase = .unloaded }
        // Reasoning switch fixtures; absent by default so existing captures are unchanged.
        if args.contains("-thinking") { store.thinkingEnabled = false }
        if args.contains("-thinking-on") { store.thinkingEnabled = true }
        if args.contains("-personas") {
            store.personas = [
                .init(id: "general", name: "Assistant", subtitle: "Everyday questions and tasks", symbol: "sparkles"),
                .init(id: "writer", name: "Writer", subtitle: "Drafts, edits, tone and stories", symbol: "pencil.line"),
                .init(id: "coder", name: "Coder", subtitle: "Write, review and debug code", symbol: "chevron.left.forwardslash.chevron.right"),
            ]
            store.selectedPersonaID = "general"
        }

        if args.contains("-camera-denied") {
            store.capabilities.canCapture = false
            store.cameraNeedsSettings = true
            store.lensStatusMessage = "Camera access is off. Turn it on to use the Lens."
        }
        if args.contains("-lens-analyzing") {
            store.lensIsAnalyzing = true
            store.capabilities.canCancelLensAnalysis = true
        }
        if args.contains("-voice-active") {
            store.voiceSessionActive = true
            store.voicePhase = .listening
            store.microphoneEnabled = true
        }
        if args.contains("-voice-session") {
            store.voiceSessionActive = true
            store.voicePhase = .listening
            store.microphoneEnabled = true
            store.microphoneCapturing = true
            store.speakerEnabled = true
            store.voiceSessionPresented = true
        }
        store.capabilities.canPreviewVoices = true
        store.capabilities.canMinimizeVoiceSession = true
        if args.contains("-voice-setup") {
            store.voiceAvailabilityMessage = "Download the selected voice engine, or choose Apple Voice in Voice settings."
            store.capabilities.canStartVoice = false
        }
        if args.contains("-voice-denied") {
            store.voicePhase = .failed(message: "Microphone or speech recognition permission denied.")
            store.voiceSessionPresented = true
            store.voiceSessionActive = false
        }
        if args.contains("-model-loading") { store.modelPhase = .preparing(step: "Loading model") }
        if args.contains("-model-failed") { store.modelPhase = .failed(message: "Model could not be loaded. Choose another model or retry.") }
        if args.contains("-model-actions") {
            store.capabilities.canLoadModels = true
            store.models.append(.init(id: "review/catalog-model", name: "Review catalog model",
                metadata: "UI test fixture", byteCount: 1_000_000_000, kind: .language,
                isInstalled: false, availableCommands: [.details, .configure, .download, .pauseDownload, .cancelDownload],
                downloadStatus: args.contains("-model-paused") ? "Paused"
                    : args.contains("-model-downloading") || args.contains("-model-invalid-progress") ? "Downloading" : nil,
                downloadProgress: args.contains("-model-invalid-progress") ? .nan
                    : args.contains("-model-downloading") || args.contains("-model-paused") ? 0.4 : nil,
                isDownloadPaused: args.contains("-model-paused"),
                summary: "Fast for chat and code.", vendor: "qwen", badges: ["Recommended"],
                downloadSizeLabel: "~1 GB"))
        }
        if args.contains("-model-dual-role") {
            store.capabilities.canLoadModels = true
            store.models.append(.init(
                id: "review/dual-model",
                name: "Unified test model",
                metadata: "Chat and vision",
                kind: .language,
                supportedKinds: [.language, .vision],
                isInstalled: true,
                availableCommands: [.details]
            ))
        }
        if args.contains("-model-dual-blocked") {
            store.capabilities.canLoadModels = true
            store.models.append(.init(
                id: "review/blocked-dual-model",
                name: "Bonsai 2 test pack",
                metadata: "Text and vision components",
                kind: .vision,
                supportedKinds: [],
                declaredKinds: [.language, .vision],
                isInstalled: true,
                isSelectable: false,
                unavailableReason: "Hadamard-aware loader unavailable",
                availableCommands: [.details]
            ))
        }
        store.onAction = { [weak self, weak store] action in
            guard let store else { return }
            self?.lastAction = String(describing: action)
            switch action {
            case .capture: store.lensHasSelectedImage = true
            case .retakeLens: store.lensHasSelectedImage = false; store.lensResultText = nil
            case .analyzeLens:
                store.lensIsAnalyzing = true
                store.capabilities.canCancelLensAnalysis = true
            case .cancelLensAnalysis:
                store.lensIsAnalyzing = false
                store.capabilities.canCancelLensAnalysis = false
                store.lensStatusMessage = "Analysis cancelled"
            case .setConversationPinned(let id, let pinned):
                if let index = store.recentConversations.firstIndex(where: { $0.id == id }) {
                    store.recentConversations[index].isPinned = pinned
                }
            case .openConversation(let id):
                store.selectedConversationID = id
                store.messages = [.init(role: .user, text: store.selectedConversation?.title ?? "Conversation")]
            case .newConversation:
                store.selectedConversationID = nil
                store.messages = []
                store.composerText = ""
            case .setThinking(let on): store.thinkingEnabled = on
            case .selectPersona(let id): store.selectedPersonaID = id
            case .selectVoice(let id): store.selectedVoiceID = id
            case .previewVoice(let id): store.voicePreviewID = id
            case .stopVoicePreview: store.voicePreviewID = nil
            case .beginVoiceSession:
                store.voicePreviewID = nil
                store.voicePhase = .listening
                store.voiceSessionActive = true
                store.voiceSessionPresented = true
                store.speakerEnabled = true
                store.microphoneEnabled = true
                store.microphoneCapturing = true
            case .endVoiceSession:
                store.voicePhase = .idle
                store.voiceSessionActive = false
            case .setSpeakerEnabled(let value): store.speakerEnabled = value
            case .setMicrophoneEnabled(let value): store.microphoneEnabled = value
            default: break
            }
        }
    }
}

struct ComposerContractView: View {
    @EnvironmentObject private var store: ODStore
    var welcome = false
    private let conversations: [StoredConversation] = {
        var yesterday = StoredConversation(title: "A quieter week")
        yesterday.updatedAt = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        return [StoredConversation(title: "Plan my day"), StoredConversation(title: "Notes from this week"), yesterday]
    }()
    private var modelName: String {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-long-model") { return "A deliberately long installed local model name Q5_K_M" }
        return args.contains("-production-footer") ? "Ornith 1.5 9B" : "Local model"
    }
    private var modelControl: AnyView {
        if ProcessInfo.processInfo.arguments.contains("-production-footer") {
            return AnyView(Button { status = "Model picker opened" } label: {
                ODModelMenuLabel(displayName: modelName)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model")
            .accessibilityValue(modelName))
        }
        return AnyView(Menu { Button("Model details") { status = "Model details opened" } } label: {
            ODModelMenuLabel(displayName: modelName)
        }
        .accessibilityLabel("Model")
        .accessibilityValue(modelName))
    }
    private var microphoneControl: AnyView? {
        guard ProcessInfo.processInfo.arguments.contains("-production-footer") else { return nil }
        return AnyView(Button { status = "Dictation opened" } label: {
            Image(systemName: "mic").frame(width: ODLayout.minimumHit, height: ODLayout.minimumHit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictation")
        .accessibilityIdentifier("chat.composer.microphone"))
    }
    @State private var text = ""
    @State private var attachments: [ODAttachment] = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-image-attachments") {
            let data = Bundle.main.url(forResource: "studio-example", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
            return [ODAttachment(id: "image-1", name: "Image 1", kind: .image, previewData: data),
                    ODAttachment(id: "image-2", name: "Image 2", kind: .image, previewData: data)]
        }
        return args.contains("-attachments") ? [.init(id: "file-1", name: "notes.txt", kind: .file)] : []
    }()
    @State private var responding = false
    @State private var status = "Ready"
    @State private var failureVisible = ProcessInfo.processInfo.arguments.contains("-generation-failed")
    @FocusState private var focus: Bool
    private var voiceAction: (() -> Void)? {
        guard ProcessInfo.processInfo.arguments.contains("-composer-voice") else { return nil }
        return { focus = false; store.send(.beginVoiceSession) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if welcome {
                        ChatThreadEmptyState(isFiltering: false, modelName: "Ornith 1.5 9B", modelStatus: "Ready",
                            loadFailure: nil, failureCanRetry: false, canGenerate: true,
                            onRetry: {}, onSwitchModel: {}, onTryAnyway: nil)
                    } else {
                        Text("Native composer review").font(.title2)
                        Text("UI fixture · no inference").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(status).accessibilityIdentifier("submission.status")
                    if ProcessInfo.processInfo.arguments.contains("-response-actions") {
                        Text("Start with one important task.").font(.body)
                        StudioGenerationRate(tokensPerSecond: 18.4)
                        StudioAnswerActionRow(footnote: "local_Ornith-1.5-9B-Q5_K_M · 16s",
                            onCopy: { status = "Copied" }, onRegenerate: { status = "Regenerate" },
                            onShare: { status = "Share" }, onSpeak: { status = "Read aloud" },
                            onQuickAction: { status = $0.label })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(welcome ? 0 : 20)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle(welcome ? "OnDevice" : "A focused workday").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar {
                    VStack(spacing: 0) {
                    ODComposer(text: $text, focus: $focus, attachments: attachments,
                    isResponding: responding, canSend: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
                    canStop: true, canAdd: !responding, canRemove: !responding,
                    microphone: microphoneControl,
                    notice: failureVisible ? AnyView(ChatReplyFailureNotice(
                        detail: "The model stayed busy; retry shortly", canRetry: true,
                        onRetry: { failureVisible = false; responding = true; status = "Retry accepted" })) : nil,
                    onVoice: voiceAction,
                    onAdd: { attachments.append(.init(id: "file-\(attachments.count + 1)", name: "notes.txt")) },
                    onRemove: { id in attachments.removeAll { $0.id == id } },
                    onSend: { submitted, ids in
                        if ProcessInfo.processInfo.arguments.contains("-reject") { status = "Not accepted"; return }
                        status = "Accepted: \(submitted)\nAttachments: \(ids.joined(separator: ","))"
                        responding = true; text = ""; attachments = []; focus = false
                    }, onStop: { responding = false; status = "Stopped" })
                    if focus {
                        HStack {
                            ODKeyboardDismissKey(focus: $focus)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, ODLayout.pageInset)
                        .frame(minHeight: ODLayout.minimumHit)
                    }
                    }
                }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .chat { focus = false }
            }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { focus = false }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton {
                        focus = false
                        store.conversationsPresented = true
                    }.accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .principal) {
                    modelControl.accessibilityIdentifier("chat.modelPicker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("More options", systemImage: "ellipsis") { status = "Options opened" }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

struct AppearanceReview: View {
    @ObservedObject var store: ODStore
    @State private var haptics = true
    @State private var fps = false
    @State private var language = "Auto"
    @State private var icon = "Max"
    @State private var reset = false
    var body: some View {
        NavigationStack {
            List {
                AppearanceSettingsContent(appearance: $store.appearance, hapticsEnabled: $haptics,
                    showFPSCounter: $fps, supportsAlternateIcons: true) {
                    HStack(spacing: 14) {
                        ForEach(["Max", "Classic"], id: \.self) { title in
                            Button { icon = title } label: {
                                VStack(spacing: 5) {
                                    Image(title == "Max" ? "AppIconPreview" : "AppIconClassicPreview")
                                        .resizable().frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(icon == title ? ODPalette.text : ODPalette.line, lineWidth: icon == title ? 2 : 1) }
                                    Text(title).font(.footnote)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 8)
                } languagePicker: {
                    Picker("Language", selection: $language) {
                        Text("Auto").tag("Auto")
                        Text("English").tag("English")
                    }
                } onResetTips: { reset = true }
            }
            .listStyle(.plain)
            .listSectionSpacing(16)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
            .alert("Tips reset", isPresented: $reset) { Button("OK", role: .cancel) {} }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .environment(\.odAppearance, store.appearance)
    }
}

/// This image is a review fixture, never a live sensor frame or inference result.
private struct LensReviewFixture: View {
    @EnvironmentObject var store: ODStore
    var body: some View {
        if store.lensHasSelectedImage,
           let url = Bundle.main.url(forResource: "studio-example", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Selected fixture image")
        } else {
            ContentUnavailableView("Camera preview unavailable", systemImage: "camera", description: Text("UI fixture · no camera capture"))
                .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        }
    }
}
