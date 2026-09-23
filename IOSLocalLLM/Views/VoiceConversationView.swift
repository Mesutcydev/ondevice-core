import SwiftUI
import AVFoundation
import Speech
import OnDeviceUI

/// Current native voice presentation, with the host's established session controls.
struct VoiceConversationView: View {
    var startOnAppear = true
    @ObservedObject private var conv = VoiceConversationService.shared
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var bridge = ODBridge.shared
    @ObservedObject private var routeManager = VoiceAudioSessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showModelPicker = false
    @State private var showVoiceSettings = false
    @State private var showVoiceValidation = false
    @State private var standalonePlayback = false
    @State private var playbackWait: Task<Void, Never>?
    private let playback = SpeechPlaybackCoordinator.shared

    private var canReplay: Bool {
        !conv.liveReply.isEmpty && conv.phase != .thinking && conv.phase != .speaking && !voice.isPlaying
    }
    var body: some View {
        ODVoiceSessionView(accessories: AnyView(accessories), options: AnyView(voiceOptions), routePicker: AnyView(AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel("Change audio output")), activity: AnyView(VoiceInputActivity()), onClose: { dismiss() })
            .environmentObject(bridge.store)
            .task {
                if startOnAppear { _ = await conv.start() }
                bridge.refresh()
                routeManager.startObserving()
            }
            .onDisappear {
                playbackWait?.cancel()
                // A replay temporarily owns the audio route. Release it before
                // the view goes away, including when the session is minimized.
                if standalonePlayback {
                    voice.stop()
                    standalonePlayback = false
                    conv.restoreListeningAfterTTS()
                }
                if startOnAppear { conv.stop(); playback.reset() }
            }
            .onChange(of: conv.phase) { _, phase in
                bridge.refresh()
                UIAccessibility.post(notification: .announcement, argument: bridge.store.voicePhase.title)
                if phase == .speaking { HapticManager.impact(.light) }
            }
            .sheet(isPresented: $showModelPicker) { VoiceModelPickerSheet() }
            .sheet(isPresented: $showVoiceSettings) { VoiceSettingsView() }
            #if DEBUG
            .sheet(isPresented: $showVoiceValidation) { VoiceValidationView() }
            #endif
    }

    private var accessories: some View {
        VStack(spacing: 12) {
            if conv.phase == .thinking || conv.phase == .speaking {
                Button("Interrupt and speak", systemImage: "hand.raised") {
                    VoicePerformanceMonitor.shared.noteInterruptRequested()
                    voice.stop()
                    playback.interruptImmediately()
                    Task { await conv.interrupt() }
                }
                .buttonStyle(.glass).controlSize(.large)
            }
            if case .failed = conv.phase {
                if AVAudioApplication.shared.recordPermission == .denied || SFSpeechRecognizer.authorizationStatus() == .denied {
                    Button("Open permission settings", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.glass)
                }
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { _ = await conv.start() }
                }.buttonStyle(.glass)
            }
        }
    }

    private var voiceOptions: some View {
                Menu("Voice options", systemImage: "ellipsis") {
                    Text("Engine: \(voice.currentEngineKind.displayName)")
                    Text("Model: \(CodingAssistantService.shared.activeDisplayName)")
                    Button("Conversation model", systemImage: "cube") {
                        showModelPicker = true
                    }
                    Button("Voice settings", systemImage: "slider.horizontal.3") { showVoiceSettings = true }
                    Button("Replay last reply", systemImage: "arrow.counterclockwise") { play(conv.liveReply) }
                        .disabled(!canReplay || standalonePlayback)
                    Button("Test audio", systemImage: "speaker.wave.2") { play("Audio test. If you hear this, voice replies will play.") }
                        .disabled(conv.phase == .thinking || conv.phase == .speaking || standalonePlayback)
                    #if DEBUG
                    Button("Voice diagnostics", systemImage: "waveform.badge.magnifyingglass") { showVoiceValidation = true }
                    #endif
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Voice options")
    }

    private func play(_ text: String) {
        guard !text.isEmpty, conv.phase != .thinking, conv.phase != .speaking else { return }
        standalonePlayback = true
        conv.prepareForTTSPlayback()
        voice.speak(text)
        playbackWait?.cancel()
        playbackWait = Task { @MainActor in
            while voice.isPlaying, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            standalonePlayback = false
            conv.restoreListeningAfterTTS()
        }
    }
}

// MARK: - VoiceModelPickerSheet

private struct VoiceModelPickerSheet: View {

    @ObservedObject private var conv = VoiceConversationService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var pendingModelID: String?
    @State private var confirmModelChange = false

    private var downloadedModels: [DownloadableModel] {
        let candidates = center.models.filter { m in
            guard m.isReady, !m.isRequired, m.category == .assistant else { return false }
            return !AssistantModelCatalog.presets.contains { $0.repoID == m.id }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                matchChatTabRow
                presetsSection
                if !downloadedModels.isEmpty { downloadedSection }
                Section { footnote }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .confirmationDialog("End voice to change its model?", isPresented: $confirmModelChange, titleVisibility: .visible) {
                Button("End voice and change model", role: .destructive) {
                    conv.stop()
                    Task { await conv.setVoiceModel(pendingModelID); dismiss() }
                }
                Button("Keep current model", role: .cancel) { pendingModelID = nil }
            }
            .navigationTitle("Conversation model")
            .background(StudioPageBackground())
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("Done")) { dismiss() }.foregroundColor(T.ink)
                }
            }
        }
    }

    private func chooseModel(_ id: String?) {
        if conv.phase != .idle || conv.isStarting {
            pendingModelID = id
            confirmModelChange = true
        } else { Task { await conv.setVoiceModel(id); dismiss() } }
    }

    private var matchChatTabRow: some View {
        let isMatching = conv.voiceModelID == nil
        return KSection(title: loc.t("default")) {
            Button {
                Task {
                    chooseModel(nil)
                }
            } label: {
                HStack(spacing: 10) {
                    radio(isSelected: isMatching)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("match chat tab"))
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        KMono(text: loc.t("voice mode uses whatever the chat tab is using"),
                              size: 10, color: T.ink3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var presetsSection: some View {
        KSection(title: loc.t("presets")) {
            ForEach(Array(AssistantModelCatalog.presets.enumerated()), id: \.offset) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(id: m.id, name: m.displayName, subtitle: m.subtitle)
            }
        }
    }

    private var downloadedSection: some View {
        KSection(title: loc.t("downloaded")) {
            ForEach(Array(downloadedModels.enumerated()), id: \.offset) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(id: LocalModelRegistry.assistantSelectionID(for: m.id,
                                                                origin: LocalModelRegistry.origin(for: m)),
                    name: m.displayName,
                    subtitle: m.subtitle.isEmpty ? loc.t("ready · on device") : m.subtitle)
            }
        }
    }

    @ViewBuilder
    private func row(id modelID: String, name: String, subtitle: String) -> some View {
        let isSelected = conv.voiceModelID == modelID
        Button {
            Task {
                chooseModel(modelID)
            }
        } label: {
            HStack(spacing: 10) {
                radio(isSelected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.ink)
                    KMono(text: subtitle, size: 10, color: T.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radio(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? T.ink : T.ink3)
            .accessibilityHidden(true)
    }

    private var footnote: some View {
        KMono(
            text: loc.t("tip: a smaller model (≤1.5B) keeps the back-and-forth snappy and avoids overheating during long voice sessions."),
            size: 10, color: T.ink3
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
}

/// A real input-level meter; Reduce Motion uses a stationary phase symbol.
private struct VoiceInputActivity: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var conversation = VoiceConversationService.shared
    var body: some View {
        if reduceMotion || conversation.phase != .listening || conversation.microphoneMuted || conversation.isInterrupted {
            Image(systemName: "waveform").font(.largeTitle).accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                ProgressView(value: Double(min(1, max(0, VoiceVisualLevelStore.shared.micLevel))))
                    .frame(width: 120).tint(.primary).accessibilityHidden(true)
            }
        }
    }
}
