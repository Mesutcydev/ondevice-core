import XCTest

final class ContentConcernFlows: XCTestCase {
    @MainActor
    func testImageReportDismissalPreservesDraftAndExistingImage() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image"]
        app.launch()
        let prompt = app.textViews["image.draft.prompt"].exists
            ? app.textViews["image.draft.prompt"].firstMatch : app.textFields["image.draft.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("A quiet green forest")
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        // Compare the draft actually delivered by keyboard automation. This
        // checks sheet preservation without assuming synthetic keys all arrived.
        let initialDraft = prompt.value as? String
        XCTAssertFalse(initialDraft?.isEmpty ?? true)
        app.buttons["image.result-actions"].tap()
        XCTAssertTrue(app.buttons["image.report-content"].waitForExistence(timeout: 3))
        app.buttons["image.report-content"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["content.report.support"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing from your conversation or generated image is attached automatically. You choose what to share on the support website."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "content-concern-privacy"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertEqual(prompt.value as? String, initialDraft)
        XCTAssertTrue(app.images["Generated image"].exists)
        XCTAssertTrue(app.buttons["image.create"].isEnabled)
    }

    @MainActor
    func testImageDeletionRequiresConfirmationAndKeepsModelAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image"]
        app.launch()
        XCTAssertTrue(app.buttons["image.result-actions"].waitForExistence(timeout: 5))
        app.buttons["image.result-actions"].tap()
        app.buttons["image.delete-result"].tap()
        // Native confirmation actions may expose their title rather than the
        // SwiftUI accessibility identifier. Fail promptly if no dialog appears.
        let cancel = app.buttons["Cancel"].firstMatch
        guard cancel.waitForExistence(timeout: 5) else {
            XCTFail("The image deletion confirmation did not appear")
            return
        }
        cancel.tap()
        XCTAssertTrue(app.images["Generated image"].exists)
        app.buttons["image.result-actions"].tap()
        app.buttons["image.delete-result"].tap()
        let confirm = app.buttons["Delete image"].firstMatch
        guard confirm.waitForExistence(timeout: 5) else {
            XCTFail("The image deletion confirmation did not reappear")
            return
        }
        confirm.tap()
        XCTAssertFalse(app.images["Generated image"].exists)
        XCTAssertTrue(app.buttons["image.model"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["No image yet. Your image will appear here."].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testChatResponseOffersContentReportWithoutChangingResponseActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "composer", "-response-actions"]
        app.launch()
        XCTAssertTrue(app.buttons["More response actions"].waitForExistence(timeout: 5))
        app.buttons["More response actions"].tap()
        guard app.buttons["Report content concern"].waitForExistence(timeout: 5) else {
            XCTFail("The response actions menu did not open")
            return
        }
        app.buttons["Report content concern"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["content.report.support"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Regenerate"].exists)
    }
}
