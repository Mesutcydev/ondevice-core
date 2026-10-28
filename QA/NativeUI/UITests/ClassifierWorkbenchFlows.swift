import XCTest

final class ClassifierWorkbenchFlows: XCTestCase {
    @MainActor func testImageInputUsesFixedLabelsAndExportsResult() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-image", "-classifier-input"]
        app.launch()
        XCTAssertTrue(app.buttons["classifier.choosePhoto"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["classifier.instructions"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["classifier.options"].exists)
        app.buttons["classifier.activate"].tap()
        XCTAssertTrue(app.buttons["classifier.unload"].waitForExistence(timeout: 5))
        run(app)
        openTicket(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.choice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "tabby cat").firstMatch.exists)
        XCTAssertTrue(app.buttons["classifier.export"].exists)
        capture("classifier-image-result")
    }

    @MainActor func testSaveTaskAndRestoreItWithoutChangingInput() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input"]
        app.launch()
        reveal(app.buttons["classifier.savedTasks"], in: app)
        app.buttons["classifier.savedTasks"].tap()
        let name = "Message intent \(UUID().uuidString.prefix(8))"
        let field = app.textFields["classifier.savedName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["classifier.saveTask"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        reveal(app.segmentedControls["classifier.type"], in: app)
        app.segmentedControls["classifier.type"].buttons["Yes / No"].tap()
        app.buttons["classifier.savedTasks"].tap()
        saved.tap()
        XCTAssertTrue(app.segmentedControls["classifier.type"].buttons["Choice"].isSelected)
        let input = app.descendants(matching: .any)["classifier.input"]
        for _ in 0..<4 where !input.isHittable { app.swipeUp() }
        XCTAssertEqual(input.value as? String, "The service was very helpful.")
        capture("classifier-restored-task")
    }

    @MainActor func testActivateChooseScoreBooleanAndExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input"]
        app.launch()
        XCTAssertTrue(app.buttons["classifier.activate"].waitForExistence(timeout: 5))
        app.buttons["classifier.activate"].tap()
        XCTAssertTrue(app.buttons["classifier.unload"].waitForExistence(timeout: 5))
        capture("classifier-choice-editor")
        run(app)
        openTicket(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.choice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["classifier.export"].exists)
        capture("classifier-choice-result")
        app.buttons["Done"].tap()
        top(app)
        reveal(app.segmentedControls["classifier.type"], in: app)
        app.segmentedControls["classifier.type"].buttons["Score"].tap()
        app.buttons["classifier.editTask"].tap()
        XCTAssertTrue(app.textFields["classifier.rubric"].exists || app.textViews["classifier.rubric"].exists)
        XCTAssertFalse(app.textFields["classifier.options"].exists)
        app.buttons["Done"].tap()
        run(app)
        openTicket(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.score"].waitForExistence(timeout: 5))
        capture("classifier-score-result")
        app.buttons["Done"].tap()
        top(app)
        reveal(app.segmentedControls["classifier.type"], in: app)
        app.segmentedControls["classifier.type"].buttons["Yes / No"].tap()
        app.buttons["classifier.editTask"].tap()
        XCTAssertTrue(app.textFields["classifier.trueCriterion"].exists || app.textViews["classifier.trueCriterion"].exists)
        app.buttons["Done"].tap()
        run(app)
        openTicket(app)
        XCTAssertTrue(app.descendants(matching: .any)["classifier.result.boolean"].waitForExistence(timeout: 5))
        capture("classifier-boolean-result")
        app.buttons["Done"].tap()
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
        XCTAssertFalse(app.descendants(matching: .any)["classifier.ticket"].exists)
    }

    @MainActor func testPrintedTicketSurvivesEditingAndSidebarNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "classifiers", "-classifier-input"]
        app.launch()
        app.buttons["classifier.activate"].tap()
        run(app)
        let ticket = app.descendants(matching: .any)["classifier.ticket"].firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        capture("classifier-printed-ticket")
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.home"].tap()
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.classifiers"].tap()
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["classifier.input"].firstMatch
        reveal(input, in: app)
        input.tap(); input.typeText(" More input")
        app.buttons["Hide keyboard"].tap()
        top(app)
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["classifier.staleResult"].exists || app.descendants(matching: .any)["classifier.staleResult"].exists)
        capture("classifier-previous-input-ticket")
        run(app)
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["classifier.staleResult"].exists)
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
        reveal(app.buttons["classifier.editTask"], in: app)
        app.buttons["classifier.editTask"].tap()
        let criterion = app.descendants(matching: .any)["classifier.trueCriterion"]
        for _ in 0..<5 where !criterion.exists { app.swipeUp() }
        XCTAssertTrue(criterion.waitForExistence(timeout: 3))
        capture("classifier-large-type")
        app.buttons["Done"].tap()
        top(app)
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.home"].tap()
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.classifiers"].tap()
        for _ in 0..<5 where !type.isHittable { app.swipeUp() }
        XCTAssertTrue(type.label.contains("Yes / No"))
        reveal(app.buttons["classifier.editTask"], in: app)
        app.buttons["classifier.editTask"].tap()
        for _ in 0..<5 where !criterion.exists { app.swipeUp() }
        XCTAssertTrue(criterion.waitForExistence(timeout: 3))
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
    @MainActor private func openTicket(_ app: XCUIApplication) {
        let ticket = app.descendants(matching: .any)["classifier.ticket"].firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(ticket.frame.maxX, app.frame.maxX + 1)
        ticket.tap()
        XCTAssertTrue(app.navigationBars["Result details"].waitForExistence(timeout: 5))
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
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
