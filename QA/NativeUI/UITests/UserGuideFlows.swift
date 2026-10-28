import XCTest

final class UserGuideFlows: XCTestCase {
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "user-guide", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    @MainActor func testFirstChatStepsAndPreviousBoundary() {
        let app = launch()
        let chapter = app.buttons["guide.chapter.first-chat"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        capture("guide-index")
        chapter.tap()
        XCTAssertTrue(app.staticTexts["guide.step.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Open the app menu")
        XCTAssertFalse(app.buttons["guide.previous"].isEnabled)
        XCTAssertTrue(app.images["guide.screen.UserGuideHome"].exists)
        capture("guide-first-chat")
        for title in ["Go to Models", "Download an Assistant model", "Load the downloaded model", "Send your first message"] {
            app.buttons["guide.next"].tap()
            XCTAssertEqual(app.staticTexts["guide.step.title"].label, title)
        }
        XCTAssertFalse(app.buttons["guide.next"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["guide.complete"].exists)
        app.buttons["guide.previous"].tap()
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Load the downloaded model")
    }

    @MainActor func testModelStatesAndPrivacyDiagrams() {
        let app = launch(extra: ["-dark"])
        reveal(app.buttons["guide.chapter.models"], in: app)
        app.buttons["guide.chapter.models"].tap()
        for _ in 0..<3 { app.buttons["guide.next"].tap() }
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Understand model states")
        XCTAssertTrue(app.descendants(matching: .any)["guide.modelStates"].exists)
        capture("guide-model-states-dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let privacy = app.buttons["guide.chapter.privacy"]
        reveal(privacy, in: app)
        privacy.tap()
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Local inference stays here")
        XCTAssertTrue(app.descendants(matching: .any)["guide.diagram"].exists)
        app.buttons["guide.next"].tap()
        app.buttons["guide.next"].tap()
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Remote features send selected context")
        capture("guide-network-privacy-dark")
    }

    @MainActor func testLargestTextKeepsNavigationReachable() {
        let app = launch(extra: ["-large-type", "-dark", "-width", "320"])
        let first = app.buttons["guide.chapter.first-chat"]
        reveal(first, in: app)
        first.tap()
        XCTAssertTrue(app.staticTexts["guide.step.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["guide.next"].isHittable)
        app.buttons["guide.next"].tap()
        XCTAssertEqual(app.staticTexts["guide.step.title"].label, "Go to Models")
        XCTAssertTrue(app.buttons["guide.previous"].isHittable)
        capture("guide-accessibility-320-dark")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserGuideScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
