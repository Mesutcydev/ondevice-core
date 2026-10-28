import XCTest

final class InterruptedDownloadFlows: XCTestCase {
    @MainActor func testInterruptedDownloadCanBeCancelledAndDoesNotReturnAfterRelaunch() {
        let app = XCUIApplication()
        let id = "review/catalog-model"
        let args = ["-screen", "models", "-model-actions", "-model-interrupted", "-action-probe"]
        app.launchArguments = args + ["-interrupted-reset"]
        app.launch()
        app.buttons["models.scope.discover"].tap()
        XCTAssertTrue(app.staticTexts["Interrupted"].waitForExistence(timeout: 4))
        let cancel = app.buttons["model.cancel.\(id)"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.buttons["Cancel download"].waitForExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label == %@", "Cancel download")).element(boundBy: 1).tap()
        let download = app.buttons["Download Review catalog model"]
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Interrupted"].exists)
        app.terminate()
        app.launchArguments = args
        app.launch()
        app.buttons["models.scope.discover"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Interrupted"].exists)
        XCTAssertFalse(app.buttons["model.cancel.\(id)"].exists)
    }
}
