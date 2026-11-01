import AVFoundation
import Foundation

// MARK: - ParadeeTTSService
//
// Paradee-8M v1.2 (Apache-2.0): an 8.5 MB int8 ONNX distillation of
// Kokoro-82M that runs far faster than real time on one CPU core. Input is
// Kokoro's phoneme vocabulary spelled the misaki way
// (KokoroPhonemizer.misakiIDs); output is 24 kHz PCM. Only the American
// voices are offered: bf_isabella and bm_fable need misaki's British
// dictionary, which the app's phonemizer does not have.

@MainActor
final class ParadeeTTSService: LocalVoiceEngine, ObservableObject {

    let kind: VoiceEngineKind = .paradee
    @Published private(set) var modelState: VoiceModelState = .unloaded

    var isReady: Bool { modelState == .ready }

    static let paradeeVoices: [VoiceOption] = [
        VoiceOption(id: "paradee:af_heart", name: "Heart", engineKind: .paradee, locale: "en-US", description: "Female"),
        VoiceOption(id: "paradee:am_puck", name: "Puck", engineKind: .paradee, locale: "en-US", description: "Male"),
    ]

    /// Row of each voice in config.json's `voices` list, the model's `voice` input.
    private static let voiceIndex: [String: Int64] = ["af_heart": 0, "am_puck": 2]

    var availableVoices: [VoiceOption] { Self.paradeeVoices }

    private var environment: ORTEnv?
    private var session: ORTSession?

    func load() async {
        guard modelState != .ready, modelState != .loading else { return }
        guard let model = VoiceModelBundleValidator.paradeeModelURL() else {
            modelState = .failed("Paradee isn't downloaded. Get it in Voice settings.")
            return
        }
        do {
            // 8.5 MB: loading is quick enough to do inline, as for Kitten.
            let environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setLogSeverityLevel(.warning)
            try options.setIntraOpNumThreads(2)
            session = try ORTSession(env: environment, modelPath: model.path, sessionOptions: options)
            self.environment = environment
            modelState = .ready
        } catch {
            session = nil
            environment = nil
            modelState = .failed(error.localizedDescription)
        }
    }

    func unload() {
        session = nil
        environment = nil
        modelState = .unloaded
    }

    func synthesize(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings
    ) async throws -> VoiceSynthesisResult {
        guard let session else { throw VoiceError.engineNotReady("Paradee isn't loaded.") }
        let name = voice.id.hasPrefix("paradee:") ? String(voice.id.dropFirst("paradee:".count)) : voice.id
        let voiceRow = Self.voiceIndex[name] ?? 0
        let speed = max(0.5, min(2.0, settings.speed))

        try Task.checkCancellation()
        let (ids, samples) = try await Task.detached(priority: .userInitiated) { () throws -> ([Int64], [Float]) in
            // The first call parses CMUdict; keep it off the main actor.
            let ids = KokoroPhonemizer.shared.misakiIDs(for: text)
            guard ids.count > 2 else { return (ids, []) }
            func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [NSNumber]) throws -> ORTValue {
                try ORTValue(tensorData: values.withUnsafeBufferPointer { NSMutableData(data: Data(buffer: $0)) },
                             elementType: type, shape: shape)
            }
            let outputs = try session.run(withInputs: [
                "input_ids": try tensor(ids, .int64, [1, NSNumber(value: ids.count)]),
                "speed": try tensor([speed], .float, [1]),
                "voice": try tensor([voiceRow], .int64, [1]),
            ], outputNames: ["waveform"], runOptions: nil)
            guard let waveform = outputs["waveform"] else { return (ids, []) }
            let data = try waveform.tensorData() as Data
            return (ids, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        }.value
        try Task.checkCancellation()

        guard ids.count > 2 else { throw VoiceError.synthesisFailedWithError("Phonemizer produced no tokens.") }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw VoiceError.synthesisFailedWithError("Paradee returned no audio.")
        }
        guard let buffer = AudioPlaybackService.makeBuffer(from: samples, sampleRate: 24_000) else {
            throw VoiceError.audioBufferCreationFailed
        }
        return VoiceSynthesisResult(
            pcmBuffer: buffer,
            sampleRate: 24_000,
            duration: Double(samples.count) / 24_000,
            engineKind: .paradee,
            voiceID: voice.id,
            alignment: nil,
            synthesisMetadata: SynthesisMetadata(phonemeIDs: ids.map(Int32.init), sourceText: text, engineKind: .paradee)
        )
    }
}
