import XCTest

final class ClassifierWorkbenchFlows: XCTestCase {
    @MainActor func testActivateChooseScoreBooleanAndExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input"]
        app.launch()
        XCTAssertTrue(app.buttons["classifier.activate"].waitForExistence(timeout: 5))
        app.buttons["classifier.activate"].tap()
        XCTAssertTrue(app.buttons["classifier.unload"].waitForExistence(timeout: 5))
        capture("classifier-choice-editor")
        run(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.choice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["classifier.export"].exists)
        capture("classifier-choice-result")
        top(app)
        app.segmentedControls["classifier.type"].buttons["Score"].tap()
        XCTAssertTrue(app.textFields["classifier.rubric"].exists || app.textViews["classifier.rubric"].exists)
        XCTAssertFalse(app.textFields["classifier.options"].exists)
        run(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.score"].waitForExistence(timeout: 5))
        capture("classifier-score-result")
        top(app)
        app.segmentedControls["classifier.type"].buttons["Yes / No"].tap()
        XCTAssertTrue(app.textFields["classifier.trueCriterion"].exists || app.textViews["classifier.trueCriterion"].exists)
        run(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.boolean"].waitForExistence(timeout: 5))
        capture("classifier-boolean-result")
        top(app)
        app.buttons["classifier.unload"].tap()
        XCTAssertTrue(app.buttons["classifier.activate"].waitForExistence(timeout: 5))
    }

    @MainActor func testStopDrainsAndDropsResult() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input", "-classifier-slow"]
        app.launch()
        app.buttons["classifier.activate"].tap()
        XCTAssertTrue(app.buttons["classifier.unload"].waitForExistence(timeout: 5))
        run(app)
        let stop = app.buttons["classifier.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 2))
        stop.tap()
        XCTAssertTrue(app.buttons["classifier.run"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["classifier.result.choice"].exists)
    }

    @MainActor func testAccessibleTaskPickerAndRetainedWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input", "-large-type"]
        app.launch()
        let type = app.buttons["classifier.type"]
        for _ in 0..<5 where !type.isHittable { app.swipeUp() }
        XCTAssertTrue(type.isHittable)
        type.tap()
        app.buttons["Yes / No"].tap()
        XCTAssertTrue(app.textFields["classifier.trueCriterion"].exists || app.textViews["classifier.trueCriterion"].exists)
        capture("classifier-large-type")
        top(app)
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.home"].tap()
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.classifiers"].tap()
        for _ in 0..<5 where !type.isHittable { app.swipeUp() }
        XCTAssertTrue(type.label.contains("Yes / No"))
        XCTAssertTrue(app.textFields["classifier.trueCriterion"].exists || app.textViews["classifier.trueCriterion"].exists)
    }

    @MainActor func testActivationRefusalAndSidebarNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input", "-classifier-refused", "-dark"]
        app.launch()
        app.buttons["classifier.activate"].tap()
        let message = app.staticTexts["classifier.error"]
        for _ in 0..<4 where !message.isHittable { app.swipeUp() }
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("memory"))
        XCTAssertFalse(app.buttons["classifier.run"].isEnabled)
        top(app)
        app.buttons["navigation.menu"].tap()
        XCTAssertTrue(app.buttons["sidebar.classifiers"].waitForExistence(timeout: 5))
        app.buttons["sidebar.classifiers"].tap()
        XCTAssertTrue(app.navigationBars["Classifiers"].waitForExistence(timeout: 5))
    }

    @MainActor private func run(_ app: XCUIApplication) {
        let button = app.buttons["classifier.run"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable && button.isEnabled)
        button.tap()
    }
    @MainActor private func top(_ app: XCUIApplication) {
        // The beta SDK gives some offscreen Form leaves a hittable frame.
        // Move the actual scroll view to the top before selecting another task.
        for _ in 0..<5 { app.swipeDown() }
    }
    @MainActor private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeUIReviewScreenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
