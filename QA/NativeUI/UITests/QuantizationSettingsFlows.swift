import XCTest

final class QuantizationSettingsFlows: XCTestCase {
    @MainActor
    private func tapSwitch(_ toggle: XCUIElement, expecting value: String) {
        // SwiftUI exposes the label and switch as one accessibility frame.
        // Touch the native switch at the trailing end, not the label's center.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
    }

    @MainActor
    func testDefaultOffAndPersistedChoiceCanBeReversed() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "quantization-settings", "-reset-turboquant-setting"]
        app.launch()
        let toggle = app.switches["settings.turboQuantEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        tapSwitch(toggle, expecting: "1")
        app.terminate()
        app.launchArguments = ["-screen", "quantization-settings"]
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        tapSwitch(toggle, expecting: "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "turboquant-settings-default-restored"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLargeTextRetainsToggleAndExplanation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "quantization-settings", "-reset-turboquant-setting", "-large-type"]
        app.launch()
        let toggle = app.switches["settings.turboQuantEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
        let explanation = app.staticTexts["Uses less cache memory for supported text models. Speed and output quality can change. Applies to the next reply."]
        XCTAssertTrue(explanation.exists)
        app.swipeUp()
        XCTAssertTrue(explanation.isHittable, "The full explanation must remain reachable at accessibility text sizes")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "turboquant-settings-large-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
