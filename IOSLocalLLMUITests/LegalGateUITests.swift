import XCTest

/// First-launch legal consent is both a privacy boundary and an accessibility
/// boundary. Keep a UI-level regression test in addition to the pure scroll
/// geometry tests so SwiftUI presentation changes cannot silently expose the
/// app behind the mandatory gate or unlock acknowledgement before review.
final class LegalGateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLegalGateIsModalAndRequiresScrollingToDocumentEnd() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITesting",
            "-legalAcceptedVersion", "0",
            "-aiDisclaimerAccepted", "false",
            "-deviceSafetyAccepted", "false",
            "-hasSeenOnboarding", "false",
        ]
        app.launch()

        let privacy = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "privacy policy")
        ).firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 12))

        let continueButton = app.buttons["Review all four to continue"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled)

        // Controls from the presenting hierarchy must not remain reachable
        // while the full-screen legal gate is active.
        XCTAssertFalse(app.tabBars.buttons["Home"].exists)

        privacy.tap()

        let locked = app.buttons["scroll to the end to continue"]
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        XCTAssertFalse(locked.isEnabled)

        let confirmed = app.buttons["i have read this"]
        for _ in 0..<14 where !confirmed.exists {
            app.swipeUp()
        }
        XCTAssertTrue(confirmed.waitForExistence(timeout: 2))
        XCTAssertTrue(confirmed.isEnabled)
        confirmed.tap()

        let progress = app.descendants(matching: .any)["1 of 4 documents reviewed"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
    }
}
