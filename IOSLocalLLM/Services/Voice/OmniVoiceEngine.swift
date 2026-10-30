import AVFoundation
import NaturalLanguage

/// LFM3-Omni's own voice as a voice engine. The Omni model runs in the visual
/// model slot (LlamaCppVLMService), so a voice chat where Omni listens,
/// replies and speaks keeps one model resident. Selectable only in LFM3_OMNI
/// builds; elsewhere it reports unloaded and refuses to synthesize.
@MainActor
final class OmniVoiceEngine: LocalVoiceEngine {
    let kind: VoiceEngineKind = .lfm3Omni
    private(set) var modelState: VoiceModelState = .unloaded
    var isReady: Bool { modelState == .ready }

    /// Omni speaks 19 languages; the language follows each sentence.
    static let voices: [VoiceOption] = [
        VoiceOption(id: "lfm3omni.female", name: "Female", engineKind: .lfm3Omni, locale: "mul",
                    description: "LFM3 Omni · speaks the reply's language"),
        VoiceOption(id: "lfm3omni.male", name: "Male", engineKind: .lfm3Omni, locale: "mul",
                    description: "LFM3 Omni · speaks the reply's language"),
    ]
    var availableVoices: [VoiceOption] { Self.voices }

    func load() async {
        #if LFM3_OMNI
        modelState = .loading
        let vision = LlamaCppVLMService.shared
        if vision.activeRepoID != LFM3Catalog.omni.repoID {
            await vision.switchTo(repoID: LFM3Catalog.omni.repoID)
        }
        if case .ready = vision.state, vision.activeRepoID == LFM3Catalog.omni.repoID {
            modelState = .ready
        } else {
            modelState = .failed("Download LFM3 Omni 2B under Models.")
        }
        #else
        modelState = .failed("LFM3 Omni needs an LFM3-Omni build.")
        #endif
    }

    /// The visual model service owns the weights; this only forgets readiness.
    func unload() { modelState = .unloaded }

    func synthesize(text: String, voice: VoiceOption, settings: VoiceSynthesisSettings) async throws -> VoiceSynthesisResult {
        #if LFM3_OMNI
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let audio = try await LlamaCppVLMService.shared.omniSpeak(
            text, language: language, voice: voice.id.hasSuffix(".male") ? "male" : "female")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("omni-voice-\(UUID().uuidString).wav")
        try audio.wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let wav = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: AVAudioFrameCount(wav.length))
        else { throw VoiceError.audioBufferCreationFailed }
        try wav.read(into: buffer)
        return VoiceSynthesisResult(pcmBuffer: buffer, sampleRate: wav.processingFormat.sampleRate,
                                    duration: Double(buffer.frameLength) / wav.processingFormat.sampleRate,
                                    engineKind: .lfm3Omni, voiceID: voice.id)
        #else
        throw VoiceError.engineNotReady("LFM3 Omni needs an LFM3-Omni build.")
        #endif
    }
}
