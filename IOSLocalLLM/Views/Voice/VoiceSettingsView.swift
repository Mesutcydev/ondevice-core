import SwiftUI

// MARK: - VoiceSettingsView
// Full voice settings screen. Studio-style sections + KRow.

struct VoiceSettingsView: View {
    var isStandalone: Bool = true

    @StateObject private var vm = VoiceSettingsViewModel()
    @ObservedObject private var voiceSettings = VoiceSettingsStore.shared
    @ObservedObject private var voiceService = VoiceService.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @State private var showEnginePicker = false
    @State private var overridesRevision = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Echo-cancellation / voice-processing toggle for the
    /// voice-conversation mic. ON: barge-in works (mic ignores the
    /// assistant's own TTS). OFF: a safety valve for users hearing
    /// distorted TTS on unusual audio routes.
    // Must match AppSettings.voiceProcessingEnabled default (false).
    // A `true` default here used to write the key on first Voice Settings
    // open and force VPIO on — a known zombie-voice path on some routes.
    @AppStorage("voiceProcessingEnabled") private var voiceProcessingEnabled: Bool = false

    /// Stream-vs-final narration toggle for the Lens tab. Off by
    /// default; turning on opts into clause-level streaming TTS with
    /// the frame-rate guard.
    @AppStorage("voiceSpeakInLens") private var voiceSpeakInLens: Bool = false

    /// Speak the assistant's reply aloud during voice-conversation
    /// mode. Surfaced here too so users find both toggles in one
    /// place (the existing voice-conversation controls bar still
    /// has its own quick-toggle for the same flag).
    @AppStorage("voiceAnswerEnabled") private var voiceAnswerEnabled: Bool = true

    var body: some View {
        if isStandalone {
            NavigationStack { settingsContent }
        } else {
            settingsContent
        }
    }

    private var settingsContent: some View {
            ScrollView {
                VStack(spacing: 0) {
                    engineSection
                    voiceSection
                    appearanceSection
                    audioSection
                    behaviorSection
                    perModelSection
                    modelsSection
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Voice & playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isStandalone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.foregroundColor(T.ink)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(LiquidPinkBackdrop())
            .sheet(isPresented: $showEnginePicker) {
                VoiceModelPickerView()
            }
    }

    // MARK: - Engine

    // Single entry point into the one-tap voice picker. Downloading,
    // loading, and selecting an engine all happen there now — this row
    // just shows the current pick + its live status and opens it.
    private var engineSection: some View {
        SettingsCard(title: "engine") {
            Button {
                showEnginePicker = true
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        KMono(text: "tts engine", size: 14, color: T.ink)
                        KMono(text: vm.selectedEngineKind.shortName.lowercased(),
                               size: 14, color: T.ink3)
                    }
                    Spacer()
                    if voiceSettings.availabilityState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking installed voice models")
                    } else {
                        engineStateBadge(vm.selectedEngineState)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(T.ink3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        SettingsCard(title: "voice") {
            if vm.voices.isEmpty {
                Text("No voices available for this engine.")
                    .font(T.sans(14))
                    .foregroundColor(T.ink3)
                    .padding(14)
            } else {
                SettingsControlRow(label: "voice", trailing: {
                    Picker("", selection: Binding(
                        get: { vm.selectedVoiceID },
                        set: { vm.selectedVoiceID = $0 }
                    )) {
                        ForEach(vm.voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                })
            }
            Rectangle().fill(T.rule).frame(height: 1)

            Button {
                if voiceService.isPlaying { vm.stopPreview() }
                else { vm.previewVoice() }
            } label: {
                HStack {
                    Image(systemName: voiceService.isPlaying ? "stop.circle" : "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundColor(voiceService.isPlaying ? T.warn : T.accent)
                    KMono(text: voiceService.isPlaying ? "stop preview" : "preview voice",
                           size: 14, color: voiceService.isPlaying ? T.warn : T.accent)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsCard(title: "appearance") {
            HStack(spacing: 14) {
                // `samplesLiveAudio: false` keeps this preview off the shared
                // level store. Writing 0.35 into it from here fed a fake constant
                // level to the live orb, and the value outlived this screen.
                VoiceActivityOrb(
                    phase: .listening,
                    micLevel: 0.35,
                    reduceMotion: reduceMotion,
                    samplesLiveAudio: false
                )
                .frame(width: 72, height: 72)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 4) {
                    KMono(text: "thinking orbs",
                          size: 14, color: T.ink)
                    KMono(text: "state-driven dotted activity",
                          size: 14, color: T.ink3)
                    Link(destination: URL(string: "https://orbs.jakubantalik.com")!) {
                        KMono(text: "thanks to creator Jakub Antalik",
                              size: 14, color: T.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        SettingsCard(title: "audio") {
            sliderBlock(
                label: "speed",
                value: Binding(get: { vm.speed }, set: { vm.speed = $0 }),
                range: 0.5...2.0,
                format: "%.1f×"
            )
            Rectangle().fill(T.rule).frame(height: 1)
            sliderBlock(
                label: "pitch",
                value: Binding(get: { vm.pitch }, set: { vm.pitch = $0 }),
                range: 0.5...2.0,
                format: "%.1f×"
            )
            Rectangle().fill(T.rule).frame(height: 1)
            sliderBlock(
                label: "volume",
                value: Binding(get: { vm.volume }, set: { vm.volume = $0 }),
                range: 0.0...1.0,
                format: "%.0f%%",
                scale: 100,
                last: true
            )
        }
    }

    // MARK: - Behaviour

    private var behaviorSection: some View {
        SettingsCard(title: "behaviour") {
            SettingsControlRow(label: "speak in assistant", trailing: {
                SettingsToggle(isOn: $voiceAnswerEnabled)
            })
            SettingsControlRow(label: "speak in lens", trailing: {
                SettingsToggle(isOn: $voiceSpeakInLens)
            })
            KMono(
                text: voiceSpeakInLens
                    ? "narrates the camera caption clause-by-clause. the frame-rate guard skips re-narration when the scene hasn't changed."
                    : "speaks the full caption once per frame instead of streaming. enable this for low-vision or hands-free use.",
                size: 14, color: T.ink3
            )
            .padding(14)
            Rectangle().fill(T.rule).frame(height: 1)
            SettingsControlRow(label: "auto-read analysis results", trailing: {
                SettingsToggle(isOn: Binding(
                    get: { vm.autoRead },
                    set: { vm.autoRead = $0 }
                ))
            })
            SettingsControlRow(label: "read code blocks aloud", trailing: {
                SettingsToggle(isOn: Binding(
                    get: { vm.readCodeBlocks },
                    set: { vm.readCodeBlocks = $0 }
                ))
            })
            if !vm.readCodeBlocks {
                Rectangle().fill(T.rule).frame(height: 1)
                KMono(text: "code blocks are skipped; only prose and review text are read.",
                       size: 14, color: T.ink3)
                    .padding(14)
            }
            Rectangle().fill(T.rule).frame(height: 1)
            SettingsControlRow(label: "echo cancellation (barge-in)", trailing: {
                SettingsToggle(isOn: $voiceProcessingEnabled)
            }, last: true)
            Rectangle().fill(T.rule).frame(height: 1)
            KMono(
                text: voiceProcessingEnabled
                    ? "mic ignores the assistant's own voice — you can interrupt by speaking."
                    : "off for clean tts on routes that distort voice processing. barge-in is disabled.",
                size: 14, color: T.ink3
            )
            .padding(14)
        }
    }

    // MARK: - Per-model overrides
    //
    // Tucked behind a disclosure so the average user doesn't see it.
    // For users who DO want per-model tuning, this is where they set
    // a slower rate for a deliberate coder model or a pinned engine
    // for a model whose locale they know better than the router
    // does. Overrides persist under `com.mesutcydev.ondevicecore.voice.profile.
    // <modelId>.<field>` and are applied on top of the built-in
    // profile by `VoiceProfileRegistry`.
    //
    // The rate/pitch sliders here ALSO update `AppSettings.voiceSpeed`
    // / `voicePitch` for back-compat with the global Audio section —
    // the rate/pitch wiring through VoiceService still reads
    // AppSettings, so these overrides are persisted ready for a
    // follow-up session that routes the per-model values through
    // synthesis. Engine and chunking-strategy overrides DO take
    // effect immediately via VoiceProfileRegistry.profile(for:).

    private var perModelSection: some View {
        let modelId = assistant.activeModel.id
        let displayName = assistant.activeModel.displayName
        let profile = VoiceProfileRegistry.profile(for: modelId)

        return SettingsDisclosureCard(title: "Model overrides") {
            Text(displayName)
                .font(.subheadline)
                .foregroundStyle(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            perModelControls(modelId: modelId, profile: profile)
                .id(overridesRevision)
        }
    }

    @ViewBuilder
    private func perModelControls(modelId: String, profile: VoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Engine override
            SettingsControlRow(label: "engine", trailing: {
                Picker("", selection: engineBinding(for: modelId, profile: profile)) {
                    Text("auto").tag(Optional<VoiceEngineKind>.none)
                    ForEach(VoiceEngineKind.userSelectableCases) { k in
                        Text(k.shortName.lowercased()).tag(Optional(k))
                    }
                }
                .labelsHidden()
            })

            // Chunking strategy override (sentence/clause only —
            // minWords is internal-only)
            SettingsControlRow(label: "chunking", trailing: {
                Picker("", selection: strategyBinding(for: modelId, profile: profile)) {
                    Text("sentence").tag(SemanticChunker.Strategy.sentence)
                    Text("clause").tag(SemanticChunker.Strategy.clause)
                }
                .labelsHidden()
            })

            // Rate / pitch — saved to the registry. The current
            // synthesis pipeline still reads AppSettings.voiceSpeed,
            // so these values are persisted for the follow-up
            // session that wires them through.
            sliderRow(
                label: "rate (per model)",
                value: rateBinding(for: modelId, profile: profile),
                range: 0.5...2.0,
                format: "%.2fx"
            )

            Rectangle().fill(T.rule).frame(height: 1)

            sliderRow(
                label: "pitch (per model)",
                value: pitchBinding(for: modelId, profile: profile),
                range: 0.5...2.0,
                format: "%.2fx"
            )

            Rectangle().fill(T.rule).frame(height: 1)

            Button(role: .destructive) {
                VoiceProfileRegistry.clearOverrides(for: modelId)
                // Refresh controls after clearing the UserDefaults-backed overrides.
                overridesRevision += 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14))
                    KMono(text: "reset to profile defaults", size: 14, color: T.bad)
                    Spacer()
                }
                .foregroundColor(T.bad)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Rectangle().fill(T.rule).frame(height: 1)

            KMono(
                text: "engine + chunking apply on next utterance. rate + pitch saved here; voice tab's global sliders still control playback for this build.",
                size: 14, color: T.ink3
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
        }
    }

    // MARK: - Per-model binding helpers
    //
    // The registry stores overrides as bare UserDefaults values;
    // these bindings translate between the picker/slider state and
    // the registry's set/clear API.

    private func engineBinding(for modelId: String,
                                profile: VoiceProfile) -> Binding<VoiceEngineKind?> {
        Binding(
            get: { profile.preferredEngine },
            set: { newValue in
                VoiceProfileRegistry.setEngineOverride(newValue, for: modelId)
            }
        )
    }

    private func strategyBinding(for modelId: String,
                                  profile: VoiceProfile) -> Binding<SemanticChunker.Strategy> {
        Binding(
            get: {
                // Collapse `.minWords` to `.sentence` for picker
                // display — the override UI doesn't expose minWords.
                switch profile.chunkingStrategy {
                case .minWords: return .sentence
                default:        return profile.chunkingStrategy
                }
            },
            set: { newValue in
                VoiceProfileRegistry.setChunkingStrategyOverride(newValue, for: modelId)
            }
        )
    }

    private func rateBinding(for modelId: String,
                              profile: VoiceProfile) -> Binding<Double> {
        Binding(
            get: { profile.defaultTTSRate },
            set: { VoiceProfileRegistry.setRateOverride($0, for: modelId) }
        )
    }

    private func pitchBinding(for modelId: String,
                               profile: VoiceProfile) -> Binding<Double> {
        Binding(
            get: { profile.defaultTTSPitch },
            set: { VoiceProfileRegistry.setPitchOverride($0, for: modelId) }
        )
    }

    @ViewBuilder
    private func sliderRow(label: String,
                            value: Binding<Double>,
                            range: ClosedRange<Double>,
                            format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KMono(text: label, size: 14, color: T.ink)
                Spacer()
                KMono(text: String(format: format, value.wrappedValue),
                       size: 14, color: T.ink2)
            }
            Slider(value: value, in: range, step: 0.05)
                .tint(T.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Model status

    private var modelsSection: some View {
        SettingsCard(title: "engine_status") {
            VoiceStatusView().padding(.horizontal, 14)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sliderBlock(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        scale: Double = 1.0,
        last: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                KMono(text: label, size: 14, color: T.ink)
                Spacer()
                KMono(text: String(format: format, value.wrappedValue * scale),
                       size: 14, color: T.ink2)
            }
            Slider(value: value, in: range, step: 0.05)
                .tint(T.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func engineStateBadge(_ state: VoiceModelState) -> some View {
        switch state {
        case .ready:    KStatusBadge(glyph: .ready, label: "ready", color: T.good)
        case .loading:  KStatusBadge(glyph: .streaming, label: "loading", color: T.warn)
        case .failed:   KStatusBadge(glyph: .remote, label: "error", color: T.bad)
        case .unloaded: KStatusBadge(glyph: .remote, label: "not loaded", color: T.ink3)
        }
    }
}
