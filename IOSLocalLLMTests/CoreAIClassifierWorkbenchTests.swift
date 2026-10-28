import Foundation
import XCTest
@testable import IOSLocalLLM

@MainActor
final class CoreAIClassifierWorkbenchTests: XCTestCase {
    func testPrintedResultKeepsCompletedModelAndScoresWhenTheDraftChanges() async throws {
        let controller = makeController()
        controller.input = "First input"
        try await controller.activate(id: "coreai:first")
        let answer = try await controller.run(controller.request())
        let printed = try XCTUnwrap(controller.printedResult)
        XCTAssertEqual(printed.answer.choice, answer.choice)
        XCTAssertEqual(printed.model.id, "coreai:first")
        XCTAssertEqual(printed.type, .choice)
        XCTAssertEqual(printed.elapsedSeconds, controller.elapsedSeconds)
        XCTAssertFalse(controller.isResultStale)

        controller.input = "Next input"
        controller.selectedModelID = "coreai:second"
        controller.refreshValidation()
        XCTAssertNil(controller.answer)
        XCTAssertTrue(controller.isResultStale)
        XCTAssertEqual(controller.printedResult?.id, printed.id)
        XCTAssertEqual(controller.printedResult?.model.id, "coreai:first")
        XCTAssertEqual(controller.printedResult?.answer.probabilities, answer.probabilities)
        controller.runtimeDidUnload()
        XCTAssertEqual(controller.printedResult?.id, printed.id)
        XCTAssertNil(controller.activeModel)
    }

    func testEverySuccessfulRunGetsANewPrintIdentityAndLoadingRetractsOldTicket() async throws {
        let controller = makeController()
        controller.input = "Same input"
        try await controller.activate(id: "coreai:first")
        _ = try await controller.run(controller.request())
        let first = try XCTUnwrap(controller.printedResult)
        _ = try await controller.run(controller.request())
        let second = try XCTUnwrap(controller.printedResult)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.answer.probabilities, first.answer.probabilities)
        XCTAssertFalse(controller.isResultStale)
        try await controller.activate(id: "coreai:second")
        XCTAssertNil(controller.printedResult)
    }

    func testRuntimeUnloadCancelsValidationAndDropsLateTokenCounts() async throws {
        let controller = CoreAIClassifierWorkbench(backend: .init(
            activate: { .init(id: $0, name: "Fixture", window: 128) },
            run: { _ in throw CoreAIClassifierError.invalidOutput },
            validate: { _ in try await Task.sleep(for: .milliseconds(500)); return 9 }, cancel: {}, unload: {}
        ))
        controller.input = "Validation draft"
        try await controller.activate(id: "fixture")
        try await Task.sleep(for: .milliseconds(300))
        controller.runtimeDidUnload()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(controller.usedTokens)
        XCTAssertNil(controller.validationMessage)
    }
    func testSavedTasksPersistConfigurationWithoutInputOrModelAndKeepDrafts() throws {
        let suite = "classifier-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = CoreAIClassifierWorkbench.Backend(activate: { .init(id: $0, name: "Fixture", window: 128) },
            run: { _ in throw CoreAIClassifierError.invalidOutput }, validate: { _ in 0 }, cancel: {}, unload: {})
        let controller = CoreAIClassifierWorkbench(backend: backend, defaults: defaults)
        controller.input = "Private input draft"
        controller.imageData = Data([1, 2, 3])
        controller.apply(.sentiment)
        try controller.saveTask(named: " My sentiment ")
        let saved = try XCTUnwrap(controller.savedTasks.first)
        XCTAssertEqual(saved.name, "My sentiment")
        let restored = CoreAIClassifierWorkbench(backend: backend, defaults: defaults)
        XCTAssertEqual(restored.savedTasks, [saved])
        XCTAssertEqual(restored.input, "")
        XCTAssertNil(restored.imageData)
        controller.apply(.yesNo)
        controller.apply(saved)
        XCTAssertEqual(controller.type, .choice)
        XCTAssertEqual(controller.input, "Private input draft")
        XCTAssertEqual(controller.imageData, Data([1, 2, 3]))
        try controller.deleteTask(id: saved.id)
        XCTAssertTrue(CoreAIClassifierWorkbench(backend: backend, defaults: defaults).savedTasks.isEmpty)
        controller.optionsText = "same: A\nsame: B"
        XCTAssertThrowsError(try controller.saveTask(named: "Invalid"))
    }

    func testImageModelRequestPreservesTextTaskAndDoesNotSendIt() throws {
        let controller = makeController()
        controller.input = "Text to keep"
        let instructions = controller.instructions
        let options = controller.optionsText
        controller.selectedModelID = "classifier:fastvit-t8"
        XCTAssertThrowsError(try controller.request())
        controller.imageData = Data([1, 2, 3])
        let image = try controller.request()
        XCTAssertEqual(image.input, "")
        XCTAssertNil(image.options)
        XCTAssertEqual(image.imageData, controller.imageData)
        controller.selectedModelID = "coreai:fixture"
        XCTAssertEqual(try controller.request().input, "Text to keep")
        XCTAssertEqual(controller.instructions, instructions)
        XCTAssertEqual(controller.optionsText, options)
    }

    func testPortableAPIIdentityIsPreserved() throws {
        XCTAssertEqual(try LocalClassifierAPI.decodeActivation(Data("{\"model\":\"classifier:julia-1-q8\"}".utf8)), "classifier:julia-1-q8")
        XCTAssertEqual(try LocalClassifierAPI.decodeActivation(Data("{\"model\":\"julia-1-q8\"}".utf8)), "classifier:julia-1-q8")
    }

    func testActivationChoiceScoreBooleanAndExportUseTypedAdapter() async throws {
        let contract = try CoreAIClassifierContract(juliaCoreMLWindow: 128, headBudget: 64)
        let adapter = try CoreAIClassifierAdapter(contract: contract, encode: { text in Array(repeating: 5, count: min(10, text.count)) }, runMain: { row in
            var scores = Array(repeating: Float(0), count: 128)
            for (offset, marker) in row.markers.enumerated() { scores[marker] = Float(offset) }
            return .init(tokenLogits: scores)
        }, checkSafety: {})
        let controller = CoreAIClassifierWorkbench(backend: .init(
            activate: { .init(id: $0, name: "Classifier fixture", window: 128) },
            run: { request in try await adapter.classify(state: request.input, question: request.question) },
            validate: { request in try await adapter.validate(state: request.input, question: request.question) },
            cancel: { Task { await adapter.cancel() } }, unload: {}
        ))
        controller.selectedModelID = "coreai:fixture"
        controller.input = "Example text"
        do { _ = try await controller.run(controller.request()); XCTFail("Activation is required") } catch { }
        try await controller.activate(id: controller.selectedModelID)
        XCTAssertEqual(controller.phase, .ready)
        controller.apply(.sentiment)
        let choice = try await controller.run(controller.request())
        XCTAssertEqual(choice.choice, "negative")
        XCTAssertEqual(choice.probabilities.count, 3)
        XCTAssertEqual(choice.probabilities.reduce(0, +), 1, accuracy: 0.00001)
        controller.apply(.relevance)
        let score = try await controller.run(controller.request())
        XCTAssertGreaterThan(try XCTUnwrap(score.score), 1)
        XCTAssertLessThan(try XCTUnwrap(score.score), 2)
        controller.apply(.yesNo)
        let boolean = try await controller.run(controller.request())
        XCTAssertGreaterThan(try XCTUnwrap(boolean.trueProbability), 0.5)
        XCTAssertNil(boolean.choice)
        let object = try JSONSerialization.jsonObject(with: Data(ClassifierResultExport.json(boolean).utf8)) as? [String: Any]
        XCTAssertNotNil(object?["true_probability"])
        controller.runtimeDidUnload()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertNil(controller.activeModel)
    }

    func testTemplatesAndTasksPreserveInputAndSwitchFields() throws {
        let controller = makeController()
        controller.input = "Keep this draft"
        controller.selectedModelID = "coreai:fixture"
        controller.apply(.sentiment)
        XCTAssertEqual(controller.type, .choice)
        XCTAssertEqual(try controller.request().options?.map(\.id), ["positive", "neutral", "negative"])
        controller.apply(.relevance)
        XCTAssertEqual(controller.type, .score)
        XCTAssertEqual(try controller.request().rubric?.count, 3)
        XCTAssertNil(try controller.request().options)
        controller.apply(.yesNo)
        XCTAssertEqual(controller.type, .boolean)
        XCTAssertNotNil(try controller.request().trueCriterion)
        XCTAssertEqual(controller.input, "Keep this draft")
    }

    func testCancelledOperationDiscardsLateOutputAndCanRunAgain() async throws {
        let gate = DeferredClassifierAnswer()
        var cancelled = 0
        let controller = makeController(run: { _ in await gate.wait() }, cancel: { cancelled += 1 })
        try await controller.activate(id: "coreai:fixture")
        controller.input = "Test input"
        let request = try controller.request()
        let run = Task { try await controller.run(request) }
        while controller.phase != .running { await Task.yield() }
        controller.stop()
        XCTAssertEqual(controller.phase, .stopping)
        XCTAssertEqual(cancelled, 1)
        await gate.finish()
        do { _ = try await run.value; XCTFail("Late output must be discarded") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertNil(controller.answer)
        XCTAssertNil(controller.printedResult)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testRemovalWaitsForClassifierUnloadBeforeReturning() async throws {
        let gate = DeferredClassifierAnswer()
        let controller = CoreAIClassifierWorkbench(backend: .init(
            activate: { .init(id: $0, name: "Fixture", window: 512) },
            run: { _ in await gate.wait() }, validate: { _ in 32 },
            cancel: {}, unload: { _ = await gate.wait() }
        ))
        try await controller.activate(id: "coreai:fixture")
        var completed = false
        let removal = Task {
            await controller.unloadAndWaitForCleanup()
            completed = true
        }
        while !(await gate.isWaiting) { await Task.yield() }
        XCTAssertFalse(completed)
        await gate.finish()
        await removal.value
        XCTAssertTrue(completed)
        XCTAssertNil(controller.activeModel)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func testAPIRejectsUnknownOptionsOversizedInputAndMixedTaskFields() throws {
        let valid = #"{"model":"fixture","input":"text","instructions":"Choose","type":"choice","options":[{"id":"a","description":"First"},{"id":"b","description":"Second"}]}"#
        let request = try LocalClassifierAPI.decodeRequest(Data(valid.utf8))
        XCTAssertEqual(request.model, "coreai:fixture")
        XCTAssertThrowsError(try LocalClassifierAPI.decodeRequest(Data(String(valid.dropLast()).appending(",\"stream\":true}").utf8)))
        XCTAssertThrowsError(try LocalClassifierAPI.decodeRequest(Data(valid.replacingOccurrences(of: "\"text\"", with: "\"" + String(repeating: "a", count: 64_001) + "\"").utf8)))
        XCTAssertThrowsError(try LocalClassifierAPI.decodeRequest(Data(String(valid.dropLast()).appending(",\"rubric\":[\"low\",\"high\"]}").utf8)))
        XCTAssertEqual(try LocalClassifierAPI.decodeActivation(Data(#"{"model":"fixture"}"#.utf8)), "coreai:fixture")
        XCTAssertThrowsError(try LocalClassifierAPI.decodeActivation(Data(#"{"model":"fixture","download":true}"#.utf8)))
    }

    private func makeController(run: @escaping (ClassifierRequest) async throws -> CoreAIClassifierAnswer = { _ in
        .init(optionIDs: ["a", "b"], probabilities: [0.2, 0.8], choice: "b", score: nil, trueProbability: nil, directAnswerProbability: nil, temperature: 1)
    }, cancel: @escaping () -> Void = {}) -> CoreAIClassifierWorkbench {
        CoreAIClassifierWorkbench(backend: .init(activate: { .init(id: $0, name: "Fixture", window: 512) }, run: run,
            validate: { _ in 32 }, cancel: cancel, unload: {}))
    }
}

private actor DeferredClassifierAnswer {
    private var waiter: CheckedContinuation<CoreAIClassifierAnswer, Never>?
    private var completed = false
    var isWaiting: Bool { waiter != nil }
    func wait() async -> CoreAIClassifierAnswer {
        if completed { return Self.answer }
        return await withCheckedContinuation { waiter = $0 }
    }
    func finish() { completed = true; waiter?.resume(returning: Self.answer); waiter = nil }
    private static var answer: CoreAIClassifierAnswer {
        .init(optionIDs: ["a", "b"], probabilities: [0.2, 0.8], choice: "b", score: nil, trueProbability: nil, directAnswerProbability: nil, temperature: 1)
    }
}
