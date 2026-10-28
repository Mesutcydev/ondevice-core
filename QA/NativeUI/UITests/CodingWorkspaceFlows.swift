import XCTest

final class CodingWorkspaceFlows: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "coding", "-review-language", "en"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["coding.browse"].waitForExistence(timeout: 10))
        return app
    }
    private func open(_ path: String, in app: XCUIApplication) {
        let browse = app.buttons["coding.browse"]
        if browse.exists { browse.tap() } else { app.buttons["coding.files"].tap() }
        let search = app.textFields["coding.files.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if app.buttons["Clear file search"].exists { app.buttons["Clear file search"].tap() }
        XCTAssertEqual(search.value as? String, "Find file")
        search.tap(); search.typeText(path)
        XCTAssertEqual(search.value as? String, path)
        let file = app.buttons["coding.file.\(path)"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        XCTAssertTrue(app.textViews["coding.editor"].waitForExistence(timeout: 5))
        capture("coding-editor-" + path.replacingOccurrences(of: "/", with: "-"))
    }
    private func waitEnabled(_ element: XCUIElement) {
        let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8), .completed)
    }

    func testEditStageReviewDiffAndReturnToChatWithSourceContext() {
        let app = launch()
        open("Sources/Counter.swift", in: app)
        let editor = app.textViews["coding.editor"]
        editor.tap(); editor.typeText("\n// Reviewed on device\n")
        let hide = app.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        let stage = app.buttons["coding.stage"]; waitEnabled(stage); stage.tap()
        let review = app.buttons["coding.review"]; waitEnabled(review); review.tap()
        let message = app.descendants(matching: .any).matching(identifier: "coding.commit.message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5)); message.tap(); message.typeText("Document the counter")
        app.buttons["coding.commit.prepare"].tap()
        let file = app.buttons["github.review.file.Sources/Counter.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 8)); file.tap()
        XCTAssertTrue(app.scrollViews["github.review.diff"].waitForExistence(timeout: 5))
        capture("coding-diff")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["github.review.cancel"].tap()
        XCTAssertTrue(app.buttons["coding.file.actions"].waitForExistence(timeout: 5))
        app.buttons["coding.file.actions"].tap(); app.buttons["Explain selection"].tap()
        let receipt = app.textViews["coding.context.receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue((receipt.value as? String)?.contains("SOURCE Sources/Counter.swift:") == true)
        app.buttons["Code"].tap()
        XCTAssertTrue(app.textViews["coding.editor"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["coding.editor"].value as? String)?.contains("Reviewed on device") == true)
    }

    func testLocalWebPreviewLoadsSiblingCSSAndJavaScriptAndExports() {
        let app = launch()
        open("styles.css", in: app); open("script.js", in: app); open("index.html", in: app)
        app.buttons["coding.preview"].tap()
        let counter = app.webViews.buttons["Count: 0"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10)); counter.tap()
        XCTAssertTrue(app.webViews.buttons["Count: 1"].waitForExistence(timeout: 5))
        capture("coding-preview")
        app.buttons["coding.preview.console"].tap()
        let console = app.descendants(matching: .any)["coding.preview.messages"]
        XCTAssertTrue(console.waitForExistence(timeout: 5))
        let blocked = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
            "coding.preview.console.text", "Blocked by policy: connect-src")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "The real web view must enforce the network policy")
        app.buttons["Phone"].tap()
        app.navigationBars.buttons["Done"].tap()
        app.buttons["coding.tab.styles.css"].tap()
        app.buttons["coding.preview"].tap()
        XCTAssertTrue(app.webViews.buttons["Count: 0"].waitForExistence(timeout: 10), "CSS and JavaScript editing must retain the HTML preview target")
        app.navigationBars.buttons["Done"].tap()
        app.buttons["coding.actions"].tap(); app.buttons["Export open files as ZIP"].tap()
        XCTAssertTrue(app.buttons["coding.export.share"].waitForExistence(timeout: 5))
    }

    func testDarkLargeTypeReadingGuideAndSidebar() {
        let app = launch(["-dark", "-large-type"])
        app.buttons["coding.actions"].tap(); app.buttons["Reading guide"].tap()
        XCTAssertTrue(app.navigationBars["Read repository"].waitForExistence(timeout: 5))
        app.buttons["README.md"].tap()
        XCTAssertTrue(app.textViews["coding.editor"].waitForExistence(timeout: 5))
        app.buttons["coding.file.actions"].tap(); app.buttons["Mark as read"].tap()
        capture("coding-dark-large-type")
        let menu = app.buttons.matching(identifier: "navigation.menu").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(menu); menu?.tap()
        XCTAssertTrue(app.buttons["sidebar.code"].waitForExistence(timeout: 5))
    }

    func testCheckpointRestoreKeepsTheReplacedEditsRecoverable() {
        let app = launch()
        open("README.md", in: app)
        app.buttons["coding.actions"].tap(); app.buttons["Save checkpoint"].tap()
        let editor = app.textViews["coding.editor"]
        editor.tap(); editor.typeText("\nRecovered note\n")
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        app.buttons["coding.actions"].tap(); app.buttons["Checkpoints"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "coding.checkpoint.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String)?.contains("Recovered note") == true)
        app.buttons["coding.actions"].tap(); app.buttons["Checkpoints"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Recovered note") == true)
        capture("coding-checkpoint-restored")
    }

    private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeUIReviewScreenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
