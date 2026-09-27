import XCTest
import UIKit
@testable import IOSLocalLLM

@MainActor
final class PageAwarePDFTests: XCTestCase {
    func testQuerySelectsLatePageWithinPromptBudget() {
        let pages = [
            FileAttachmentService.PDFPageText(number: 1, text: "General introduction and overview."),
            FileAttachmentService.PDFPageText(number: 27, text: "The lunar permit expires on 14 October."),
            FileAttachmentService.PDFPageText(number: 28, text: "Appendix and references.")
        ]
        let result = FileAttachmentService.selectedPDFPageText(
            pages, query: "When does the lunar permit expire?", byteBudget: 240
        )
        XCTAssertTrue(result.contains("Page 27:"))
        XCTAssertTrue(result.contains("14 October"))
        XCTAssertLessThanOrEqual(result.utf8.count, 240)
    }

    func testPDFImportKeepsPagesAfterLegacyPreviewCap() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-aware-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let repeated = String(repeating: "A long report contains many ordinary facts. ", count: 25)
        try renderer.writePDF(to: url) { context in
            for page in 1...80 {
                context.beginPage()
                let text = page == 80
                    ? "The secret lunar permit expires on 14 October."
                    : "Page \(page). \(repeated)"
                (text as NSString).draw(
                    in: CGRect(x: 24, y: 24, width: 564, height: 744),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 10)]
                )
            }
        }

        let attachment = try await FileAttachmentService.read(url)
        XCTAssertLessThanOrEqual(attachment.extractedText.utf8.count,
                                 FileAttachmentService.perFileByteCap)
        XCTAssertEqual(attachment.pdfPages?.last?.number, 80)
        let prompt = FileAttachmentService.renderForPrompt(
            [attachment], byteBudget: 2_000,
            relevanceQuery: "When does the secret lunar permit expire?"
        )
        XCTAssertTrue(prompt.contains("Page 80:"))
        XCTAssertTrue(prompt.contains("14 October"))
    }

    func testPageLexicalScoreRewardsMatchingEvidence() {
        let terms: Set<String> = ["lunar", "permit", "expires"]
        XCTAssertGreaterThan(
            KnowledgeBaseService.pageLexicalScore(terms, text: "The lunar permit expires tomorrow."),
            KnowledgeBaseService.pageLexicalScore(terms, text: "A report about rain.")
        )
    }
}
