import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject private var settings   = AppSettings.shared
    @ObservedObject private var assistant: CodingAssistantService
    @ObservedObject private var fastVLM    = FastVLMService.shared
    @ObservedObject private var voiceServiceObs = VoiceService.shared
    @ObservedObject private var loc        = LocalizationService.shared
    @ObservedObject private var hfToken    = HFTokenStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.koduTheme) private var T

    @State private var settingsSearch = ""
    @State private var showingHFTokenSheet: Bool = false
    #if !targetEnvironment(macCatalyst)
    /// nil = default "Silver" icon; "AppIconClassic" = previous pink mark.
    @State private var activeIconName: String? = UIApplication.shared.alternateIconName
    #endif
    @State private var showingKnowledgeBase: Bool = false
    @ObservedObject private var knowledgeBase = KnowledgeBaseService.shared

    private var fastVLMStatus: FastVLMComponentStatus { fastVLM.componentStatus }
    private var fastVLMDebugInfo: FastVLMDebugInfo?   { fastVLM.debugInfo }
    /// Filled once OnDevice: AI Image Studio is live on the App Store.
    /// Keeping this nil makes the promo visible without exposing a dead link.
    private static let imageStudioAppStoreURL: URL? = nil
    private static let imageStudioWebsiteURL = URL(string: "https://mesut.uk/apps/ondeviceimage")!

    init(assistant: CodingAssistantService) {
        self.assistant = assistant
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Top-level category index. Replaces the previous flat
                    // 13-section scroll, which dumped every preference,
                    // status panel, and diagnostic on the same screen and
                    // overwhelmed first-time users. Each row navigates to a
                    // focused sub-screen that still hosts the original
                    // KSection bodies — same content, less noise.
                    VStack(spacing: 8) {
                        ForEach(filteredCategories) { cat in
                            NavigationLink {
                                categoryDestination(cat)
                            } label: {
                                SettingsNavigationRow(title: loc.t(cat.title), subtitle: loc.t(cat.subtitle), icon: cat.icon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)

                    if filteredCategories.isEmpty {
                        ContentUnavailableView.search(text: settingsSearch)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .searchable(text: $settingsSearch, prompt: loc.t("Search settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text(loc.t("Done")).font(T.sans(15, .medium)).foregroundColor(T.accent)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(loc.t("Settings")).font(T.sans(16, .semibold)).foregroundColor(T.ink)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        // SwiftUI sheets don't inherit `.preferredColorScheme` from the
        // root WindowGroup in iOS 18, so the appearance Picker's underlying
        // UISegmentedControl stayed in the OLD scheme after the user toggled
        // it — the unselected option washed out against the new theme bg
        // and looked greyed/un-tappable. Re-apply here so the sheet tracks
        // the same setting as the rest of the app.
        .preferredColorScheme(settings.resolvedColorScheme)
        .sheet(isPresented: $showingHFTokenSheet) {
            HFTokenSheet()
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        .sheet(isPresented: $showingKnowledgeBase) {
            KnowledgeBaseView()
                .preferredColorScheme(settings.resolvedColorScheme)
        }
    }

    // MARK: - Category index
    //
    // Top-level navigation pattern: six categories that route to focused
    // sub-screens. iOS Settings.app pattern (group → sub-page) preserves
    // discoverability while collapsing the at-a-glance complexity from
    // 13 sections to 6 rows. The sub-pages render the original KSection
    // bodies inline, so no content was lost — only the firehose.

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case appearance, modelsAI, capture, voice, downloads, system, privacyLegal, userGuide, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return "Appearance & Language"
            case .modelsAI: return "Assistant"
            case .capture: return "Capture & Lens"
            case .voice: return "Voice"
            case .downloads: return "Downloads & Connections"
            case .system: return "Advanced & Diagnostics"
            case .privacyLegal: return "Privacy & Data"
            case .userGuide: return "Help"
            case .about: return "About"
            }
        }
        var subtitle: String {
            switch self {
            case .appearance: return "Theme, language, haptics, app icon"
            case .modelsAI: return "Thinking, tools, response style and length"
            case .capture: return "Analysis mode, camera and detection"
            case .voice: return "Engine, voice, audio and playback"
            case .downloads: return "Models, Wi-Fi downloads and Hugging Face token"
            case .system: return "Memory, load timeout, FPS, thermal and FastVLM pipeline"
            case .privacyLegal: return "On-device privacy, reset and legal notices"
            case .userGuide: return "User guide and getting started"
            case .about: return "Website, source code and app information"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .modelsAI: return "brain"
            case .capture: return "camera.viewfinder"
            case .voice: return "waveform"
            case .downloads: return "arrow.down.circle"
            case .system: return "gauge.with.dots.needle.bottom.50percent"
            case .privacyLegal: return "lock.shield"
            case .userGuide: return "book.closed"
            case .about: return "info.circle"
            }
        }
        var searchKeywords: String {
            switch self {
            case .modelsAI: return "temperature tokens persona snippets knowledge documents"
            case .system: return "OCR encoder decoder tokenizer debugging safety cache paging RAM"
            case .downloads: return "API keys credentials authentication internet network wifi HF token"
            case .voice: return "speech microphone read aloud transcription TTS STT"
            case .privacyLegal: return "delete wipe clear data licenses"
            case .about: return "OnDevice Core ondevice.fun website GitHub open source MIT repository version"
            default: return ""
            }
        }
        func matches(_ query: String) -> Bool {
            let searchable = [LocalizationService.shared.t(title), LocalizationService.shared.t(subtitle), title, subtitle, searchKeywords].joined(separator: " ")
            return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
                searchable.localizedCaseInsensitiveContains(String($0))
            }
        }

    }

    private var filteredCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { $0.matches(settingsSearch) }
    }

    // Privacy hero — quiet card with the on-device promise.
    private var privacyHero: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(T.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(T.rule, lineWidth: 1))
                Image(systemName: "lock.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundColor(T.ink)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("On-device & private"))
                    .font(T.sans(17, .bold)).foregroundColor(T.ink)
                Text(loc.t("On-device inference by default."))
                    .font(T.sans(14)).foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .kGlass(cornerRadius: 22, fallbackFill: T.surface, fallbackStroke: T.rule)
    }

    @ViewBuilder
    private func categoryDestination(_ cat: SettingsCategory) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                switch cat {
                case .userGuide:
                    UserGuideView()
                case .capture:
                    analysisModeSection
                case .modelsAI:
                    assistantSection
                case .voice:
                    voiceSection
                case .appearance:
                    uiSection
                case .downloads:
                    downloadsPreferences
                    apiSettingsSection
                case .system:
                    runtimePreferences
                    fastvlmPipelineSection
                    systemStatusSection
                    thermalProtectionSection
                    developerSection
                case .privacyLegal:
                    privacyHero.padding()
                    privacyResetSection
                    legalSection
                case .about:
                    SettingsAboutSection()
                    imageStudioBanner.padding()
                }
            }
            .padding(.bottom, 32)
        }
        .background(LiquidPinkBackdrop())
        .navigationTitle(loc.t(cat.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Sections

    // MARK: - Analysis Mode Section

    private var analysisModeSection: some View {
        SettingsCard(title: "Analysis mode") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Mode", selection: $settings.analysisMode) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode.rawValue)
                    }
                }
                .modifier(SettingsPickerStyle())

                let mode = AnalysisMode(rawValue: settings.analysisMode) ?? .code
                Text(mode == .code
                     ? "Extracts source code from the detected region and generates a code review."
                     : "Describes what the camera sees — useful for diagrams, whiteboards, UI screenshots, or any non-code scene.")
                    .font(T.sans(14))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private var downloadsPreferences: some View {
        SettingsCard(title: "Downloads") {
            Button {
                dismiss()
                AppBridge.shared.requestTab(.models)
            } label: {
                SettingsNavigationRow(
                    title: loc.t("Manage models"),
                    subtitle: loc.t("Import, discover and manage your library"),
                    icon: "square.stack.3d.up"
                )
            }.buttonStyle(.plain)
            SettingsControlRow(label: "Wi-Fi only downloads", subtitle: "Avoid downloading models over cellular.", trailing: {
                SettingsToggle(isOn: $settings.wifiOnlyDownloads)
            })
        }
    }

    private var runtimePreferences: some View {
            SettingsCard(title: "Runtime & memory") {
                SettingsControlRow(label: "Text detector", trailing: {
                    KMono(text: "Apple Vision · System", size: 14, color: T.ink2, mono: false)
                })
                SettingsControlRow(label: "Vision encoder", trailing: {
                    KMono(text: "468 MB · Neural Engine", size: 14, color: T.ink2, mono: false)
                })
                SettingsControlRow(label: "Enable vision encoder", trailing: {
                    SettingsToggle(isOn: $settings.fastVLMEnabled)
                })
                SettingsControlRow(label: "Memory safety", subtitle: "Check available memory before loading a model.", trailing: {
                    SettingsToggle(isOn: $settings.strictMemoryGate)
                })
                SettingsControlRow(label: "Low-memory mode", subtitle: "Reduce MLX cache use and enable GGUF paging.", trailing: {
                    SettingsToggle(isOn: $settings.largeModelLowMemoryEnabled)
                })
                SettingsControlRow(label: "Load timeout", trailing: {
                    HStack(spacing: 8) {
                        KMono(text: settings.modelLoadTimeoutSeconds == 0
                                ? "Off"
                                : "\(settings.modelLoadTimeoutSeconds / 60) min",
                              size: 14, color: T.ink2, mono: false)
                        Stepper("", value: $settings.modelLoadTimeoutSeconds,
                                in: 0...1800, step: 60)
                            .labelsHidden()
                    }
                }, last: true)
            }
    }

    // MARK: - System Status Section

    @State private var showSystemStatus = false

    private var systemStatusSection: some View {
        SettingsDisclosureCard(title: "System status", defaultExpanded: false) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(T.good.opacity(0.12))
                            .frame(width: 28, height: 28)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(T.good)
                    }
                    statusSummary
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Rectangle().fill(T.rule).frame(height: 1)

                Button {
                    showSystemStatus = true
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 14))
                            .foregroundColor(T.accent)
                        KMono(text: "Open full diagnostics", size: 14, color: T.accent, mono: false)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showSystemStatus) { SystemStatusView() }
    }

    @State private var settingsStatusSnap: SystemStatusService.Snapshot = .empty

    @ViewBuilder
    private var statusSummary: some View {
        // Static snapshot — refreshed on view appear, not via observation.
        // This prevents the 2s timer from re-rendering all of Settings.
        let snap = settingsStatusSnap
        HStack(spacing: 6) {
            KMono(text: snap.totalRAM.formattedBytes + " RAM", size: 14, color: T.ink3, mono: false)
            KMono(text: "·", size: 14, color: T.ink4, mono: false)
            KMono(text: snap.supportsNeuralEngine ? "ANE available" : "No ANE",
                   size: 14, color: snap.supportsNeuralEngine ? T.good : T.ink3, mono: false)
            KMono(text: "·", size: 14, color: T.ink4, mono: false)
            KMono(text: snap.modelStorageUsed.formattedBytes + " models",
                   size: 14, color: T.ink3, mono: false)
        }
        .onAppear {
            SystemStatusService.shared.refresh()
            settingsStatusSnap = SystemStatusService.shared.snapshot
        }
    }

    // MARK: - API Settings Section
    //
    // Hugging Face token surface. Mirrors the FastVLM section's
    // typographic rhythm — KSection caption + KRow body + a stack
    // row for the trailing button so the description has room to
    // breathe under the title.

    private var apiSettingsSection: some View {
        SettingsCard(title: "Hugging Face") {
            Button {
                showingHFTokenSheet = true
                HapticManager.impact(.light)
            } label: {
                SettingsNavigationRow(
                    title: loc.t("Access token"),
                    subtitle: loc.t(hfToken.hasToken ? "Saved securely · tap to update" : "Add a token to download restricted models"),
                    icon: "key"
                )
            }.buttonStyle(.plain)
            Divider().padding(.leading, 16)
            SettingsControlRow(
                label: "Use token for downloads",
                subtitle: hfToken.hasToken ? "Send the saved token with Hugging Face requests." : "Add a token first to enable authenticated downloads.",
                trailing: {
                    SettingsToggle(isOn: $settings.useHFToken)
                        .disabled(!hfToken.hasToken)
                }, last: true
            )
        }
    }

    // MARK: - FastVLM Pipeline Section

    private var fastvlmPipelineSection: some View {
        SettingsDisclosureCard(title: "FastVLM pipeline", defaultExpanded: false) {
            componentStatusRow("Encoder (FastViT-HD)", state: fastVLMStatus.encoder)
            componentStatusRow("Projector (linear+GELU)", state: fastVLMStatus.projector)
            componentStatusRow("Decoder (Qwen2-0.5B)", state: fastVLMStatus.decoder)
            componentStatusRow("Tokenizer", state: fastVLMStatus.tokenizer, last: true)

            Rectangle().fill(T.rule).frame(height: 1)

            SettingsControlRow(label: "Use OCR fallback", trailing: {
                SettingsToggle(isOn: $settings.useOCRFallback)
            })

            SettingsControlRow(label: "Temperature", trailing: {
                KMono(text: String(format: "%.2f", settings.fastvlmTemperature),
                       color: T.ink2, mono: false)
            }, stack: true)
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $settings.fastvlmTemperature, in: 0.0...1.0, step: 0.05)
                    .tint(T.accent)
                KMono(text: "0 = greedy. Recommended 0.2 for extraction.",
                       size: 14, color: T.ink3, mono: false)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Rectangle().fill(T.rule).frame(height: 1)

            SettingsControlRow(label: "Max tokens", trailing: {
                Stepper("\(settings.fastvlmMaxTokens)",
                        value: $settings.fastvlmMaxTokens, in: 64...1024, step: 64)
                    .labelsHidden()
            }, last: fastVLMStatus.canGenerate || !LocalModelRegistry.isDefaultVisionSelection(
                AppSettings.shared.cameraVisualModelID
            ))

            // FastVLM "missing components" panel — only relevant when the
            // user is actually relying on FastVLM. If they've picked an MLX
            // VLM (SmolVLM etc.) the lens won't touch FastVLM, so nagging
            // them about its components here is just noise. The panel also
            // stayed visible after a successful download because
            // canGenerate requires the model to be LOADED into memory, not
            // just present on disk — copy now makes that distinction clear.
            let usingFastVLM = LocalModelRegistry.isDefaultVisionSelection(
                AppSettings.shared.cameraVisualModelID
            )
            if usingFastVLM, !fastVLMStatus.canGenerate {
                let filesOnDisk = ModelDownloadCenter.shared.fastvlmModel?.isReady == true
                Rectangle().fill(T.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    KCaption(
                        text: filesOnDisk ? "DOWNLOADED — NOT YET LOADED" : "MISSING COMPONENTS",
                        color: T.warn
                    )
                    KMono(text: filesOnDisk
                          ? "Weights are on disk. Tap below to load them into memory (first capture also triggers a load)."
                          : "Open Download Models → FastVLM MLX Weights to fetch the missing files from HuggingFace.",
                           size: 14, color: T.ink2, mono: false)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        HapticManager.impact(.light)
                        if filesOnDisk {
                            // Files exist — trigger the load directly so
                            // canGenerate flips to true without bouncing
                            // through the Models tab.
                            Task { await FastVLMService.shared.load() }
                        } else {
                            dismiss()
                            AppBridge.shared.requestTab(.models)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: filesOnDisk
                                  ? "arrow.triangle.2.circlepath"
                                  : "arrow.down.circle")
                                .font(.system(size: 14, weight: .medium))
                            Text(filesOnDisk ? "Load now" : "Download models")
                                .font(T.sans(14, .semibold))
                        }
                        .foregroundColor(T.bg)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(T.ink))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

    }

    // MARK: - Developer Section
    //
    // Path/URL escape hatches + diagnostic overlays. Collapsed by default so
    // they don't compete with everyday preferences. README §Settings: "Power-
    // user escape hatches don't live in the main flow."

    private var developerSection: some View {
        SettingsDisclosureCard(title: "developer", tinted: true, defaultExpanded: false) {
            SettingsControlRow(label: "Show FPS counter", trailing: {
                SettingsToggle(isOn: $settings.showFPSCounter)
            })
            // Live diagnostics: crash trail, logs, memory/thermal, MetricKit.
            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13))
                        .foregroundColor(T.ink)
                    KMono(text: "Diagnostics & crash log", size: 14, color: T.ink, mono: false)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundColor(T.ink3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Rectangle().fill(T.rule).frame(height: 1)

            // Editable FastVLM repo ID — lets users switch to a working
            // mirror if the default 404/401s.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    KMono(text: "FastVLM repo", size: 14, color: T.ink3, mono: false)
                    Spacer()
                    Button {
                        settings.fastVLMRepoID = "apple/FastVLM-0.5B-MLX"
                        HapticManager.impact(.light)
                    } label: {
                        Text("Reset")
                            .font(T.sans(14))
                            .foregroundColor(T.accent)
                    }
                }
                TextField("author/repo", text: $settings.fastVLMRepoID)
                    .font(T.mono(14))
                    .foregroundColor(T.ink)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                KMono(text: "Hugging Face repo for the VLM weights. Takes effect on next app launch.",
                       size: 14, color: T.ink3, mono: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle().fill(T.rule).frame(height: 1)
            SettingsControlRow(label: "Show debug model shapes", trailing: {
                SettingsToggle(isOn: $settings.showDebugModelShapes)
            })

            if settings.showDebugModelShapes, let debug = fastVLMDebugInfo {
                VStack(alignment: .leading, spacing: 4) {
                    if let shape = debug.encoderOutputShape {
                        KMono(text: "encoder out: \(shape.map(String.init).joined(separator: "×"))",
                               size: 14, color: T.ink2)
                    }
                    if let shape = debug.projectorOutputShape {
                        KMono(text: "projector out: \(shape.map(String.init).joined(separator: "×"))",
                               size: 14, color: T.ink2)
                    }
                    if let tps = debug.lastTokensPerSecond {
                        KMono(text: String(format: "speed: %.1f tok/s", tps),
                               size: 14, color: T.ink2)
                    }
                    if let err = debug.lastGenerationError {
                        KMono(text: "error: \(err)", size: 14, color: T.bad)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(T.rule).frame(height: 1)
            }

            // Diagnostic toggle. When on, the lens shows a small
            // thumbnail of the exact image MLX received last (post-
            // orientation, post-resize, post-everything). Lets you
            // diagnose accuracy issues at a glance.
            SettingsControlRow(label: "show model input debug", trailing: {
                SettingsToggle(isOn: $settings.showModelInputDebug)
            }, last: !settings.showModelInputDebug)

            if settings.showModelInputDebug {
                Button {
                    if let url = MLXVisionService.shared.saveLastModelInputToDocuments() {
                        ToastCenter.shared.success("Saved model input",
                                                    detail: url.lastPathComponent)
                    } else {
                        ToastCenter.shared.error("No model input to save",
                                                  detail: "Run a lens capture first.")
                    }
                    HapticManager.impact(.light)
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14))
                            .foregroundColor(T.ink)
                        KMono(text: "Save last model input PNG", size: 14, color: T.ink, mono: false)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func componentStatusRow(_ label: String, state: FastVLMModelState, last: Bool = false) -> some View {
        SettingsControlRow(label: label, trailing: {
            HStack(spacing: 6) {
                Text(stateGlyph(for: state))
                    .font(T.mono(14))
                    .foregroundColor(statusColor(for: state))
                KMono(text: state.statusLabel.lowercased(), size: 14, color: T.ink3, mono: false)
            }
        }, last: last)
    }

    private func stateGlyph(for state: FastVLMModelState) -> String {
        switch state {
        case .ready:    return "●"
        case .loading:  return "◐"
        case .failed:   return "✕"
        case .unloaded: return "○"
        }
    }

    private func statusColor(for state: FastVLMModelState) -> Color {
        switch state {
        case .ready:   return T.good
        case .loading: return T.warn
        case .failed:  return T.bad
        case .unloaded: return T.ink3
        }
    }

    private var assistantSection: some View {
        VStack(spacing: 0) {
        SettingsCard(title: "Assistant behavior") {
            NavigationLink {
                PersonaPickerView()
            } label: {
                SettingsNavigationRow(title: loc.t("Persona"), subtitle: PersonaStore.shared.active.name, icon: PersonaStore.shared.active.icon)
            }.buttonStyle(.plain)
            SettingsControlRow(label: "Thinking mode", subtitle: "Let supported models reason before answering.", trailing: {
                SettingsToggle(isOn: $settings.assistantThinking)
            })
            // Lets the assistant emit `tool` JSON blocks (calculator,
            // datetime, web_search, file_read, describe_image) and have
            // them executed on-device. Off → the system prompt drops
            // the tool addendum, so the model never mentions tools at
            // all. Defaults on.
            SettingsControlRow(label: "Allow tools", subtitle: "Let the assistant use enabled tools when needed.", trailing: {
                SettingsToggle(isOn: $settings.toolsEnabled)
            })
        }
        SettingsCard(title: "Responses") {
            VStack(alignment: .leading, spacing: 6) {
                KMono(text: "Response style", size: 14, color: T.ink3, mono: false)
                Picker(loc.t("Response style"), selection: Binding(
                    get: { ResponseStyle.nearest(settings.assistantTemperature) },
                    set: { settings.assistantTemperature = $0.temperature }
                )) {
                    ForEach(ResponseStyle.allCases, id: \.self) {
                        Text($0.rawValue.lowercased()).tag($0)
                    }
                }
                .modifier(SettingsPickerStyle())
                KMono(text: ResponseStyle.nearest(settings.assistantTemperature).hint, size: 14, color: T.ink3, mono: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle().fill(T.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                KMono(text: "Response length", size: 14, color: T.ink3, mono: false)
                Picker(loc.t("Response length"), selection: Binding(
                    get: { ResponseLength.nearest(settings.assistantMaxTokens) },
                    set: {
                        settings.assistantMaxTokens = $0.maxTokens
                        settings.hasPickedResponseLength = true
                    }
                )) {
                    ForEach(ResponseLength.allCases, id: \.self) {
                        Text($0.rawValue.lowercased()).tag($0)
                    }
                }
                .modifier(SettingsPickerStyle())
                KMono(text: ResponseLength.nearest(settings.assistantMaxTokens).hint, size: 14, color: T.ink3, mono: false)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

        }
        SettingsCard(title: "Documents") {
            Button { showingKnowledgeBase = true } label: {
                SettingsNavigationRow(
                    title: loc.t("Knowledge base"),
                    subtitle: knowledgeBase.documents.isEmpty ? loc.t("Add documents for the assistant to reference") : "\(knowledgeBase.documents.count) " + loc.t("documents"),
                    icon: "books.vertical"
                )
            }
            .buttonStyle(.plain)
        }
        }
    }

    // MARK: - Voice Section

    private var voiceSection: some View {
        SettingsCard(title: "voice") {
            NavigationLink {
                VoiceSettingsView(isStandalone: false)
            } label: {
                SettingsNavigationRow(title: loc.t("Voice & playback"), subtitle: currentEngineLabel, icon: "speaker.wave.2")
            }
            .buttonStyle(.plain)
            Rectangle().fill(T.rule).frame(height: 1)

            SettingsControlRow(label: "Read results aloud", trailing: {
                SettingsToggle(isOn: $settings.voiceAutoRead)
            })

            // Speech-to-text provider picker. Whisper option is disabled
            // when no whisper model is installed on disk so users can't
            // toggle into a broken state — tapping the segment when
            // disabled would silently fall back to system anyway, which
            // is confusing. The row owns its own download affordance so
            // users can fetch Whisper inline without leaving Settings.
            WhisperSTTBlock()

            if VoiceService.shared.isPlaying {
                Rectangle().fill(T.rule).frame(height: 1)
                KSecondaryButton(label: "Stop speaking",
                                 systemImage: "stop.circle",
                                 trailing: nil,
                                 destructive: true) {
                    VoiceService.shared.stop()
                }
                .padding(10)
            }
        }
    }

    private var currentEngineLabel: String {
        (VoiceEngineKind(rawValue: settings.voiceEngine) ?? .appleSystem).shortName
    }

    // MARK: - App Icon Picker

    #if !targetEnvironment(macCatalyst)
    /// Default "Silver" icon + the previous "Classic" mark as an alternate.
    /// Declared via CFBundleAlternateIcons in Info.plist; the classic asset
    /// compiles because of INCLUDE_ALL_APPICON_ASSETS.
    private var appIconPickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            KMono(text: "app icon", size: 14, color: T.ink, mono: false)
            HStack(spacing: 14) {
                appIconOption(name: nil, title: "Silver", preview: "AppIconPreview")
                appIconOption(name: "AppIconClassic", title: "Classic", preview: "AppIconClassicPreview")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func appIconOption(name: String?, title: String, preview: String) -> some View {
        let selected = activeIconName == name
        return Button {
            guard !selected else { return }
            HapticManager.impact(.light)
            activeIconName = name
            UIApplication.shared.setAlternateIconName(name) { error in
                guard let error else { return }
                Task { @MainActor in
                    ToastCenter.shared.info(
                        "Couldn't change app icon",
                        detail: error.localizedDescription
                    )
                }
            }
        } label: {
            VStack(spacing: 5) {
                Image(preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? T.accent : T.rule,
                                          lineWidth: selected ? 2 : 1)
                    )
                KMono(text: title, size: 14,
                      color: selected ? T.accent : T.ink3, mono: false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) app icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif

    private var uiSection: some View {
        VStack(spacing: 0) {
        SettingsCard(title: "Personalization") {
            SettingsControlRow(label: loc.t("Appearance"), trailing: {
                Picker("", selection: $settings.appearance) {
                    Text(loc.t("light")).tag("light")
                    Text(loc.t("dark")).tag("dark")
                    Text(loc.t("OLED")).tag("oled")
                }
                .modifier(SettingsPickerStyle())
                .frame(maxWidth: .infinity)
            }, stack: true)
            #if !targetEnvironment(macCatalyst)
            if UIApplication.shared.supportsAlternateIcons {
                appIconPickerRow
            }
            #endif
            SettingsControlRow(label: loc.t("language"), trailing: {
                Picker("", selection: Binding(
                    get: { AppLanguage(rawValue: settings.uiLanguage) ?? .system },
                    set: { newValue in
                        settings.uiLanguage = newValue.rawValue
                        loc.setLanguage(newValue)
                    }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .tint(T.ink)
            })
            SettingsControlRow(label: loc.t("haptic feedback"), trailing: {
                SettingsToggle(isOn: $settings.hapticsEnabled)
            })
        }
        SettingsCard(title: "Getting started") {
            Button {
                settings.hasSeenOnboarding = false
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14))
                        .foregroundColor(T.ink)
                    KMono(text: "Show onboarding again", size: 14, color: T.ink, mono: false)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Rectangle().fill(T.rule).frame(height: 1)
            Button {
                TipsManager.shared.resetAll()
                HapticManager.impact(.light)
                ToastCenter.shared.info("Tips reset",
                                          detail: "First-use hints will show again.")
            } label: {
                HStack {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 14))
                        .foregroundColor(T.ink)
                    KMono(text: "Reset onboarding tips", size: 14, color: T.ink, mono: false)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        }
    }

    // MARK: - Thermal protection

    @ObservedObject private var safetyMonitor = DeviceSafetyMonitor.shared

    private var thermalProtectionSection: some View {
        SettingsDisclosureCard(title: "Thermal protection", defaultExpanded: false) {
            VStack(spacing: 0) {
                // Live state — both the raw iOS reading AND our debounced
                // "effective" value. Useful when the user thinks the warning
                // is a false positive.
                SettingsKeyValueRows(rows: [
                    ("raw state",       label(for: safetyMonitor.thermalState)),
                    ("effective state", label(for: safetyMonitor.effectiveThermalState)),
                    ("low-power mode",  safetyMonitor.lowPowerMode ? "on" : "off"),
                    ("warnings",        settings.thermalWarningsEnabled ? "enabled" : "disabled"),
                ], keyWidth: 110)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Rectangle().fill(T.rule).frame(height: 1)

                // Toggle — for users who know their device is fine and want
                // to silence the pill / lift the max-token cap.
                Toggle(isOn: $settings.thermalWarningsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        KMono(text: "Thermal warnings", size: 14, color: T.ink, mono: false)
                        KMono(
                            text: "off → hide pill, no auto-cap on max tokens",
                            size: 14, color: T.ink3
                        )
                    }
                }
                .tint(T.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Rectangle().fill(T.rule).frame(height: 1)

                // Manual override: force-clear a stuck warning. iOS sometimes
                // reports .serious after a heavy first-load and takes 30s+ to
                // drop back to .nominal even when the device feels cool.
                Button {
                    safetyMonitor.clearThermalWarning()
                    HapticManager.impact(.light)
                    ToastCenter.shared.info("Cleared until iOS updates the reading")
                } label: {
                    HStack {
                        Image(systemName: "thermometer.snowflake")
                            .font(.system(size: 14))
                            .foregroundColor(T.accent)
                        KMono(text: "Clear current warning", size: 14, color: T.accent, mono: false)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(for s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    // MARK: - Privacy / reset

    @State private var showWipeConfirm = false
    @State private var lastWipeReceipt: WipeAllDataService.Receipt?

    private var privacyResetSection: some View {
        SettingsCard(title: "Reset data") {
            VStack(spacing: 0) {
                Button(role: .destructive) {
                    showWipeConfirm = true
                    HapticManager.impact(.medium)
                } label: {
                    HStack {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 14))
                            .foregroundColor(T.bad)
                        KMono(text: "Wipe all on-device data", size: 14, color: T.bad, mono: false)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if let r = lastWipeReceipt {
                    Rectangle().fill(T.rule).frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        KMono(text: "wiped", size: 14, color: T.ink3, mono: false)
                        Text("\(r.modelsDeleted) models · \(r.conversationsDeleted) conversations · \(r.snippetsDeleted) snippets · \(r.memoriesDeleted) memories · \(r.keychainItemsCleared) credentials · freed \(r.bytesFreed.formattedBytes)")
                            .font(T.mono(14))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        .confirmationDialog(
            "Wipe all on-device data?",
            isPresented: $showWipeConfirm,
            titleVisibility: .visible
        ) {
            Button("Wipe everything", role: .destructive) {
                lastWipeReceipt = WipeAllDataService.wipeAll()
                ToastCenter.shared.success(
                    "Wiped",
                    detail: "Restart the app for a completely fresh state."
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes downloaded models, conversations, snippets, memories, saved API keys, Mac Bridge pairings, cache, and resets onboarding. Cannot be undone.")
        }
    }

    // MARK: - Legal Section

    @State private var showPrivacy = false
    @State private var showEULA = false
    @State private var showDisclaimer = false
    @State private var showAttributions = false

    @State private var showDeviceSafety = false

    private var legalSection: some View {
        SettingsCard(title: "legal") {
            legalRow(icon: "lock.shield", label: "privacy policy") { showPrivacy = true }
            legalRow(icon: "doc.text", label: "open-source license & safety") { showEULA = true }
            legalRow(icon: "exclamationmark.triangle", label: "ai output disclaimer") { showDisclaimer = true }
            legalRow(icon: "thermometer.medium", label: "device safety notice") { showDeviceSafety = true }
            legalRow(icon: "heart.text.square", label: "open-source & attributions",
                     last: URL(string: LegalDocuments.supportURL) == nil) {
                showAttributions = true
            }
            // Acceptance audit row — small, ink3 — so users (and us) can see
            // when they accepted.
            if let when = LegalAcceptanceManager.shared.acceptedAtDescription {
                Rectangle().fill(T.rule).frame(height: 1)
                HStack {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 14))
                        .foregroundColor(T.ink3)
                    KMono(text: "accepted v\(LegalDocuments.currentVersion) on \(when)",
                          size: 14, color: T.ink3)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if let supportURL = URL(string: LegalDocuments.supportURL) {
                Link(destination: supportURL) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(T.accent)
                        KMono(text: "Support", size: 14, color: T.accent, mono: false)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 14))
                            .foregroundColor(T.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .sheet(isPresented: $showPrivacy) {
            LegalDocumentView(title: "Privacy Policy",
                              markdown: LegalDocuments.privacyPolicy,
                              externalURL: LegalDocuments.privacyPolicyURL)
        }
        .sheet(isPresented: $showEULA) {
            LegalDocumentView(title: "License & Safety",
                              markdown: LegalDocuments.eula,
                              externalURL: LegalDocuments.eulaURL)
        }
        .sheet(isPresented: $showDisclaimer) {
            LegalDocumentView(title: "AI Disclaimer",
                              markdown: LegalDocuments.aiDisclaimer)
        }
        .sheet(isPresented: $showDeviceSafety) {
            LegalDocumentView(title: "Device Safety",
                              markdown: LegalDocuments.deviceSafetyNotice)
        }
        .sheet(isPresented: $showAttributions) { AttributionsView() }
    }

    @ViewBuilder
    private func legalRow(icon: String, label: String, last: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(T.ink)
                KMono(text: label, size: 14, color: T.ink, mono: false)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(T.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(T.rule).frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Response style / length helpers (used by assistantSection pickers)

    private var imageStudioBanner: some View {
        Button {
            openURL(Self.imageStudioWebsiteURL)
            HapticManager.impact(.light)
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    Image("image_studio_app_icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(T.rule, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        KCaption(text: "also by mesut")
                        Text("OnDevice: AI Image Studio")
                            .font(T.sans(18, .bold))
                            .foregroundColor(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Create private AI images on-device, even when you're offline.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }

                Label("App Store release coming soon", systemImage: "clock")
                    .font(T.sans(13))
                    .foregroundStyle(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("Visit the preview website")
                        .font(T.sans(14))
                        .foregroundColor(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(T.ink2)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: 20, fallbackFill: T.surface, fallbackStroke: T.rule)
        }
        .buttonStyle(KTactileButtonStyle())
        .accessibilityLabel("Open the OnDevice AI Image Studio preview website. App Store release coming soon.")
    }

    @ViewBuilder
    private var assistantStatusBadge: some View {
        switch assistant.state {
        case .ready:      KStatusBadge(glyph: .ready, label: "ready", color: T.good)
        case .loading:    KStatusBadge(glyph: .streaming, label: "loading", color: T.warn)
        case .generating: KStatusBadge(glyph: .streaming, label: "busy", color: T.accent)
        case .unloaded:   KStatusBadge(glyph: .remote, label: "off", color: T.ink3)
        case .failed:     KStatusBadge(glyph: .remote, label: "error", color: T.bad)
        }
    }
}

private struct SettingsAboutSection: View {
    @Environment(\.koduTheme) private var theme
    @ObservedObject private var loc = LocalizationService.shared

    private static let websiteURL = URL(string: "https://ondevice.fun")!
    private static let sourceURL = URL(string: "https://github.com/Mesutcydev/ondevice-core")!

    private var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("OnDevice Core")
                    .font(theme.display(28, .semibold))
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(loc.t("Your local AI studio"))
                    .font(theme.sans(17, .medium))
                    .foregroundStyle(theme.ink)
                Text(loc.t("Chat, explore images, and talk with models on your device."))
                    .font(theme.sans(15))
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                SettingsAboutLink(
                    title: loc.t("Website"), detail: "ondevice.fun", symbol: "globe",
                    url: Self.websiteURL, identifier: "appWebsiteLink"
                )
                Divider().overlay(theme.rule).padding(.leading, 56)
                SettingsAboutLink(
                    title: "GitHub", detail: loc.t("Source code & contributions"), symbol: "chevron.left.forwardslash.chevron.right",
                    url: Self.sourceURL, identifier: "appSourceCodeLink"
                )
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(loc.t("Version"), value: version)
                    .font(theme.sans(14))
                    .foregroundStyle(theme.ink2)
                Text(loc.t("Open-source app · MIT License"))
                    .font(theme.sans(14, .medium))
                    .foregroundStyle(theme.ink)
                Text(loc.t("Models and third-party components have their own licenses. See Privacy & Data for details."))
                    .font(theme.sans(13))
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

private struct SettingsAboutLink: View {
    let title: String
    let detail: String
    let symbol: String
    let url: URL
    let identifier: String
    @Environment(\.koduTheme) private var theme

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(theme.sans(16, .semibold))
                    Text(detail)
                        .font(theme.sans(13))
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(KTactileButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Response style presets

private enum ResponseStyle: String, CaseIterable, Hashable {
    case precise  = "Precise"
    case balanced = "Balanced"
    case creative = "Creative"

    var temperature: Double {
        switch self { case .precise: 0.2; case .balanced: 0.6; case .creative: 0.9 }
    }

    var hint: String {
        switch self {
        case .precise:  return "focused · less variation"
        case .balanced: return "good for most questions"
        case .creative: return "more varied · best for writing"
        }
    }

    static func nearest(_ t: Double) -> Self {
        if t <= 0.4 { return .precise }
        if t <= 0.75 { return .balanced }
        return .creative
    }
}

// MARK: - Response length presets

private enum ResponseLength: String, CaseIterable, Hashable {
    case short    = "Short"
    case normal   = "Normal"
    case detailed = "Detailed"
    case full     = "Full"

    var maxTokens: Int {
        switch self { case .short: 512; case .normal: 1024; case .detailed: 2048; case .full: 4096 }
    }

    var hint: String {
        switch self {
        case .short:    return "quick answers · faster"
        case .normal:   return "good for most questions"
        case .detailed: return "thorough explanations"
        case .full:     return "longest possible reply"
        }
    }

    static func nearest(_ tokens: Int) -> Self {
        if tokens <= 512  { return .short }
        if tokens <= 768  { return .normal }
        if tokens <= 1280 { return .detailed }
        return .full
    }
}

// MARK: - Whisper STT row
//
// Speech-to-text segmented picker (system / whisper) with an inline
// Download Whisper button that takes the user from "greyed-out" to
// "fully installed" without leaving Settings. Previously the row
// pointed at the Models tab with a static hint — a two-screen
// detour for a single 142 MB file.
//
// Drives off the existing `whisper-base-en` catalog entry in
// ModelDownloadCenter, so the download itself is identical to the
// one a user would kick off from the Download Center. The Voice
// section just gets a more proximate trigger.

private struct WhisperSTTBlock: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var voiceServiceObs = VoiceService.shared
    @StateObject private var observer: DownloadObserver
    @Environment(\.koduTheme) private var T

    private let whisperModel: DownloadableModel?

    init() {
        let m = ModelDownloadCenter.shared.models.first { $0.id == "whisper-base-en" }
        self.whisperModel = m
        // ModelDownloadCenter.buildCatalog runs in init and always
        // appends the whisper-base-en entry, so the optional should
        // never be nil at runtime. Crash early if catalog wiring
        // changes — DownloadObserver requires a real model.
        _observer = StateObject(wrappedValue: DownloadObserver(
            model: m ?? ModelDownloadCenter.shared.models.first!
        ))
    }

    /// Reactive install check — disk presence OR observer reporting
    /// .ready. We can't rely on `WhisperModelCatalog.isInstalled` alone
    /// because that's a static fileExists probe; the Picker stays
    /// disabled across a successful in-place download without the
    /// observer half of the check.
    private var isInstalled: Bool {
        observer.state == .ready || WhisperModelCatalog.isInstalled
    }

    var body: some View {
        let speaking = voiceServiceObs.isPlaying
        VStack(spacing: 0) {
            SettingsControlRow(label: "speech-to-text", trailing: {
                Picker("", selection: $settings.sttProvider) {
                    Text("system").tag("system")
                    Text("whisper").tag("whisper")
                }
                .modifier(SettingsPickerStyle())
                .frame(maxWidth: .infinity)
                .disabled(!isInstalled)
            }, last: !speaking && isInstalled && !observer.isActive, stack: true)

            if !isInstalled {
                Rectangle().fill(T.rule).frame(height: 1)
                downloadCard
            }
        }
    }

    @ViewBuilder
    private var downloadCard: some View {
        switch observer.state {
        case .downloading, .enumerating:
            progressCard
        case .failed(let msg):
            failedCard(message: msg)
        case .idle, .ready:
            idleCard
        }
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(T.ink3)
                KMono(text: "Install Whisper for on-device, multilingual STT.", size: 14, color: T.ink3, mono: false)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            KSecondaryButton(
                label: "Download Whisper base.en (~142 MB)",
                systemImage: "arrow.down.circle",
                trailing: nil
            ) {
                whisperModel?.start()
                HapticManager.impact(.medium)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(T.accent)
                    .scaleEffect(0.7)
                KMono(
                    text: observer.state == .enumerating
                        ? "checking files…"
                        : "downloading whisper… \(Int(observer.progress * 100))%",
                    size: 14, color: T.ink2
                )
                Spacer()
                Button {
                    whisperModel?.cancel()
                    HapticManager.impact(.light)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(T.ink3)
                }
                .buttonStyle(.plain)
            }
            // Thin progress bar mirroring the Download Center.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(T.surface2).frame(height: 2)
                    Rectangle().fill(T.accent)
                        .frame(width: geo.size.width * max(0, min(1, observer.progress)),
                               height: 2)
                        .animation(.linear(duration: 0.3), value: observer.progress)
                }
            }
            .frame(height: 2)
            if observer.totalBytes > 0 {
                KMono(
                    text: "\(observer.downloadedBytes.formattedBytes) / \(observer.totalBytes.formattedBytes)",
                    size: 14, color: T.ink3
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func failedCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundColor(T.bad)
                KMono(text: "Download failed: \(message)", size: 14, color: T.bad, mono: false)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            KSecondaryButton(
                label: "Retry download",
                systemImage: "arrow.clockwise",
                trailing: nil
            ) {
                whisperModel?.start()
                HapticManager.impact(.medium)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    @Environment(\.koduTheme) private var theme

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(theme.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(theme.ink2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// Settings-only surfaces match the category index without changing other app screens.
struct SettingsCard<Content: View>: View {
    let title: String
    var tinted: Bool = false
    @ViewBuilder var content: () -> Content
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizationService.shared.t(settingsSectionTitle(title)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    var tinted: Bool = false
    @ViewBuilder let content: () -> Content
    @State private var expanded: Bool
    @Environment(\.koduTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, tinted: Bool = false, defaultExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.tinted = tinted
        self.content = content
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(LocalizationService.shared.t(settingsSectionTitle(title)))
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(LocalizationService.shared.t(expanded ? "Expanded" : "Collapsed"))
            if expanded {
                Divider().padding(.horizontal, 16)
                VStack(spacing: 0) { content() }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

struct SettingsControlRow<Trailing: View>: View {
    let label: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var last: Bool = false
    var stack: Bool = false
    @Environment(\.koduTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            let layout = stack || textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizationService.shared.t(settingsSectionTitle(label))).font(.body).foregroundStyle(theme.ink)
                    if let subtitle {
                        Text(LocalizationService.shared.t(subtitle))
                            .font(.subheadline).foregroundStyle(theme.ink2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !stack && !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                trailing().accessibilityLabel(LocalizationService.shared.t(label))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            if !last { Divider().padding(.leading, 16) }
        }
    }
}

struct SettingsToggle: View {
    @Binding var isOn: Bool
    @Environment(\.koduTheme) private var theme
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().tint(theme.accent)
    }
}

struct SettingsPickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var textSize
    func body(content: Content) -> some View {
        if textSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}


private func settingsSectionTitle(_ title: String) -> String {
    let words = title.replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
}

struct SettingsKeyValueRows: View {
    let rows: [(String, String)]
    var keyWidth: CGFloat = 110
    @Environment(\.koduTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                let layout = textSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Text(LocalizationService.shared.t(settingsSectionTitle(rows[index].0)))
                        .foregroundStyle(theme.ink2)
                    if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Text(rows[index].1).foregroundStyle(theme.ink).monospacedDigit()
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
