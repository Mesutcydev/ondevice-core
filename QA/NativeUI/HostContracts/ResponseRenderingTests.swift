import Foundation
import Testing
@testable import NativeUIReview

@MainActor
struct ResponseRenderingTests {
    @Test func openingFenceMountsCodeBeforeFirstBodyToken() {
        for prefix in ["```", "```s", "```swift", "```swift\n"] {
            guard case .code(_, let code) = StudioTextBlocks.parse(prefix).last else {
                Issue.record("Opening fence rendered as prose: \(prefix)"); continue
            }
            #expect(code.isEmpty)
        }
    }
    @Test func streamingAndCompletedAnswersKeepCodeAndReasoningSeparate() {
        let code = "let greeting = \"İstanbul 東京\"\n// <think>literal</think>\n"
        let prefix = "<think>Plan</think>\n```swift\n" + code
        let live = AssistantReplyPresentation(content: prefix, isStreaming: true)
        let done = AssistantReplyPresentation(content: prefix + "```", isStreaming: false)
        #expect(live.reasoning == done.reasoning)
        #expect(live.answer == done.answer)
        #expect(StudioTextBlocks.parse(live.answer).contains(.code("swift", code)))
    }
    @Test func exportUsesSafeKnownExtensionsAndPreservesAllBytes() {
        #expect(AssistantSourceFile.filename(language: " HTML ") == "code.html")
        #expect(AssistantSourceFile.filename(language: "python") == "code.py")
        #expect(AssistantSourceFile.filename(language: "diff") == "code.patch")
        #expect(AssistantSourceFile.filename(language: "../../bad") == "code.txt")
        #expect(AssistantSourceFile.filename(language: "") == "code.txt")
        let source = "\tİstanbul 東京\r\n" + String(repeating: "line\n", count: 200) + "  "
        #expect(Data(AssistantSourceDocument(text: source).text.utf8) == Data(source.utf8))
    }
}
