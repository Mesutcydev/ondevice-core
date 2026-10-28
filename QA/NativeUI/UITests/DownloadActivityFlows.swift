import XCTest

final class DownloadActivityFlows: XCTestCase {
    @MainActor func testActivityStartsAndCancels() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-screen", "download-activity"]
        app.launch()
        let start = app.buttons["download.activity.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let status = app.staticTexts["download.activity.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        if status.label == "Live Activity unavailable" {
            throw XCTSkip("This simulator does not permit ActivityKit requests; shipping widget content is still rendered here.")
        }
        XCTAssertEqual(status.label, "Live Activity started")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Activity system compact"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.activate()
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["download.activity.cancel"].tap()
        let requested = expectation(for: NSPredicate(format: "label == %@", "Cancel requested"),
                                    evaluatedWith: app.staticTexts["download.activity.status"])
        wait(for: [requested], timeout: 5)
        let count = app.staticTexts["download.activity.count"]
        let ended = expectation(for: NSPredicate(format: "label == %@", "Active activities: 0"), evaluatedWith: count)
        wait(for: [ended], timeout: 10)
    }
}
