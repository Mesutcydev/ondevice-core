import Foundation
import NaturalLanguage

// MARK: - SupertonicPipeline
//
// Supertonic 3 text-to-speech (Supertone; weights under OpenRAIL-M) on ONNX
// Runtime: duration predictor → text encoder → flow-matching vector
// estimator (`steps` denoising passes) → vocoder, mono PCM at the config's
// sample rate. Adapted from the MIT reference implementation in
// supertone-inc/supertonic (swift/Sources/Helper.swift @ 1e9799e) with flat
// tensors instead of nested arrays and batch size 1.
//
// No app types live here, so the Mac harness that checks the port against
// the real model (scripts/supertonic-harness) compiles this same file.

final class SupertonicPipeline: @unchecked Sendable {
    /// Languages Supertonic 3 reads. Text in anything else is read as English.
    static let languages: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
        "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]

    /// One preset voice: the text-to-latent and duration style tensors.
    struct Style: @unchecked Sendable {
        let ttl: ORTValue
        let dp: ORTValue
    }

    let sampleRate: Int
    private let baseChunkSize: Int
    private let chunkCompress: Int
    private let latentDim: Int
    private let indexer: [Int64]
    private let env: ORTEnv
    private let durationPredictor: ORTSession
    private let textEncoder: ORTSession
    private let vectorEstimator: ORTSession
    private let vocoder: ORTSession

    /// `directory` is the model folder: `onnx/` (four models, tts.json,
    /// unicode_indexer.json) and `voice_styles/`.
    init(directory: URL, threads: Int32 = 2) throws {
        struct Config: Decodable {
            struct AE: Decodable { let sample_rate: Int; let base_chunk_size: Int }
            struct TTL: Decodable { let chunk_compress_factor: Int; let latent_dim: Int }
            let ae: AE
            let ttl: TTL
        }
        let onnx = directory.appendingPathComponent("onnx")
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: onnx.appendingPathComponent("tts.json")))
        sampleRate = config.ae.sample_rate
        baseChunkSize = config.ae.base_chunk_size
        chunkCompress = config.ttl.chunk_compress_factor
        latentDim = config.ttl.latent_dim
        indexer = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: onnx.appendingPathComponent("unicode_indexer.json")))

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setLogSeverityLevel(.warning)
        try options.setIntraOpNumThreads(threads)
        func session(_ name: String) throws -> ORTSession {
            try ORTSession(env: env, modelPath: onnx.appendingPathComponent(name).path, sessionOptions: options)
        }
        self.env = env
        durationPredictor = try session("duration_predictor.onnx")
        textEncoder = try session("text_encoder.onnx")
        vectorEstimator = try session("vector_estimator.onnx")
        vocoder = try session("vocoder.onnx")
    }

    /// Loads `voice_styles/<name>.json`.
    static func loadStyle(_ url: URL) throws -> Style {
        struct Component: Decodable { let data: [[[Float]]]; let dims: [Int] }
        struct File: Decodable { let style_ttl: Component; let style_dp: Component }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        func value(_ c: Component) throws -> ORTValue {
            try tensor(c.data.flatMap { $0.flatMap { $0 } }, .float, c.dims)
        }
        return Style(ttl: try value(file.style_ttl), dp: try value(file.style_dp))
    }

    /// Speaks `text` in `language` (an ISO 639-1 code). `speed` 1.05 is the
    /// reference default; `steps` trades quality for time (reference: 8).
    func synthesize(_ text: String, language: String, style: Style,
                    speed: Float = 1.05, steps: Int = 8) throws -> [Float] {
        let lang = Self.languages.contains(language) ? language : "en"
        let maxLength = (lang == "ko" || lang == "ja") ? 120 : 300
        let pause = [Float](repeating: 0, count: Int(0.3 * Float(sampleRate)))
        var wav: [Float] = []
        for (i, chunk) in Self.chunks(text, maxLength: maxLength).enumerated() {
            if i > 0 { wav += pause }
            wav += try infer(chunk, lang: lang, style: style, speed: speed, steps: steps)
        }
        return wav
    }

    private func infer(_ text: String, lang: String, style: Style, speed: Float, steps: Int) throws -> [Float] {
        let ids = Self.preprocess(text, lang: lang).unicodeScalars.map { scalar -> Int64 in
            Int(scalar.value) < indexer.count ? indexer[Int(scalar.value)] : -1
        }
        let textIDs = try Self.tensor(ids, .int64, [1, ids.count])
        let textMask = try Self.tensor([Float](repeating: 1, count: ids.count), .float, [1, 1, ids.count])

        let predicted = try durationPredictor.run(
            withInputs: ["text_ids": textIDs, "style_dp": style.dp, "text_mask": textMask],
            outputNames: ["duration"], runOptions: nil)
        guard let seconds = try Self.floats(predicted["duration"]).first else { return [] }
        let duration = seconds / speed

        guard let textEmbedding = try textEncoder.run(
            withInputs: ["text_ids": textIDs, "style_ttl": style.ttl, "text_mask": textMask],
            outputNames: ["text_emb"], runOptions: nil)["text_emb"] else { return [] }

        // Start from Gaussian noise over the latent frames the duration needs;
        // with one utterance the latent mask is all ones.
        let wavLength = Int(duration * Float(sampleRate))
        let chunkSize = baseChunkSize * chunkCompress
        let frames = max(1, (wavLength + chunkSize - 1) / chunkSize)
        let channels = latentDim * chunkCompress
        var latent = (0..<(channels * frames)).map { _ in Self.gaussian() }
        let latentMask = try Self.tensor([Float](repeating: 1, count: frames), .float, [1, 1, frames])
        let totalStep = try Self.tensor([Float(steps)], .float, [1])

        for step in 0..<steps {
            let denoised = try vectorEstimator.run(withInputs: [
                "noisy_latent": try Self.tensor(latent, .float, [1, channels, frames]),
                "text_emb": textEmbedding,
                "style_ttl": style.ttl,
                "latent_mask": latentMask,
                "text_mask": textMask,
                "current_step": try Self.tensor([Float(step)], .float, [1]),
                "total_step": totalStep,
            ], outputNames: ["denoised_latent"], runOptions: nil)
            latent = try Self.floats(denoised["denoised_latent"])
        }

        let audio = try vocoder.run(
            withInputs: ["latent": try Self.tensor(latent, .float, [1, channels, frames])],
            outputNames: ["wav_tts"], runOptions: nil)
        return Array(try Self.floats(audio["wav_tts"]).prefix(wavLength))
    }

    // MARK: - Text

    /// The reference normalizer: NFKD, emoji and symbol cleanup, closing
    /// punctuation, then `<lang>…</lang>` tags the model is trained on.
    static func preprocess(_ text: String, lang: String) -> String {
        var text = String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { scalar in
            let v = scalar.value
            return !((0x1F600...0x1F64F).contains(v) || (0x1F300...0x1F5FF).contains(v)
                || (0x1F680...0x1F6FF).contains(v) || (0x1F700...0x1FAFF).contains(v)
                || (0x2600...0x27BF).contains(v) || (0x1F1E6...0x1F1FF).contains(v))
        }))
        let replacements: [(String, String)] = [
            ("–", "-"), ("‑", "-"), ("—", "-"), ("_", " "),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("´", "'"), ("`", "'"), ("[", " "), ("]", " "), ("|", " "), ("/", " "), ("#", " "),
            ("→", " "), ("←", " "), ("♥", ""), ("☆", ""), ("♡", ""), ("©", ""), ("\\", ""),
            ("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, "),
            (" ,", ","), (" .", "."), (" !", "!"), (" ?", "?"), (" ;", ";"), (" :", ":"), (" '", "'"),
        ]
        for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
        while text.contains("\"\"") { text = text.replacingOccurrences(of: "\"\"", with: "\"") }
        while text.contains("''") { text = text.replacingOccurrences(of: "''", with: "'") }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.unicodeScalars.last,
           !".!?;:,'\"\u{201C}\u{201D}\u{2018}\u{2019})]}…。」』】〉》›»".unicodeScalars.contains(last) {
            text += "."
        }
        return "<\(lang)>\(text)</\(lang)>"
    }

    /// Sentences packed up to `maxLength` characters; an over-long sentence
    /// splits on spaces, and a run with no spaces on characters.
    static func chunks(_ text: String, maxLength: Int) -> [String] {
        var pieces: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            guard sentence.count > maxLength else { pieces.append(sentence); return true }
            var line = ""
            for word in sentence.split(separator: " ") {
                for part in stride(from: 0, to: word.count, by: maxLength).map({
                    String(word.dropFirst($0).prefix(maxLength))
                }) {
                    if !line.isEmpty, line.count + part.count + 1 > maxLength { pieces.append(line); line = "" }
                    line += line.isEmpty ? part : " " + part
                }
            }
            if !line.isEmpty { pieces.append(line) }
            return true
        }
        var packed: [String] = []
        for piece in pieces {
            if let last = packed.last, last.count + piece.count + 1 <= maxLength {
                packed[packed.count - 1] = last + " " + piece
            } else {
                packed.append(piece)
            }
        }
        return packed
    }

    // MARK: - Tensors

    private static func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(data: Data(buffer: $0)) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    private static func floats(_ value: ORTValue?) throws -> [Float] {
        guard let value else { return [] }
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Box–Muller, as in the reference.
    private static func gaussian() -> Float {
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
