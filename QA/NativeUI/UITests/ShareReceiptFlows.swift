import XCTest

final class ShareReceiptFlows: XCTestCase {
    @MainActor
    func testSavedShareReceipt() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "share-receipt"]
        app.launch()
        XCTAssertTrue(app.alerts["Saved to Token AI"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Open Token AI to continue with your shared content."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "appstore-share-receipt"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.alerts["Saved to Token AI"].exists)
    }

    @MainActor
    func testFailedShareReceiptAtLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "share-receipt", "-share-failed",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.alerts["Couldn't share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Couldn't save this item to Token AI."].exists)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "appstore-share-error-large-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
    }
}
