import Foundation
import Testing
@testable import NativeUIReview

@MainActor
struct AttachmentDeliveryTests {
    @Test func uncommonTextExtensionIsReadAndRelevantFieldReachesSmallContext() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cson")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "{" + String(repeating: "\"padding\":\"abcdef\",", count: 180)
            + "\"targetSetting\":\"enabled\"}"
        try Data(source.utf8).write(to: url)

        let attachment = try await FileAttachmentService.read(url)
        let budget = FileAttachmentService.promptByteBudget(forInputTokens: 640)
        let rendered = FileAttachmentService.renderForPrompt(
            [attachment], byteBudget: budget,
            relevanceQuery: "What is targetSetting?"
        )

        #expect(attachment.extractedText.contains("targetSetting"))
        #expect(rendered.contains("targetSetting"))
        #expect(rendered.contains("enabled"))
        #expect(rendered.utf8.count <= budget)
    }

    @Test func groundedImageKeepsTextWhileRemovingBytesForTextRuntime() {
        let image = ChatMessage.ImageAttachment(data: Data([1, 2, 3]), caption: "chart")
        let original = ChatMessage(role: .user, content: "What is shown?",
            modelContent: "The chart shows an upward trend.", imageThumbnails: [image])
        let runtimeCopy = original.withoutImagePayloads()
        #expect(original.hasAttachedImages)
        #expect(!runtimeCopy.hasAttachedImages)
        #expect(runtimeCopy.content == original.content)
        #expect(runtimeCopy.modelContent == original.modelContent)
    }

    @Test func threeLongNamedFilesStayWithinSmallContextBudget() {
        let budget = FileAttachmentService.promptByteBudget(forInputTokens: 640)
        let files = (1...3).map { index in
            FileAttachmentService.Attachment(
                id: UUID(), url: URL(fileURLWithPath: "/tmp/file-\(index).cson"),
                displayName: String(repeating: "configuration-", count: 8) + "\(index).cson",
                byteSize: 2_000, extractedText: String(repeating: "setting = true\n", count: 130),
                kind: .text, warning: nil
            )
        }
        let rendered = FileAttachmentService.renderForPrompt(files, byteBudget: budget)
        #expect(rendered.utf8.count <= budget)
        #expect(rendered.contains("File [3]"))
    }
}
