import Foundation
import XCTest
@testable import IOSLocalLLM

final class PortableClassifierRuntimeTests: XCTestCase {
    func testImageDecodingRejectsEmptyOversizedAndInvalidBytes() {
        XCTAssertThrowsError(try FastViTClassifierSession.decode(nil))
        XCTAssertThrowsError(try FastViTClassifierSession.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try FastViTClassifierSession.decode(Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1)))
    }
    func testRealJuliaGGUFChoiceScoreBooleanAndCancellationRecovery() async throws {
        let root = try fixtures().appendingPathComponent("julia-1-q8")
        let entry = try XCTUnwrap(ClassifierCatalog.model(id: "julia-1-q8"))
        let session = try await PortableClassifierRuntime.loadAdmitted(entry, root: root, checkSafety: {})
        try await decisions(session, id: entry.selectionID)
        let pending = Task {
            try await session.classify(.init(model: entry.selectionID, input: String(repeating: "A useful message. ", count: 60),
                instructions: "Does the message ask for help?", type: .boolean))
        }
        try await Task.sleep(for: .milliseconds(5)); pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled work must not publish an answer") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        try await decisions(session, id: entry.selectionID)
    }
    func testRealEnglishLayaGGUF() async throws {
        let root = try fixtures().appendingPathComponent("gguf-downloads/laya-gguf-q8")
        let entry = try XCTUnwrap(ClassifierCatalog.model(id: "laya-gguf-q8"))
        let session = try await PortableClassifierRuntime.loadAdmitted(entry, root: root, checkSafety: {})
        try await decisions(session, id: entry.selectionID)
    }
    func testRealMultilingualLayaCoreML() async throws {
        let root = try fixtures().appendingPathComponent("downloads/laya-multilingual-512-e8")
        let entry = try XCTUnwrap(ClassifierCatalog.model(id: "laya-multilingual-512-e8"))
        let session = try await PortableClassifierRuntime.loadAdmitted(entry, root: root, checkSafety: {})
        try await decisions(session, id: entry.selectionID)
    }
    func testRealFastViTUsesPublishedDictionaryWithoutRenormalizing() async throws {
        let root = try fixtures().appendingPathComponent("downloads/fastvit-t8")
        guard let imagePath = ProcessInfo.processInfo.environment["CLASSIFIER_RUNTIME_IMAGE"] else { throw XCTSkip("Set CLASSIFIER_RUNTIME_IMAGE to an existing sample image") }
        let entry = try XCTUnwrap(ClassifierCatalog.model(id: "fastvit-t8"))
        let session = try await PortableClassifierRuntime.loadAdmitted(entry, root: root, checkSafety: {})
        let answer = try await session.classify(.init(model: entry.selectionID, input: "", instructions: "", type: .choice,
            imageData: Data(contentsOf: URL(fileURLWithPath: imagePath))))
        XCTAssertEqual(answer.optionIDs.count, 999)
        XCTAssertEqual(Set(answer.optionIDs).count, 999)
        XCTAssertEqual(answer.optionIDs.filter { $0 == "crane" }.count, 1)
        XCTAssertEqual(answer.choice, answer.optionIDs.first)
        XCTAssertTrue(answer.probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }
    private func fixtures() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CLASSIFIER_RUNTIME_FIXTURES"] else { throw XCTSkip("Set CLASSIFIER_RUNTIME_FIXTURES to existing audited model folders") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private func decisions(_ session: ClassifierRuntimeSession, id: String) async throws {
        let base = "The team was helpful and solved the issue."
        let choice = try await session.classify(.init(model: id, input: base, instructions: "Classify the sentiment.", type: .choice,
            options: [.init(id: "positive", description: "Positive sentiment"), .init(id: "negative", description: "Negative sentiment")]))
        XCTAssertEqual(choice.optionIDs, ["positive", "negative"])
        XCTAssertEqual(choice.probabilities.reduce(0, +), 1, accuracy: 1e-6)
        let score = try await session.classify(.init(model: id, input: base, instructions: "Rate how positive this message is.", type: .score, rubric: ["Negative", "Neutral", "Positive"]))
        XCTAssertTrue((0...2).contains(try XCTUnwrap(score.score)))
        let boolean = try await session.classify(.init(model: id, input: base, instructions: "Is the message positive?", type: .boolean))
        XCTAssertTrue((0...1).contains(try XCTUnwrap(boolean.trueProbability)))
    }
}
