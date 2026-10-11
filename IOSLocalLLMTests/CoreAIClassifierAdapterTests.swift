import XCTest
@testable import IOSLocalLLM

enum ClassifierTestFixtures {
    static func metadata(layout: String = "julia", asset: String = "classifier.aimodel") throws -> Data {
        func tensor(_ type: String, _ shape: [Int]) -> [String: Any] { ["dtype": type, "shape": shape] }
        var inputs = [
            "input_ids": tensor("int32", [1, 512]),
            "attention_mask": tensor("int32", [1, 512]),
            "qtype_onehot": tensor("float32", [1, 3])
        ]
        inputs["qtype_onehot"]?["order"] = ["choice", "score", "noul"]
        var decision: [String: Any] = [
            "head": "encoder", "layout": layout, "window": 512, "head_max_len": 256,
            "option_text_tokens": 48, "cls_token_id": 2, "sep_token_id": 1,
            "pad_token_id": 0, "mask_token_id": 4, "functions": ["main": "main"],
            "inputs": inputs, "outputs": ["token_logits": tensor("float32", [1, 512])],
            "source_temperature": [1.0, 1.0, 1.0]
        ]
        if layout == "laya" {
            var features = tensor("float32", [1, 4])
            features["order"] = ["top1", "top1_minus_top2", "entropy_over_ln_max_k_2", "max_k_2_over_255"]
            decision["functions"] = ["main": "main", "act": "act"]
            decision["outputs"] = ["token_logits": tensor("float32", [1, 512]), "pooled_cls": tensor("float32", [1, 768])]
            decision["act"] = [
                "inputs": ["pooled_cls": tensor("float32", [1, 768]), "feats": features],
                "outputs": ["act_logits": tensor("float32", [1, 2])]
            ]
            decision["temperature"] = [3.0, 4.0, 5.0]
            decision["temperature_by_options"] = ["choice:2": 2.0]
        }
        return try JSONSerialization.data(withJSONObject: [
            "metadata_version": "0.2", "kind": "encoder", "decision": decision,
            "assets": ["main": asset], "language": ["vocab_size": 1_000, "max_context_length": 512]
        ])
    }

    static let encode: CoreAIClassifierAdapter.Encode = { $0.utf8.map { Int32($0) + 10 } }
    static let choice = CoreAIClassifierQuestion.choice(instructions: "Pick", options: [
        .init(id: "a", description: "yes"), .init(id: "b", description: "no")
    ])
    static func output(_ row: CoreAIClassifierInput, logits: [Float] = [0, 2], pooled: Bool = false) -> CoreAIClassifierOutput {
        var values = [Float](repeating: 0, count: row.inputIDs.count)
        for (marker, value) in zip(row.markers, logits) { values[marker] = value }
        return CoreAIClassifierOutput(tokenLogits: values, pooledCLS: pooled ? Array(repeating: 0, count: 768) : nil)
    }
}

private actor ClassifierCallCounts {
    var main = 0
    var safety = 0
    func recordMain() { main += 1 }
    func recordSafety() { safety += 1 }
}

@MainActor
final class CoreAIClassifierAdapterTests: XCTestCase {
    func testCoreMLJuliaContractKeepsTheMatchRaterWindowAndUnpaddedRow() throws {
        let contract = try CoreAIClassifierContract(juliaCoreMLWindow: 2_048, headBudget: 512)
        let row = try CoreAIClassifierAdapter.buildInput(contract: contract, state: "s", question: ClassifierTestFixtures.choice, encode: ClassifierTestFixtures.encode)
        XCTAssertEqual(row.inputIDs.count, 2_048)
        XCTAssertEqual(contract.vocabSize, 256_000)
        XCTAssertEqual(row.inputIDs[row.realTokenCount - 1], contract.sep)
        XCTAssertTrue(row.inputIDs.dropFirst(row.realTokenCount).allSatisfy { $0 == contract.pad })
        XCTAssertNil(contract.mainFunction)
        XCTAssertThrowsError(try contract.modelURL(in: URL(fileURLWithPath: "/tmp")))
        XCTAssertThrowsError(try CoreAIClassifierContract(juliaCoreMLWindow: 4_096))
    }

    func testJuliaMatchesPiecewiseRowFixtureAndRightPadding() throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        let table: [String: [Int32]] = ["choice question: Pick": [10, 11], " yes": [22], " no": [23], "state": [40, 41]]
        let row = try CoreAIClassifierAdapter.buildInput(contract: contract, state: "state", question: ClassifierTestFixtures.choice) {
            guard let ids = table[$0] else { throw CoreAIClassifierError.invalidToken }; return ids
        }
        XCTAssertEqual(Array(row.inputIDs.prefix(12)), [2, 10, 11, 1, 4, 22, 4, 23, 1, 40, 41, 1])
        XCTAssertEqual(row.markers, [4, 6])
        XCTAssertEqual(row.realTokenCount, 12)
        XCTAssertEqual(row.inputIDs.count, 512)
        XCTAssertTrue(row.inputIDs.dropFirst(12).allSatisfy { $0 == 0 })
        XCTAssertEqual(row.attentionMask, Array(repeating: 1, count: 12) + Array(repeating: 0, count: 500))
        XCTAssertEqual(row.questionType, [1, 0, 0])
    }

    func testLayaUsesLabelsAndPublisherBooleanDefaults() throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata(layout: "laya"))
        let table: [String: [Int32]] = [
            "choice question: Pick": [10], " a: yes": [22], " b: no": [23],
            "noul question: Check": [11], " false: no, the statement does not hold": [24],
            " true: yes, the statement holds": [25]
        ]
        let encode: CoreAIClassifierAdapter.Encode = { guard let ids = table[$0] else { throw CoreAIClassifierError.invalidToken }; return ids }
        let choice = try CoreAIClassifierAdapter.buildInput(contract: contract, state: "", question: ClassifierTestFixtures.choice, encode: encode)
        XCTAssertEqual(choice.markers.map { choice.inputIDs[$0 + 1] }, [22, 23])
        let boolean = try CoreAIClassifierAdapter.buildInput(contract: contract, state: "", question: .boolean(instructions: "Check"), encode: encode)
        XCTAssertEqual(boolean.markers.map { boolean.inputIDs[$0 + 1] }, [24, 25])
        XCTAssertEqual(boolean.questionType, [0, 0, 1])
    }

    func testStrictEncodingRefusesCutsAndMarkerInjection() throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        func refused(_ error: CoreAIClassifierError, _ state: String, _ question: CoreAIClassifierQuestion) {
            XCTAssertThrowsError(try CoreAIClassifierAdapter.buildInput(contract: contract, state: state, question: question, encode: ClassifierTestFixtures.encode)) {
                XCTAssertEqual($0 as? CoreAIClassifierError, error)
            }
        }
        refused(.reservedMarker, "<mask>", ClassifierTestFixtures.choice)
        refused(.stateTooLong, String(repeating: "s", count: 512), ClassifierTestFixtures.choice)
        refused(.optionTooLong, "", .score(instructions: "Pick", rubric: [String(repeating: "a", count: 48), "b"]))
        refused(.headTooLong, "", .score(instructions: String(repeating: "h", count: 240), rubric: ["a", "b"]))
        refused(.invalidQuestion, "", .boolean(instructions: "Pick", falseCriterion: "no"))
        refused(.invalidQuestion, "", .choice(instructions: "Pick", options: [.init(id: "a", description: "one"), .init(id: "a", description: "two")]))
    }

    func testUnsafeMetadataAndWrongGraphContractAreRejected() throws {
        for asset in ["../model.aimodel", "/model.aimodel", "https://example.com/model.aimodel", "model.bin"] {
            XCTAssertThrowsError(try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata(asset: asset)))
        }
        XCTAssertThrowsError(try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata(layout: "decoder")))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ClassifierTestFixtures.metadata()) as? [String: Any])
        json["kind"] = "llm"
        XCTAssertThrowsError(try CoreAIClassifierContract(metadata: JSONSerialization.data(withJSONObject: json)))
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        XCTAssertThrowsError(try CoreAIClassifierAdapter.buildInput(contract: contract, state: "s", question: ClassifierTestFixtures.choice, encode: { _ in [4] }))
    }

    func testChoiceScoreAndBooleanReadouts() async throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        let adapter = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { ClassifierTestFixtures.output($0, logits: [10_000, 10_002]) }, checkSafety: {})
        let choice = try await adapter.classify(state: "s", question: ClassifierTestFixtures.choice)
        XCTAssertEqual(choice.choice, "b")
        XCTAssertEqual(choice.probabilities[1], 0.8807970779778823, accuracy: 1e-12)
        let score = try await adapter.classify(state: "s", question: .score(instructions: "Rate", rubric: ["low", "high"]))
        XCTAssertEqual(try XCTUnwrap(score.score), choice.probabilities[1], accuracy: 1e-12)
        let boolean = try await adapter.classify(state: "s", question: .boolean(instructions: "Check"))
        XCTAssertEqual(try XCTUnwrap(boolean.trueProbability), choice.probabilities[1], accuracy: 1e-12)
        XCTAssertNil(boolean.choice)
        XCTAssertNil(boolean.directAnswerProbability)
    }

    func testTiesChooseFirstAndNonfiniteLogitsAreRejected() async throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        let adapter = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { ClassifierTestFixtures.output($0, logits: [1, 1]) }, checkSafety: {})
        let answer = try await adapter.classify(state: "s", question: ClassifierTestFixtures.choice)
        XCTAssertEqual(answer.choice, "a")
        for values in [[Double.nan, 0], [Double.infinity, 0], [-Double.infinity, 0]] {
            XCTAssertThrowsError(try CoreAIClassifierAdapter.softmax(values))
        }
    }

    func testLayaActUsesRawProbabilitiesBeforeCalibration() async throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata(layout: "laya"))
        let calls = ClassifierCallCounts()
        let adapter = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { ClassifierTestFixtures.output($0, pooled: true) }, runAct: { _, features in
                guard abs(features[0] - 0.8807971) < 1e-6, abs(features[3] - 2.0 / 255) < 1e-6 else {
                    throw CoreAIClassifierError.invalidOutput
                }
                return [0, 0]
            }, checkSafety: { await calls.recordSafety() })
        let answer = try await adapter.classify(state: "s", question: ClassifierTestFixtures.choice, calibration: .published)
        XCTAssertEqual(answer.temperature, 2)
        XCTAssertEqual(answer.probabilities[1], 0.7310585786300049, accuracy: 1e-12)
        XCTAssertEqual(answer.directAnswerProbability, 0.5)
        let count = await calls.safety
        XCTAssertEqual(count, 2)
    }

    func testSafetyRefusalPreventsExecutionAndInvalidOutputDoesNotLeak() async throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        let calls = ClassifierCallCounts()
        let denied = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { row in await calls.recordMain(); return ClassifierTestFixtures.output(row) },
            checkSafety: { throw CancellationError() })
        do { _ = try await denied.classify(state: "s", question: ClassifierTestFixtures.choice); XCTFail("Safety refusal ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error type") }
        let count = await calls.main; XCTAssertEqual(count, 0)
        let bad = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { _ in CoreAIClassifierOutput(tokenLogits: []) }, checkSafety: {})
        do { _ = try await bad.classify(state: "s", question: ClassifierTestFixtures.choice); XCTFail("Invalid output accepted") }
        catch { XCTAssertEqual(error as? CoreAIClassifierError, .invalidOutput) }
    }

    func testCancellationDiscardsSubmittedResultAndRejectsOverlappingCalls() async throws {
        let contract = try CoreAIClassifierContract(metadata: ClassifierTestFixtures.metadata())
        let calls = ClassifierCallCounts()
        let adapter = try CoreAIClassifierAdapter(contract: contract, encode: ClassifierTestFixtures.encode,
            runMain: { row in
                await calls.recordMain()
                try await Task.sleep(for: .milliseconds(100))
                return ClassifierTestFixtures.output(row)
            }, checkSafety: {})
        let request = Task { try await adapter.classify(state: "s", question: ClassifierTestFixtures.choice) }
        while await calls.main == 0 { await Task.yield() }
        do { _ = try await adapter.classify(state: "s", question: ClassifierTestFixtures.choice); XCTFail("Concurrent call accepted") }
        catch { XCTAssertEqual(error as? CoreAIClassifierError, .busy) }
        await adapter.cancel()
        do { _ = try await request.value; XCTFail("Cancelled result returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error type") }
    }
}
