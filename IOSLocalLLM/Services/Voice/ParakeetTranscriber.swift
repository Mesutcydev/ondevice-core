import Foundation

// MARK: - ParakeetTranscriber
//
// NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0; 25 European languages, detected
// automatically) on ONNX Runtime, from istupakov's int8 ONNX export:
// nemo128 mel preprocessor → FastConformer encoder → greedy
// token-and-duration (TDT) decoding with the joint network. The decoding
// loop follows onnx-asr's `_AsrWithTransducerDecoding` (MIT, istupakov).
//
// No app types live here, so scripts/onnx-harness compiles this same
// file on a Mac and compares its transcripts with onnx-asr's.

final class ParakeetTranscriber: @unchecked Sendable {
    /// The joint network can emit at most this many tokens on one frame.
    private static let maxTokensPerStep = 10
    /// input_states_1/2 of decoder_joint-model: [layers, 1, hidden].
    private static let stateShape = [2, 1, 640]

    private let env: ORTEnv
    private let preprocessor: ORTSession
    private let encoder: ORTSession
    private let decoderJoint: ORTSession
    private let vocab: [Int: String]
    private let vocabSize: Int
    private let blank: Int

    /// `directory` holds nemo128.onnx, encoder-model.int8.onnx,
    /// decoder_joint-model.int8.onnx and vocab.txt.
    init(directory: URL, threads: Int32 = 4) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setLogSeverityLevel(.warning)
        try options.setIntraOpNumThreads(threads)
        func session(_ name: String) throws -> ORTSession {
            try ORTSession(env: env, modelPath: directory.appendingPathComponent(name).path, sessionOptions: options)
        }
        self.env = env
        preprocessor = try session("nemo128.onnx")
        encoder = try session("encoder-model.int8.onnx")
        decoderJoint = try session("decoder_joint-model.int8.onnx")

        // "<piece> <id>" per line; ▁ marks a word start.
        var vocab: [Int: String] = [:]
        for line in try String(contentsOf: directory.appendingPathComponent("vocab.txt"), encoding: .utf8)
            .split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let id = Int(parts[1]) else { continue }
            vocab[id] = parts[0].replacingOccurrences(of: "\u{2581}", with: " ")
        }
        self.vocab = vocab
        vocabSize = vocab.count
        blank = vocab.first(where: { $0.value == "<blk>" })?.key ?? vocab.count - 1
    }

    /// Transcribes 16 kHz mono samples.
    func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        let features = try preprocessor.run(withInputs: [
            "waveforms": try Self.tensor(samples, .float, [1, samples.count]),
            "waveforms_lens": try Self.tensor([Int64(samples.count)], .int64, [1]),
        ], outputNames: ["features", "features_lens"], runOptions: nil)
        guard let melFeatures = features["features"], let melLengths = features["features_lens"] else { return "" }

        let encoded = try encoder.run(
            withInputs: ["audio_signal": melFeatures, "length": melLengths],
            outputNames: ["outputs", "encoded_lengths"], runOptions: nil)
        guard let output = encoded["outputs"], let lengths = encoded["encoded_lengths"] else { return "" }
        // outputs is [1, D, frames].
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        let dimension = shape[1], frames = shape[2]
        let values: [Float] = try Self.values(output)
        let validFrames = min(frames, Int((try Self.values(lengths) as [Int64]).first ?? Int64(frames)))

        var state1 = [Float](repeating: 0, count: Self.stateShape.reduce(1, *))
        var state2 = state1
        var tokens: [Int] = []
        var t = 0
        var emitted = 0
        while t < validFrames {
            let frame = (0..<dimension).map { values[$0 * frames + t] }
            let step = try decoderJoint.run(withInputs: [
                "encoder_outputs": try Self.tensor(frame, .float, [1, dimension, 1]),
                "targets": try Self.tensor([Int32(tokens.last ?? blank)], .int32, [1, 1]),
                "target_length": try Self.tensor([Int32(1)], .int32, [1]),
                "input_states_1": try Self.tensor(state1, .float, Self.stateShape),
                "input_states_2": try Self.tensor(state2, .float, Self.stateShape),
            ], outputNames: ["outputs", "output_states_1", "output_states_2"], runOptions: nil)
            let logits: [Float] = try Self.values(step["outputs"])
            guard logits.count > vocabSize else { break }
            let token = Self.argmax(logits[0..<vocabSize])
            let duration = Self.argmax(logits[vocabSize...]) - vocabSize
            if token != blank {
                // The prediction network only advances on a real token.
                state1 = try Self.values(step["output_states_1"])
                state2 = try Self.values(step["output_states_2"])
                tokens.append(token)
                emitted += 1
            }
            if duration > 0 {
                t += duration
                emitted = 0
            } else if token == blank || emitted == Self.maxTokensPerStep {
                t += 1
                emitted = 0
            }
        }
        return Self.detokenize(tokens.compactMap { vocab[$0] })
    }

    /// onnx-asr's DECODE_SPACE_PATTERN: drop a leading space and spaces
    /// before punctuation, keep the rest as single spaces.
    static func detokenize(_ pieces: [String]) -> String {
        let text = pieces.joined()
        let pattern = try! NSRegularExpression(pattern: #"\A\s|\s\B|(\s)\b"#)
        var out = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[last..<range.lowerBound]
            if match.range(at: 1).location != NSNotFound { out += " " }
            last = range.upperBound
        }
        return (out + text[last...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tensors

    private static func argmax(_ values: ArraySlice<Float>) -> Int {
        var best = values.startIndex
        for i in values.indices where values[i] > values[best] { best = i }
        return best
    }

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
