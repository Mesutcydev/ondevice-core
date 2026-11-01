import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - SupertonicTTSService
//
// Supertonic 3: one multilingual neural model (31 languages, including all
// of the app's interface languages) with ten preset voices. Voices are not
// tied to a language: the reply's language is detected per utterance and
// passed to the model, falling back to the device language, then English.
// Inference runs off the main actor in SupertonicPipeline.

@MainActor
final class SupertonicTTSService: LocalVoiceEngine, ObservableObject {

    let kind: VoiceEngineKind = .supertonic
    @Published private(set) var modelState: VoiceModelState = .unloaded

    var isReady: Bool { modelState == .ready }

    /// The repository's preset styles, `voice_styles/<F1…M5>.json`.
    nonisolated static let styleNames = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]

    static let supertonicVoices: [VoiceOption] = styleNames.map { name in
        VoiceOption(
            id: "supertonic:\(name)",
            name: "\(name.hasPrefix("F") ? "Female" : "Male") \(name.dropFirst())",
            engineKind: .supertonic,
            locale: "mul",
            description: "Multilingual"
        )
    }

    var availableVoices: [VoiceOption] { Self.supertonicVoices }

    private var pipeline: SupertonicPipeline?
    private var styles: [String: SupertonicPipeline.Style] = [:]

    func load() async {
        guard modelState != .ready, modelState != .loading else { return }
        guard let directory = VoiceModelBundleValidator.supertonicDirectoryURL() else {
            modelState = .failed("Supertonic 3 isn't downloaded. Get it in Voice settings.")
            return
        }
        modelState = .loading
        do {
            let (pipeline, styles) = try await Task.detached(priority: .userInitiated) {
                let pipeline = try SupertonicPipeline(directory: directory)
                var styles: [String: SupertonicPipeline.Style] = [:]
                for name in Self.styleNames {
                    styles[name] = try SupertonicPipeline.loadStyle(
                        directory.appendingPathComponent("voice_styles/\(name).json"))
                }
                return (pipeline, styles)
            }.value
            self.pipeline = pipeline
            self.styles = styles
            modelState = .ready
        } catch {
            pipeline = nil
            styles = [:]
            modelState = .failed(error.localizedDescription)
        }
    }

    func unload() {
        pipeline = nil
        styles = [:]
        modelState = .unloaded
    }

    func synthesize(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings
    ) async throws -> VoiceSynthesisResult {
        guard let pipeline else { throw VoiceError.engineNotReady("Supertonic 3 isn't loaded.") }
        let name = voice.id.hasPrefix("supertonic:") ? String(voice.id.dropFirst("supertonic:".count)) : voice.id
        guard let style = styles[name] ?? styles["F1"] else { throw VoiceError.noVoiceSelected }
        let language = Self.language(for: text)
        // 1.05 is Supertonic's natural pace; the user's speed scales it.
        let speed = 1.05 * max(0.5, min(2.0, settings.speed))

        try Task.checkCancellation()
        let samples = try await Task.detached(priority: .userInitiated) {
            try pipeline.synthesize(text, language: language, style: style, speed: speed)
        }.value
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw VoiceError.synthesisFailedWithError("Supertonic returned no audio.")
        }
        let sampleRate = Double(pipeline.sampleRate)
        guard let buffer = AudioPlaybackService.makeBuffer(from: samples, sampleRate: sampleRate) else {
            throw VoiceError.audioBufferCreationFailed
        }
        return VoiceSynthesisResult(
            pcmBuffer: buffer,
            sampleRate: sampleRate,
            duration: Double(samples.count) / sampleRate,
            engineKind: .supertonic,
            voiceID: voice.id,
            alignment: nil,
            synthesisMetadata: SynthesisMetadata(sourceText: text, engineKind: .supertonic)
        )
    }

    /// The utterance's own language when Supertonic reads it, else the
    /// device language, else English.
    static func language(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue.split(separator: "-").first.map(String.init)
        let device = Locale.current.language.languageCode?.identifier
        return [detected, device].compactMap { $0 }.first(where: SupertonicPipeline.languages.contains) ?? "en"
    }
}
