import XCTest

final class MiniCPMV47Flows: XCTestCase {
    @MainActor
    func testPinnedDenseModelShowsDetailsAndRoutesDownload() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "models", "-minicpm-v47", "-model-actions", "-action-probe"]
        app.launch()
        app.buttons["models.scope.discover"].tap()
        let row = app.buttons["model.row.openbmb/MiniCPM-V-4.7-1B-gguf"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "compact image-understanding model")).firstMatch.waitForExistence(timeout: 3))
        let download = app.buttons["Download model"]
        XCTAssertTrue(download.isHittable)
        download.tap()
        let action = app.staticTexts["fixture.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertTrue(action.label.contains("download"))
        XCTAssertTrue(action.label.contains("openbmb/MiniCPM-V-4.7-1B-gguf"))
    }

    @MainActor
    func testStreaming35BShowsRequirementsAndRoutesItsOwnDownload() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "models", "-minicpm-v47", "-model-actions", "-action-probe"]
        app.launch()
        app.buttons["models.scope.discover"].tap()
        let row = app.buttons["model.row.openbmb/MiniCPM-V-4.7-35B-A3B-gguf"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "at least 12 GB RAM")).firstMatch.waitForExistence(timeout: 3))
        let download = app.buttons["Download model"]
        XCTAssertTrue(download.isHittable)
        download.tap()
        let action = app.staticTexts["fixture.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertTrue(action.label.contains("download"))
        XCTAssertTrue(action.label.contains("openbmb/MiniCPM-V-4.7-35B-A3B-gguf"))
    }
}
