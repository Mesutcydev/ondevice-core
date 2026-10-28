import XCTest

final class ResponseRenderingFlows: XCTestCase {
    func testCompletedHTMLPreviewRunsLocallyAndStreamingShowsFullSource() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "response-rendering", "-review-language", "en"]
        app.launch()

        let preview = app.buttons["response.code.preview"]
        XCTAssertFalse(preview.exists)
        app.buttons["review.nextChunk"].tap()
        XCTAssertTrue(app.staticTexts["<p>Line 35: İstanbul & 東京</p>"].waitForExistence(timeout: 5))
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(app.buttons["response.code.expand"].exists)

        app.buttons["review.nextChunk"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        capture("response-html-complete-source")
        preview.tap()
        XCTAssertTrue(app.navigationBars["HTML preview"].waitForExistence(timeout: 5))

        let counter = app.webViews.buttons["Generate: 0"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.webViews.buttons["Generate: 1"].waitForExistence(timeout: 5))
        app.buttons["coding.preview.console"].tap()
        let blocked = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "coding.preview.console.text", "Blocked by policy: connect-src")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        capture("response-html-local-preview")

        app.buttons["response.preview.running"].tap()
        XCTAssertTrue(app.staticTexts["Preview stopped"].waitForExistence(timeout: 3))
        app.buttons["response.preview.running"].tap()
        XCTAssertTrue(app.webViews.buttons["Generate: 0"].waitForExistence(timeout: 10))
        app.buttons["response.preview.reload"].tap()
        XCTAssertTrue(app.webViews.buttons["Generate: 0"].waitForExistence(timeout: 10))

        app.buttons["Source"].tap()
        XCTAssertTrue(app.staticTexts["<p>Line 35: İstanbul & 東京</p>"].waitForExistence(timeout: 5))
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.webViews.buttons["Generate: 0"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
    }

    private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeUIReviewScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
