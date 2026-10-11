#!/usr/bin/env bash
# Optional local integration check against the owner's private MatchRater.
# Reads its existing tokenizer, fixtures and base Core ML model in place.
# No source, assets, credentials or fixture text are copied into this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATCHRATER="${1:?Usage: test_matchrater_classifier.sh /path/to/MatchRater}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/main.swift" <<'SWIFT'
import CoreML
import Foundation

struct TokenizerFixture: Decodable { let text: String; let ids: [Int32] }
struct EncoderFixture: Decodable {
    struct Request: Decodable { let state: String; let question: String; let options: [String]; let type: String? }
    let request: Request
    let ids: [Int32]
    let markers: [Int]
    let qtype: Int32
    let reference_logits: [Double]
    var question: CoreAIClassifierQuestion {
        switch qtype {
        case 1: return .score(instructions: request.question, rubric: request.options)
        case 2: return .boolean(instructions: request.question, falseCriterion: request.options[0], trueCriterion: request.options[1])
        default: return .choice(instructions: request.question, options: request.options.enumerated().map {
            .init(id: String($0.offset), description: $0.element)
        })
        }
    }
}

@main struct Check {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = URL(fileURLWithPath: CommandLine.arguments[2])
        let tokenizer = try JuliaTokenizer(contentsOf: root.appendingPathComponent("app/MatchRater/Resources/julia-tokenizer.bin"))
        let decoder = JSONDecoder()
        let tokenCases = try decoder.decode([TokenizerFixture].self, from: Data(contentsOf: root.appendingPathComponent("tools/fixtures/tokenizer-cases.json")))
        guard tokenCases.allSatisfy({ tokenizer.encode($0.text) == $0.ids }) else { throw CoreAIClassifierError.invalidToken }
        print("MatchRater tokenizer: \(tokenCases.count)/\(tokenCases.count) exact")
        let cases = try decoder.decode([EncoderFixture].self, from: Data(contentsOf: root.appendingPathComponent("tools/fixtures/encoder-cases.json")))
        let contract = try CoreAIClassifierContract(juliaCoreMLWindow: 1_024, headBudget: 256)
        for fixture in cases {
            let row = try CoreAIClassifierAdapter.buildInput(contract: contract, state: fixture.request.state, question: fixture.question, encode: { tokenizer.encode($0) })
            guard Array(row.inputIDs.prefix(row.realTokenCount)) == fixture.ids,
                  row.markers == fixture.markers, row.questionType[Int(fixture.qtype)] == 1 else {
                throw CoreAIClassifierError.invalidQuestion
            }
        }
        print("Classifier row versus MatchRater fixtures: \(cases.count)/\(cases.count) exact")
        // Recompile the existing package for this Mac into the temporary folder.
        // The test loader is outside the production app's runtime lifecycle.
        let compiled = try await MLModel.compileModel(at: root.appendingPathComponent("app/MatchRater/Resources/Julia1.mlpackage"))
        let copy = work.appendingPathComponent("Julia1.mlmodelc")
        try FileManager.default.moveItem(at: compiled, to: copy)
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: copy, configuration: config)
        let adapter = try CoreMLJuliaClassifierRuntime.makeAdapter(model: model, encode: { tokenizer.encode($0) }, checkSafety: {})
        // Include each question type and additional fixture rows, without logging text.
        var selected: [Int] = []
        for type in 0...2 { if let index = cases.firstIndex(where: { $0.qtype == type }) { selected.append(index) } }
        for index in cases.indices where selected.count < 6 && !selected.contains(index) { selected.append(index) }
        var largestDifference = 0.0
        for index in selected {
            let fixture = cases[index]
            let answer = try await adapter.classify(state: fixture.request.state, question: fixture.question)
            let tokens = try MLMultiArray(shape: [1, NSNumber(value: fixture.ids.count)], dataType: .int32)
            for (i, id) in fixture.ids.enumerated() { tokens[i] = NSNumber(value: id) }
            let type = try MLMultiArray(shape: [1], dataType: .int32); type[0] = NSNumber(value: fixture.qtype)
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": tokens, "qtype": type])
            let output = try await model.prediction(from: input)
            guard let scores = output.featureValue(for: "scores")?.multiArrayValue else { throw CoreAIClassifierError.invalidOutput }
            let expected = try CoreAIClassifierAdapter.softmax(fixture.markers.map { scores[[0, NSNumber(value: $0)]].doubleValue })
            let difference = zip(expected, answer.probabilities).map { abs($0 - $1) }.max() ?? 0
            guard difference < 1e-6 else { throw CoreAIClassifierError.invalidOutput }
            largestDifference = max(largestDifference, difference)
        }
        print("Actual CPU Core ML readout: \(selected.count)/\(selected.count), max probability difference \(largestDifference)")
    }
}
SWIFT
CLANG_MODULE_CACHE_PATH="$WORK/ModuleCache" swiftc -O -swift-version 6 -parse-as-library \
    "$ROOT/IOSLocalLLM/Services/CoreAIClassifierAdapter.swift" \
    "$ROOT/IOSLocalLLM/Services/CoreMLJuliaClassifierRuntime.swift" \
    "$MATCHRATER/app/MatchRater/Julia/JuliaTokenizer.swift" \
    "$WORK/main.swift" -o "$WORK/check"
"$WORK/check" "$MATCHRATER" "$WORK"
