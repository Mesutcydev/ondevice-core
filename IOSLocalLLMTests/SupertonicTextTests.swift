import XCTest
@testable import IOSLocalLLM

/// Supertonic's text front end. The ONNX path itself is checked against the
/// real model on a Mac by scripts/supertonic-harness.
final class SupertonicTextTests: XCTestCase {
    func testPreprocessNormalizesDashesAndClosesTheSentence() {
        XCTAssertEqual(SupertonicPipeline.preprocess("Hello — world", lang: "en"), "<en>Hello - world.</en>")
    }

    func testPreprocessDropsEmojiAndKeepsTurkishLetters() {
        XCTAssertEqual(SupertonicPipeline.preprocess("Merhaba 😀 dünya!", lang: "tr"), "<tr>Merhaba dünya!</tr>")
    }

    func testChunksStayUnderTheLimitAndKeepEveryWord() {
        let text = String(repeating: "Short sentence here. ", count: 40)
        let chunks = SupertonicPipeline.chunks(text, maxLength: 120)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 120 })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").count, 120)
    }

    func testChunksSplitTextWithoutSpaces() {
        XCTAssertEqual(SupertonicPipeline.chunks(String(repeating: "あ", count: 300), maxLength: 120).map(\.count),
                       [120, 120, 60])
    }

    @MainActor
    func testLanguageFollowsTheTextAndStaysSupported() {
        XCTAssertEqual(SupertonicTTSService.language(for: "Guten Morgen, wie geht es dir heute?"), "de")
        XCTAssertTrue(SupertonicPipeline.languages.contains(SupertonicTTSService.language(for: "שלום, מה שלומך?")))
    }
}
