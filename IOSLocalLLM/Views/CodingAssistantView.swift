import SwiftUI
import OnDeviceUI
import PhotosUI
import Vision
import CoreImage
import os

private struct AssistantSharePayload: Identifiable {
    let id = UUID()
    let text: String
    /// Set when the payload is a file (a conversation exported as .md/.json)
    /// rather than a transcript string.
    var fileURL: URL? = nil

    /// What the share sheet actually receives. `text` doubles as the title of
    /// a file payload so a single sheet can present both kinds.
    var shareItems: [Any] { fileURL.map { [$0] } ?? [text] }
}

/// Keeps thermal observation inside the runtime sheet. Thermal and battery
/// changes no longer invalidate the entire 5K-line assistant screen while the
/// sheet is closed.
private struct AssistantRuntimeDetailsSheetHost: View {
    let model: AssistantModel
    let status: String
    let onSwitchModel: () -> Void

    @ObservedObject private var safety = DeviceSafetyMonitor.shared

    var body: some View {
        AssistantRuntimeDetailsSheet(
            model: model,
            status: status,
            thermalStatus: safety.statusLabel ?? "Nominal",
            onSwitchModel: onSwitchModel
        )
    }
}

// MARK: - CodingAssistantView

struct CodingAssistantView: View {
    /// TabView keeps inactive tabs mounted. Thread the real selection through
    /// so a hidden Assistant cannot reload its model while Lens is taking
    /// ownership of the inference runtime.
    let isActive: Bool
    var onClose: () -> Void = {}

    @StateObject private var assistant = CodingAssistantService.shared
    @StateObject private var store = ConversationStore.shared
    @StateObject private var bridge = AppBridge.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var legal = LegalAcceptanceManager.shared
    @ObservedObject private var loc = LocalizationService.shared
    @ObservedObject private var imageGen = ImageGenerationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var draftRevision: UInt64 = 0
    @State private var operationID = UUID()
    @State private var acceptedSubmission: ChatPresentationRequest?
    @State private var submissionPreparing = false
    @State private var generationFailure: String?
    @State private var readingMessageID: UUID?
    @State private var restoredDraftImages: [ChatMessage.ImageAttachment]?
    @State private var restoredInitialPresentation = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var dictationResetID = UUID()
    // Per-send sampler overrides. nil → fall back to AppSettings defaults
    // inside CodingAssistantService.generate(). Cleared after each
    // successful send so the override is genuinely "for the next message
    // only" (matches how cloud assistants like Pi handle one-off tonal
    // knobs). showSamplerControls drives the inline disclosure.
    @State private var nextSendTemperature: Double?
    @State private var nextSendTopP: Double?
    @State private var nextSendTopK: Int?
    @State private var nextSendRepetitionPenalty: Double?
    @State private var nextSendSeed: UInt64?
    @State private var showSamplerControls = false
    @State private var nextSendJSONMode: Bool = false
    @State private var nextSendCollectLogprobs: Bool = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showClearConfirm = false
    @State private var showConversationPicker = false
    @State private var showPhotoPicker = false
    @State private var showModelPicker = false
    @State private var showRuntimeDetails = false
    @State private var showPersonaPicker = false
    @State private var showSnippetPicker = false
    /// Replaces the five-icon keyboard toolbar — see StudioAddSheet.
    @State private var showAddSheet = false
    /// Message IDs whose reasoning rule is expanded in place.
    @State private var reasoningExpanded: Set<UUID> = []
    @State private var showSettings = false
    @State private var showBenchmark = false
    @State private var showCompare = false
    @State private var showMacros = false
    @State private var showWebSettings = false
    @State private var showDownloadCenter = false
    @State private var showUnsafeModelLoadConfirmation = false
    @State private var sharePayload: AssistantSharePayload?
    @State private var pendingWebPermission: WebPermissionRequest? = nil
    @State private var webPreparationTask: Task<Void, Never>?
    @State private var webPreparationID: UUID?
    @State private var webPreparationPrompt: String?
    /// Consent gate for a web_search the *model* requested via a tool call
    /// while Web Access is "ask every time". Mirrors pendingWebPermission but
    /// resumes a tool follow-up instead of a fresh send.
    @State private var pendingToolWeb: ToolWebApproval? = nil
    /// Consent/UI bridge for a model-initiated `file_read` tool call.
    @State private var pendingToolFile: ToolFileRequest? = nil
    @State private var pendingToolConfirm: ToolConfirmRequest? = nil
    /// Presents the document picker only after the inline file-approval
    /// card is accepted. The generate loop itself does not change.
    @State private var showToolFilePicker = false
    /// Name of the in-flight tool (web_search, file_read, …). Overlay-only;
    /// never persisted into the transcript.
    @State private var runningToolName: String? = nil
    /// Set by Stop. Late tool completions still persist their result card
    /// but must not start another generate.
    @State private var userAbortedToolTurn = false
    /// Assistant message ids that already tried the "final answer only"
    /// recovery pass after ending inside an open reasoning block.
    @State private var reasoningRecoveryMessageIDs: Set<UUID> = []
    /// Calls recognized before generation naturally stops. Detecting a
    /// complete JSON object lets us cancel decoding immediately instead of
    /// making the user wait while a small model rambles after its tool call.
    @State private var detectedStreamingToolCalls: [UUID: ToolCall] = [:]
    /// User-attached files for the next send. Cleared after send completes.
    @State private var pendingAttachments: [FileAttachmentService.Attachment] = []
    @State private var showFilePicker = false
    /// JPEG thumbnail (~480 px) of the most-recently-attached photo.
    /// Travels with the next user message as `imageThumbnailData` so the
    /// chat bubble renders the actual picture instead of pretending the
    /// user typed a code block of OCR'd text. Cleared after send.
    @State private var pendingImageThumbnail: Data? = nil
    /// Multiple image thumbnails for interleaved vision (Feature #11).
    /// When non-empty, all images are bundled into the ChatMessage.
    @State private var pendingImageThumbnails: [ChatMessage.ImageAttachment] = []
    /// Text-only chat models temporarily hand attached images to the selected
    /// visual model, then resume with the resulting on-device description.
    @State private var isPreparingImageContext = false
    @State private var imageGroundingTask: Task<Void, Never>?
    @State private var imageGroundingPrompt: String?
    @State private var emptyVisualRecoveryMessageIDs: Set<UUID> = []
    /// Cited indices the LLM emitted in its last reply — used to filter the
    /// citations panel.
    @State private var lastUsedCitedIndices: Set<Int> = []
    @State private var lastWebCitations: [WebSourceCitation] = []
    @State private var draftImageIDs: [UUID] = []
    @State private var legacyDraftImageID = UUID()
    @State private var currentConversationID: UUID? = nil
    /// Persistent summary of turns that have aged out of the model's live
    /// context. The full `messages` transcript remains untouched for the UI.
    @State private var conversationContextMemory: ConversationContextMemory? = nil

    /// Bridge-pill state. Drives the small capsule next to the model
    /// picker that tells the user whether `/mac …` is going to reach
    /// a paired Mac. Updated on tab appear + on tap (manual probe).
    /// No background polling — heartbeat is cheap but not free, and
    /// the user is in control of when to verify.
    @State private var bridgePillState: BridgePillState = .unknown

    enum BridgePillState {
        case unknown                      // first paint, before any probe
        case notPaired                    // no Mac with a bearer in pairing store
        case probing                      // heartbeat in flight
        case connected(latencyMs: Int)    // last probe was ok
        case unreachable(reason: String)  // last probe failed
    }

    /// Wraps the data needed to drive WebPermissionSheet so SwiftUI's
    /// `.sheet(item:)` can identify the request.
    struct WebPermissionRequest: Identifiable {
        let id = UUID()
        let reason: String
        let payload: QueryOrURL
        let originalText: String
    }

    /// Drives the consent sheet for a model-initiated `web_search` tool call.
    struct ToolWebApproval: Identifiable {
        let id = UUID()
        let query: String
        let payload: QueryOrURL
        /// Tool-chain recursion depth captured when consent was requested, so
        /// the consent detour doesn't reset the runaway-loop cap.
        let depth: Int
    }

    struct ToolFileRequest: Identifiable {
        let id = UUID()
        let prompt: String
        let depth: Int
        let scope: ChatPresentationRequest
    }

    struct ToolConfirmRequest: Identifiable {
        let id = UUID()
        let call: ToolCall
        let depth: Int
    }
    /// Filter text for in-conversation search. Non-empty value swaps the
    /// scrollview into a filtered view that only shows matching messages.
    @State private var conversationFilter: String = ""
    @State private var showConversationSearch = false
    @FocusState private var inputFocused: Bool
    @StateObject private var keyboardClearance = ODComposerKeyboardClearance()
    @State private var isNearConversationBottom = true
    /// Remember whether the user was following the live answer before the
    /// composer left the layout. When it returns, re-anchor only in that case;
    /// someone who deliberately scrolled up should not be pulled away.
    @State private var followsConversation = true
    @State private var documentSearchTask: Task<Void, Never>?
    @State private var documentSearchID: UUID?
    @State private var documentSearchPrompt: String?
    @State private var completionScrollTask: Task<Void, Never>?
    @State private var lastStreamScrollTime = 0.0
    @Environment(\.accessibilityReduceMotion) private var chatReduceMotion
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// A dedicated target after every message and its trailing actions.
    ///
    /// Scrolling to the final message's ID is subtly wrong when that message is
    /// taller than the viewport: SwiftUI may reveal the message view without
    /// placing its actual bottom above the composer. The tail anchor always
    /// represents the true end of the conversation.
    private let conversationBottomAnchorID = "conversation-bottom-anchor"

    var body: some View {
        // Backdrop is owned by ContentView (StudioPageBackground for the assistant
        // tab, Color.black for the camera tab). Painting a full-bleed T.bg here
        // used to leak as a cream-colored vertical strip on the lens tab when
        // SwiftUI kept this subtree resident across a tab switch.
        NavigationStack {
            VStack(spacing: 0) {
                // Model selection lives in the composer. Explain live runtime
                // work independently of any stored replies in the transcript.
                if modelStatusDescriptor.title != "Ready" {
                    modelStatusBar
                }

                if showConversationSearch {
                    conversationSearchBar
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ODLayout.groupGap) {
                            if filteredMessages.isEmpty {
                                ChatThreadEmptyState(
                                    isFiltering: showConversationSearch
                                        && !conversationFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    attachedFilename: draftAttachmentNames.first,
                                    attachedFileCount: draftAttachmentNames.count,
                                    modelName: assistant.activeDisplayName,
                                    modelStatus: modelStatusDescriptor.title,
                                    loadFailure: modelLoadFailure,
                                    failureCanRetry: !hasPermanentModelCapacityFailure,
                                    canGenerate: assistant.canGenerateSelectedTarget,
                                    onRetry: {
                                        Task { await ensureModelReady() }
                                    },
                                    onSwitchModel: {
                                        showModelPicker = true
                                    },
                                    onTryAnyway: hasPermanentModelCapacityFailure
                                        ? { showUnsafeModelLoadConfirmation = true }
                                        : nil
                                )
                                // No horizontal padding here — the empty state
                                // applies the thread's own 20pt inset, so
                                // adding 16 on top pushed it 36pt in, well out
                                // of line with every message below it.
                            }
                            ForEach(filteredMessages) { msg in
                                transcriptRow(msg)
                                .id(msg.id)
                            }
                            activityCards
                            // The safe-area inset reserves the composer's
                            // measured height. This small tail is only visual
                            // breathing room below the final message.
                            Color.clear
                                .frame(height: 12)
                                .id(conversationBottomAnchorID)
                        }
                        .padding(.vertical, 12)
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $readingMessageID, anchor: .top)
                    .scrollDismissesKeyboard(.interactively)
                    // Tap empty space in the chat area to dismiss the keyboard
                    .simultaneousGesture(
                        TapGesture().onEnded { inputFocused = false }
                    )
                    .onAppear { scrollProxy = proxy }
                    // Coalesce streaming scroll work by elapsed time, independent of token size.
                    .onChange(of: messages.last?.content.utf8.count) { _, _ in
                        let now = ProcessInfo.processInfo.systemUptime
                        guard followsConversation, now - lastStreamScrollTime >= 0.08 else { return }
                        lastStreamScrollTime = now
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            followsConversation = false
                            completionScrollTask?.cancel()
                        } else if phase == .idle {
                            followsConversation = isNearConversationBottom
                        }
                    }
                    .onChange(of: pendingToolWeb?.id) { _, _ in
                        guard followsConversation else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                        }
                    }
                    .onChange(of: pendingToolFile?.id) { _, _ in
                        guard followsConversation else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                        }
                    }
                    .onChange(of: runningToolName) { _, _ in
                        if isNearConversationBottom {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                                proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                        return visibleBottom >= geometry.contentSize.height - 96
                    } action: { _, nearBottom in
                        isNearConversationBottom = nearBottom
                    }
                    .onChange(of: inputFocused) { _, focused in
                        // When focusing, scroll the last message to bottom so it
                        // doesn't end up behind the composer
                        if focused, !messages.isEmpty {
                            isNearConversationBottom = true
                            followsConversation = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearConversationBottom, !messages.isEmpty {
                        Button {
                            isNearConversationBottom = true
                            followsConversation = true
                            if !messages.isEmpty {
                                withAnimation(reduceMotion ? nil : AppAnimation.state) {
                                    scrollProxy?.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.adaptiveMaterial(reduceTransparency: reduceTransparency,
                                                              opaque: T.studio.surfaceRaised),
                                            in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous).stroke(T.rule, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Jump to latest message")
                        // Lifted well off the bottom edge: the reply-action
                        // chip row (Continue / Shorter / …) sits at the foot
                        // of the transcript, and a 16pt inset put this button
                        // on top of the trailing chip (2026-09-21 device
                        // report). 72pt clears the chip row plus breathing room.
                        .padding(.trailing, 16)
                        .padding(.bottom, 72)
                    }
                }
            }
            // Flat paper page. The thread is the surface; the composer card is
            // the only thing that sits above it, which is what gives the page
            // its one clear layer boundary.
            .background(T.studio.paper.ignoresSafeArea())
            // Pin the composer above the keyboard.
            //
            //   [ chat content        ]
            //   [ composer card       ]
            //   [ keyboard / tab bar  ]
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Stays mounted while generating — the field remains editable
                // and the metrics row appears above the card instead of the
                // whole bar swapping out.
                ODComposerKeyboardSlot(clearance: keyboardClearance) {
                    ODWorkspaceBottomBar { inputBar }
                }
            }
            // Leading chat apps dismiss entry focus when a request starts and
            // retain a dedicated Stop action. Our Stop remains in the top
            // toolbar, so the large composer can get out of the answer's way.
            .animation(.easeOut(duration: 0.18), value: isGenerating)
            .onChange(of: isGenerating) { wasGenerating, generating in
                completionScrollTask?.cancel()
                guard wasGenerating, !generating, followsConversation else { return }
                let lastMessageID = messages.last?.id
                completionScrollTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                    guard !Task.isCancelled, followsConversation, !isGenerating,
                          messages.last?.id == lastMessageID else { return }
                    scrollProxy?.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                }
            }
            .onDisappear { completionScrollTask?.cancel(); cancelDocumentSearch(); savePresentation() }
            .navigationTitle(currentConversationTitle ?? "OnDevice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    KeyboardDismissKey(focus: $inputFocused, clearance: keyboardClearance)
                    Spacer(minLength: 0)
                }
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton {
                        inputFocused = false
                        ODBridge.shared.store.conversationsPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Open conversations and app menu")
                    .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Overflow menu — groups secondary actions so iOS never
                    // collapses toolbar items into the unreliable "..." button.
                    // Voice conversation lives here too (was a separate top
                    // button); the input bar's mic still provides one-tap
                    // dictation, so the top row stays uncluttered.
                    Menu {
                        Button {
                            clearConversation()
                            HapticManager.impact(.medium)
                        } label: {
                            Label(loc.t("New conversation"), systemImage: "square.and.pencil")
                        }
                        Button("Past conversations", systemImage: "clock.arrow.circlepath") {
                            inputFocused = false
                            ODBridge.shared.store.selectedTab = .home
                        }
                        Button("Device", systemImage: "iphone") {
                            ODBridge.shared.store.secondaryRoute = .device
                        }
                        // (The duplicate "Past conversations" entry that used to
                        // live here is gone: the toolbar glyph above opens the
                        // same sheet, and two controls for one destination is
                        // how a menu starts looking like a second toolbar.)
                        Divider()
                        Button {
                            ODBridge.shared.store.selectedTab = .voice
                            ODBridge.shared.store.send(.beginVoiceSession)
                            HapticManager.impact(.light)
                        } label: {
                            Label(loc.t("Voice conversation"), systemImage: "waveform")
                        }
                        Button {
                            ODBridge.shared.store.selectedTab = .imageStudio
                            HapticManager.impact(.light)
                        } label: {
                            Label(loc.t("Image generation"), systemImage: "wand.and.stars")
                        }
                        // (Past conversations now lives as a dedicated toolbar
                        // button — see the topBarTrailing History button above.)
                        Button {
                            showPersonaPicker = true
                            HapticManager.impact(.light)
                        } label: {
                            Label("\(loc.t("Persona")): \(PersonaStore.shared.active.name)",
                                  systemImage: PersonaStore.shared.active.icon)
                        }
                        Button {
                            showSettings = true
                            HapticManager.impact(.light)
                        } label: {
                            Label(loc.t("Settings"), systemImage: "gearshape")
                        }
                        Button {
                            diagnoseAppErrors()
                            HapticManager.impact(.light)
                        } label: {
                            Label(loc.t("Diagnose app errors"), systemImage: "stethoscope")
                        }
                        Divider()
                        Button {
                            showConversationSearch.toggle()
                            if !showConversationSearch { conversationFilter = "" }
                            HapticManager.impact(.light)
                        } label: {
                            Label(loc.t(showConversationSearch ? "Hide search" : "Search messages"),
                                  systemImage: showConversationSearch
                                    ? "magnifyingglass.circle.fill"
                                    : "magnifyingglass")
                        }
                        if messages.contains(where: {
                            ($0.role == .user || $0.role == .assistant)
                                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }) {
                            Button {
                                shareCurrentConversation()
                            } label: {
                                Label(loc.t("Share conversation"),
                                      systemImage: "square.and.arrow.up")
                            }
                        }
                        // Web Tool settings
                        Button {
                            showWebSettings = true
                            HapticManager.impact(.light)
                        } label: {
                            Label(
                                loc.t(WebToolService.shared.settings.mode == .off
                                    ? "Web Tool (off)" : "Web Tool settings"),
                                systemImage: WebToolService.shared.settings.mode == .off
                                    ? "globe.slash" : "globe"
                            )
                        }
                        Divider()
                        // Power-user / diagnostic actions grouped under one
                        // "Advanced" submenu so the top-level menu stays short
                        // and uncluttered (these are rarely-used vs. the chat
                        // essentials above).
                        Menu {
                            Button {
                                showBenchmark = true
                                HapticManager.impact(.light)
                            } label: {
                                Label(loc.t("Benchmark model"), systemImage: "speedometer")
                            }
                            // A/B compare — heavier workflow, max-tier only.
                            if !DeviceTierAdvisor.shouldHideHeavyFeatures {
                                Button {
                                    showCompare = true
                                    HapticManager.impact(.light)
                                } label: {
                                    Label(loc.t("Compare models"), systemImage: "rectangle.split.2x1")
                                }
                            }
                            Button {
                                showMacros = true
                                HapticManager.impact(.light)
                            } label: {
                                Label(loc.t("Run macro"), systemImage: "arrow.triangle.branch")
                            }
                        } label: {
                            Label(loc.t("Advanced"), systemImage: "slider.horizontal.3")
                        }
                        // Clear conversation — destructive, at the bottom
                        if !messages.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Label(loc.t("Clear conversation"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel(loc.t("More options"))
                }
            }
            .confirmationDialog("Clear conversation?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) { clearConversation() }
            }
            .sheet(isPresented: $showConversationPicker) {
                ConversationPickerView(
                    store: store,
                    onSelect: { conv in
                        loadConversation(conv)
                        showConversationPicker = false
                    },
                    // Dismiss first, then present: presenting the share sheet
                    // while this one is closing is the stacked-modal case.
                    onShareFile: { url in
                        showConversationPicker = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(260))
                            sharePayload = AssistantSharePayload(text: url.lastPathComponent,
                                                                 fileURL: url)
                        }
                    }
                )
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPickerView { picked in
                    handlePickedPhoto(picked)
                }
            }
            .sheet(isPresented: $showModelPicker) {
                AssistantModelPickerView(downloadedOnly: true)
            }
            .sheet(isPresented: $showRuntimeDetails) {
                AssistantRuntimeDetailsSheetHost(
                    model: assistant.activeModel,
                    status: modelStatusDescriptor.title,
                    onSwitchModel: { showModelPicker = true }
                )
            }
            .sheet(isPresented: $showSamplerControls) {
                SamplingSettingsSheet(
                    temperature: $nextSendTemperature,
                    topP: $nextSendTopP,
                    topK: $nextSendTopK,
                    repetitionPenalty: $nextSendRepetitionPenalty,
                    defaults: assistant.effectiveGenerationSettings
                )
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.shareItems)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(assistant: CodingAssistantService.shared)
            }
            .sheet(isPresented: $showBenchmark) {
                BenchmarkView()
            }
            .sheet(isPresented: $showCompare) {
                CompareView()
            }
            .sheet(isPresented: $showMacros) {
                MacroChainView()
            }
            .sheet(isPresented: $showWebSettings) {
                WebSettingsView()
            }
            .sheet(isPresented: $showDownloadCenter) {
                ModelDownloadCenterView()
            }
            .sheet(isPresented: $showUnsafeModelLoadConfirmation) {
                UnsafeModelLoadConfirmationSheet(
                    modelName: assistant.activeModel.displayName
                ) {
                    Task {
                        await assistant.load(allowUnsafeMemoryLoad: true)
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                FileAttachmentPicker(
                    existing: pendingAttachments,
                    onPick: { added, errors in
                        pendingAttachments.append(contentsOf: added)
                        if !added.isEmpty { HapticManager.impact(.medium) }
                        for err in errors {
                            ToastCenter.shared.error("Couldn't attach", detail: err)
                        }
                        showFilePicker = false
                    },
                    onCancel: { showFilePicker = false }
                )
            }
            .sheet(isPresented: $showToolFilePicker) {
                let request = pendingToolFile
                FileAttachmentPicker(
                    existing: [],
                    onPick: { added, errors in
                        guard let request, accepts(request.scope) else { return }
                        for err in errors {
                            ToastCenter.shared.error("Couldn't read file", detail: err)
                        }
                        let result: String
                        if added.isEmpty {
                            result = errors.isEmpty
                                ? "The user did not choose a readable file."
                                : "File read failed:\n" + errors.joined(separator: "\n")
                        } else {
                            result = FileAttachmentService.renderForPrompt(added)
                        }
                        let depth = request.depth
                        pendingToolFile = nil
                        showToolFilePicker = false
                        feedToolResultAndFollowUp(name: "file_read", result: result, depth: depth)
                    },
                    onCancel: {
                        guard let request, accepts(request.scope) else { return }
                        let depth = request.depth
                        pendingToolFile = nil
                        showToolFilePicker = false
                        feedToolResultAndFollowUp(
                            name: "file_read",
                            result: "The user cancelled file selection.",
                            depth: depth
                        )
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPersonaPicker) {
                PersonaPickerView()
            }
            .sheet(isPresented: $showAddSheet) {
                StudioAddSheet(
                    draft: $inputText,
                    thinkingEnabled: thinkingEnabledBinding,
                    webLookupsAllowed: webLookupsBinding,
                    temperature: $nextSendTemperature,
                    topP: $nextSendTopP,
                    topK: $nextSendTopK,
                    repetitionPenalty: $nextSendRepetitionPenalty,
                    samplerDefaults: assistant.effectiveGenerationSettings,
                    snippetCount: SnippetStore.shared.snippets.count,
                    onPhoto: { handOffFromAddSheet { showPhotoPicker = true } },
                    onFile: { handOffFromAddSheet { showFilePicker = true } },
                    onPaste: { handOffFromAddSheet { pasteFromClipboard() } },
                    onSnippets: { handOffFromAddSheet { showSnippetPicker = true } }
                )
            }
            .sheet(isPresented: $showSnippetPicker) {
                SnippetPickerView { text in
                    if inputText.isEmpty {
                        inputText = text
                    } else {
                        inputText += (inputText.hasSuffix("\n") ? "" : "\n") + text
                    }
                    inputFocused = true
                }
            }
        }
        // Auto-prepare the model when the assistant tab appears.
        //
        // The "Jetsam at 6 GB" concern that drove an earlier lazy-load
        // pattern is now addressed by the cross-tab unload in
        // ContentView.onChange(of: selectedTab) — switching to the lens
        // drops the LLM, so only one model is ever resident.
        //
        // The "Downloading on every launch" complaint was a labelling bug
        // that's already fixed: when the weights are cached, modelConfig
        // routes through `ModelConfiguration(directory:)` which bypasses
        // HubApi entirely (no progress callback), and the load progress
        // pill reads "Preparing X" instead of "Downloading X%".
        //
        // The 250 ms sleep is just to let SwiftUI complete its initial
        // layout pass before MLX starts uploading weights to Metal — a
        // small concession that keeps the assistant tab feeling instant
        // on appear.
        .task(id: isActive) {
            guard isActive else { return }
            // Simulator UI verification must not initialize MLX/Metal. The
            // simulated GPU aborts before SwiftUI can present the chat, which
            // makes ordinary simulator navigation and deterministic layout
            // checks impossible. Physical-device builds still prepare the
            // model normally.
#if targetEnvironment(simulator)
            return
#else
#if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("-assistantUITestMode") else {
                return
            }
#endif
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, isActive else { return }
            await ensureModelReady()
#endif
        }
        .onChange(of: legal.needsAcceptance) { _, needsAcceptance in
            if !needsAcceptance, isActive {
                Task { await ensureModelReady() }
                consumeSharedText()
                consumeNewChat()
                consumeBridge()
                consumeOpenConversation()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                persistCurrentConversation()
                savePresentation()
                store.flush()
            }
        }
        // Consume bridge code from camera capture
        .onAppear {
            if !restoredInitialPresentation {
                restoredInitialPresentation = true
                if let raw = UserDefaults.standard.string(forKey: "chat.lastConversationID"),
                   let id = UUID(uuidString: raw), let conversation = store.conversations.first(where: { $0.id == id }) {
                    loadConversation(conversation)
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-assistantUITestMode"),
               messages.isEmpty {
                messages = [
                    ChatMessage(
                        role: .assistant,
                        content: """
                        I reviewed the attached file and organized the important details into a clean summary.

                        The document contains several practical steps, a list of services to review, and guidance for keeping records. It also explains which actions need confirmation and which parts can be completed directly on the device.

                        Here are the next steps:

                        1. Review the collected information.
                        2. Choose the service you want to handle first.
                        3. Keep the confirmation message for your records.

                        I can also turn this into a shorter checklist or explain any section in more detail.
                        """,
                        generationTokensPerSecond: 11.2,
                        generationDuration: 31
                    )
                ]
            }
#endif
            consumeBridge()
            consumeSharedText()
            consumeNewChat()
            consumeOpenConversation()
        }
        .onChange(of: bridge.pendingNewChat) { _, _ in consumeNewChat() }
        .onChange(of: bridge.pendingOpenConversationID) { _, _ in consumeOpenConversation() }
        .onChange(of: bridge.pendingCode) { _, _ in consumeBridge() }
        // Text/URL handoff from the share extension. AppBridge sets
        // `pendingSharedText` and flips `requestedTab` to assistant; we pull
        // the payload here and prefill the composer so the user lands directly
        // on the message they're about to send.
        .onChange(of: bridge.pendingSharedText) { _, _ in consumeSharedText() }
        .onChange(of: isActive) { _, active in
            if active, !legal.needsAcceptance {
                consumeSharedText()
                consumeNewChat()
                consumeBridge()
                consumeOpenConversation()
            }
            if !active {
                dictationResetID = UUID()
                inputFocused = false
                KeyboardDismiss.now()
                savePresentation()
            }
        }
        .onReceive(ODBridge.shared.store.$conversationsPresented.removeDuplicates()) { presented in
            if presented { inputFocused = false; dictationResetID = UUID() }
        }
    }

    // MARK: - In-conversation search

    /// Filters `messages` by `conversationFilter`. When search is off or
    /// the query is empty, returns everything.
    private var filteredMessages: [ChatMessage] {
        let q = conversationFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard showConversationSearch, !q.isEmpty else { return messages }
        return messages.filter { $0.content.lowercased().contains(q) }
    }

    private var conversationSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(T.ink3)
            TextField("filter messages…", text: $conversationFilter)
                .font(T.mono(12))
                .foregroundColor(T.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !conversationFilter.isEmpty {
                Button {
                    conversationFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(T.ink3)
                }
                .buttonStyle(.plain)
            }
            Text("\(filteredMessages.count)/\(messages.count)")
                .font(T.mono(10))
                .foregroundColor(T.ink3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .kClearGlass(in: Rectangle(), fallbackFill: T.surface)
        .overlay(Rectangle().fill(T.rule).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Bridge consumption

    private func consumeBridge() {
        guard isActive, !legal.needsAcceptance else { return }
        guard let pending = bridge.consume() else { return }
        inputText = pending.prefillPrompt
        inputFocused = true
        HapticManager.impact(.medium)
    }

    /// Drains a pending share-extension text/URL payload into the
    /// composer. For URLs we wrap in a brief framing line so the offline
    /// model has clear instructions ("summarise this link") rather than
    /// receiving a bare URL with no context — local LLMs without web
    /// access otherwise tend to either hallucinate page content or
    /// refuse outright. The user can still edit the framing before
    /// hitting send.
    private func consumeSharedText() {
        guard isActive, !legal.needsAcceptance else { return }
        guard let payload = bridge.pendingSharedText else { return }
        bridge.pendingSharedText = nil

        let prefill: String
        switch payload.kind {
        case .text:
            prefill = payload.body
        case .url:
            prefill = "Help me with this link (I can't fetch it for you — just react to the URL itself):\n\n\(payload.body)"
        }

        inputText = prefill

        // "Ask OnDevice" App Intent path: fire the prompt automatically so a
        // Siri/Shortcuts request actually produces an answer. Defer one run
        // loop so the @State write above is committed before sendMessage()
        // reads `inputText`, and give ensureModelReady() a beat to kick in.
        if payload.autoSend {
            inputFocused = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard isActive, !legal.needsAcceptance else { return }
                await ensureModelReady()
                guard isActive, !legal.needsAcceptance else { return }
                sendMessage()
            }
        } else {
            inputFocused = true
        }
        HapticManager.impact(.medium)
    }

    /// Drains a pending "New Chat" request set by the App Intent.
    private func consumeNewChat() {
        guard isActive, !legal.needsAcceptance else { return }
        guard bridge.pendingNewChat else { return }
        bridge.pendingNewChat = false
        clearConversation()
        inputText = ""
        inputFocused = true
        HapticManager.impact(.light)
    }

    /// Drains a pending "open this conversation" request from a Spotlight tap.
    private func consumeOpenConversation() {
        guard isActive, !legal.needsAcceptance else { return }
        guard let id = bridge.pendingOpenConversationID else { return }
        bridge.pendingOpenConversationID = nil
        guard let conv = store.conversations.first(where: { $0.id == id }) else { return }
        loadConversation(conv)
        HapticManager.impact(.light)
    }

    // MARK: - Conversation management

    private func clearConversation() {
        completionScrollTask?.cancel()
        stopGeneration()
        persistCurrentConversation()
        savePresentation()
        if let id = currentConversationID {
            store.saveConversation(
                id: id,
                messages: messages,
                contextMemory: conversationContextMemory,
                assistantModelID: assistant.activeSelectionID
            )
        }
        messages = []
        currentConversationID = nil
        conversationContextMemory = nil
        restorePresentation(nil)
        UserDefaults.standard.removeObject(forKey: "chat.lastConversationID")
        restoreDefaultModelForNewConversation()
    }

    private func loadConversation(_ conv: StoredConversation) {
        guard conv.id != currentConversationID else { return }
        stopGeneration()
        cancelDocumentSearch()
        savePresentation()
        completionScrollTask?.cancel()
        followsConversation = true
        if !messages.isEmpty, let id = currentConversationID {
            store.saveConversation(
                id: id,
                messages: messages,
                contextMemory: conversationContextMemory,
                assistantModelID: assistant.activeSelectionID
            )
        }
        messages = conv.messages.map { $0.chatMessage }
        currentConversationID = conv.id
        conversationContextMemory = conv.contextMemory
        restorePresentation(conv.presentation)
        UserDefaults.standard.set(conv.id.uuidString, forKey: "chat.lastConversationID")
        if conv.assistantModelID == ApplePrivateCloud.modelID,
           ApplePrivateCloud.isSupportedOnCurrentOS {
            guard assistant.activeSelectionID != ApplePrivateCloud.modelID else {
                return
            }
            Task {
                await assistant.selectApplePrivateCloud(persistAsDefault: false)
            }
            return
        }
        let storedModel = conv.assistantModelID.flatMap {
            AssistantModelCatalog.selection(forStoredID: $0)
        }
        let targetModel = storedModel ?? AssistantModelCatalog.currentSelection()
        guard targetModel.id != assistant.activeSelectionID else { return }
        Task {
            await assistant.switchTo(targetModel, persistAsDefault: false)
        }
    }

    private var currentDraft: ConversationPresentation {
        ConversationPresentation(
            text: inputText, files: pendingAttachments, images: pendingImageThumbnails,
            imageIDs: draftImageIDs, legacyImage: pendingImageThumbnail,
            legacyImageID: legacyDraftImageID, readingMessageID: readingMessageID,
            followsLatest: followsConversation
        )
    }

    private func captureRequest() -> ChatPresentationRequest {
        if currentConversationID == nil { currentConversationID = store.create().id }
        return ChatPresentationRequest(id: operationID, conversationID: currentConversationID!,
            draftRevision: draftRevision, modelID: assistant.activeSelectionID,
            draft: currentDraft, attachmentIDs: draftAttachmentMetadata.map(\.id))
    }

    private func accepts(_ request: ChatPresentationRequest) -> Bool {
        request.belongsTo(requestID: operationID, conversationID: currentConversationID,
                          modelID: assistant.activeSelectionID)
    }

    private func preserveUnsentSubmission() {
        guard submissionPreparing, let request = acceptedSubmission,
              request.id == operationID, request.conversationID == currentConversationID else { return }
        if inputText.isEmpty { inputText = request.draft.text }
        else if inputText != request.draft.text {
            store.preserveUnsentDraft(id: request.conversationID, draft: request.draft)
        }
    }

    private func restoreUnsentDraft(at index: Int) {
        guard !isGenerating, let id = currentConversationID,
              var recovered = store.takeUnsentDraft(id: id, at: index) else { return }
        if currentDraft.hasDraft { store.preserveUnsentDraft(id: id, draft: currentDraft) }
        recovered.readingMessageID = readingMessageID
        recovered.followsLatest = followsConversation
        restorePresentation(recovered)
        savePresentation()
        inputFocused = true
    }

    private func consumeSubmittedAttachments() {
        guard let request = acceptedSubmission, accepts(request) else { return }
        let ids = Set(request.draft.files.map(\.id))
        pendingAttachments.removeAll { ids.contains($0.id) }
        if pendingImageThumbnails == request.draft.images { pendingImageThumbnails = []; draftImageIDs = [] }
        if pendingImageThumbnail == request.draft.legacyImage { pendingImageThumbnail = nil }
    }

    private func savePresentation() {
        draftSaveTask?.cancel()
        let presentation = currentDraft
        if currentConversationID == nil, presentation.hasDraft {
            currentConversationID = store.create().id
        }
        guard let id = currentConversationID else { return }
        store.savePresentation(id: id, presentation: presentation)
        UserDefaults.standard.set(id.uuidString, forKey: "chat.lastConversationID")
    }

    private func schedulePresentationSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            savePresentation()
        }
    }

    private func restorePresentation(_ saved: ConversationPresentation?) {
        draftSaveTask?.cancel()
        dictationResetID = UUID()
        let presentation = saved ?? ConversationPresentation()
        inputText = presentation.text
        pendingAttachments = presentation.files
        restoredDraftImages = presentation.images
        pendingImageThumbnails = presentation.images
        pendingImageThumbnail = presentation.legacyImage
        draftImageIDs = presentation.imageIDs
        legacyDraftImageID = presentation.legacyImageID
        followsConversation = presentation.followsLatest
        readingMessageID = presentation.readingMessageID
        if let id = presentation.readingMessageID, !presentation.followsLatest {
            Task { @MainActor in
                await Task.yield()
                scrollProxy?.scrollTo(id, anchor: .top)
            }
        }
    }

    /// A new thread always starts from the explicit default. Switching a
    /// model inside another conversation must not leak into future chats.
    private func restoreDefaultModelForNewConversation() {
        if AppSettings.shared.assistantModelID == ApplePrivateCloud.modelID,
           ApplePrivateCloud.isSupportedOnCurrentOS {
            guard assistant.activeSelectionID != ApplePrivateCloud.modelID else {
                return
            }
            Task {
                await assistant.selectApplePrivateCloud(persistAsDefault: false)
            }
            return
        }
        let defaultModel = AssistantModelCatalog.currentSelection()
        guard defaultModel.id != assistant.activeSelectionID else { return }
        Task {
            await assistant.switchTo(defaultModel, persistAsDefault: false)
        }
    }

    private func persistCurrentConversation() {
        guard !messages.filter({ $0.role != .system }).isEmpty else { return }
        let id = currentConversationID ?? UUID()
        let isFirstAssistantTurn =
            currentConversationID == nil ||
            messages.filter { $0.role == .assistant && !$0.content.isEmpty }.count == 1
        currentConversationID = id
        store.saveConversation(
            id: id,
            messages: messages,
            contextMemory: conversationContextMemory,
            assistantModelID: assistant.activeSelectionID
        )

        // Auto-title once after the first complete assistant reply. Runs as
        // a small follow-up generate() with maxTokens=16 — costs ~200ms but
        // makes the conversation picker actually scannable instead of being
        // a list of dates.
        if isFirstAssistantTurn,
           generationFailure == nil,
           !messages.contains(where: \.isStreaming),
           messages.last(where: { $0.role == .assistant })?.wasInterrupted != true,
           let firstUser = messages.first(where: { $0.role == .user })?.content,
           !firstUser.isEmpty {
            Task { await ConversationTitler.titleIfNeeded(
                conversationID: id,
                firstUserMessage: firstUser
            ) }
        }
    }

    // MARK: - Model status bar

    /// Quiet collapsed runtime status. Technical metrics live in the details
    /// sheet so the conversation keeps visual priority.
    private var modelStatusBar: some View {
        Button {
            if assistant.activeExecutionLocation == .applePrivateCloud {
                showModelPicker = true
                Task { await assistant.refreshApplePrivateCloudStatus() }
                HapticManager.impact(.light)
            } else if hasPermanentModelCapacityFailure {
                showModelPicker = true
                HapticManager.impact(.light)
            } else if canLoadSelectedModel {
                Task { await assistant.load() }
                HapticManager.impact(.medium)
            } else {
                showRuntimeDetails = true
                HapticManager.impact(.light)
            }
        } label: {
            HStack(spacing: AppSpacing.small) {
                if isModelPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: modelStatusDescriptor.title == "Ready"
                          ? "checkmark.circle.fill"
                          : modelStatusDescriptor.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Text(
                    modelStatusDescriptor.title == "Ready"
                        ? {
                            switch assistant.activeExecutionLocation {
                            case .applePrivateCloud: return "Ready via Apple Private Cloud"
                            case .localCoreAI:       return "Ready via Apple Core AI"
                            default:                 return "Ready on device"
                            }
                        }()
                        : (isModelPreparing ? modelProgressTitle : modelStatusDescriptor.title)
                )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(T.ink2)
                if modelStatusDescriptor.title != "Ready" {
                    Text(ODPresentation.modelName(assistant.activeDisplayName, compact: true))
                        .font(.caption)
                        .foregroundStyle(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: AppSpacing.small)
                if canLoadSelectedModel {
                    Label(
                        hasPermanentModelCapacityFailure ? "Choose" : "Load",
                        systemImage: hasPermanentModelCapacityFailure
                            ? "square.stack.3d.up.fill"
                            : "arrow.down.circle.fill"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(T.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                                .fill(T.accent.opacity(T.isDark ? 0.18 : 0.10))
                        )
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(T.ink3)
                }
            }
            .padding(.horizontal, AppSpacing.large)
            .frame(minHeight: ODLayout.minimumHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Runtime status: \(modelStatusDescriptor.title)")
        .accessibilityHint(
            canLoadSelectedModel
                ? (hasPermanentModelCapacityFailure
                    ? "Shows compatible on-device models"
                    : "Loads the selected on-device model")
                : "Shows on-device model and performance details"
        )
        .accessibilityValue(isModelPreparing ? "In progress" : modelStatusDescriptor.title)
    }

    private var canLoadSelectedModel: Bool {
        guard assistant.activeExecutionLocation != .applePrivateCloud else {
            return false
        }
        return switch assistant.state {
        case .unloaded, .failed: true
        default: false
        }
    }

    private var modelProgressTitle: String {
        guard assistant.activeExecutionLocation != .applePrivateCloud else { return modelStatusDescriptor.title }
        if case .loading(let detail) = assistant.state, detail.localizedCaseInsensitiveContains("downloading") {
            return "Downloading model"
        }
        return "Preparing model"
    }

    private var isModelPreparing: Bool {
        if assistant.activeExecutionLocation == .applePrivateCloud {
            return assistant.applePrivateCloudGenerationState == .generating
        }
        return switch assistant.state {
        case .loading: true
        default: false
        }
    }

    private var modelLoadFailure: String? {
        if assistant.activeExecutionLocation == .applePrivateCloud,
           case .failed(let error) = assistant.applePrivateCloudGenerationState {
            return error.localizedDescription
        }
        guard case .failed(let message) = assistant.state else { return nil }
        return message
    }

    private var hasPermanentModelCapacityFailure: Bool {
        guard let modelLoadFailure else { return false }
        return MemoryAdvisor.isHardCapacityFailure(modelLoadFailure)
    }

    // Legacy status implementation retained temporarily for source-level
    // compatibility with its helper views; it is no longer rendered.
    @ViewBuilder
    private var legacyModelStatusBar: some View {
        let safety = DeviceSafetyMonitor.shared
        let descriptor = modelStatusDescriptor
        HStack(spacing: 10) {
            // Tappable model name → Models tab (the unified hub owns
            // assistant-model selection now).
            Button {
                AppBridge.shared.requestTab(.models)
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                        .fill(descriptor.color.opacity(T.isDark ? 0.24 : 0.14))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: descriptor.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(descriptor.color)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ODPresentation.modelName(assistant.activeDisplayName, compact: true))
                            .font(T.sans(12, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.85)
                        HStack(spacing: 6) {
                            Text(descriptor.title)
                                .font(T.mono(9, .semibold))
                                .tracking(0)
                                .foregroundColor(descriptor.color)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            if let badge = descriptor.badge {
                                Text(badge)
                                    .font(T.mono(8, .semibold))
                                    .foregroundColor(descriptor.color)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                                            .fill(descriptor.color.opacity(T.isDark ? 0.22 : 0.12))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                                            .stroke(descriptor.color.opacity(0.25), lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(T.ink3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                // Fill only the space the row offers. Intrinsic fixed sizing
                // let long imported filenames extend beyond the screen and
                // push Retry/status controls off the trailing edge.
                .frame(maxWidth: .infinity, alignment: .leading)
                .kGlassCapsule(tint: descriptor.color.opacity(T.isDark ? 0.10 : 0.05),
                               fallbackFill: T.surface)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityLabel("Change model")

            Spacer(minLength: 2)
            // Web Tool badge — appears when the Web Tool is active or paused.
            WebStatusBadge()
            // Memory chip — shows how many facts are in scope for the active
            // persona. Tap to navigate to the memory editor (Settings sheet).
            memoryChip
            // Network activity dot — red glow when ANY URLSession request is
            // in flight (model download, HF search). Reinforces local-first
            // promise: when the dot is dark, nothing is leaving the device.
            networkActivityDot
            // Thermal / low-power pill — only visible when the device is
            // noticeably warm or in low-power mode. Helps the user understand
            // why responses are shorter or paused.
            if let label = safety.statusLabel {
                let color: Color = {
                    switch safety.statusColor {
                    case "red":    return T.bad
                    case "orange": return T.warn
                    default:       return T.ink2
                    }
                }()
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 9))
                    Text(label).font(T.mono(10, .semibold))
                }
                .foregroundColor(color)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .kGlass(cornerRadius: StudioRadius.spine,
                        tint: color.opacity(0.4),
                        fallbackFill: color.opacity(0.12),
                        fallbackStroke: color.opacity(0.4))
            }
            if case .generating = assistant.state {
                KMono(text: String(format: "%.1f t/s", assistant.tokenRate),
                       size: 11, weight: .semibold, color: T.ink)
            }
            // Token-cap chip — thermal advisor or the compact GGUF profile
            // (128) is holding the reply below the user's setting.
            let configuredMaxTokens = assistant.effectiveGenerationSettings.maxTokens
            let effectiveMax = assistant.effectiveOutputTokenCap
            if effectiveMax < configuredMaxTokens {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(effectiveMax) tok")
                        .font(T.mono(10, .semibold))
                }
                .foregroundColor(T.warn)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(T.warn.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel))
                .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel).stroke(T.warn.opacity(0.3), lineWidth: 0.5))
                .accessibilityLabel("Reply length capped at \(effectiveMax) tokens")
            }
            if assistant.lastGenerationHitTokenLimit, assistant.state != .generating {
                Button {
                    continueTruncatedReply()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "text.append")
                            .font(.system(size: 8, weight: .semibold))
                        Text("cut off")
                            .font(T.mono(10, .semibold))
                    }
                    .foregroundColor(T.warn)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(T.warn.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel))
                    .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel).stroke(T.warn.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reply reached the token limit. Continue from here.")
            }
            if case .loading = assistant.state {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.6).tint(T.accent)
            }
            if case .failed = assistant.state {
                Button {
                    Task { await assistant.load() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("retry")
                            .font(T.mono(10, .semibold))
                    }
                    .foregroundColor(T.warn)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .kGlass(cornerRadius: StudioRadius.spine,
                            tint: T.warn.opacity(0.3),
                            fallbackFill: T.warn.opacity(0.12),
                            fallbackStroke: T.warn.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .kClearGlass(in: Rectangle(), fallbackFill: T.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.rule).frame(height: 0.5)
        }
    }

    // Memory chip — reflects how many facts are in scope for the active persona.
    @ViewBuilder
    private var memoryChip: some View {
        let active = PersonaStore.shared.active
        let count = MemoryStore.shared.countInScope(forPersonaID: active.id)
        if count > 0 {
            Button {
                showSettings = true
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 9))
                    Text("\(count)")
                        .font(T.mono(10, .semibold))
                }
                .foregroundColor(T.accent)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .kGlass(cornerRadius: StudioRadius.spine,
                        tint: T.accent.opacity(0.3),
                        fallbackFill: T.accentSoft,
                        fallbackStroke: .clear)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(count) memory facts active")
        }
    }

    // Network activity dot — green when idle, red glow when ≥1 request is in flight.
    @ViewBuilder
    private var networkActivityDot: some View {
        let mon = NetworkActivityMonitor.shared
        RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
            .fill(mon.isActive ? T.bad : T.good.opacity(0.65))
            .frame(width: 6, height: 6)
            .shadow(color: mon.isActive ? T.bad.opacity(0.7) : .clear, radius: 3)
            .accessibilityLabel(mon.isActive ? "Network active" : "No network activity")
            .help(mon.topLabel ?? (mon.isActive ? "Network in use" : "Local-only"))
    }

    private var statusGlyph: String {
        if assistant.activeExecutionLocation == .applePrivateCloud {
            return assistant.applePrivateCloudGenerationState == .generating ? "◐" : "●"
        }
        switch assistant.state {
        case .ready:      return "●"
        case .generating: return "◐"
        case .loading:    return "◐"
        case .failed:     return "✕"
        case .unloaded:   return "○"
        }
    }
    private var statusColor: Color {
        if assistant.activeExecutionLocation == .applePrivateCloud {
            if assistant.applePrivateCloudGenerationState == .generating {
                return T.accent
            }
            switch assistant.applePrivateCloudStatus {
            case .ready: return T.good
            case .approachingLimit: return T.warn
            case .limitReached: return T.bad
            default: return T.ink3
            }
        }
        switch assistant.state {
        case .ready:      return T.good
        case .generating: return T.accent
        case .loading:    return T.warn
        case .failed:     return T.bad
        case .unloaded:   return T.ink3
        }
    }

    private var modelStatusDescriptor: (symbol: String, title: String, badge: String?, color: Color) {
        if assistant.activeExecutionLocation == .applePrivateCloud {
            if assistant.applePrivateCloudGenerationState == .generating {
                return ("sparkles", "Generating", "cloud", T.accent)
            }
            switch assistant.applePrivateCloudStatus {
            case .ready:
                return ("checkmark.circle.fill", "Ready", "cloud", T.good)
            case .approachingLimit:
                return ("exclamationmark.circle.fill", "Nearing daily limit", "cloud", T.warn)
            case .limitReached:
                return ("hourglass.circle.fill", "Daily limit reached", nil, T.bad)
            case .offline:
                return ("wifi.slash", "Offline", nil, T.bad)
            case .unsupportedOS:
                return ("info.circle.fill", "Requires iOS 27", nil, T.ink3)
            case .unsupportedDevice:
                return ("info.circle.fill", "Device not eligible", nil, T.ink3)
            case .appleIntelligenceUnavailable:
                return ("info.circle.fill", "Apple Intelligence unavailable", nil, T.ink3)
            case .temporarilyUnavailable, .entitlementUnavailable, .unknown:
                return ("exclamationmark.circle.fill", "Cloud unavailable", nil, T.ink3)
            }
        }
        switch assistant.state {
        case .ready:
            return ("checkmark.circle.fill", "Ready", nil, T.good)
        case .generating:
            let rate = assistant.tokenRate > 0 ? String(format: "%.1f t/s", assistant.tokenRate) : nil
            return ("sparkles", "Generating", rate, T.accent)
        case .loading(let raw):
            let stripped = raw
                .replacingOccurrences(of: assistant.activeModel.displayName, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let percent = Self.percentage(in: stripped).map { "\(Int($0 * 100))%" }
            let isDownloading = stripped.lowercased().hasPrefix("downloading")
            let title = titleCaseStatus(
                stripped.replacingOccurrences(
                    of: #"\s+\d+%$"#,
                    with: "",
                    options: .regularExpression
                )
            )
            return (
                isDownloading ? "arrow.down.circle.fill" : "bolt.circle.fill",
                title.isEmpty ? (isDownloading ? "Downloading" : "Preparing") : title,
                percent,
                isDownloading ? T.warn : T.accent
            )
        case .failed:
            return ("exclamationmark.triangle.fill", "Load failed", nil, T.bad)
        case .unloaded:
            return ("circle.dashed", "Not loaded", nil, T.ink3)
        }
    }

    private func titleCaseStatus(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Nav row identity. Empty thread: a 6pt state dot + the model name + a
    /// small chevron — not a pill, no background. Once a conversation exists
    /// it becomes a two-line title with the mode summary underneath.
    private var assistantPickerPill: some View {
        let S = T.studio
        return Button {
            showModelPicker = true
            HapticManager.impact(.light)
        } label: {
            Group {
                if let title = currentConversationTitle {
                    VStack(spacing: 1) {
                        // The thread's proper name — editorial content, so it
                        // carries the serif like the model name on SYS and the
                        // voice names on VOX. The machine facts under it stay
                        // mono.
                        Text(title)
                            .font(S.serif(15, .semibold))
                            .foregroundStyle(S.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        StudioMonoLabel(text: navModeSummary, size: 11)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 230)
                } else {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                            .fill(assistant.state == .ready ? S.accent : S.ink4)
                            .frame(width: 6, height: 6)
                        Text(ODPresentation.modelName(assistant.activeDisplayName, compact: true))
                            .font(S.sans(14, .medium))
                            .foregroundStyle(S.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(S.ink3)
                    }
                    .frame(maxWidth: 230)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant, \(assistant.activeDisplayName)")
        .accessibilityHint("Shows available assistant models")
    }

    /// Title of the conversation being viewed, if it has been named yet.
    private var currentConversationTitle: String? {
        guard !messages.isEmpty,
              let id = currentConversationID,
              let title = store.conversations.first(where: { $0.id == id })?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return title
    }

    /// "qwen3 · thinks first" — the machine facts under the nav title.
    private var navModeSummary: String {
        var parts = [assistant.activeDisplayName]
        if assistant.activeModel.supportsThinking {
            parts.append(thinkingEnabledBinding.wrappedValue ? "thinks first" : "answers directly")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Bridge status pill
    //
    // Compact secondary pill that sits to the right of the model
    // picker. Communicates one thing: will `/mac …` reach the Mac?
    // Tap = probe. No background polling — the user knows when they
    // care about bridge state (typically right before they type
    // `/mac`), and a heartbeat per appearance is wasted battery on
    // the 99% of sessions that never use the bridge.
    //
    // States map to colors:
    //   .unknown      — neutral, "mac?"
    //   .notPaired    — gray, "no mac" (tap routes to Mac tab via the
    //                   bottom bar — the chat view doesn't own that
    //                   navigation, so we just toast the instruction)
    //   .probing      — accent, "checking…", spinner
    //   .connected    — green, "mac ✓ NNms"
    //   .unreachable  — red,   "mac ✗"

    @ViewBuilder
    private var bridgeStatusPill: some View {
        Button {
            HapticManager.impact(.light)
            probeBridge()
        } label: {
            HStack(spacing: 5) {
                bridgePillIcon
                Text(bridgePillLabel)
                    .font(T.mono(9, .semibold))
                    .foregroundColor(bridgePillColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).fill(bridgePillColor.opacity(T.isDark ? 0.18 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).stroke(bridgePillColor.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac bridge: \(bridgePillLabel). Tap to test connection.")
        .onAppear { refreshBridgeStateFromStore() }
    }

    @ViewBuilder
    private var bridgePillIcon: some View {
        switch bridgePillState {
        case .probing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(bridgePillColor)
        case .unreachable:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(bridgePillColor)
        case .notPaired, .unknown:
            RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                .fill(bridgePillColor)
                .frame(width: 6, height: 6)
        }
    }

    /// SF Symbol name for the bridge state when shown inside the overflow
    /// menu (where SwiftUI's `Label(_:systemImage:)` only accepts a
    /// string). Mirrors the colors/icons of `bridgePillIcon` but without
    /// the embedded ProgressView for the .probing case — Menu items
    /// don't render arbitrary views inside their leading icon slot.
    private var bridgePillMenuIcon: String {
        switch bridgePillState {
        case .unknown, .notPaired:  return "desktopcomputer"
        case .probing:              return "arrow.triangle.2.circlepath"
        case .connected:            return "checkmark.circle.fill"
        case .unreachable:          return "xmark.circle.fill"
        }
    }

    private var bridgePillLabel: String {
        switch bridgePillState {
        case .unknown:                 return "mac?"
        case .notPaired:               return "no mac"
        case .probing:                 return "checking…"
        case .connected(let ms):       return "mac ✓ \(ms)ms"
        case .unreachable:             return "mac ✗"
        }
    }

    private var bridgePillColor: Color {
        switch bridgePillState {
        case .unknown:        return T.ink3
        case .notPaired:      return T.ink3
        case .probing:        return T.accent
        case .connected:      return .green
        case .unreachable:    return .red
        }
    }

    /// Cheap synchronous refresh: just check the pairing store. If
    /// there's no paired Mac with a bearer, the pill renders gray
    /// "no mac" without firing a network probe. Real reachability
    /// requires a tap (or a `/mac …` send).
    private func refreshBridgeStateFromStore() {
        let hasPaired = BridgePairingStore.shared.firstAgentClient() != nil
        switch bridgePillState {
        // Don't clobber a fresh probe result — only refresh when we
        // haven't probed yet OR the previous result is stale.
        case .unknown:
            bridgePillState = hasPaired ? .unknown : .notPaired
        case .notPaired:
            if hasPaired { bridgePillState = .unknown }
        case .connected, .unreachable, .probing:
            if !hasPaired { bridgePillState = .notPaired }
        }
    }

    /// Tap handler. Pairing absent → toast a hint instead of probing
    /// the wire (nothing to hit). Pairing present → heartbeat with a
    /// generous timeout and show the round-trip ms on success.
    private func probeBridge() {
        guard BridgePairingStore.shared.firstAgentClient() != nil else {
            bridgePillState = .notPaired
            ToastCenter.shared.info("No paired Mac. Open the Mac tab to pair.")
            return
        }
        bridgePillState = .probing
        Task { @MainActor in
            let start = Date()
            do {
                _ = try await BridgeAgentClient.shared.heartbeat()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                bridgePillState = .connected(latencyMs: ms)
            } catch {
                bridgePillState = .unreachable(reason: error.localizedDescription)
                ToastCenter.shared.error(
                    "Mac unreachable",
                    detail: error.localizedDescription
                )
            }
        }
    }

    private var statusLabel: String {
        let name = assistant.activeDisplayName.lowercased()
        if assistant.activeExecutionLocation == .applePrivateCloud {
            if assistant.applePrivateCloudGenerationState == .generating {
                return "\(name) · generating…"
            }
            switch assistant.applePrivateCloudStatus {
            case .ready: return "\(name) · ready"
            case .approachingLimit: return "\(name) · nearing daily limit"
            case .limitReached: return "\(name) · daily limit reached"
            case .offline: return "\(name) · offline"
            default: return "\(name) · unavailable"
            }
        }
        switch assistant.state {
        case .ready:             return "\(name) · ready"
        case .generating:        return "\(name) · generating…"
        case .loading(let msg):  return msg.lowercased()
        case .failed:            return "\(name) · load failed — tap to switch"
        case .unloaded:          return "\(name) · not loaded"
        }
    }

    // MARK: - Input bar

    /// The composer card. Attachments, recents, mode readouts and the
    /// generating rule all live inside it; the old keyboard toolbar's actions
    /// moved to the Add sheet.
    private func transcriptRow(_ msg: ChatMessage) -> some View {
                                VStack(spacing: 0) {
                                    MessageBubble(message: msg) { imgData in
                                        analyzeImageWithVLM(imageData: imgData)
                                    }
                                        .equatable()
                                        .contextMenu {
                                            Button {
                                                UIPasteboard.general.string = msg.content
                                                HapticManager.impact(.light)
                                                ToastCenter.shared.info(loc.t("Copied"))
                                            } label: {
                                                Label(loc.t("Copy text"), systemImage: "doc.on.doc")
                                            }
                                            if msg.role == .user {
                                                Button {
                                                    inputText = msg.content
                                                    inputFocused = true
                                                } label: {
                                                    Label(loc.t("Edit & resend"),
                                                          systemImage: "pencil.line")
                                                }
                                            }
                                            if msg.role == .assistant && !msg.isStreaming,
                                               messages.last(where: { $0.role == .assistant })?.id == msg.id {
                                                Button {
                                                    regenerateLastResponse()
                                                    HapticManager.impact(.medium)
                                                } label: {
                                                    Label(loc.t("Regenerate"), systemImage: "arrow.clockwise")
                                                }
                                            }
                                        }
                                    // Four glyphs under the LAST answer, above a
                                    // 1px divider. Older turns keep copy /
                                    // regenerate / share on long-press.
                                    if msg.role == .assistant, !msg.isStreaming,
                                       !msg.content.isEmpty,
                                       messages.last(where: { $0.role == .assistant })?.id == msg.id {
                                        VStack(alignment: .leading, spacing: 12) {
                                            StudioAnswerActionRow(
                                                provenance: answerProvenance,
                                                footnote: answerFootnote(for: msg),
                                                canRegenerate: assistant.state == .ready,
                                                onCopy: {
                                                    UIPasteboard.general.string = msg.content
                                                    ToastCenter.shared.info(loc.t("Copied"))
                                                },
                                                onRegenerate: { regenerateLastResponse() },
                                                onShare: {
                                                    sharePayload = AssistantSharePayload(text: msg.content)
                                                },
                                                onSpeak: {
                                                    ODBridge.shared.store.requestExclusiveOperation("Reading this reply aloud") {
                                                        VoiceService.shared.speak(msg.content)
                                                    }
                                                }
                                            )
                                            // Follow-up chips that reframe the
                                            // previous reply (continue / shorter /
                                            // more formal) stay on the last turn.
                                            if assistant.state == .ready {
                                                AssistantQuickActions(
                                                    disabled: assistant.state != .ready,
                                                    onAction: { sendQuickAction($0) }
                                                )
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.top, 4)
                                        .padding(.bottom, 8)
                                    }
                                }
    }

    private var inputBar: some View {
        ODComposer(
            text: $inputText, focus: $inputFocused,
            attachments: draftAttachmentMetadata,
            isResponding: isGenerating || isPreparingImageContext || documentSearchID != nil,
            canSend: canSendMessage,
            canStop: true,
            canAdd: !isGenerating && !isPreparingImageContext && documentSearchID == nil,
            canRemove: !isGenerating && !isPreparingImageContext && documentSearchID == nil,
            modelMenu: AnyView(composerModelMenu),
            microphone: AnyView(MicDictationButton(text: $inputText, compact: true, resetID: dictationResetID)),
            notice: composerNotice,
            onVoice: (assistant.canGenerateSelectedTarget || ODBridge.shared.store.voiceSessionActive) ? {
                inputFocused = false
                dictationResetID = UUID()
                let ui = ODBridge.shared.store
                if ui.voiceSessionActive { ui.voiceSessionPresented = true }
                else {
                    ui.selectedTab = .voice
                    if ui.capabilities.canStartVoice { ui.send(.beginVoiceSession) }
                }
            } : nil,
            onAdd: { showAddSheet = true },
            onRemove: removeDraftAttachment,
            onSend: { text, ids in
                // Resolve the immutable metadata snapshot against the host's current files.
                guard text == inputText, ids == draftAttachmentMetadata.map(\.id), canSendMessage else { return }
                sendMessage()
            },
            onStop: stopGeneration
        )
        .onAppear {
            ODBridge.shared.chatAction = { action in
                switch action {
                case .addAttachment: showAddSheet = true
                case .removeAttachment(let id): removeDraftAttachment(id)
                case .stopGeneration: stopGeneration()
                case .sendMessage(let text):
                    guard inputText == text, draftAttachmentMetadata.isEmpty else { return }
                    sendMessage()
                case .sendMessageWithAttachments(let text, let ids):
                    guard text == inputText, ids == draftAttachmentMetadata.map(\.id) else { return }
                    sendMessage()
                default: break
                }
            }
            ODBridge.shared.refresh()
        }
        .onChange(of: inputText, initial: true) { _, value in
            draftRevision &+= 1
            ODBridge.shared.store.composerText = value
            schedulePresentationSave()
        }
        .onChange(of: readingMessageID) { _, _ in schedulePresentationSave() }
        .onChange(of: pendingImageThumbnails, initial: true) { old, new in
            draftRevision &+= 1
            if restoredDraftImages == new {
                restoredDraftImages = nil
                syncComposerMetadata()
                return
            }
            restoredDraftImages = nil
            var used = Set<Int>()
            draftImageIDs = new.map { image in
                if let i = old.indices.first(where: { !used.contains($0) && old[$0] == image }),
                   draftImageIDs.indices.contains(i) {
                    used.insert(i)
                    return draftImageIDs[i]
                }
                return UUID()
            }
            syncComposerMetadata()
        }
        .onChange(of: pendingAttachments) { _, _ in draftRevision &+= 1; syncComposerMetadata() }
        .onChange(of: pendingImageThumbnail) { _, _ in draftRevision &+= 1; syncComposerMetadata() }
        .onChange(of: assistant.activeSelectionID) { _, _ in
            if let request = acceptedSubmission, !accepts(request), isGenerating { stopGeneration() }
        }
        .onChange(of: currentConversationID, initial: true) { _, id in
            ODBridge.shared.store.selectedConversationID = id?.uuidString
        }
        .onChange(of: isGenerating, initial: true) { _, value in
            ODBridge.shared.store.isResponding = value
        }
    }

    private var draftAttachmentNames: [String] {
        draftAttachmentMetadata.map(\.name).filter { !$0.isEmpty }
    }

    private var draftAttachmentMetadata: [ODAttachment] {
        var result = pendingAttachments.map {
            ODAttachment(id: $0.id.uuidString, name: $0.displayName, kind: .file)
        }
        for index in pendingImageThumbnails.indices {
            guard draftImageIDs.indices.contains(index) else { continue }
            result.append(ODAttachment(id: draftImageIDs[index].uuidString,
                                       name: "Image \(index + 1)", kind: .image, previewData: pendingImageThumbnails[index].data))
        }
        if pendingImageThumbnails.isEmpty, pendingImageThumbnail != nil {
            result.append(ODAttachment(id: legacyDraftImageID.uuidString, name: "Image", kind: .image, previewData: pendingImageThumbnail))
        }
        return result
    }

    private func syncComposerMetadata() {
        schedulePresentationSave()
        ODBridge.shared.store.draftAttachments = draftAttachmentMetadata
    }

    private func removeDraftAttachment(_ id: String) {
        guard !isGenerating, !isPreparingImageContext, documentSearchID == nil else { return }
        if let index = pendingAttachments.firstIndex(where: { $0.id.uuidString == id }) {
            pendingAttachments.remove(at: index)
        } else if let index = draftImageIDs.firstIndex(where: { $0.uuidString == id }),
                  pendingImageThumbnails.indices.contains(index) {
            pendingImageThumbnails.remove(at: index)
            pendingImageThumbnail = pendingImageThumbnails.first?.data
        } else if id == legacyDraftImageID.uuidString {
            pendingImageThumbnail = nil
        }
    }

    private var composerModelMenu: some View {
        Menu {
            Button("Choose an assistant model", systemImage: "cube") { ODBridge.shared.store.requestExclusiveOperation("Changing the active model") { showModelPicker = true } }
            if canLoadSelectedModel {
                Button("Load model", systemImage: "arrow.up.circle") { ODBridge.shared.store.requestExclusiveOperation("Loading a model") { Task { await assistant.load() } } }
            }
            if assistant.activeModel.supportsThinking {
                Toggle("Think before answering", isOn: thinkingEnabledBinding)
            }
            Button("Device status", systemImage: "iphone") { ODBridge.shared.store.secondaryRoute = .device }
        } label: {
            ODModelMenuLabel(displayName: assistant.activeDisplayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(ODPresentation.modelName(assistant.activeDisplayName))
    }

    private var composerNotice: AnyView? {
        if isPreparingImageContext {
            return AnyView(Label("Reading image", systemImage: "photo").font(.footnote).foregroundStyle(.secondary))
        }
        if let warning = DeviceSafetyMonitor.shared.statusLabel {
            return AnyView(Text(warning).font(.footnote).foregroundStyle(T.warn))
        }
        if let generationFailure {
            return AnyView(ChatReplyFailureNotice(detail: generationFailure,
                canRetry: !isGenerating && (assistant.canGenerateSelectedTarget || canLoadSelectedModel),
                onRetry: retryFailedResponse))
        }
        if !isGenerating, let drafts = store.conversations.first(where: { $0.id == currentConversationID })?.unsentDrafts,
           !drafts.isEmpty {
            return AnyView(Menu("Unsent drafts", systemImage: "arrow.uturn.backward") {
                ForEach(Array(drafts.enumerated()), id: \.offset) { index, draft in
                    Button(draft.text.isEmpty ? "Restore attached files" : String(draft.text.prefix(80))) {
                        restoreUnsentDraft(at: index)
                    }
                }
            }.font(.footnote).buttonStyle(.glass).frame(minHeight: ODLayout.minimumHit))
        }
        if !assistant.canGenerateSelectedTarget && !isGenerating {
            return AnyView(HStack(spacing: ODLayout.elementGap) {
                Text(isModelPreparing ? "\(modelProgressTitle). Your draft is kept here."
                     : modelLoadFailure != nil ? "The model couldn’t load. Try again or choose another model."
                     : "Choose or load a model to send your message.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !isModelPreparing {
                    Button(canLoadSelectedModel && !hasPermanentModelCapacityFailure
                           ? (modelLoadFailure == nil ? "Load model" : "Retry loading") : "Choose model") {
                        if canLoadSelectedModel && !hasPermanentModelCapacityFailure { Task { await assistant.load() } }
                        else { showModelPicker = true }
                    }
                    .font(.footnote.weight(.medium)).frame(minHeight: ODLayout.minimumHit)
                }
            })
        }
        return nil
    }

    /// Reasoning toggle — honours a per-model profile when one exists, so the
    /// readout and the model's saved settings never disagree.
    private var thinkingEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                AssistantModelSettingsStore.shared
                    .settings(for: assistant.activeModel.repoID)?.thinkingEnabled
                    ?? AppSettings.shared.assistantThinking
            },
            set: { newValue in
                let model = assistant.activeModel
                if var override = AssistantModelSettingsStore.shared.settings(for: model.repoID) {
                    override.thinkingEnabled = newValue
                    AssistantModelSettingsStore.shared.save(
                        override, for: model.repoID, supportsThinking: model.supportsThinking
                    )
                } else {
                    AppSettings.shared.assistantThinking = newValue
                }
            }
        )
    }

    /// "Allow web lookups" — on means the tool asks before every search.
    private var webLookupsBinding: Binding<Bool> {
        Binding(
            get: { WebToolService.shared.settings.mode != .off },
            set: { WebToolService.shared.settings.mode = $0 ? .askEveryTime : .off }
        )
    }

    /// Web-use provenance under the last answer: what left the device and how
    /// much came back. `nil` keeps the provenance line hidden entirely.
    private var answerProvenance: String? {
        let pages = lastWebCitations.count
        guard pages > 0 else { return nil }
        return "searched once · \(pages) page\(pages == 1 ? "" : "s") · nothing stored"
    }

    /// Mono footnote right-aligned in the answer action row: model · time or
    /// model · duration once generation finishes.
    private func answerFootnote(for msg: ChatMessage) -> String {
        let model = msg.generationModelID ?? "Model not recorded"
        if msg.isStreaming {
            if msg.content.isEmpty { return model }
            return "\(model) · writing"
        }
        if let duration = msg.generationDuration, duration > 0 {
            return "\(model) · \(formattedDuration(duration))"
        }
        return msg.timestamp.formatted(date: .omitted, time: .shortened)
    }

    /// Throughput of the reply currently being written, when the runtime has
    /// reported one. `nil` keeps the generating rule's metric slot empty
    /// rather than showing a made-up zero.
    private var liveTokensPerSecond: Double? {
        messages.last(where: { $0.role == .assistant })?.generationTokensPerSecond
    }

    private func shareCurrentConversation() {
        let title = currentConversationID.flatMap { id in
            store.conversations.first(where: { $0.id == id })?.title
        } ?? ""
        let transcript = ConversationShareFormatter.markdown(
            title: title,
            messages: messages
        )
        sharePayload = AssistantSharePayload(text: transcript)
        HapticManager.impact(.light)
    }

    @ViewBuilder
    private var activityCards: some View {
        if documentSearchID != nil {
            AssistantLiveStatusRow(title: "Searching your documents", symbol: "doc.text.magnifyingglass")
        }
        if let last = messages.last(where: { $0.role == .assistant }),
           last.isStreaming,
           pendingToolWeb == nil,
           pendingToolFile == nil,
           pendingToolConfirm == nil,
           runningToolName == nil,
           let name = detectedStreamingToolCalls[last.id]?.name {
            AssistantLiveStatusRow(
                title: AssistantActivity.statusTitle(.preparingTool(name)),
                symbol: AssistantActivity.symbol(forTool: name)
            )
        }
        // Web consent — asked in the thread, not in a sheet, so the question
        // sits where the answer will. Both the model-initiated tool call and
        // the pre-send check use the same card.
        if let req = pendingWebPermission {
            StudioWebPermissionCard(
                query: webPermissionQueryText(req.payload),
                reason: req.reason,
                onAllowOnce: {
                    pendingWebPermission = nil
                    beginWebPreparation(payload: req.payload, originalText: req.originalText)
                },
                onAlwaysAllow: {
                    WebToolService.shared.settings.mode = .alwaysAllow
                    pendingWebPermission = nil
                    beginWebPreparation(payload: req.payload, originalText: req.originalText)
                },
                onDeny: {
                    let text = req.originalText
                    pendingWebPermission = nil
                    // Declined — answer offline instead of dropping the turn.
                    sendOffline(text: text)
                }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        if let req = pendingToolWeb {
            StudioWebPermissionCard(
                query: webPermissionQueryText(req.payload),
                onAllowOnce: {
                    pendingToolWeb = nil
                    Task { await runToolWebAndFollowUp(query: req.query, payload: req.payload, depth: req.depth) }
                },
                onAlwaysAllow: {
                    WebToolService.shared.settings.mode = .alwaysAllow
                    pendingToolWeb = nil
                    Task { await runToolWebAndFollowUp(query: req.query, payload: req.payload, depth: req.depth) }
                },
                onDeny: {
                    pendingToolWeb = nil
                    declineToolWebAndFollowUp(depth: req.depth)
                }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        if let req = pendingToolFile {
            AssistantFileApprovalCard(
                prompt: req.prompt,
                onChoose: { showToolFilePicker = true },
                onDecline: {
                    let depth = req.depth
                    pendingToolFile = nil
                    feedToolResultAndFollowUp(
                        name: "file_read",
                        result: "The user cancelled file selection.",
                        depth: depth
                    )
                }
            )
        }
        if let req = pendingToolConfirm {
            AssistantApprovalCard(
                toolName: req.call.name,
                reason: req.call.name == "generate_image"
                    ? "The assistant wants to generate an image on this device. That uses the GPU and battery."
                    : "The assistant wants to save this text into your on-device Knowledge Base.",
                detail: toolConfirmDetail(req.call),
                onAllowOnce: {
                    let call = req.call
                    let depth = req.depth
                    pendingToolConfirm = nil
                    Task { await runConfirmedTool(call, depth: depth) }
                },
                onAlwaysAllow: nil,
                onDecline: {
                    let name = req.call.name
                    let depth = req.depth
                    pendingToolConfirm = nil
                    feedToolResultAndFollowUp(
                        name: name,
                        result: "The user declined this \(name) request.",
                        depth: depth
                    )
                }
            )
        }
        if let name = runningToolName, pendingToolWeb == nil, pendingToolFile == nil, pendingToolConfirm == nil {
            AssistantRunningToolCard(name: name)
        }
        if let status = imageActivityStatus {
            AssistantImageGenerationCard(status: status, detail: imageGen.statusMessage)
        }
        if !lastUsedCitedIndices.isEmpty {
            AssistantCitationCard(
                citations: lastWebCitations,
                citedIndices: lastUsedCitedIndices
            )
        }
    }

    private var imageActivityStatus: AssistantActivity.ImageStatus? {
        switch imageGen.state {
        case .downloading(let p): return .downloading(p)
        case .loading: return .loading
        case .generating(let p): return .generating(p)
        case .failed(let msg): return .failed(msg)
        case .idle, .ready: return nil
        }
    }

    private func webApprovalDetail(_ payload: QueryOrURL) -> String {
        switch payload {
        case .query(let q): return "Query: \(q)"
        case .url(let u): return "URL: \(u.absoluteString)"
        }
    }

    /// Exactly what would leave the device, quoted back to the user.
    private func webPermissionQueryText(_ payload: QueryOrURL) -> String {
        switch payload {
        case .query(let q): return q
        case .url(let u): return u.absoluteString
        }
    }

    private var isGenerating: Bool {
        if submissionPreparing { return true }
        if messages.contains(where: \.isStreaming) { return true }
        if isPreparingImageContext || documentSearchID != nil || pendingWebPermission != nil || webPreparationID != nil { return true }
        if pendingToolWeb != nil || pendingToolFile != nil || runningToolName != nil {
            return true
        }
        return assistant.isGeneratingSelectedTarget
    }

    private var canSendMessage: Bool {
        guard !isGenerating, pendingWebPermission == nil, documentSearchID == nil, assistant.canGenerateSelectedTarget else { return false }
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFile = !pendingAttachments.isEmpty
        let hasSupportedImage = !pendingImageThumbnails.isEmpty || pendingImageThumbnail != nil
        return hasText || hasFile || hasSupportedImage
    }

    private func stopGeneration() {
        preserveUnsentSubmission()
        generationFailure = nil
        operationID = UUID()
        submissionPreparing = false
        webPreparationTask?.cancel()
        webPreparationTask = nil
        webPreparationID = nil
        if inputText.isEmpty, let prompt = webPreparationPrompt { inputText = prompt }
        webPreparationPrompt = nil
        if let request = pendingWebPermission {
            if inputText.isEmpty { inputText = request.originalText }
            pendingWebPermission = nil
        }
        if isPreparingImageContext {
            imageGroundingTask?.cancel()
            imageGroundingTask = nil
            MLXVisionService.shared.cancelCurrentInference()
            FastVLMService.shared.stopGeneration()
            LlamaCppVLMService.shared.cancelCurrentInference()
            isPreparingImageContext = false
            if inputText.isEmpty, let prompt = imageGroundingPrompt { inputText = prompt }
            imageGroundingPrompt = nil
        }
        cancelDocumentSearch()
        userAbortedToolTurn = true
        pendingToolWeb = nil
        pendingToolFile = nil
        pendingToolConfirm = nil
        showToolFilePicker = false
        runningToolName = nil
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].wasInterrupted = true
            messages[idx].isStreaming = false
        }
        assistant.stopGeneration()
        HapticManager.impact(.medium)
    }

    private func assistantStreamingMessage() -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            generationModelID: assistant.activeSelectionID,
            generationExecutionLocation: assistant.activeExecutionLocation
        )
    }

    @MainActor
    private func recordGenerationMetrics(messageID: UUID, tokensPerSecond: Double) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if tokensPerSecond > 0 {
            messages[idx].generationTokensPerSecond = tokensPerSecond
        }
        messages[idx].generationDuration = max(
            0,
            Date().timeIntervalSince(messages[idx].timestamp)
        )
        if assistant.lastGenerationHitTokenLimit {
            messages[idx].hitTokenLimit = true
        }
    }

    /// Closes the Add sheet, then runs the follow-up on the next beat.
    /// Presenting a second sheet while the first is still animating out is
    /// silently dropped by SwiftUI.
    private func handOffFromAddSheet(_ next: @escaping () -> Void) {
        showAddSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: next)
    }

    /// Pastes clipboard text into the composer (Add sheet → Paste clipboard).
    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            inputText = text
            inputFocused = true
            HapticManager.impact(.light)
        }
    }

    @available(*, deprecated, message: "Moved to KeyboardToolbar")
    private var sendButton: some View {
        let canSend = (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (assistant.isVisionChatCapable
                && (!pendingImageThumbnails.isEmpty || pendingImageThumbnail != nil)))
            && assistant.state == .ready

        return Button { sendMessage() } label: {
            Image(systemName: "arrow.up").accessibilityLabel("Send")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(canSend ? T.onAccentFill : .white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous).fill(
                        canSend ? AnyShapeStyle(T.accentStrong) : AnyShapeStyle(T.ink3)
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .animation(.easeInOut(duration: 0.18), value: canSend)
    }

    // MARK: - Web Tool send path

    /// Runs the Web Tool, then sends the augmented user message through the
    /// existing offline path. On any Web Tool failure, falls back to a plain
    /// offline send so the user always gets an answer.
    private func beginWebPreparation(payload: QueryOrURL, originalText: String) {
        let requestID = UUID()
        webPreparationID = requestID
        webPreparationPrompt = originalText
        webPreparationTask = Task {
            await runWithWebTool(payload: payload, originalText: originalText, requestID: requestID)
        }
    }

    private func runWithWebTool(payload: QueryOrURL, originalText: String, requestID: UUID) async {
        let scope = captureRequest()
        let result = await WebToolService.shared.runWebTool(
            for: payload, originalMessage: originalText
        )
        guard !Task.isCancelled, webPreparationID == requestID, accepts(scope) else { return }
        webPreparationID = nil
        webPreparationPrompt = nil
        webPreparationTask = nil
        switch result {
        case .success(let pkg):
            lastWebCitations = pkg.citations
            // Append a one-time system addition + the user message wrapped
            // with the WEB CONTEXT block. The local LLM uses [n] markers we
            // post-process below.
            if messages.isEmpty {
                let persona = PersonaStore.shared.active
                var prompt = persona.systemPrompt
                prompt += "\n\n" + CodingAssistantService.groundingPrompt
                prompt += "\n\n" + CodingAssistantService.responseFormattingPrompt
                let memory = MemoryStore.shared.contextBlock(forPersonaID: persona.id)
                if !memory.isEmpty { prompt += "\n\n" + memory }
                if activeModelToolsEnabled {
                    prompt += ToolRunner.systemPromptAddendum
                } else if AppSettings.shared.toolsEnabled,
                          assistant.activeModel.runtime == .coreAI {
                    prompt += ToolRunner.unavailablePromptAddendum
                }
                prompt += WebToolPromptBuilder.systemAddition()
                messages.append(ChatMessage(role: .system, content: prompt))
            } else {
                // Add a transient system-style note to existing convo so the
                // model knows web context follows.
                messages.append(ChatMessage(
                    role: .system,
                    content: WebToolPromptBuilder.systemAddition()
                ))
            }
            let userPayload = WebToolPromptBuilder.userMessageWithContext(
                originalMessage: originalText, pkg: pkg
            )
            sendAfterPromptBuild(text: userPayload, displayText: originalText,
                                  validCitations: Set(pkg.citations.map(\.index)))
        case .failure(let err):
            ToastCenter.shared.error(
                "Web Tool failed",
                detail: err.localizedDescription + " — answering offline."
            )
            sendOffline(text: originalText)
        }
    }

    /// Same as `sendOffline` but lets us substitute the display vs the prompt
    /// text (we don't want the giant WEB CONTEXT block visible in the chat
    /// bubble — only the model sees it).
    private func sendAfterPromptBuild(text promptText: String,
                                       displayText: String,
                                       validCitations: Set<Int>) {
        guard let submission = acceptedSubmission, accepts(submission) else { return }
        let attachmentBlock = FileAttachmentService.renderForPrompt(submission.draft.files)
        let resolvedPrompt = attachmentBlock.isEmpty ? promptText : attachmentBlock + "\n" + promptText
        if !submission.draft.files.isEmpty {
            messages.append(ChatMessage(role: .system, content: FileAttachmentService.systemPromptAddendum))
        }
        let pendingImage = submission.draft.legacyImage
        let pendingImages = submission.draft.images
        let imageAttachments: [ChatMessage.ImageAttachment] = {
            var imgs = pendingImages
            if imgs.isEmpty, let pi = pendingImage {
                imgs.insert(ChatMessage.ImageAttachment(data: pi, caption: nil), at: 0)
            }
            return imgs
        }()
        messages.append(ChatMessage(
            role: .user,
            content: displayText,
            modelContent: resolvedPrompt,
            imageThumbnailData: pendingImage,
            imageThumbnails: imageAttachments
        ))
        consumeSubmittedAttachments()
        let assistantMsg = assistantStreamingMessage()
        messages.append(assistantMsg)
        let msgID = assistantMsg.id

        // The visible turn keeps `displayText`; its persisted model-facing
        // content keeps the web excerpts available to later follow-ups.
        let llmMessages = messages.filter { $0.id != msgID }
        streamAssistantReply(
            messages: llmMessages,
            msgID: msgID,
            validCitations: validCitations,
            samplerConfig: buildSamplerConfig(),
            jsonMode: nextSendJSONMode,
            collectLogprobs: nextSendCollectLogprobs
        )
    }

    /// Runs diagnostics through the dedicated safe-analysis route instead of
    /// the selected chat model. This prevents a heavyweight selection such as
    /// Bonsai 27B from being loaded merely to inspect a small diagnostics log.
    private func diagnoseAppErrors() {
        inputFocused = false
        let instructions = "You are analyzing diagnostics from OnDevice, an on-device iOS AI app that runs local models (MLX / Core ML). Identify the most likely root cause(s), ranked, and give concrete prioritized fixes or user actions. Be concise and specific. If nothing looks wrong, say the device looks healthy. Do not invent log lines that are not present."
        let displayText = loc.t("Diagnose my app's recent errors and suggest fixes.")
        messages.append(ChatMessage(role: .user, content: displayText))
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(reply)
        let messageID = reply.id

        let responseScope = captureRequest()
        submissionPreparing = false
        SafeOnDeviceAnalysisCoordinator.shared.analyze(
            prompt: Diagnostics.shared.analysisContext(),
            instructions: instructions,
            maxTokens: 700,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        self.messages[idx].content += token
                    }
                }
            },
            onComplete: { routeError in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        if self.messages[idx].content.isEmpty, let routeError {
                            self.messages[idx].content = "Analysis unavailable: \(routeError)"
                        }
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: messageID,
                            tokensPerSecond: 0
                        )
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
    }

    /// Build a SamplerConfig from the current per-send override state.
    private func buildSamplerConfig() -> SamplerConfig {
        SamplerConfig(
            temperature: nextSendTemperature,
            topP: nextSendTopP,
            topK: nextSendTopK,
            minP: nil,
            repetitionPenalty: nextSendRepetitionPenalty,
            frequencyPenalty: nil,
            presencePenalty: nil,
            seed: nextSendSeed
        )
    }

    /// Builds the bounded context sent to the runtime. Old completed turns are
    /// replaced with persistent memory while `messages` remains the complete
    /// user-visible transcript.
    @MainActor
    private func preparedRuntimeContext(_ source: [ChatMessage]) -> [ChatMessage] {
        let policyAdjustedSource: [ChatMessage]
        if assistant.activeModel.runtime == .coreAI {
            policyAdjustedSource = CoreAIConversationPlanner.applyingCompactPromptPolicy(
                to: source,
                toolsEnabled: activeModelToolsEnabled
            )
        } else {
            policyAdjustedSource = source
        }
        let previous = conversationContextMemory
        let prepared = ConversationContextCompactor.prepare(
            messages: policyAdjustedSource,
            existingMemory: previous,
            maxTokens: assistant.currentInputBudget
        )
        conversationContextMemory = prepared.memory
        if prepared.memory != previous, let id = currentConversationID {
            store.setContextMemory(prepared.memory, for: id)
        }
        return prepared.messages
    }

    @MainActor
    private func stopAfterCompleteToolCallIfNeeded(messageID: UUID) {
        guard activeModelToolsEnabled,
              detectedStreamingToolCalls[messageID] == nil,
              let body = messages.first(where: { $0.id == messageID })?.content,
              let call = ToolRunner.extractCall(from: body) else { return }
        detectedStreamingToolCalls[messageID] = call
        assistant.stopGeneration()
    }

    /// Core AI must honor its curated dialect capability. MLX/GGUF retain the
    /// tolerant text-tool path that existed before Core AI was added.
    private var activeModelToolsEnabled: Bool {
        ToolRunner.toolsEnabled(
            settingEnabled: AppSettings.shared.toolsEnabled,
            runtime: assistant.activeModel.runtime,
            modelSupportsTools: assistant.activeModel.supportsTools
        )
    }

    /// Common streaming path that drops fake citations after the model finishes.
    private func streamAssistantReply(messages llmMessages: [ChatMessage],
                                       msgID: UUID,
                                       validCitations: Set<Int>,
                                       samplerConfig: SamplerConfig? = nil,
                                       jsonMode: Bool = false,
                                       collectLogprobs: Bool = false) {
        // Snapshot the per-send sampler overrides BEFORE we dispatch the
        // generation. We immediately clear the @State so the next message
        // starts from defaults; the snapshot is what gets used by this
        // specific call. If we kept reading from @State inside the
        // closure, a fast double-send could leak the override into the
        // wrong reply.
        let tempOverride = nextSendTemperature
        let topPOverride = nextSendTopP
        let sc = samplerConfig
        let jm = jsonMode
        let cl = collectLogprobs
        nextSendTemperature = nil
        nextSendTopP = nil
        nextSendTopK = nil
        nextSendRepetitionPenalty = nil
        nextSendSeed = nil
        nextSendJSONMode = false
        nextSendCollectLogprobs = false
        let runtimeMessages = preparedRuntimeContext(llmMessages)
        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: runtimeMessages,
            temperatureOverride: tempOverride,
            topPOverride: topPOverride,
            samplerConfig: sc,
            jsonMode: jm,
            collectLogprobs: cl,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                        self.messages[idx].content += token
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                        let raw = self.messages[idx].content
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: msgID,
                            tokensPerSecond: rate
                        )
                        if self.recoverUnfinishedReasoningIfNeeded(
                            messageID: msgID,
                            contextMessages: runtimeMessages,
                            validCitations: validCitations
                        ) {
                            return
                        }
                        if self.assistant.lastGenerationHitTokenLimit {
                            // The model exhausted its reply budget mid-answer
                            // (no EOS). Say so — a silently truncated bubble
                            // reads as a complete answer otherwise.
                            ToastCenter.shared.info(
                                "Reply reached the token limit",
                                detail: "The answer may be incomplete — send \"continue\" or raise Response length in assistant settings."
                            )
                        }
                        if !validCitations.isEmpty {
                            let cited = WebToolPromptBuilder.citedIndices(in: raw)
                            self.lastUsedCitedIndices = cited.intersection(validCitations)
                            let cleaned = WebToolPromptBuilder.filterFakeCitations(
                                answer: raw, validIndices: validCitations
                            )
                            self.messages[idx].content = cleaned
                        }
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
    }

    /// Thinking models sometimes exhaust their output budget before they
    /// close `<think>` and start the final answer. Close the block for
    /// rendering, then run one short no-thinking continuation that appends
    /// only the final answer to the same bubble.
    @MainActor
    private func recoverUnfinishedReasoningIfNeeded(
        messageID: UUID,
        contextMessages: [ChatMessage],
        validCitations: Set<Int> = []
    ) -> Bool {
        guard !reasoningRecoveryMessageIDs.contains(messageID),
              let idx = messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }
        let raw = messages[idx].content
        guard ReasoningCompletionGuard.needsFinalAnswerRecovery(raw) else {
            return false
        }

        reasoningRecoveryMessageIDs.insert(messageID)
        messages[idx].content = ReasoningCompletionGuard.closeForDisplay(raw) + "\n\n"
        messages[idx].isStreaming = true
        ToastCenter.shared.info(
            "Finishing answer",
            detail: "The model used its reply budget while reasoning."
        )

        var recoveryContext = contextMessages
        recoveryContext.append(ChatMessage(role: .assistant, content: raw))
        recoveryContext.append(ChatMessage(role: .user, content: ReasoningCompletionGuard.recoveryPrompt))

        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: recoveryContext,
            maxTokensOverride: 768,
            temperatureOverride: 0.2,
            topPOverride: 0.9,
            forceNoThinking: true,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        self.messages[idx].content += token
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        let raw = self.messages[idx].content
                        if !validCitations.isEmpty {
                            let cited = WebToolPromptBuilder.citedIndices(in: raw)
                            self.lastUsedCitedIndices = cited.intersection(validCitations)
                            self.messages[idx].content = WebToolPromptBuilder.filterFakeCitations(
                                answer: raw,
                                validIndices: validCitations
                            )
                        }
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: messageID,
                            tokensPerSecond: rate
                        )
                        if self.assistant.lastGenerationHitTokenLimit {
                            ToastCenter.shared.info(
                                "Reply reached the token limit",
                                detail: "The answer may be incomplete — send \"continue\" or raise Response length in assistant settings."
                            )
                        }
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
        return true
    }

    // MARK: - Send

    private func retryFailedResponse() {
        guard !isGenerating else { return }
        let scope = captureRequest()
        Task { @MainActor in
            await ensureModelReady()
            guard accepts(scope), !isGenerating, assistant.canGenerateSelectedTarget else { return }
            regenerateLastResponse()
        }
    }

    /// Deliver failure separately from answer text. The runtime has already
    /// drained before onComplete; keep all existing successful completion and
    /// tool/reasoning behavior, but never run it for a failed generation.
    private func generateChatReply(
        messages runtimeMessages: [ChatMessage],
        maxTokensOverride: Int? = nil,
        temperatureOverride: Double? = nil,
        topPOverride: Double? = nil,
        samplerConfig: SamplerConfig? = nil,
        jsonMode: Bool = false,
        collectLogprobs: Bool = false,
        forceNoThinking: Bool = false,
        resumeTruncatedReply: Bool = false,
        onToken: @escaping @Sendable (String) -> Void,
        onLogprobToken: (@Sendable (TokenLogprob) -> Void)? = nil,
        onComplete: @escaping @Sendable (Double) -> Void
    ) {
        let scope = captureRequest()
        let replyID = messages.last(where: \.isStreaming)?.id
        let failure = ChatGenerationFailure()
        generationFailure = nil
        Diagnostics.shared.breadcrumb("chat request started · request=\(scope.id)", category: "chat-presentation")
        assistant.generate(
            messages: runtimeMessages,
            maxTokensOverride: maxTokensOverride,
            temperatureOverride: temperatureOverride,
            topPOverride: topPOverride,
            samplerConfig: samplerConfig,
            jsonMode: jsonMode,
            collectLogprobs: collectLogprobs,
            forceNoThinking: forceNoThinking,
            resumeTruncatedReply: resumeTruncatedReply,
            onToken: onToken,
            onLogprobToken: onLogprobToken,
            onComplete: { rate in
                let detail = failure.detail
                Task { @MainActor in
                    guard self.accepts(scope) else {
                        Diagnostics.shared.breadcrumb("stale chat completion ignored · request=\(scope.id)", category: "chat-presentation")
                        return
                    }
                    guard let detail else {
                        Diagnostics.shared.breadcrumb("chat request completed · request=\(scope.id)", category: "chat-presentation")
                        onComplete(rate)
                        return
                    }
                    Diagnostics.shared.breadcrumb("chat request failed · request=\(scope.id)", category: "chat-presentation")
                    self.submissionPreparing = false
                    self.generationFailure = detail
                    if let index = self.messages.firstIndex(where: { $0.id == replyID }) {
                        self.messages[index].isStreaming = false
                    }
                    self.persistCurrentConversation()
                }
            },
            onError: { failure.record($0) }
        )
    }

    /// Wires up the result of PhotoPickerView: stash a thumbnail for the
    /// next user message (so the bubble shows the actual photo). When the
    /// loaded assistant runtime is vision-capable it receives pixels directly.
    /// Text-only assistants use the selected visual model as a sequential
    /// on-device bridge when Send is tapped, so image-only turns work without
    /// exposing a noisy OCR dump in the composer.
    private func handlePickedPhoto(_ picked: PickedPhoto) {
        DispatchQueue.main.async {
            ToolBridge.shared.lastImage = picked.image
            if let jpeg = Self.makeThumbnailJPEG(picked.image) {
                // Multi-image: add to thumbnails array instead of replacing.
                // First image also populates pendingImageThumbnail for backward compat.
                if self.pendingImageThumbnail == nil {
                    self.pendingImageThumbnail = jpeg
                }
                self.pendingImageThumbnails.append(
                    ChatMessage.ImageAttachment(
                        data: jpeg,
                        caption: picked.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
            self.inputFocused = true
            HapticManager.impact(.light)
        }
    }

    /// Down-samples a UIImage to a ~480-pt-long-edge JPEG so the
    /// thumbnail kept on every chat message stays well under 100 KB.
    /// Returns nil only if the image is degenerate (zero size); the
    /// caller skips the attachment in that case.
    private static func makeThumbnailJPEG(_ image: UIImage) -> Data? {
        let maxEdge: CGFloat = 480
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxEdge / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.75)
    }

    private func sendMessage() {
        if ODBridge.shared.store.voiceSessionActive {
            ODBridge.shared.store.requestExclusiveOperation("Sending a chat message") { sendMessage() }
            return
        }
        guard canSendMessage else { return }
        operationID = UUID()
        let submission = captureRequest()
        acceptedSubmission = submission
        submissionPreparing = true
        userAbortedToolTurn = false
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Image-only sends work for both native multimodal models and text
        // models bridged through the selected on-device visual model.
        let imageOnlySend = trimmed.isEmpty
            && (!pendingImageThumbnails.isEmpty || pendingImageThumbnail != nil)
        let fileOnlySend = trimmed.isEmpty && !pendingAttachments.isEmpty
        guard !trimmed.isEmpty || imageOnlySend || fileOnlySend else { return }
        let text: String
        if imageOnlySend {
            text = "What's in this image? Describe it in detail."
        } else if fileOnlySend {
            text = "Review the attached file."
        } else {
            text = inputText
        }
        dictationResetID = UUID()
        if submission.matchesDraft(currentDraft, revision: draftRevision) { inputText = "" }
        inputFocused = false
        KeyboardDismiss.now()
        HapticManager.messageSent()

        if !assistant.isVisionChatCapable,
           !pendingImageThumbnails.isEmpty || pendingImageThumbnail != nil {
            isPreparingImageContext = true
            ToastCenter.shared.info(
                "Analyzing image on device",
                detail: "The visual model will hand its description to \(assistant.activeDisplayName)."
            )
            imageGroundingPrompt = text
            imageGroundingTask = Task { await sendWithVisualGrounding(displayText: text) }
            return
        }

        // Web Tool decision happens BEFORE we start generation. If the user's
        // settings (off / askEveryTime / alwaysAllow) route to web sources,
        // we either prompt for permission or kick off the fetch immediately.
        let decision = WebToolService.shared.decide(for: text)
        switch decision {
        case .requiresPermission(let reason, let payload):
            pendingWebPermission = .init(reason: reason, payload: payload,
                                          originalText: text)
            return   // user will hit a button in WebPermissionSheet
        case .webRecommended(_, let query):
            beginWebPreparation(payload: .query(query), originalText: text)
            return
        case .directURL(let url):
            beginWebPreparation(payload: .url(url), originalText: text)
            return
        case .noWebNeeded, .blocked:
            break   // fall through to offline path
        }

        sendOffline(text: text)
    }

    private func cancelDocumentSearch() {
        if documentSearchID != nil { preserveUnsentSubmission() }
        if documentSearchID != nil { submissionPreparing = false }
        documentSearchTask?.cancel()
        documentSearchTask = nil
        documentSearchID = nil
        if let prompt = documentSearchPrompt, inputText.isEmpty { inputText = prompt }
        documentSearchPrompt = nil
    }

    /// Resolve local document context without blocking typing or scrolling.
    private func sendOffline(text: String, visualContext: String? = nil) {
        guard let submission = acceptedSubmission, accepts(submission) else { return }
        guard documentSearchID == nil else { return }
        if visualContext == nil,
           submission.draft.files.isEmpty,
           submission.draft.images.isEmpty,
           submission.draft.legacyImage == nil,
           LocalDateAnswer.isDateOnlyQuestion(text) {
            sendOfflinePrepared(text: text, visualContext: nil, kb: nil)
            return
        }
        let kb = KnowledgeBaseService.shared
        guard kb.isEnabled, kb.totalChunks > 0 else {
            sendOfflinePrepared(text: text, visualContext: visualContext, kb: nil)
            return
        }
        let requestID = UUID()
        let conversationID = currentConversationID
        let lastMessageID = messages.last?.id
        let selectionID = assistant.activeSelectionID
        documentSearchID = requestID
        documentSearchPrompt = text
        documentSearchTask = Task { @MainActor in
            let context = await kb.contextBlock(for: text)
            guard !Task.isCancelled, documentSearchID == requestID, accepts(submission) else { return }
            guard currentConversationID == conversationID, messages.last?.id == lastMessageID,
                  assistant.activeSelectionID == selectionID, assistant.canGenerateSelectedTarget else {
                cancelDocumentSearch()
                return
            }
            documentSearchID = nil
            documentSearchPrompt = nil
            documentSearchTask = nil
            sendOfflinePrepared(text: text, visualContext: visualContext, kb: context)
        }
    }

    /// Pure offline send (no web context).
    private func sendOfflinePrepared(text: String, visualContext: String?, kb: (block: String, sources: [ChatMessage.DocumentSource])?) {
        guard let submission = acceptedSubmission, accepts(submission) else { return }
        userAbortedToolTurn = false
        let attachments = submission.draft.files
        let attachmentBlock = FileAttachmentService.renderForPrompt(attachments)
        // On-device RAG: pull the most relevant excerpts from the Knowledge
        // Base for THIS query (cosine over locally-embedded chunks, nothing
        // leaves the device). nil when the KB is disabled/empty or nothing is
        // relevant — in which case behaviour is unchanged.

        if messages.isEmpty {
            // System prompt = persona + memory facts (scoped to persona) + tool instructions
            let persona = PersonaStore.shared.active
            var prompt = persona.systemPrompt
            prompt += "\n\n" + CodingAssistantService.groundingPrompt
            prompt += "\n\n" + CodingAssistantService.responseFormattingPrompt
            let memory = MemoryStore.shared.contextBlock(forPersonaID: persona.id)
            if !memory.isEmpty { prompt += "\n\n" + memory }
            if activeModelToolsEnabled {
                prompt += ToolRunner.systemPromptAddendum
            } else if AppSettings.shared.toolsEnabled,
                      assistant.activeModel.runtime == .coreAI {
                prompt += ToolRunner.unavailablePromptAddendum
            }
            if !attachments.isEmpty {
                prompt += FileAttachmentService.systemPromptAddendum
            }
            if kb != nil {
                prompt += "\n\nYou have a Knowledge Base of the user's own files. When excerpts are provided in a turn, ground your answer in them and cite the [source]."
            }
            messages.append(ChatMessage(role: .system, content: prompt))
        } else if !attachments.isEmpty {
            // Append a system note before the user turn so the model picks
            // up on the attachment convention even mid-conversation.
            messages.append(ChatMessage(
                role: .system,
                content: FileAttachmentService.systemPromptAddendum
            ))
        }
        if attachments.isEmpty, visualContext == nil, kb == nil,
           submission.draft.images.isEmpty,
           submission.draft.legacyImage == nil,
           let answer = LocalDateAnswer.answer(for: text) {
            messages.append(ChatMessage(role: .user, content: text))
            messages.append(ChatMessage(role: .assistant, content: answer))
            submissionPreparing = false
            persistCurrentConversation()
            HapticManager.analysisComplete()
            return
        }
        // Display message: bare user text. The LLM sees the same chat history
        // but with the attachment block prepended to JUST the latest turn —
        // we build that snapshot below and pass it through `streamAssistantReply`.
        let pendingImage = submission.draft.legacyImage
        let pendingImages = submission.draft.images
        let imageAttachments: [ChatMessage.ImageAttachment] = {
            var imgs = pendingImages
            if imgs.isEmpty, let pi = pendingImage {
                imgs.insert(ChatMessage.ImageAttachment(data: pi, caption: nil), at: 0)
            }
            return imgs
        }()
        messages.append(ChatMessage(
            role: .user,
            content: text,
            imageThumbnailData: pendingImage,
            imageThumbnails: imageAttachments
        ))

        var assistantMsg = assistantStreamingMessage()
        assistantMsg.documentSources = kb?.sources
        messages.append(assistantMsg)
        let msgID = assistantMsg.id

        // Keep grounding on the user turn itself. `content` remains the small
        // bubble text while `modelContent` survives follow-ups and persistence.
        if let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) {
            var prefix = ""
            if let kb { prefix += kb.block + "\n\n" }
            if !attachmentBlock.isEmpty { prefix += attachmentBlock + "\n" }
            if let visualContext, !visualContext.isEmpty {
                prefix += """
                [ON-DEVICE IMAGE ANALYSIS]
                \(visualContext)
                [END IMAGE ANALYSIS]

                """
            }
            if !prefix.isEmpty {
                messages[lastUserIdx].modelContent = "\(prefix)\(text)"
            }
        }
        let llmMessages = messages.filter { $0.id != msgID }
        // Files are one-shot — clear after handing them to the model.
        consumeSubmittedAttachments()

        // Coalesce token mutations onto the main actor explicitly. Using
        // Task { @MainActor } (not DispatchQueue.main.async) lets the runtime
        // batch updates with the SwiftUI render loop — fewer redraws, less
        // chance of mutating a stale view struct.
        let tempOverride = nextSendTemperature
        let topPOverride = nextSendTopP
        let samplerCfg = buildSamplerConfig()
        let useJSON = nextSendJSONMode
        let useLogprobs = nextSendCollectLogprobs
        nextSendTemperature = nil
        nextSendTopP = nil
        nextSendTopK = nil
        nextSendRepetitionPenalty = nil
        nextSendSeed = nil
        nextSendJSONMode = false
        nextSendCollectLogprobs = false
        let runtimeMessages = preparedRuntimeContext(llmMessages)

        // Wrap the generate kickoff in a small inline helper so the
        // `/mac` async-augment path can call it with a rewritten
        // message list without duplicating the closure bodies.
        let responseScope = captureRequest()
        let startGenerate: @MainActor ([ChatMessage]) -> Void = { finalMessages in
            guard self.accepts(responseScope) else { return }
            self.submissionPreparing = false
            // Bind the optional logprob hook to a typed local first — a
            // `closure : nil` ternary can't be type-inferred inline inside a
            // multi-closure call. Logprobs aren't available from this MLX
            // build, so the handler is a no-op kept for a future backend.
            let logprobHandler: (@Sendable (TokenLogprob) -> Void)?
            if useLogprobs {
                logprobHandler = { _ in }
            } else {
                logprobHandler = nil
            }
            self.generateChatReply(
                messages: finalMessages,
                temperatureOverride: tempOverride,
                topPOverride: topPOverride,
                samplerConfig: samplerCfg,
                jsonMode: useJSON,
                collectLogprobs: useLogprobs,
                onToken: { token in
                    Task { @MainActor in
                        guard self.accepts(responseScope) else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                            self.messages[idx].content += token
                            self.stopAfterCompleteToolCallIfNeeded(messageID: msgID)
                        }
                    }
                },
                onLogprobToken: logprobHandler,
                onComplete: { rate in
                    Task { @MainActor in
                        guard self.accepts(responseScope) else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                            if visualContext != nil,
                               self.messages[idx].content
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               self.recoverEmptyVisualReplyIfNeeded(
                                messageID: msgID,
                                contextMessages: finalMessages
                               ) {
                                return
                            }
                            self.messages[idx].isStreaming = false
                            self.messages[idx].isJSONMode = useJSON
                            self.recordGenerationMetrics(
                                messageID: msgID,
                                tokensPerSecond: rate
                            )
                        }
                        let streamedCall = self.detectedStreamingToolCalls.removeValue(
                            forKey: msgID
                        )
                        let toolCall = self.activeModelToolsEnabled
                            ? streamedCall ?? self.messages
                                .first(where: { $0.id == msgID })
                                .flatMap({ ToolRunner.extractCall(from: $0.content) })
                            : nil
                        if let call = toolCall {
                            // Tool protocol JSON is transport, not an answer.
                            // Remove it from the visible transcript and replace
                            // it with the eventual natural-language synthesis.
                            self.messages.removeAll { $0.id == msgID }
                            self.persistCurrentConversation()
                            await self.executeToolCallAndFollowUp(call)
                            return
                        }
                        if self.recoverUnfinishedReasoningIfNeeded(
                            messageID: msgID,
                            contextMessages: finalMessages
                        ) {
                            return
                        }
                        self.persistCurrentConversation()
                        HapticManager.analysisComplete()
                    }
                }
            )
        }

        // `/mac` prefix → fetch Mac desktop context async, prepend
        // to the LLM-bound user turn, then generate. The non-`/mac`
        // path stays bit-for-bit identical to before — no async hop,
        // no extra latency. Mac context fetch failure quietly falls
        // through to the un-augmented prompt (just with the `/mac`
        // token stripped) so chat keeps working when the Mac is off.
        if BridgeAgentMode.shared.isMacCommand(text) {
            Task { @MainActor in
                let augmented = await BridgeAgentMode.shared.augmented(
                    messages: runtimeMessages,
                    userText: text
                )
                guard self.accepts(responseScope), !Task.isCancelled else { return }
                startGenerate(augmented)
            }
        } else {
            startGenerate(runtimeMessages)
        }
    }

    /// Runs a tool call, appends the result as a user message, and asks
    /// the assistant for a follow-up synthesis. Keeps the loop bounded to
    /// one tool call per send to avoid runaway chains.
    /// Hard cap on chained tool calls within one user turn — stops a model
    /// that loops on tools from running forever.
    private static let maxToolDepth = 5

    private func executeToolCallAndFollowUp(_ call: ToolCall, depth: Int = 0) async {
        guard AssistantActivity.shouldFollowUpAfterTool(aborted: userAbortedToolTurn) else { return }
        // Web access is consent-gated. When the model asks to search and the
        // user's mode is "ask every time", ToolRunner.runWebSearch would just
        // hard-fail (it can't pop UI from inside the runner). Intercept here
        // and route through the same permission sheet the pre-send path uses,
        // so the model CAN use the web — with the user's explicit OK. Always-
        // allow runs through the same web service here so citations are kept;
        // off returns a clear error without touching the network.
        if call.name == "web_search",
           let q = (call.args["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !q.isEmpty {
            let payload = webPayload(from: q)
            switch WebToolService.shared.settings.mode {
            case .askEveryTime:
                pendingToolWeb = ToolWebApproval(query: q, payload: payload, depth: depth)
                return   // resumed by the sheet's buttons
            case .alwaysAllow:
                await runToolWebAndFollowUp(query: q, payload: payload, depth: depth)
                return
            case .off:
                lastWebCitations = []
                feedToolResultAndFollowUp(
                    name: "web_search",
                    result: "Error: Web access is turned off in Settings -> Models & AI.",
                    depth: depth
                )
                return
            }
        }
        if call.name == "file_read" {
            let prompt = ((call.args["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
            pendingToolFile = ToolFileRequest(
                prompt: (prompt?.isEmpty == false) ? prompt! : "Pick a file to share with the assistant.",
                depth: depth, scope: captureRequest()
            )
            return
        }
        if call.name == "index_document" || call.name == "generate_image" {
            pendingToolConfirm = ToolConfirmRequest(call: call, depth: depth)
            return
        }

        await runConfirmedTool(call, depth: depth)
    }

    private func toolConfirmDetail(_ call: ToolCall) -> String {
        switch call.name {
        case "generate_image":
            return (call.args["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Generate an image"
        case "index_document":
            let name = (call.args["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (call.args["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = text.count > 240 ? String(text.prefix(240)) + "…" : text
            if let name, !name.isEmpty {
                return "\(name)\n\n\(preview)"
            }
            return preview
        default:
            return call.name
        }
    }

    private func runConfirmedTool(_ call: ToolCall, depth: Int) async {
        let scope = captureRequest()
        runningToolName = call.name
        ToastCenter.shared.info("Running tool: \(call.name)")
        let result = await ToolRunner.run(call)
        guard accepts(scope), !Task.isCancelled else { return }
        runningToolName = nil
        if call.name == "web_search" {
            lastWebCitations = []
        }
        // generate_image is fire-and-forget — the diffusion result lands on
        // ImageGenerationService asynchronously. Start a bounded waiter that
        // drops the finished image into the chat inline, in addition to the
        // textual status the model synthesises from below.
        if call.name == "generate_image", result.hasPrefix("Started generating") {
            appendGeneratedImageWhenReady()
        }
        feedToolResultAndFollowUp(name: call.name, result: result, depth: depth)
    }

    /// Polls `ImageGenerationService` (bounded) for the image produced by a
    /// `generate_image` tool call and appends it to the conversation as an
    /// assistant image message, so the result is visible inline rather than
    /// only in the Image tab. No-ops on timeout or generation failure.
    private func appendGeneratedImageWhenReady() {
        let service = ImageGenerationService.shared
        let scope = captureRequest()
        let baseline = service.resultURL
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(180)   // 3-minute safety cap
            while Date() < deadline {
                guard self.accepts(scope), !Task.isCancelled else { return }
                if case .failed = service.state { return }
                // A fresh, fully-decoded image is a different instance than
                // whatever was there when the tool fired.
                if let img = service.image, service.resultURL != baseline {
                    if case .generating = service.state {
                        // a later denoise step is still publishing — keep waiting
                    } else if let data = Self.makeThumbnailJPEG(img) {
                        self.messages.append(ChatMessage(role: .assistant,
                                                         content: "",
                                                         imageThumbnailData: data))
                        self.persistCurrentConversation()
                        return
                    } else {
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4s
            }
        }
    }

    /// Runs a consented web_search (bypassing the runner's mode gate, since
    /// the user just approved it in the sheet) and continues the follow-up.
    private func runToolWebAndFollowUp(query: String, payload: QueryOrURL, depth: Int) async {
        let scope = captureRequest()
        guard AssistantActivity.shouldFollowUpAfterTool(aborted: userAbortedToolTurn) else {
            runningToolName = nil
            return
        }
        runningToolName = "web_search"
        ToastCenter.shared.info("Running tool: web_search")
        let result = await WebToolService.shared.runWebTool(
            for: payload, originalMessage: query
        )
        guard accepts(scope), !Task.isCancelled else { return }
        runningToolName = nil
        let block: String
        switch result {
        case .success(let pkg):
            lastWebCitations = pkg.citations
            block = pkg.renderedBlock.isEmpty
                ? "Web search returned no usable content."
                : pkg.renderedBlock
        case .failure(let err):
            lastWebCitations = []
            block = "Web search failed: \(err.localizedDescription)"
        }
        // Carry the captured depth so a model looping via the consent path
        // still hits the maxToolDepth cap instead of restarting the counter.
        feedToolResultAndFollowUp(name: "web_search", result: block, depth: depth)
    }

    /// User declined the web_search consent — feed an offline-only result so
    /// the model still produces an answer instead of stalling on the tool block.
    private func declineToolWebAndFollowUp(depth: Int) {
        lastWebCitations = []
        feedToolResultAndFollowUp(
            name: "web_search",
            result: "The user declined web access for this request. Answer using your existing knowledge and note any uncertainty.",
            depth: depth
        )
    }

    /// A cross-model image handoff gets one bounded retry when the text model
    /// immediately emits EOS. This is intentionally limited to visually
    /// grounded turns and to one retry per message so a broken model can never
    /// enter a generation loop or leave a permanent empty bubble.
    @MainActor
    private func recoverEmptyVisualReplyIfNeeded(
        messageID: UUID,
        contextMessages: [ChatMessage]
    ) -> Bool {
        guard !emptyVisualRecoveryMessageIDs.contains(messageID),
              let idx = messages.firstIndex(where: { $0.id == messageID })
        else { return false }

        emptyVisualRecoveryMessageIDs.insert(messageID)
        messages[idx].isStreaming = true
        Diagnostics.shared.notice(
            "empty visual handoff response · retrying without thinking",
            category: "assistant"
        )

        var recoveryContext = contextMessages
        recoveryContext.append(ChatMessage(
            role: .user,
            content: """
            Answer the latest image question now using the on-device image analysis already provided. Give a direct, useful answer. Do not return an empty response.
            """
        ))

        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: recoveryContext,
            maxTokensOverride: 768,
            temperatureOverride: 0.2,
            topPOverride: 0.9,
            forceNoThinking: true,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        self.messages[idx].content += token
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        if self.messages[idx].content
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.messages[idx].content = """
                            I analyzed the image, but this text model did not produce an answer. Please tap Regenerate or try a different assistant model.
                            """
                        }
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: messageID,
                            tokensPerSecond: rate
                        )
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
        return true
    }

    /// Appends a `tool_result` block as a user turn and asks the model for the
    /// natural-language follow-up. Shared by every tool path.
    private func feedToolResultAndFollowUp(name: String, result: String, depth: Int = 0) {
        runningToolName = nil
        let resultBlock = ToolRunner.resultBlock(name: name, result: result)
        let resultMessage = ChatMessage(role: .user, content: resultBlock)
        messages.append(resultMessage)
        guard AssistantActivity.shouldFollowUpAfterTool(aborted: userAbortedToolTurn) else {
            persistCurrentConversation()
            return
        }

        let followUpMsg = assistantStreamingMessage()
        messages.append(followUpMsg)
        let followID = followUpMsg.id
        let validCitations: Set<Int> = name == "web_search"
            ? Set(lastWebCitations.map(\.index))
            : []
        let followUpContext = preparedRuntimeContext(toolFollowUpContext(
            name: name,
            result: result,
            resultMessageID: resultMessage.id,
            followID: followID
        ))

        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: followUpContext,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == followID }) {
                        self.messages[idx].content += token
                        self.stopAfterCompleteToolCallIfNeeded(messageID: followID)
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == followID }) {
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: followID,
                            tokensPerSecond: rate
                        )
                    }
                    let streamedCall = self.detectedStreamingToolCalls.removeValue(
                        forKey: followID
                    )
                    let nextCall = self.activeModelToolsEnabled && depth + 1 < Self.maxToolDepth
                        ? streamedCall ?? self.messages
                            .first(where: { $0.id == followID })
                            .flatMap({ ToolRunner.extractCall(from: $0.content) })
                        : nil
                    if let next = nextCall {
                        self.messages.removeAll { $0.id == followID }
                        self.persistCurrentConversation()
                        await self.executeToolCallAndFollowUp(next, depth: depth + 1)
                        return
                    }
                    if self.recoverUnfinishedReasoningIfNeeded(
                        messageID: followID,
                        contextMessages: followUpContext,
                        validCitations: validCitations
                    ) {
                        return
                    }
                    if let idx = self.messages.firstIndex(where: { $0.id == followID }),
                       !validCitations.isEmpty {
                        let raw = self.messages[idx].content
                        let cited = WebToolPromptBuilder.citedIndices(in: raw)
                        self.lastUsedCitedIndices = cited.intersection(validCitations)
                        self.messages[idx].content = WebToolPromptBuilder.filterFakeCitations(
                            answer: raw,
                            validIndices: validCitations
                        )
                    }
                    // Multi-step agent loop: if the model asked for ANOTHER
                    // tool in its follow-up, run it too — up to maxToolDepth —
                    // so it can chain (e.g. knowledge_base → web_search →
                    // answer) instead of being limited to a single tool call.
                    self.persistCurrentConversation()
                }
            }
        )
    }

    /// Keeps the persisted/UI message compact while giving the model the tool
    /// result in a form it can actually read. This matters most for web_search:
    /// JSON is the right storage format, but escaped newlines make fetched page
    /// text much harder for small local models to use.
    private func toolFollowUpContext(
        name: String,
        result: String,
        resultMessageID: UUID,
        followID: UUID
    ) -> [ChatMessage] {
        var context = messages.filter { $0.id != followID }
        if let idx = context.firstIndex(where: { $0.id == resultMessageID }) {
            context[idx].content = ToolRunner.resultForModelContext(name: name, result: result)
        }
        guard name == "web_search" else { return context }

        let hasWebNotice = context.contains { msg in
            msg.role == .system
                && msg.content.contains("WEB TOOL")
                && msg.content.contains("WEB CONTEXT")
        }
        if !hasWebNotice {
            context.append(ChatMessage(role: .system,
                                       content: WebToolPromptBuilder.systemAddition()))
        }
        return context
    }

    /// Treat a bare http(s) URL as a direct fetch; otherwise a search query.
    private func webPayload(from q: String) -> QueryOrURL {
        if let url = URL(string: q),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return .url(url)
        }
        return .query(q)
    }

    // MARK: - Sampler override status (computed for the toggle pill)

    /// True when either the temperature or top-p override is set. Used
    /// to color the disclosure pill (accent vs muted) so the user can
    /// tell at a glance that the next send will deviate from defaults.
    private var samplerOverrideActive: Bool {
        nextSendTemperature != nil || nextSendTopP != nil
    }

    /// Short label inside the disclosure pill. Either "sampling" (no
    /// override) or "T 0.42 · P 0.85" so the active override values are
    /// visible without expanding the row.
    private var samplerStatusLabel: String {
        guard samplerOverrideActive else { return "sampling" }
        var parts: [String] = []
        if let t = nextSendTemperature {
            parts.append(String(format: "T %.2f", t))
        }
        if let p = nextSendTopP {
            parts.append(String(format: "P %.2f", p))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quick actions

    /// Inject a follow-up prompt that reframes the previous reply. The
    /// chip taps land here; we map the case to a concrete prompt and
    /// dispatch through the existing offline path so all the regular
    /// state machinery (streaming message append, web tool decision,
    /// stop-button toolbar, etc.) keeps working unchanged.
    private func sendQuickAction(_ kind: QuickActionKind) {
        guard !isGenerating, assistant.canGenerateSelectedTarget else { return }
        if kind == .continueReply,
           AssistantActivity.continuationMessageIndex(in: messages) != nil {
            continueTruncatedReply()
            return
        }
        let prompt: String = {
            switch kind {
            case .continueReply:
                return "Please continue from where you left off."
            case .shorter:
                return "Rewrite that more concisely. Keep the key points but cut anything redundant."
            case .moreFormal:
                return "Rewrite that in a more formal, professional tone."
            case .explain:
                return "Explain that in simpler terms, as if I were unfamiliar with the topic."
            }
        }()
        HapticManager.impact(.light)
        operationID = UUID()
        let scope = captureRequest()
        acceptedSubmission = ChatPresentationRequest(id: scope.id, conversationID: scope.conversationID,
            draftRevision: scope.draftRevision, modelID: scope.modelID,
            draft: ConversationPresentation(text: prompt), attachmentIDs: [])
        submissionPreparing = true
        sendOffline(text: prompt)
    }

    /// Resume the last truncated assistant turn in the same bubble.
    /// Standard GGUFs keep the native KV when possible; otherwise this
    /// re-prefills an open assistant turn (still no fake "continue" user message).
    private func continueTruncatedReply() {
        guard assistant.state == .ready,
              let idx = AssistantActivity.continuationMessageIndex(in: messages)
        else { return }
        operationID = UUID()
        userAbortedToolTurn = false
        pendingToolWeb = nil
        pendingToolFile = nil
        pendingToolConfirm = nil
        showToolFilePicker = false
        runningToolName = nil
        messages[idx].isStreaming = true
        messages[idx].hitTokenLimit = false
        messages[idx].wasInterrupted = false
        let msgID = messages[idx].id
        let context = preparedRuntimeContext(messages)
        HapticManager.impact(.light)
        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: context,
            resumeTruncatedReply: true,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let i = self.messages.firstIndex(where: { $0.id == msgID }) {
                        self.messages[i].content += token
                        self.stopAfterCompleteToolCallIfNeeded(messageID: msgID)
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let i = self.messages.firstIndex(where: { $0.id == msgID }) {
                        self.messages[i].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: msgID,
                            tokensPerSecond: rate
                        )
                    }
                    let streamedCall = self.detectedStreamingToolCalls.removeValue(forKey: msgID)
                    let toolCall = self.activeModelToolsEnabled
                        ? streamedCall ?? self.messages
                            .first(where: { $0.id == msgID })
                            .flatMap({ ToolRunner.extractCall(from: $0.content) })
                        : nil
                    if let call = toolCall {
                        self.messages.removeAll { $0.id == msgID }
                        self.persistCurrentConversation()
                        await self.executeToolCallAndFollowUp(call)
                        return
                    }
                    if self.recoverUnfinishedReasoningIfNeeded(
                        messageID: msgID,
                        contextMessages: context
                    ) {
                        return
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
    }

    // MARK: - Regenerate

    private func regenerateLastResponse() {
        stopGeneration()
        userAbortedToolTurn = false
        pendingToolWeb = nil
        pendingToolFile = nil
        pendingToolConfirm = nil
        showToolFilePicker = false
        runningToolName = nil
        assistant.stopGeneration()
        // Remove all trailing assistant messages to replay from the last user turn.
        while let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        guard messages.last?.role == .user else { return }

        let assistantMsg = assistantStreamingMessage()
        messages.append(assistantMsg)
        let msgID = assistantMsg.id
        let regenerateContext = preparedRuntimeContext(
            messages.filter { $0.id != msgID }
        )

        let responseScope = captureRequest()
        submissionPreparing = false
        generateChatReply(
            messages: regenerateContext,
            onToken: { token in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                        self.messages[idx].content += token
                    }
                }
            },
            onComplete: { rate in
                Task { @MainActor in
                    guard self.accepts(responseScope) else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == msgID }) {
                        self.messages[idx].isStreaming = false
                        self.recordGenerationMetrics(
                            messageID: msgID,
                            tokensPerSecond: rate
                        )
                    }
                    if self.recoverUnfinishedReasoningIfNeeded(
                        messageID: msgID,
                        contextMessages: regenerateContext
                    ) {
                        return
                    }
                    self.persistCurrentConversation()
                    HapticManager.analysisComplete()
                }
            }
        )
    }

    // MARK: - Chat image grounding

    /// Gives text-only assistant models real image understanding without
    /// keeping two large runtimes resident at once. The visual model runs
    /// first, is released by `assistant.load()`, and its factual output is
    /// injected only into the model-facing copy of the user turn.
    @MainActor
    private func sendWithVisualGrounding(displayText: String) async {
        guard let request = acceptedSubmission, accepts(request) else { return }
        var attachments = request.draft.images
        if attachments.isEmpty, let data = request.draft.legacyImage {
            attachments = [ChatMessage.ImageAttachment(data: data, caption: nil)]
        }

        let visualPrompt = """
        Analyze this image for another assistant answering the user's request:
        "\(displayText)"
        Describe the important visual details and transcribe all relevant visible text. Be factual and concise.
        """
        var grounded: [String] = []

        for (index, attachment) in attachments.enumerated() {
            guard !Task.isCancelled, accepts(request) else { return }
            guard let image = UIImage(data: attachment.data) else { continue }
            let rawDescription = await describeForChatGrounding(
                image: image,
                prompt: visualPrompt
            )
            guard !Task.isCancelled, accepts(request) else { return }
            let description = ImageGroundingSanitizer.clean(rawDescription)
            if !description.isEmpty {
                grounded.append("Image \(index + 1):\n\(description)")
            } else if let ocr = attachment.caption,
                      !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                grounded.append("Image \(index + 1) visible text:\n\(ocr)")
            }
        }

        guard !Task.isCancelled, accepts(request) else { return }
        // A local assistant load drains whichever visual backend was selected.
        // PCC has no resident weights, so it only refreshes availability.
        await assistant.load()
        guard !Task.isCancelled, accepts(request) else { return }
        guard assistant.canGenerateSelectedTarget else {
            preserveUnsentSubmission()
            submissionPreparing = false
            isPreparingImageContext = false
            if inputText.isEmpty { inputText = displayText }
            ToastCenter.shared.error(
                "Couldn't resume the selected assistant",
                detail: "The image remains attached. Check model availability and try again."
            )
            return
        }

        guard !grounded.isEmpty else {
            preserveUnsentSubmission()
            submissionPreparing = false
            isPreparingImageContext = false
            if inputText.isEmpty { inputText = displayText }
            ToastCenter.shared.error(
                "Image analysis unavailable",
                detail: "Download or select a visual model in Models, then try again. The image remains attached."
            )
            return
        }

        isPreparingImageContext = false
        imageGroundingPrompt = nil
        imageGroundingTask = nil
        sendOffline(text: displayText, visualContext: grounded.joined(separator: "\n\n"))
    }

    @MainActor
    private func describeForChatGrounding(image: UIImage, prompt: String) async -> String {
        // SmolVLM2-500M Q8 is the smallest compatible visual runtime shipped
        // by the app (~520 MB on disk / ~850 MB working set). Prefer it for
        // text-model handoffs regardless of the heavier Lens model the user
        // may have selected. The llama.cpp + mtmd path also avoids the known
        // upstream MLX SmolVLM2 tiling crash.
        if BundledVLMInstaller.isInstalled {
            let smol = LlamaCppVLMService.shared
            if smol.activeRepoID != BundledVLMInstaller.bundledRepoID {
                await smol.switchTo(repoID: BundledVLMInstaller.bundledRepoID)
            }
            guard !Task.isCancelled else { return "" }
            if case .ready = smol.state {
                let accumulator = OSAllocatedUnfairLock(initialState: "")
                let output: String = await withCheckedContinuation { continuation in
                    smol.describe(
                        image: image,
                        prompt: prompt,
                        maxTokens: 320,
                        onToken: { token in
                            accumulator.withLock { text in
                                if text.count < 1_800 { text += token }
                            }
                        },
                        onComplete: { _ in
                            continuation.resume(returning: accumulator.withLock { $0 })
                        }
                    )
                }
                guard !Task.isCancelled else { return "" }
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Diagnostics.shared.breadcrumb(
                        "chat image grounded with bundled SmolVLM2-500M",
                        category: "assistant"
                    )
                    return output
                }
            }
        }

        // Compatibility fallbacks: FastVLM when it is the configured default,
        // then the user's installed Lens model. Every backend still runs
        // sequentially and is drained before the chat model reloads.
        guard !Task.isCancelled else { return "" }
        let storedSelection = AppSettings.shared.cameraVisualModelID
        let selectionID = LocalModelRegistry.storedVisionSelectionID(storedSelection)

        if LocalModelRegistry.isDefaultVisionSelection(selectionID) {
            guard AppSettings.shared.fastVLMEnabled,
                  let pixelBuffer = image.toCVPixelBuffer()
            else { return "" }

            let fastVLM = FastVLMService.shared
            if !fastVLM.componentStatus.canGenerate {
                await fastVLM.load()
            }
            guard !Task.isCancelled, fastVLM.componentStatus.canGenerate else { return "" }

            let settings = FastVLMGenerationSettings(
                maxTokens: 320,
                temperature: 0.1,
                topP: 0.9,
                repetitionPenalty: 1.0,
                stopOnEOS: true
            )
            var output = ""
            do {
                for try await chunk in fastVLM.analyze(
                    pixelBuffer: pixelBuffer,
                    task: .answerQuestion(prompt),
                    settings: settings
                ) {
                    output += chunk
                    if output.count >= 1_800 { break }
                }
            } catch {
                Diagnostics.shared.error(
                    "Chat image grounding failed: \(error.localizedDescription)",
                    category: "assistant"
                )
            }
            return output
        }

        let descriptor = LocalModelRegistry.visualDescriptor(
            forStoredSelectionID: storedSelection,
            catalog: ModelDownloadCenter.shared.models
        )
        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: storedSelection,
            catalog: ModelDownloadCenter.shared.models
        )
        let repoID = descriptor.repoID
        let accumulator = OSAllocatedUnfairLock(initialState: "")

        if runtime == .llamaCpp {
            let service = LlamaCppVLMService.shared
            if service.activeRepoID != repoID {
                await service.switchTo(repoID: repoID)
            }
            guard !Task.isCancelled else { return "" }
            guard case .ready = service.state else { return "" }
            return await withCheckedContinuation { continuation in
                service.describe(
                    image: image,
                    prompt: prompt,
                    maxTokens: 320,
                    onToken: { token in
                        accumulator.withLock { text in
                            if text.count < 1_800 { text += token }
                        }
                    },
                    onComplete: { _ in
                        continuation.resume(returning: accumulator.withLock { $0 })
                    }
                )
            }
        }

        let service = MLXVisionService.shared
        if service.activeRepoID != repoID {
            await service.switchTo(repoID: repoID)
        }
        guard !Task.isCancelled else { return "" }
        guard case .ready = service.state else { return "" }
        return await withCheckedContinuation { continuation in
            service.describe(
                image: image,
                prompt: prompt,
                maxTokens: 320,
                onToken: { token in
                    accumulator.withLock { text in
                        if text.count < 1_800 { text += token }
                    }
                },
                onComplete: { _ in
                    continuation.resume(returning: accumulator.withLock { $0 })
                }
            )
        }
    }

    // MARK: - Local VLM description

    private func analyzeImageWithVLM(imageData: Data) {
        guard !isGenerating, let uiImage = UIImage(data: imageData) else { return }
        operationID = UUID()
        let scope = captureRequest()

        let desiredRepoID: String = {
            let visionDescriptor = LocalModelRegistry.visualDescriptor(
                forStoredSelectionID: AppSettings.shared.cameraVisualModelID,
                catalog: ModelDownloadCenter.shared.models
            )
            return visionDescriptor.repoID
        }()

        guard !desiredRepoID.isEmpty else {
            ToastCenter.shared.error("No VLM model selected", detail: "Please select a visual model first.")
            return
        }

        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: AppSettings.shared.cameraVisualModelID,
            catalog: ModelDownloadCenter.shared.models
        )

        // Add user turn
        let userMsg = ChatMessage(
            role: .user,
            content: "Please describe the attached image.",
            imageThumbnailData: imageData,
            imageThumbnails: [ChatMessage.ImageAttachment(data: imageData, caption: nil)]
        )
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        let assistantMsgID = assistantMsg.id

        isPreparingImageContext = true
        imageGroundingTask = Task {
            if runtime == .llamaCpp {
                let llama = LlamaCppVLMService.shared
                if llama.activeRepoID != desiredRepoID {
                    ToastCenter.shared.info("Loading VLM...", detail: "Preparing \(desiredRepoID.components(separatedBy: "/").last ?? desiredRepoID)")
                    await llama.switchTo(repoID: desiredRepoID)
                }
                guard accepts(scope), !Task.isCancelled else { return }
                guard case .ready = llama.state else {
                    await MainActor.run {
                        guard self.accepts(scope) else { return }
                        self.isPreparingImageContext = false
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                            self.messages[idx].content = "Failed to load VLM model \(desiredRepoID)."
                            self.messages[idx].isStreaming = false
                        }
                    }
                    return
                }

                llama.describe(
                    image: uiImage,
                    prompt: "Describe what's in this image. Be concise.",
                    maxTokens: 256,
                    onToken: { token in
                        Task { @MainActor in
                            guard self.accepts(scope) else { return }
                            if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                                self.messages[idx].content += token
                            }
                        }
                    },
                    onComplete: { _ in
                        Task { @MainActor in
                            guard self.accepts(scope) else { return }
                            self.isPreparingImageContext = false
                            self.imageGroundingTask = nil
                            if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                                self.messages[idx].isStreaming = false
                                self.recordGenerationMetrics(
                                    messageID: assistantMsgID,
                                    tokensPerSecond: 0
                                )
                                self.persistCurrentConversation()
                                HapticManager.analysisComplete()
                            }
                        }
                    }
                )
            } else {
                let vision = MLXVisionService.shared
                if vision.activeRepoID != desiredRepoID {
                    ToastCenter.shared.info("Loading VLM...", detail: "Preparing \(desiredRepoID.components(separatedBy: "/").last ?? desiredRepoID)")
                    await vision.switchTo(repoID: desiredRepoID)
                }
                guard accepts(scope), !Task.isCancelled else { return }
                guard case .ready = vision.state else {
                    await MainActor.run {
                        guard self.accepts(scope) else { return }
                        self.isPreparingImageContext = false
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                            self.messages[idx].content = "Failed to load VLM model \(desiredRepoID)."
                            self.messages[idx].isStreaming = false
                        }
                    }
                    return
                }

                vision.describe(
                    image: uiImage,
                    prompt: "Describe what's in this image. Be concise.",
                    maxTokens: 256,
                    onToken: { token in
                        Task { @MainActor in
                            guard self.accepts(scope) else { return }
                            if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                                self.messages[idx].content += token
                            }
                        }
                    },
                    onComplete: { _ in
                        Task { @MainActor in
                            guard self.accepts(scope) else { return }
                            self.isPreparingImageContext = false
                            self.imageGroundingTask = nil
                            if let idx = self.messages.firstIndex(where: { $0.id == assistantMsgID }) {
                                self.messages[idx].isStreaming = false
                                self.recordGenerationMetrics(
                                    messageID: assistantMsgID,
                                    tokensPerSecond: 0
                                )
                                self.persistCurrentConversation()
                                HapticManager.analysisComplete()
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - Context window bar

    @ViewBuilder
    private var contextWindowBar: some View {
        if assistant.estimatedInputTokens > 0 {
            let used = Double(assistant.estimatedInputTokens)
            let total = Double(max(1, assistant.selectedContextWindowTokens))
            let fraction = min(used / total, 1.0)
            GeometryReader { geo in
                Rectangle()
                    .fill(fraction > 0.85 ? T.warn : T.accent.opacity(0.55))
                    .frame(width: geo.size.width * fraction, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            }
            .frame(height: 2)
        }
    }

    // MARK: - Loading-banner helpers

    /// Parses a 0–1 progress fraction out of a CodingAssistantService
    /// status message like "Downloading 47%" or "Preparing 8%". Returns
    /// nil when there's no percentage in the string (the opening
    /// "Preparing X…" tick), so the banner can show an indeterminate bar
    /// rather than a misleading 0%.
    private static func percentage(in message: String) -> Double? {
        guard let percentIdx = message.firstIndex(of: "%") else { return nil }
        let prefix = message[..<percentIdx]
        // Walk backward collecting digits.
        var digits = ""
        for ch in prefix.reversed() {
            if ch.isWholeNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        digits = String(digits.reversed())
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return Double(n) / 100.0
    }

    // MARK: - Model loading

    private func ensureModelReady() async {
        // Don't load the model until the user has accepted the legal terms.
        // Loading a 2+ GB model before the gate is cleared causes an OOM kill
        // from iOS Jetsam while the legal acceptance screen is still visible.
        guard isActive, !legal.needsAcceptance else { return }
        if assistant.activeExecutionLocation == .applePrivateCloud {
            await assistant.refreshApplePrivateCloudStatus()
            return
        }
        switch assistant.state {
        case .unloaded, .failed: await assistant.load()
        default: break
        }
    }
}

// MARK: - ConversationPickerView

private struct UnsafeModelLoadConfirmationSheet: View {
    let modelName: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @State private var hasAcknowledgedRisk = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("Experimental load", systemImage: "exclamationmark.triangle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(T.bad)

                    Text("\(modelName) is estimated to exceed this device's app memory limit. This one-time attempt bypasses the memory preflight checks.")
                        .font(.body)
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 14) {
                        riskRow(
                            symbol: "xmark.app.fill",
                            text: "iOS may terminate OnDevice while the model loads or generates."
                        )
                        riskRow(
                            symbol: "doc.badge.clock",
                            text: "Unsaved or in-progress work may be lost."
                        )
                        riskRow(
                            symbol: "thermometer.high",
                            text: "The device may become hot and battery use may increase."
                        )
                    }

                    Toggle(isOn: $hasAcknowledgedRisk) {
                        Text("I understand these risks and want to try this model once.")
                            .font(.body.weight(.medium))
                            .foregroundStyle(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(T.bad)

                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Label("I understand — try once", systemImage: "flask.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(hasAcknowledgedRisk ? T.bad : T.ink3)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasAcknowledgedRisk)
                }
                .padding(22)
            }
            .background(T.bg)
            .navigationTitle("Use at your own risk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func riskRow(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(T.bad)
                .frame(width: 24)
        }
    }
}


struct ConversationPickerView: View {
    @ObservedObject var store: ConversationStore
    let onSelect: (StoredConversation) -> Void
    /// When set, an export is handed to the presenter instead of this view
    /// stacking a share sheet inside itself. A sheet presented from inside a
    /// presented sheet is two modal layers over one screen — and the crash
    /// class this app has already been bitten by.
    var onShareFile: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var searchText: String = ""
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    private var filtered: [StoredConversation] {
        store.conversations.filter { $0.matches(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    emptyState
                } else if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(T.ink3)
                        KMono(text: "no matches", size: 12, color: T.ink2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { conv in
                            row(for: conv)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        if let idx = store.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            store.deleteConversations(at: IndexSet(integer: idx))
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        exportMarkdown(conv)
                                    } label: {
                                        Label("Export", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(T.accent)
                                }
                                .contextMenu {
                                    Button {
                                        exportMarkdown(conv)
                                    } label: {
                                        Label("Export as Markdown", systemImage: "doc.text")
                                    }
                                    Button {
                                        exportJSON(conv)
                                    } label: {
                                        Label("Export as JSON", systemImage: "curlybraces")
                                    }
                                    Button {
                                        UIPasteboard.general.string = conv.markdownExport
                                        ToastCenter.shared.info("Copied as Markdown")
                                    } label: {
                                        Label("Copy text", systemImage: "doc.on.doc")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        if let idx = store.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            store.deleteConversations(at: IndexSet(integer: idx))
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search conversations")
            .background(StudioPageBackground())
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for conv: StoredConversation) -> some View {
        Button {
            onSelect(conv)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(conv.title)
                    .font(.body)
                    .foregroundColor(T.ink)
                HStack(spacing: 8) {
                    KMono(text: conv.updatedAt.relativeShort, size: 10, color: T.ink3)
                    KMono(text: "·", size: 10, color: T.ink4)
                    KMono(text: "\(conv.messages.filter { $0.role != "system" }.count) msgs",
                           size: 10, color: T.ink3)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(T.surface)
    }

    private var emptyState: some View {
        ContentUnavailableView("No saved conversations", systemImage: "bubble.left.and.bubble.right",
                               description: Text("Your conversations and drafts will appear here."))
    }

    // MARK: - Export

    private func exportMarkdown(_ conv: StoredConversation) {
        let md = conv.markdownExport
        let safeTitle = conv.title.replacingOccurrences(
            of: "/", with: "-").prefix(80)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle).md")
        try? md.write(to: tmpURL, atomically: true, encoding: .utf8)
        guard let onShareFile else {
            shareItems = [tmpURL]
            showShare = true
            return
        }
        onShareFile(tmpURL)
    }

    private func exportJSON(_ conv: StoredConversation) {
        guard let data = conv.jsonExport else { return }
        let safeTitle = conv.title.replacingOccurrences(
            of: "/", with: "-").prefix(80)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle).json")
        try? data.write(to: tmpURL)
        guard let onShareFile else {
            shareItems = [tmpURL]
            showShare = true
            return
        }
        onShareFile(tmpURL)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var onAnalyzeImage: ((Data) -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @Environment(\.koduTheme) private var T

    /// Skip re-render unless content, role, or streaming state changed.
    /// Stops every bubble in the LazyVStack from redrawing when an unrelated
    /// bubble's content updates.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.content == rhs.message.content &&
        lhs.message.isStreaming == rhs.message.isStreaming &&
        lhs.message.wasInterrupted == rhs.message.wasInterrupted &&
        lhs.message.imageThumbnailData == rhs.message.imageThumbnailData &&
        lhs.message.imageThumbnails == rhs.message.imageThumbnails &&
        lhs.message.generationTokensPerSecond == rhs.message.generationTokensPerSecond &&
        lhs.message.generationDuration == rhs.message.generationDuration &&
        lhs.message.documentSources == rhs.message.documentSources &&
        lhs.message.role == rhs.message.role &&
        lhs.message.generationModelID == rhs.message.generationModelID &&
        lhs.message.generationExecutionLocation == rhs.message.generationExecutionLocation &&
        lhs.message.hitTokenLimit == rhs.message.hitTokenLimit
    }

    var body: some View {
        if message.role == .system {
            EmptyView()
        } else if message.role == .user {
            if let tr = toolResultPayload {
                toolResultChip(tr)
            } else {
                userBubble
            }
        } else {
            assistantBubble
        }
    }

    /// A tool result is injected as a `user` turn whose body is a
    /// ```` ```tool_result … ```` ```` block — parse it so we can render a
    /// compact chip instead of a raw JSON pink bubble.
    private var toolResultPayload: (name: String, result: String)? {
        guard let parsed = AssistantActivity.parseToolResult(message.content) else { return nil }
        return (parsed.name, parsed.result)
    }

    private func toolResultChip(_ tr: (name: String, result: String)) -> some View {
        AssistantToolResultCard(name: tr.name, result: tr.result)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
    }

    // User content follows the current neutral, naturally sized bubble.
    private var userBubble: some View {
        ODUserBubbleLayout(displayScale: displayScale) {
            VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                if !message.imageThumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ODLayout.elementGap) {
                            ForEach(Array(message.imageThumbnails.enumerated()), id: \.offset) { _, attachment in
                                imageTile(data: attachment.data) { onAnalyzeImage?(attachment.data) }
                            }
                        }
                    }
                } else if let data = message.imageThumbnailData {
                    imageTile(data: data) { onAnalyzeImage?(data) }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(ODPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, ODLayout.bubbleInsetH)
            .padding(.vertical, ODLayout.bubbleInsetV)
            .background(ODPalette.input, in: RoundedRectangle(cornerRadius: ODLayout.bubbleCorner))

        }
        .padding(.horizontal, ODLayout.pageInset)
        .accessibilityLabel("You: \(message.content)")
    }

    /// 46pt square photo tile inside a user turn, with the same tap-to-analyze
    /// affordance the old carousel card had.
    private func imageTile(data: Data, onAnalyze: (() -> Void)? = nil) -> some View {
        let S = T.studio
        return Group {
            if let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(S.fillActive)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous)
                .stroke(S.rule, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if let onAnalyze {
                Button {
                    HapticManager.impact(.medium)
                    onAnalyze()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Analyze")
                            .font(S.mono(9, .medium))
                    }
                    .foregroundColor(S.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(S.paper.opacity(0.9), in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                            .stroke(S.rule, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(5)
            }
        }
        .accessibilityLabel("Attached image")
    }

    // Assistant turn — full-measure prose. No bubble, no glass, no avatar:
    // the answer reads as a document on the page. Only state that is not
    // obvious (Apple Private Cloud, interrupted, token limit) keeps a compact
    // mono line; a normal finished answer is bare prose.
    private var assistantBubble: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 8) {
            // The answering side gets the same speaker rule as the asking
            // side, named for whatever actually produced the text. Symmetry is
            // the point: in a transcript neither party is the guest.

            VStack(alignment: .leading, spacing: 8) {
                // .equatable() wires AssistantMarkdownView's `==` into
                // SwiftUI diffing so parseBlocks only re-runs when this
                // bubble's own content / streaming state changes.
                if message.isStreaming && message.content.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing reply")
                            .font(.subheadline)
                            .foregroundStyle(T.ink2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat.reply.preparing")
                } else {
                    AssistantMarkdownView(content: message.content, isStreaming: message.isStreaming)
                        .equatable()
                }
            }

            if let sources = message.documentSources, !sources.isEmpty {
                DocumentSourcesButton(sources: sources)
            }

            // Quiet mono line only when the state is not obvious from the
            // prose or the action row's footnote.
            if assistantStateFootnote != nil {
                HStack(spacing: 6) {
                    Image(systemName: assistantMetaIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(assistantStateFootnote!)
                        .font(S.mono(11))
                        .tracking(0.4)
                }
                .foregroundColor(S.ink3)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// Mono state line shown under prose only when it carries information
    /// the answer itself does not: Apple Private Cloud execution, a stopped
    /// turn, or a token-limit cut-off.
    private var assistantStateFootnote: String? {
        if message.generationExecutionLocation == .applePrivateCloud && !message.isStreaming {
            return message.wasInterrupted
                ? "apple private cloud · stopped"
                : "apple private cloud"
        }
        if message.wasInterrupted { return "stopped" }
        if message.hitTokenLimit == true { return "cut off at token limit" }
        return nil
    }

    private var assistantMetaIcon: String {
        message.generationExecutionLocation == .applePrivateCloud
            ? "icloud.fill"
            : "lock.fill"
    }

    private func generationMetric(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(T.sans(10, .medium))
        }
        .foregroundStyle(T.ink3)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 10 {
            return String(format: "%.1fs", duration)
        }
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }
        let totalSeconds = Int(duration.rounded())
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }

    @ViewBuilder
    private func imageCard(data: Data, isCarousel: Bool) -> some View {
        if let ui = UIImage(data: data) {
            ZStack(alignment: .bottomTrailing) {
                if isCarousel {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                                .stroke(T.glassBorder, lineWidth: 0.5)
                        )
                } else {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                                .stroke(T.glassBorder, lineWidth: 0.5)
                        )
                }

                // "Analyze with VLM" button overlay
                Button {
                    onAnalyzeImage?(data)
                    HapticManager.impact(.medium)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Analyze")
                            .font(T.mono(9, .bold))
                    }
                    .foregroundColor(T.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                            .fill(T.surface2.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                            .stroke(T.glassBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(StudioPressStyle())
                .padding(8)
            }
        }
    }
}

private struct AssistantToolResultCard: View {
    let name: String
    let result: String

    @State private var isExpanded = false
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            Button {
                // Keep the surrounding LazyVStack's scroll anchor stable.
                // Animating a large web-result height change could move the
                // card and the following answer completely out of view.
                isExpanded.toggle()
                HapticManager.selection()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(T.accent)
                        .frame(width: 28, height: 28)
                        .background(T.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(T.ink)
                        Text(AssistantActivity.toolResultSummary(name: name, result: result))
                            .font(.caption)
                            .foregroundStyle(T.ink3)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(T.ink3)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses tool details" : "Shows tool details")

            if isExpanded {
                Divider().overlay(T.rule)
                // Tool payloads—especially web-search context—can be many
                // screens tall. Bound them inside the card so expanding does
                // not displace the card and the assistant reply off-screen.
                ScrollView(.vertical) {
                    Text(result)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(T.ink2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .glassSurface(.card, cornerRadius: StudioRadius.action)
        .overlay {
            RoundedRectangle(cornerRadius: StudioRadius.action, style: .continuous)
                .stroke(T.rule.opacity(0.7), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var symbol: String {
        let lower = name.lowercased()
        if lower.contains("web") || lower.contains("search") { return "globe" }
        if lower.contains("file") { return "doc.text" }
        if lower.contains("vision") || lower.contains("image") { return "eye" }
        if lower.contains("memory") { return "brain.head.profile" }
        return "wrench.and.screwdriver"
    }
}

// MARK: - QuickAction
//
// Chip-style follow-up actions surfaced under the last assistant reply:
// "Continue / Shorter / More formal / Explain". Each chip sends a
// re-framing prompt through the normal offline path, so streaming,
// stop-button, and web-tool routing all behave the same as a Send tap.

enum QuickActionKind: String, CaseIterable, Identifiable {
    case continueReply, shorter, moreFormal, explain
    var id: String { rawValue }

    var label: String {
        switch self {
        case .continueReply: return "Continue"
        case .shorter:       return "Shorter"
        case .moreFormal:    return "More formal"
        case .explain:       return "Explain"
        }
    }

    var systemImage: String {
        switch self {
        case .continueReply: return "arrow.right.to.line"
        case .shorter:       return "text.redaction"
        case .moreFormal:    return "graduationcap"
        case .explain:       return "lightbulb"
        }
    }
}

struct AssistantQuickActions: View {
    let disabled: Bool
    let onAction: (QuickActionKind) -> Void
    @Environment(\.koduTheme) private var T

    var body: some View {
        // Horizontal scroller so the row stays single-line on narrow
        // devices without truncating chip labels. Native iOS pattern
        // (mirrors the model picker bar across cloud-AI competitors).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(QuickActionKind.allCases) { kind in
                    Button {
                        onAction(kind)
                    } label: {
                        // Instrument prompt keys, not glass chips: one shared
                        // height, a tonal fill, a hairline edge. They are
                        // commands issued to the model, so they read as keys
                        // on the same console as the composer.
                        HStack(spacing: 5) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 10, weight: .medium))
                            Text(kind.label)
                                .font(T.sans(12, .medium))
                        }
                        .foregroundColor(T.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous)
                                .fill(T.studio.fillActive)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous)
                                .strokeBorder(T.rule2, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous))
                    }
                    .buttonStyle(StudioPressStyle())
                    .disabled(disabled)
                    .opacity(disabled ? 0.45 : 1.0)
                }
            }
            .padding(.trailing, 8)
        }
        // Don't let the inner ScrollView eat the parent's gesture
        // (chat ScrollView scroll/tap dismiss). showsIndicators false
        // already, but disabling vertical bounce keeps it contained.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

// MARK: - AssistantMarkdownView

struct AssistantMarkdownView: View, Equatable {
    let content: String
    let isStreaming: Bool
    @Environment(\.koduTheme) private var T

    /// Reasoning-rule timing for "thought 4s". The start is stamped when a
    /// live think block first appears; the duration is frozen the moment the
    /// closing tag arrives so the label can't keep growing afterwards.
    @State private var reasoningStartedAt: Date?
    @State private var reasoningSeconds: Int?

    private func noteReasoningStart() {
        if reasoningStartedAt == nil && reasoningSeconds == nil {
            reasoningStartedAt = Date()
        }
    }

    private func freezeReasoningSeconds() {
        guard reasoningSeconds == nil, let started = reasoningStartedAt else { return }
        reasoningSeconds = max(1, Int(Date().timeIntervalSince(started).rounded()))
    }

    /// SwiftUI uses this to skip re-rendering when content + streaming state
    /// haven't changed. Without it, every parent re-render re-parses the
    /// markdown.
    static func == (lhs: AssistantMarkdownView, rhs: AssistantMarkdownView) -> Bool {
        lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        // During streaming the body changes on every token — parseBlocks runs
        // 30-50× per second which tanks scroll perf. Render as a lightweight
        // streaming view; re-parse fully only once generation finishes.
        if isStreaming {
            streamingBody
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(parseBlocks(AssistantOutputSanitizer.clean(content)).enumerated()),
                    id: \.offset
                ) { _, block in
                    switch block {
                    case .text(let t):
                        AssistantProseView(content: t)
                    case .code(let lang, let code):
                        if lang.lowercased() == "diff" {
                            DiffView(diffText: code)
                        } else {
                            CodeBlock(language: lang, code: code)
                        }
                    case .thinking(let t, let isOpen):
                        ThinkingBlock(content: t, isOpen: isOpen, seconds: reasoningSeconds)
                    case .math(let latex):
                        MathBlock(latex: latex)
                    }
                }
            }
        }
    }

    // .thinking(content, isOpen) — isOpen = true while </think> not yet seen
    // MARK: - Streaming body
    // Cheap per-token render: detect think-block state with simple string
    // checks instead of running the full parseBlocks algorithm.

    @ViewBuilder private var streamingBody: some View {
        // Selection is DISABLED throughout streaming. Enabling it forces
        // CoreText to retain selection-anchor state across every token,
        // which pushes Futhark's line-segment allocator (the one that
        // SIGABRTs at `createNewLineseg`) over its capacity on long
        // streaming replies. The non-streaming branch above re-enables
        // selection once generation finishes.
        let expectsImplicitThinking =
            (AssistantModelSettingsStore.shared.settings(
                for: CodingAssistantService.shared.activeModel.repoID
            )?.thinkingEnabled ?? AppSettings.shared.assistantThinking)
            && CodingAssistantService.shared.activeModel.supportsThinking
        let c = normalizedThink(content)
        if expectsImplicitThinking
            && !c.contains("<think>")
            && !c.contains("</think>") {
            // Qwen thinking templates prefill the opening tag, so the token
            // stream contains raw reasoning until the model emits </think>.
            // Show a bounded live tail: users can follow the reasoning again,
            // while the fixed character ceiling avoids the unbounded
            // CoreText/Futhark layout churn that motivated the old placeholder.
            ThinkingBlock(content: liveReasoningTail(c), isOpen: true)
                .onAppear { noteReasoningStart() }
        } else if c.hasPrefix("<think>") {
            if let closeRange = c.range(of: "</think>") {
                // Reasoning phase complete — show collapsed think block +
                // whatever the model has generated after it so far.
                let thinkContent = String(c[c.index(c.startIndex, offsetBy: 7)..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let afterThink = String(c[closeRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                VStack(alignment: .leading, spacing: 8) {
                    ThinkingBlock(content: thinkContent, isOpen: false, seconds: reasoningSeconds)
                        .onAppear { freezeReasoningSeconds() }
                    if !afterThink.isEmpty {
                        Text(afterThink)
                            .font(T.conversationBody)
                            .foregroundColor(T.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.disabled)
                    }
                }
            } else {
                // Still inside <think> — stream a bounded live reasoning tail.
                let reasoning = String(c.dropFirst(7))
                ThinkingBlock(content: liveReasoningTail(reasoning), isOpen: true)
                    .onAppear { noteReasoningStart() }
            }
        } else {
            // No think block — plain streaming text.
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(c)
                    .font(T.conversationBody)
                    .foregroundColor(T.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                StreamingCaret()
            }
        }
    }

    /// Qwen3 "thinking" models emit only the closing </think> (the chat
    /// template pre-fills the opening <think>). Synthesize the opening tag so
    /// the parser collapses the reasoning instead of leaking a stray </think>.
    private func normalizedThink(_ s: String) -> String {
        if !s.contains("<think>"), s.contains("</think>") { return "<think>" + s }
        return s
    }

    private func liveReasoningTail(_ source: String) -> String {
        let limit = 1_200
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…\n" + String(trimmed.suffix(limit))
    }

    private func parseBlocks(_ text: String) -> [StudioTextBlocks.Block] {
        StudioTextBlocks.parse(text)
    }

}

/// Completed answers keep Markdown's block structure. SwiftUI Text renders
/// inline emphasis well, but a single Text made from full Markdown joins
/// headings and table cells into run-on prose on iPhone.
private struct AssistantProseView: View {
    let content: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(content)
        let blocks = StudioMarkdownLayout.parse(source)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let title):
                    Text(Self.inline(title))
                        .font(T.studio.sans(level == 1 ? 23 : level == 2 ? 20 : 18, .semibold))
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .font(T.conversationBody)
                        .foregroundStyle(T.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let items):
                    AssistantProseList(items: items)
                case .quote(let text):
                    AssistantProseQuote(text: text)
                case .table(let headers, let rows):
                    AssistantProseTable(headers: headers, rows: rows)
                case .rule:
                    Rectangle().fill(T.rule).frame(height: 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)
    }
}

private struct AssistantProseList: View {
    let items: [StudioMarkdownLayout.ListItem]
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(item.marker)
                        .font(T.conversationBody.weight(.medium))
                        .foregroundStyle(T.ink2)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(AssistantProseView.inline(item.text))
                        .font(T.conversationBody)
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 16)
            }
        }
    }
}

private struct AssistantProseQuote: View {
    let text: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(AssistantProseView.inline(text))
            .font(T.conversationBody)
            .foregroundStyle(T.ink2)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(T.rule).frame(width: 2)
            }
    }
}

/// A compact row per record reads better than squeezing four columns into a
/// phone-width grid. Every value keeps its original column label.
private struct AssistantProseTable: View {
    let headers: [String]
    let rows: [[String]]
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text(headers.joined(separator: " · "))
                    .font(T.studio.sans(14))
                    .foregroundStyle(T.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(T.surface, in: RoundedRectangle(cornerRadius: StudioRadius.tile))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 8) {
                    if let first = row.first {
                        Text(headers.first ?? "Item")
                            .font(T.studio.sans(12, .medium))
                            .foregroundStyle(T.ink3)
                        Text(AssistantProseView.inline(first))
                            .font(T.studio.sans(16, .semibold))
                            .foregroundStyle(T.ink)
                    }
                    if row.count > 1 {
                        ForEach(1..<row.count, id: \.self) { column in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(column < headers.count ? headers[column] : "Column \(column + 1)")
                                    .font(T.studio.sans(12, .medium))
                                    .foregroundStyle(T.ink3)
                                    .frame(minWidth: 48, alignment: .leading)
                                Text(AssistantProseView.inline(row[column]))
                                    .font(T.studio.sans(14))
                                    .foregroundStyle(T.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(T.surface, in: RoundedRectangle(cornerRadius: StudioRadius.tile))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioRadius.tile)
                        .stroke(T.rule, lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - CodeBlock

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    @Environment(\.koduTheme) private var T

    private var S: StudioTokens { T.studio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: lang label + copy
            HStack {
                Text((language.isEmpty ? "code" : language).lowercased())
                    .font(T.studio.mono(11, .medium))
                    .tracking(0.8)
                    .foregroundStyle(S.ink3)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                    // One-time AI-generated-code reminder — shown only on the
                    // first copy ever. Subsequent copies are silent.
                    LegalAcceptanceManager.shared.markCodeCopiedAndWarnIfNeeded()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text((copied ? "copied" : "copy").uppercased())
                            .font(T.studio.mono(11, .medium))
                            .tracking(0.8)
                    }
                    .foregroundStyle(copied ? S.accent : S.ink3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(S.codeInk.opacity(0.14))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(T.studio.mono(12.5))
                    .foregroundStyle(S.codeInk)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .background(S.codeBg, in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
    }
}

// MARK: - Bucketed throttle helper

// MARK: - MathBlock
//
// Display-math block extracted from `$$...$$` in assistant markdown.
// Renders the LaTeX SOURCE in a math-coded surface (accent eyebrow + serif
// italic font + light accent border) so the expression is visually
// distinct from prose and trivially copy-pasteable into a LaTeX renderer
// or Mathematica.
//
// **This is not a real LaTeX renderer yet.** The math-coded source is
// the interim treatment until a single shared WKWebView + KaTeX bridge
// can be wired through — see comment in `parseBlocks` above for why
// per-block WKWebView is the wrong shape inside a LazyVStack. Until
// then the user gets: a clear "this is math" affordance, a tap-to-copy
// shortcut, and the original LaTeX source preserved so external tools
// can render it.

struct MathBlock: View {
    let latex: String
    @State private var copied = false
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "function")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(T.accent)
                Text("MATH · LATEX")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(T.accent)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = latex
                    HapticManager.impact(.light)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(copied ? T.good : T.ink3)
                        .symbolEffect(.bounce, value: copied)
                }
                .buttonStyle(.plain)
            }
            Text(latex)
                // Serif italic is deliberate for maths. Anchored to a text
                // style rather than a fixed 14pt so it still scales — the
                // theme helpers only offer sans and mono.
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundColor(T.ink)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                .fill(T.accent.opacity(T.isDark ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                .stroke(T.accent.opacity(0.25), lineWidth: 0.6)
        )
    }
}

// MARK: - ThinkingBlock
// Collapsible reasoning section for Qwen3 <think>…</think> output.
// isOpen = true  → model is still reasoning (animated indicator, no expand/collapse)
// isOpen = false → reasoning complete (collapsed by default, tap to expand)

struct ThinkingBlock: View {
    let content: String
    let isOpen: Bool
    /// Reasoning duration in seconds — shown as `thought 4s` once the phase
    /// completed in this session. Nil for reopened conversations, which have
    /// no timing to show.
    var seconds: Int? = nil

    @State private var expanded = false
    @Environment(\.koduTheme) private var T

    private var S: StudioTokens { T.studio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                guard !isOpen else { return }
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                // Reasoning summary is a flat rule, not a card: mono uppercase
                // label, flexible hairline, show/hide affordance at the end.
                HStack(spacing: 10) {
                    if isOpen {
                        RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                            .fill(S.accent)
                            .frame(width: 6, height: 6)
                            .opacity(0.9)
                    } else {
                        Text(seconds.map { "thought \($0)s" } ?? "thought")
                            .font(T.studio.mono(11.5, .medium))
                            .tracking(0.8)
                            .foregroundStyle(S.ink2)
                    }
                    if !isOpen {
                        Rectangle()
                            .fill(S.rule2)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    if !isOpen {
                        Text(expanded ? "hide" : "show")
                            .font(T.studio.mono(11, .medium))
                            .tracking(0.8)
                            .foregroundStyle(S.ink3)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isOpen)

            if (expanded && !isOpen) || (isOpen && !content.isEmpty) {
                Rectangle()
                    .fill(S.rule2)
                    .frame(height: 1)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
                if isOpen {
                    reasoningText
                        .textSelection(.disabled)
                } else {
                    reasoningText
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var reasoningText: some View {
        Text(content)
            .font(T.studio.sans(14))
            .foregroundStyle(S.ink2)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var wordCount: Int { content.split(separator: " ").count }
}

// MARK: - Bucketed throttle helper

func formattedDuration(_ duration: TimeInterval) -> String {
    if duration < 10 {
        return String(format: "%.1fs", duration)
    }
    if duration < 60 {
        return "\(Int(duration.rounded()))s"
    }
    let totalSeconds = Int(duration.rounded())
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
}

extension Int {
    /// Returns the integer rounded down to the nearest multiple of `step`.
    /// Used to throttle SwiftUI redraws on rapidly-changing values like the
    /// streaming chat token count — only buckets-of-24 changes fire `onChange`.
    func bucketed(by step: Int) -> Int { (self / step) * step }
}


/// A snapshot of context supplied to a reply, independent of future index edits.
private struct DocumentSourcesButton: View {
    let sources: [ChatMessage.DocumentSource]
    @State private var isPresented = false
    @Environment(\.koduTheme) private var theme

    var body: some View {
        Button { isPresented = true } label: {
            Label("Sources used · \(sources.count)", systemImage: "doc.text.magnifyingglass")
                .font(theme.sans(12, .medium))
                .frame(minHeight: 44)
        }
        .tint(theme.ink2)
        .accessibilityIdentifier("chat.documentSources")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                List {
                    Section {
                        Text("These excerpts were supplied to the model for this reply. They are saved snapshots; review them to check the answer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources) { source in
                        Section(source.name) {
                            Text(source.excerpt)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("Sources used")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
            }
        }
    }
}
