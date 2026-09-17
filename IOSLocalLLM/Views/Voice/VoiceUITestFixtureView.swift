import SwiftUI

#if DEBUG

/// Deterministic Voice Mode surface for UI tests. Activated only when
/// `-voiceUITestMode` is present in launch arguments. Never used in Release.
struct VoiceUITestFixtureView: View {
    @State private var transcript = ProcessInfo.processInfo.environment["MOCK_TRANSCRIPT"]
        ?? "This is a deterministic assistant response used for Voice Mode UI tests. It is long enough to require scrolling when collapsed, and it includes several sentences so karaoke highlighting can advance."
    @State private var expanded = false
    @State private var followSpeech = true
    @State private var playbackTime: Double = 0
    @State private var phase: VoiceSessionPhase = .speaking
    @State private var level: Float = 0.35
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mockDuration: Double {
        let raw = UserDefaults.standard.string(forKey: "mockDuration")
            ?? ProcessInfo.processInfo.arguments.drop(while: { $0 != "-mockDuration" }).dropFirst().first
        return Double(raw ?? "20") ?? 20
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-orbShowcase") {
            ApertureOrbShowcase()
        } else {
            fixtureContent
        }
    }

    private var fixtureContent: some View {
        VStack(spacing: 12) {
            Text("Conversation model")
                .font(.caption)
                .accessibilityIdentifier("conversationModelLabel")
            Text("Ternary Bonsai 8B")
                .font(.headline)
                .accessibilityIdentifier("conversationModelValue")

            Text("Voice")
                .font(.caption)
            Text(mockVoiceLabel)
                .font(.subheadline)
                .accessibilityIdentifier("ttsVoiceValue")

            VoiceActivityOrb(
                phase: phase,
                micLevel: 0,
                reduceMotion: reduceMotion
            )
            .frame(width: 200, height: 200)
            .onAppear {
                VoiceVisualLevelStore.shared.playbackLevel = level
            }
            .onChange(of: level) { _, newLevel in
                VoiceVisualLevelStore.shared.playbackLevel = newLevel
            }

            KaraokeTranscriptView(
                text: transcript,
                activePhraseID: nil,
                activeRange: activeRange,
                spokenUTF16End: spokenEnd,
                isExpanded: expanded,
                onToggleExpand: { expanded.toggle() }
            )
            .accessibilityIdentifier("karaokeTranscript")

            if !followSpeech {
                Button("Follow speech") { followSpeech = true }
                    .accessibilityIdentifier("followSpeechButton")
            }

            HStack {
                Button("End") {}
                    .accessibilityIdentifier("endButton")
                Button("Mute voice") {}
                    .accessibilityIdentifier("muteButton")
                Button("Interrupt") {
                    phase = .interrupted
                    level = 0
                }
                .accessibilityIdentifier("interruptButton")
            }
        }
        .padding()
        .onAppear { startMockPlayback() }
    }

    private var mockVoiceLabel: String {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-mockTTS"), args.indices.contains(idx + 1) {
            switch args[idx + 1].lowercased() {
            case "kitten": return "KittenTTS — Bella"
            case "kokoro": return "Kokoro — American English"
            default: return "Apple TTS — Samantha"
            }
        }
        return "Kokoro — American English"
    }

    private var spokenEnd: Int {
        let len = (transcript as NSString).length
        return Int(Double(len) * min(1, playbackTime / max(mockDuration, 1)))
    }

    private var activeRange: NSRange? {
        let len = (transcript as NSString).length
        guard len > 0, phase == .speaking else { return nil }
        let loc = min(spokenEnd, len - 1)
        return NSRange(location: loc, length: min(4, len - loc))
    }

    private func startMockPlayback() {
        phase = .speaking
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            playbackTime += 0.25
            level = reduceMotion ? 0.1 : Float(0.2 + 0.3 * abs(sin(playbackTime)))
            if playbackTime >= mockDuration {
                timer.invalidate()
                phase = .idle
                level = 0
            }
        }
    }
}

/// A manual QA surface for every pose, quiet audio, and the two render budgets.
/// Kept behind the existing DEBUG-only voice test launch gate.
private struct ApertureOrbShowcase: View {
    @State private var selection = 0
    @State private var reduced = false
    @State private var still = false
    @State private var level = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let labels = ["Ready", "Listening", "Thinking", "Preparing", "Speaking", "Paused"]
    private var phase: VoiceSessionPhase {
        switch selection {
        case 1: .listening
        case 2: .thinking
        case 3: .preparingSpeech
        case 4: .speaking
        case 5: .paused
        default: .idle
        }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Aperture").font(.largeTitle.bold())
                Text("Voice appearance preview").font(.subheadline).foregroundStyle(.secondary)
                VoiceActivityOrb(phase: phase, micLevel: Float(level),
                    reduceMotion: reduceMotion || still,
                    renderingMode: reduced ? .reduced : .automatic, samplesLiveAudio: false)
                    .frame(height: 300)
                Text(labels[selection]).font(.headline)
                Picker("Voice state", selection: $selection) {
                    ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("orbShowcaseState")
                Slider(value: $level, in: 0...1) { Text("Simulated audio") }
                Toggle("Lighter rendering", isOn: $reduced)
                Toggle("Reduce Motion", isOn: $still)
            }
            .padding(24)
        }
    }
}

enum VoiceUITestLaunch {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-voiceUITestMode")
    }
}

#endif
