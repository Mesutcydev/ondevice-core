import Accelerate
import Foundation

// MARK: - NemotronTranscriber
//
// NVIDIA Nemotron 3.5 ASR streaming 0.6B (NVIDIA Open Model License): a
// cache-aware FastConformer-RNNT whose 128-slot language prompt covers 40+
// locales, every interface language of the app among them. Runs soniqo's
// int8 ONNX export, whose int8 ConvInteger needs ONNX Runtime 1.30 (1.23 has
// no kernel for it).
//
// Ported from soniqo/speech-core (Apache-2.0; NemotronMultilingualStt and
// StreamingMelSpectrogram @ 8294f9e) for whole clips: the clip's log-mel is
// cut into 320 ms windows that pass through the encoder in order with its
// caches carried, each followed by greedy RNN-T over the frames it emits.
// No app types live here, so scripts/onnx-harness compiles this file.

final class NemotronTranscriber: @unchecked Sendable {
    private static let melBins = 128, nFFT = 512, hop = 160, winLength = 400
    private static let windowFrames = 32, windowSamples = 5_120            // 320 ms
    private static let preCacheFrames = 9, layers = 24, hidden = 1_024
    private static let leftContext = 56, convCache = 8, prompts = 128
    private static let decoderLayers = 2, decoderHidden = 640, maxSymbols = 10

    private let env: ORTEnv
    private let encoder: ORTSession
    private let decoder: ORTSession
    private let joint: ORTSession
    private let decoderInputs: [String]
    /// decoder_output, h_out, c_out: read by position, as speech-core does.
    private let decoderOutputs: [String]
    private let jointInputs: [String]
    private let jointOutput: String
    private let vocab: [String]
    private let slots: [String: Int]
    private let autoSlot: Int
    private let filterbank = NemotronTranscriber.slaneyFilterbank()
    private let window = (0..<NemotronTranscriber.winLength).map {
        0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(NemotronTranscriber.winLength - 1)))
    }

    /// `directory` holds encoder.onnx, decoder.onnx(+.data), joint.onnx(+.data),
    /// vocab.json and languages.json.
    init(directory: URL, threads: Int32 = 4) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setLogSeverityLevel(.warning)
        try options.setIntraOpNumThreads(threads)
        func session(_ name: String) throws -> ORTSession {
            try ORTSession(env: env, modelPath: directory.appendingPathComponent(name).path, sessionOptions: options)
        }
        self.env = env
        encoder = try session("encoder.onnx")
        decoder = try session("decoder.onnx")
        joint = try session("joint.onnx")
        decoderInputs = try decoder.inputNames()
        decoderOutputs = try decoder.outputNames()
        jointInputs = try joint.inputNames()
        jointOutput = try joint.outputNames().first ?? "joint_output"

        let pieces = try JSONDecoder().decode([String: String].self,
                                              from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        var vocab = [String](repeating: "", count: (pieces.keys.compactMap(Int.init).max() ?? -1) + 1)
        for (key, piece) in pieces { if let id = Int(key), id >= 0 { vocab[id] = piece } }
        self.vocab = vocab

        struct Languages: Decodable { let promptDictionary: [String: Int]; let autoSlot: Int }
        let languages = try JSONDecoder().decode(Languages.self,
                                                 from: Data(contentsOf: directory.appendingPathComponent("languages.json")))
        slots = languages.promptDictionary
        autoSlot = languages.autoSlot
    }

    /// Transcribes 16 kHz mono samples. `language` is a BCP-47 tag or a bare
    /// language code; unknown or nil uses the model's automatic slot.
    func transcribe(_ samples: [Float], language: String?) throws -> String {
        guard !samples.isEmpty else { return "" }
        let slot = language.flatMap { slots[$0] ?? slots[String($0.prefix { $0 != "-" && $0 != "_" })] } ?? autoSlot
        var languageMask = [Float](repeating: 0, count: Self.prompts)
        if (0..<Self.prompts).contains(slot) { languageMask[slot] = 1 }

        // Zero-pad to whole 320 ms windows, as the reference does.
        let windows = (samples.count + Self.windowSamples - 1) / Self.windowSamples
        let frames = logMel(samples + [Float](repeating: 0, count: windows * Self.windowSamples - samples.count))

        var preCache = [Float](repeating: 0, count: Self.melBins * Self.preCacheFrames)
        var lastChannel = [Float](repeating: 0, count: Self.layers * Self.leftContext * Self.hidden)
        var lastTime = [Float](repeating: 0, count: Self.layers * Self.hidden * Self.convCache)
        var lastChannelLength: Int32 = 0
        let stateCount = Self.decoderLayers * Self.decoderHidden
        var h = [Float](repeating: 0, count: stateCount)
        var c = [Float](repeating: 0, count: stateCount)
        let blank = vocab.count
        var lastToken = Int64(blank)   // blank primes the prediction network
        var text = ""

        for w in 0..<windows {
            // Encoder input is [bin, frame]; frames the clip lacks stay zero.
            var mel = [Float](repeating: 0, count: Self.melBins * Self.windowFrames)
            for f in 0..<Self.windowFrames where w * Self.windowFrames + f < frames.count {
                let frame = frames[w * Self.windowFrames + f]
                for b in 0..<Self.melBins { mel[b * Self.windowFrames + f] = frame[b] }
            }
            let encoded = try encoder.run(withInputs: [
                "audio_signal": try Self.tensor(mel, .float, [1, Self.melBins, Self.windowFrames]),
                "audio_length": try Self.tensor([Int32(Self.windowFrames)], .int32, [1]),
                "language_mask": try Self.tensor(languageMask, .float, [1, Self.prompts]),
                "pre_cache": try Self.tensor(preCache, .float, [1, Self.melBins, Self.preCacheFrames]),
                "cache_last_channel": try Self.tensor(lastChannel, .float, [Self.layers, 1, Self.leftContext, Self.hidden]),
                "cache_last_time": try Self.tensor(lastTime, .float, [Self.layers, 1, Self.hidden, Self.convCache]),
                "cache_last_channel_len": try Self.tensor([lastChannelLength], .int32, [1]),
            ], outputNames: ["encoded_output", "encoded_length", "new_pre_cache", "new_cache_last_channel",
                             "new_cache_last_time", "new_cache_last_channel_len"], runOptions: nil)
            let output: [Float] = try Self.values(encoded["encoded_output"])
            let length = Int((try Self.values(encoded["encoded_length"]) as [Int32]).first ?? 0)
            preCache = try Self.values(encoded["new_pre_cache"])
            lastChannel = try Self.values(encoded["new_cache_last_channel"])
            lastTime = try Self.values(encoded["new_cache_last_time"])
            lastChannelLength = (try Self.values(encoded["new_cache_last_channel_len"]) as [Int32]).first ?? 0

            // Greedy RNN-T: up to maxSymbols tokens per encoder frame ([1, T, H]).
            for t in 0..<min(length, output.count / Self.hidden) {
                let frame = try Self.tensor(Array(output[(t * Self.hidden)..<((t + 1) * Self.hidden)]),
                                            .float, [1, 1, Self.hidden])
                for _ in 0..<Self.maxSymbols {
                    let predicted = try decoder.run(withInputs: [
                        decoderInputs[0]: try Self.tensor([lastToken], .int64, [1, 1]),
                        decoderInputs[1]: try Self.tensor(h, .float, [Self.decoderLayers, 1, Self.decoderHidden]),
                        decoderInputs[2]: try Self.tensor(c, .float, [Self.decoderLayers, 1, Self.decoderHidden]),
                    ], outputNames: Set(decoderOutputs), runOptions: nil)
                    let decoderOutput: [Float] = try Self.values(predicted[decoderOutputs[0]])
                    guard decoderOutput.count == Self.decoderHidden else { break }
                    let logits: [Float] = try Self.values(try joint.run(withInputs: [
                        jointInputs[0]: frame,
                        jointInputs[1]: try Self.tensor(decoderOutput, .float, [1, 1, Self.decoderHidden]),
                    ], outputNames: [jointOutput], runOptions: nil)[jointOutput])
                    guard !logits.isEmpty else { break }
                    let token = vDSP.indexOfMaximum(logits).0
                    if Int(token) == blank { break }
                    let piece = Int(token) < vocab.count ? vocab[Int(token)] : ""
                    text += piece.hasPrefix("\u{2581}") ? " " + piece.dropFirst() : piece
                    lastToken = Int64(token)
                    h = try Self.values(predicted[decoderOutputs[1]])
                    c = try Self.values(predicted[decoderOutputs[2]])
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Front end (StreamingMelSpectrogram over the whole clip)

    /// Pre-emphasis 0.97, symmetric Hann window at the start of each 512-point
    /// frame, frames from t·hop − n_fft/2 with reflection before sample 0,
    /// power spectrum, Slaney mel, log(x + 2⁻²⁴); no normalization.
    func logMel(_ samples: [Float]) -> [[Float]] {
        var y = samples
        for i in stride(from: samples.count - 1, to: 0, by: -1) { y[i] = samples[i] - 0.97 * samples[i - 1] }
        let pad = Self.nFFT / 2
        let bins = Self.nFFT / 2 + 1
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(setup) }
        var real = [Float](repeating: 0, count: Self.nFFT), imaginary = real
        var outReal = real, outImaginary = real
        var frames: [[Float]] = []
        var t = 0
        while true {
            let origin = t * Self.hop - pad
            if origin + Self.winLength > y.count || (origin < 0 && -origin >= y.count) { break }
            for i in 0..<Self.nFFT { real[i] = 0; imaginary[i] = 0 }
            for i in 0..<Self.winLength { real[i] = y[abs(origin + i)] * window[i] }
            vDSP_DFT_Execute(setup, real, imaginary, &outReal, &outImaginary)
            var mel = [Float](repeating: 0, count: Self.melBins)
            for m in 0..<Self.melBins {
                var sum: Float = 0
                for f in 0..<bins {
                    sum += (outReal[f] * outReal[f] + outImaginary[f] * outImaginary[f]) * filterbank[m * bins + f]
                }
                mel[m] = log(sum + 1 / Float(1 << 24))
            }
            frames.append(mel)
            t += 1
        }
        return frames
    }

    /// Slaney-scale triangles with area normalization, as speech-core builds them.
    private static func slaneyFilterbank() -> [Float] {
        func hzToMel(_ hz: Float) -> Float {
            hz < 1_000 ? 3 * hz / 200 : 15 + log(hz / 1_000) * (27 / log(6.4))
        }
        func melToHz(_ mel: Float) -> Float {
            mel < 15 ? 200 * mel / 3 : 1_000 * exp((mel - 15) / (27 / log(6.4)))
        }
        let bins = nFFT / 2 + 1
        let low = hzToMel(0), high = hzToMel(8_000)
        let hz = (0..<(melBins + 2)).map { Double(melToHz(low + (high - low) * Float($0) / Float(melBins + 1))) }
        let binHz = 16_000.0 / Double(nFFT)
        var fb = [Float](repeating: 0, count: melBins * bins)
        for m in 0..<melBins {
            let left = hz[m], center = hz[m + 1], right = hz[m + 2]
            let norm = right > left ? 2 / (right - left) : 0
            for f in 0..<bins {
                let fHz = Double(f) * binHz
                var w = 0.0
                if fHz >= left && fHz <= center && center > left { w = (fHz - left) / (center - left) }
                else if fHz > center && fHz <= right && right > center { w = (right - fHz) / (right - center) }
                fb[m * bins + f] = Float(w * norm)
            }
        }
        return fb
    }

    // MARK: - Tensors

    private static func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(data: Data(buffer: $0)) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    private static func values<T>(_ value: ORTValue?) throws -> [T] {
        guard let value else { return [] }
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }
}
