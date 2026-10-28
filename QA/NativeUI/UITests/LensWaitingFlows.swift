import XCTest

final class LensWaitingFlows: XCTestCase {
    @MainActor func testLongPrefillShowsStageElapsedTimeAndWorkingStop() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lens", "-lens-waiting-stage", "preparingAnswer", "-action-probe"]
        app.launch()
        let stage = app.staticTexts["lens.analysis.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertEqual(stage.label, "Preparing answer")
        let elapsed = app.staticTexts["lens.analysis.elapsed"]
        XCTAssertTrue(elapsed.exists)
        XCTAssertTrue(elapsed.label.contains("elapsed"))
        let stop = app.buttons["Stop image analysis"]
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(app.staticTexts["Analysis cancelled"].waitForExistence(timeout: 3))
        XCTAssertFalse(stage.exists)
    }

    @MainActor func testLoadingModelStageFitsWithLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lens", "-lens-waiting-stage", "loadingModel", "-large-type"]
        app.launch()
        let stage = app.staticTexts["lens.analysis.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertEqual(stage.label, "Preparing model")
        XCTAssertTrue(app.buttons["Stop image analysis"].isHittable)
    }
}
