import Foundation

enum CoreAIClassifierError: LocalizedError, Equatable {
    case unsupportedContract
    case unsafeAssetPath
    case invalidQuestion
    case reservedMarker
    case invalidToken
    case optionTooLong
    case headTooLong
    case stateTooLong
    case invalidOutput
    case busy

    var errorDescription: String? {
        switch self {
        case .unsupportedContract: return "This model does not provide a supported classifier contract."
        case .unsafeAssetPath: return "The classifier pack contains an invalid model path."
        case .invalidQuestion: return "Use 2–20 nonempty options with unique IDs, or supply both yes/no criteria."
        case .reservedMarker: return "Remove the reserved MASK marker from the input or options."
        case .invalidToken: return "The tokenizer does not match this classifier model."
        case .optionTooLong: return "An option exceeds the model’s 48-token limit. Shorten its description."
        case .headTooLong: return "The instructions and options exceed this model’s question budget. Shorten them."
        case .stateTooLong: return "The input exceeds this model’s context window. Shorten the input."
        case .invalidOutput: return "The model returned an invalid classifier result."
        case .busy: return "The classifier is busy. Wait for the current operation to finish."
        }
    }
}

/// The encoder decision contract is deliberately separate from an LLM bundle.
/// Metadata marked `kind: llm` (including decoder-based decision heads) requires
/// a different executor and is refused here.
struct CoreAIClassifierContract: Sendable {
    enum Layout: String, Decodable, Sendable { case julia, laya }
    let layout: Layout
    let window: Int
    let headBudget: Int
    let optionTokenLimit: Int
    let vocabSize: Int
    let cls: Int32
    let sep: Int32
    let pad: Int32
    let mask: Int32
    let asset: String?
    let mainFunction: String?
    let actFunction: String?
    let pooledSize: Int?
    let sourceTemperatures: [Double]
    let calibratedTemperatures: [Double]?
    let temperatureBuckets: [String: Double]

    /// MatchRater's Core ML Julia export uses the same strict row protocol,
    /// with a variable sequence and a scalar qtype instead of a one-hot input.
    /// This contract has no Core AI asset or function to resolve.
    init(juliaCoreMLWindow: Int = 2_048, headBudget: Int = 512) throws {
        guard (2...2_048).contains(juliaCoreMLWindow), headBudget > 0, headBudget <= juliaCoreMLWindow else {
            throw CoreAIClassifierError.unsupportedContract
        }
        layout = .julia; window = juliaCoreMLWindow; self.headBudget = headBudget
        optionTokenLimit = 48; vocabSize = 256_000
        cls = 2; sep = 1; pad = 0; mask = 4
        asset = nil; mainFunction = nil; actFunction = nil; pooledSize = nil
        sourceTemperatures = [1, 1, 1]; calibratedTemperatures = nil; temperatureBuckets = [:]
    }

    init(metadata: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: metadata)
        let d = envelope.decision
        guard envelope.metadataVersion == "0.2", envelope.kind == "encoder",
              d.head == "encoder", (1...4_096).contains(d.window),
              d.headMaxLen > 0, d.headMaxLen <= d.window,
              d.optionTextTokens == 48, envelope.language.vocabSize > 0,
              envelope.language.maxContextLength == d.window,
              let asset = envelope.assets["main"],
              let main = d.functions["main"], !main.isEmpty,
              d.inputs.count == 3,
              d.inputs["input_ids"]?.matches("int32", [1, d.window]) == true,
              d.inputs["attention_mask"]?.matches("int32", [1, d.window]) == true,
              d.inputs["qtype_onehot"]?.matches("float32", [1, 3]) == true,
              d.inputs["qtype_onehot"]?.order == ["choice", "score", "noul"],
              d.outputs["token_logits"]?.matches("float32", [1, d.window]) == true
        else { throw CoreAIClassifierError.unsupportedContract }
        let special = [d.clsTokenId, d.sepTokenId, d.padTokenId, d.maskTokenId]
        guard special.allSatisfy({ $0 >= 0 && Int($0) < envelope.language.vocabSize }),
              Set(special).count == 4,
              d.sourceTemperature.count == 3,
              d.sourceTemperature.allSatisfy({ $0.isFinite && $0 > 0 }),
              d.temperature.map({ $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 > 0 } }) ?? true,
              (d.temperatureByOptions ?? [:]).values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw CoreAIClassifierError.unsupportedContract }
        // Julia has no fitted calibration and its published readout uses T=1.
        guard d.layout != .julia || (d.sourceTemperature == [1, 1, 1] && d.temperature == nil),
              d.layout != .julia || d.functions["act"] == nil
        else { throw CoreAIClassifierError.unsupportedContract }
        if d.layout == .laya {
            guard let act = d.functions["act"], !act.isEmpty,
                  let pooled = d.outputs["pooled_cls"], pooled.dtype == "float32",
                  pooled.shape.count == 2, pooled.shape[0] == 1, (1...4_096).contains(pooled.shape[1]),
                  d.act?.inputs["pooled_cls"]?.matches("float32", pooled.shape) == true,
                  d.act?.inputs["feats"]?.matches("float32", [1, 4]) == true,
                  d.act?.inputs["feats"]?.order == ["top1", "top1_minus_top2", "entropy_over_ln_max_k_2", "max_k_2_over_255"],
                  d.act?.outputs["act_logits"]?.matches("float32", [1, 2]) == true
            else { throw CoreAIClassifierError.unsupportedContract }
        }
        self.layout = d.layout
        window = d.window
        headBudget = d.headMaxLen
        optionTokenLimit = d.optionTextTokens
        vocabSize = envelope.language.vocabSize
        cls = d.clsTokenId; sep = d.sepTokenId; pad = d.padTokenId; mask = d.maskTokenId
        self.asset = asset
        mainFunction = main
        actFunction = d.functions["act"]
        pooledSize = d.outputs["pooled_cls"]?.shape.last
        sourceTemperatures = d.sourceTemperature
        calibratedTemperatures = d.temperature
        temperatureBuckets = d.temperatureByOptions ?? [:]
        _ = try modelURL(in: URL(fileURLWithPath: "/classifier-bundle"))
    }

    func modelURL(in folder: URL) throws -> URL {
        guard let asset else { throw CoreAIClassifierError.unsupportedContract }
        let parts = asset.split(separator: "/", omittingEmptySubsequences: false)
        guard !asset.contains(":"), !asset.contains("\\"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ["aimodel", "aimodelc"].contains((asset as NSString).pathExtension.lowercased())
        else { throw CoreAIClassifierError.unsafeAssetPath }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(asset).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw CoreAIClassifierError.unsafeAssetPath }
        return url
    }

    private struct Tensor: Decodable {
        let dtype: String
        let shape: [Int]
        let order: [String]?
        func matches(_ type: String, _ dimensions: [Int]) -> Bool { dtype == type && shape == dimensions }
    }
    private struct Act: Decodable { let inputs: [String: Tensor]; let outputs: [String: Tensor] }
    private struct Language: Decodable {
        let vocabSize: Int
        let maxContextLength: Int
        enum CodingKeys: String, CodingKey {
            case vocabSize = "vocab_size", maxContextLength = "max_context_length"
        }
    }
    private struct Decision: Decodable {
        let head: String
        let layout: Layout
        let window: Int
        let headMaxLen: Int
        let optionTextTokens: Int
        let clsTokenId: Int32
        let sepTokenId: Int32
        let padTokenId: Int32
        let maskTokenId: Int32
        let functions: [String: String]
        let inputs: [String: Tensor]
        let outputs: [String: Tensor]
        let act: Act?
        let sourceTemperature: [Double]
        let temperature: [Double]?
        let temperatureByOptions: [String: Double]?
        enum CodingKeys: String, CodingKey {
            case head, layout, window, functions, inputs, outputs, act, temperature
            case headMaxLen = "head_max_len", optionTextTokens = "option_text_tokens"
            case clsTokenId = "cls_token_id", sepTokenId = "sep_token_id"
            case padTokenId = "pad_token_id", maskTokenId = "mask_token_id"
            case sourceTemperature = "source_temperature", temperatureByOptions = "temperature_by_options"
        }
    }
    private struct Envelope: Decodable {
        let metadataVersion: String
        let kind: String
        let assets: [String: String]
        let language: Language
        let decision: Decision
        enum CodingKeys: String, CodingKey {
            case metadataVersion = "metadata_version", kind, assets, language, decision
        }
    }
}

enum CoreAIClassifierQuestion: Sendable {
    struct Option: Sendable { let id: String; let description: String }
    case choice(instructions: String, options: [Option])
    case score(instructions: String, rubric: [String])
    case boolean(instructions: String, falseCriterion: String? = nil, trueCriterion: String? = nil)

    fileprivate var pieces: (type: String, index: Int, instructions: String, ids: [String], descriptions: [String]) {
        switch self {
        case .choice(let instructions, let options):
            return ("choice", 0, instructions, options.map(\.id), options.map(\.description))
        case .score(let instructions, let rubric):
            return ("score", 1, instructions, rubric.indices.map(String.init), rubric)
        case .boolean(let instructions, let no, let yes):
            return ("noul", 2, instructions, ["false", "true"], [no ?? "false", yes ?? "true"])
        }
    }
}

struct CoreAIClassifierInput: Sendable {
    let inputIDs: [Int32]
    let attentionMask: [Int32]
    let questionType: [Float]
    let markers: [Int]
    let realTokenCount: Int
}

struct CoreAIClassifierOutput: Sendable {
    let tokenLogits: [Float]
    var pooledCLS: [Float]? = nil
}

struct CoreAIClassifierAnswer: Sendable {
    let optionIDs: [String]
    let probabilities: [Double]
    let choice: String?
    let score: Double?
    let trueProbability: Double?
    /// Laya's act head: probability of class 0 (answer directly). This is
    /// advisory metadata; it never starts tools or changes the app's policy.
    let directAnswerProbability: Double?
    let temperature: Double
}

/// Serial host orchestration, with injectable local tokenizer and executor.
/// The SDK bridge accepts an already admitted AIModel. This adapter never
/// downloads, loads weights, starts tools, or logs requests/results.
actor CoreAIClassifierAdapter {
    enum Calibration: Sendable { case source, published }
    typealias Encode = @Sendable (String) throws -> [Int32]
    typealias RunMain = @Sendable (CoreAIClassifierInput) async throws -> CoreAIClassifierOutput
    typealias RunAct = @Sendable ([Float], [Float]) async throws -> [Float]
    let contract: CoreAIClassifierContract
    private let encode: Encode
    private let runMain: RunMain
    private let runAct: RunAct?
    /// Mandatory host callback: recheck live memory/thermal/cancellation policy
    /// before every graph call. Loading/residency remains the host's responsibility.
    private let checkSafety: @Sendable () async throws -> Void
    private var inFlight = false
    private var cancellationEpoch: UInt64 = 0

    init(contract: CoreAIClassifierContract, encode: @escaping Encode,
         runMain: @escaping RunMain, runAct: RunAct? = nil,
         checkSafety: @escaping @Sendable () async throws -> Void) throws {
        guard (contract.actFunction == nil) == (runAct == nil) else {
            throw CoreAIClassifierError.unsupportedContract
        }
        self.contract = contract; self.encode = encode; self.runMain = runMain
        self.runAct = runAct; self.checkSafety = checkSafety
    }

    func cancel() { cancellationEpoch &+= 1 }

    func validate(state: String, question: CoreAIClassifierQuestion) throws -> Int {
        let row = try Self.buildInput(contract: contract, state: state, question: question, encode: encode)
        return row.attentionMask.reduce(0) { $0 + Int($1) }
    }

    /// Structured states should be passed as pre-serialized text. In particular,
    /// Julia parity uses Python json.dumps(ensure_ascii=False), preserving order
    /// and its spaces. Foundation's compact/sorted JSON changes the token row.
    func classify(state: String, question: CoreAIClassifierQuestion,
                  calibration: Calibration = .source) async throws -> CoreAIClassifierAnswer {
        guard !inFlight else { throw CoreAIClassifierError.busy }
        inFlight = true
        defer { inFlight = false }
        let epoch = cancellationEpoch
        let row = try Self.buildInput(contract: contract, state: state, question: question, encode: encode)
        let p = question.pieces
        let temperature = try Self.temperature(contract: contract, type: p.index,
                                               count: p.ids.count, calibration: calibration)
        try await checkSafety()
        try checkCancellation(epoch)
        let output = try await runMain(row)
        try checkCancellation(epoch)
        guard output.tokenLogits.count == contract.window else { throw CoreAIClassifierError.invalidOutput }
        let logits = row.markers.map { Double(output.tokenLogits[$0]) }
        let raw = try Self.softmax(logits)
        var direct: Double?
        if let runAct {
            guard let pooled = output.pooledCLS, pooled.count == contract.pooledSize,
                  pooled.allSatisfy(\.isFinite) else { throw CoreAIClassifierError.invalidOutput }
            try await checkSafety()
            try checkCancellation(epoch)
            let actLogits = try await runAct(pooled, Self.actFeatures(raw))
            try checkCancellation(epoch)
            guard actLogits.count == 2 else { throw CoreAIClassifierError.invalidOutput }
            direct = try Self.softmax(actLogits.map(Double.init))[0]
        }
        let probabilities = try Self.softmax(logits.map { $0 / temperature })
        // Preserve the publisher's argmax tie policy: first option wins.
        let winner = probabilities.firstIndex(of: probabilities.max() ?? 0) ?? 0
        return CoreAIClassifierAnswer(
            optionIDs: p.ids, probabilities: probabilities,
            choice: p.index == 0 ? p.ids[winner] : nil,
            score: p.index == 1 ? probabilities.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } : nil,
            trueProbability: p.index == 2 ? probabilities[1] : nil,
            directAnswerProbability: direct, temperature: temperature
        )
    }

    private func checkCancellation(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == cancellationEpoch else { throw CancellationError() }
    }

    nonisolated static func buildInput(contract c: CoreAIClassifierContract, state: String,
                                      question: CoreAIClassifierQuestion, encode: Encode) throws -> CoreAIClassifierInput {
        let p = question.pieces
        guard (2...20).contains(p.ids.count), Set(p.ids).count == p.ids.count,
              p.ids.allSatisfy({ !$0.isEmpty }), p.descriptions.allSatisfy({ !$0.isEmpty })
        else { throw CoreAIClassifierError.invalidQuestion }
        if case .boolean(_, let no, let yes) = question, (no == nil) != (yes == nil) {
            throw CoreAIClassifierError.invalidQuestion
        }
        guard ([state, p.instructions] + p.ids + p.descriptions).allSatisfy({ !$0.contains("<mask>") })
        else { throw CoreAIClassifierError.reservedMarker }
        func tokens(_ text: String) throws -> [Int32] {
            let ids = text.isEmpty ? [] : try encode(text)
            guard ids.allSatisfy({ $0 >= 0 && Int($0) < c.vocabSize && $0 != c.mask })
            else { throw CoreAIClassifierError.invalidToken }
            return ids
        }
        var descriptions = p.descriptions
        if c.layout == .laya {
            descriptions = descriptions.enumerated().map { index, text in
                switch p.index {
                case 0:
                    let label = p.ids[index]
                    if text.unicodeScalars.elementsEqual(label.unicodeScalars)
                        || text.unicodeScalars.starts(with: (label + ": ").unicodeScalars) { return text }
                    return "\(label): \(text)"
                case 1: return "level \(index): \(text)"
                default: return "\(p.ids[index]): \(text)"
                }
            }
            if case .boolean(_, let no, let yes) = question {
                descriptions = [
                    "false: " + (no ?? "no, the statement does not hold"),
                    "true: " + (yes ?? "yes, the statement holds")
                ]
            }
        }
        let options = try descriptions.map { try tokens(" " + $0) }
        guard options.allSatisfy({ $0.count <= c.optionTokenLimit }) else { throw CoreAIClassifierError.optionTooLong }
        let head = try tokens("\(p.type) question: \(p.instructions)")
        let budget = c.headBudget - options.reduce(0) { $0 + $1.count + 1 }
        // The publisher squeezes an option when fewer than 16 head tokens
        // remain. Strict hosts refuse that row rather than changing the question.
        guard budget >= 16, head.count <= budget else { throw CoreAIClassifierError.headTooLong }
        var ids = [c.cls] + head + [c.sep]
        var markers: [Int] = []
        for option in options { markers.append(ids.count); ids += [c.mask] + option }
        ids.append(c.sep)
        let stateIDs = try tokens(state)
        guard stateIDs.count <= c.window - ids.count - 1 else { throw CoreAIClassifierError.stateTooLong }
        ids += stateIDs + [c.sep]
        let count = ids.count
        ids += Array(repeating: c.pad, count: c.window - count)
        var onehot: [Float] = [0, 0, 0]; onehot[p.index] = 1
        return CoreAIClassifierInput(inputIDs: ids,
            attentionMask: Array(repeating: 1, count: count) + Array(repeating: 0, count: c.window - count),
            questionType: onehot, markers: markers, realTokenCount: count)
    }

    nonisolated static func softmax(_ logits: [Double]) throws -> [Double] {
        guard !logits.isEmpty, logits.allSatisfy(\.isFinite), let top = logits.max() else {
            throw CoreAIClassifierError.invalidOutput
        }
        let expValues = logits.map { exp($0 - top) }
        let sum = expValues.reduce(0, +)
        return expValues.map { $0 / sum }
    }

    nonisolated static func actFeatures(_ raw: [Double]) -> [Float] {
        let sorted = raw.sorted(by: >)
        let k = Double(max(raw.count, 2))
        let entropy = -raw.reduce(0) { $0 + ($1 > 0 ? $1 * log($1) : 0) }
        return [Float(sorted[0]), Float(sorted[0] - sorted[1]), Float(entropy / log(k)), Float(k / 255)]
    }

    private nonisolated static func temperature(contract c: CoreAIClassifierContract, type: Int,
                                               count: Int, calibration: Calibration) throws -> Double {
        switch calibration {
        case .source: return c.sourceTemperatures[type]
        case .published:
            guard let temperatures = c.calibratedTemperatures else { throw CoreAIClassifierError.unsupportedContract }
            let bucket: String
            switch type {
            case 0: bucket = "choice:\(count == 2 ? "2" : count <= 5 ? "3-5" : count <= 10 ? "6-10" : "11+")"
            case 1: bucket = "score:3-5"
            default: bucket = "noul:2"
            }
            if type == 1 && !(3...5).contains(count) { return temperatures[type] }
            return c.temperatureBuckets[bucket] ?? temperatures[type]
        }
    }
}
