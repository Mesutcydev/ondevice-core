import XCTest

final class ParentalControlFlows: XCTestCase {
    @MainActor
    private func enterPIN(_ pin: String, into field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        for digit in pin {
            let key = keyboard.keys[String(digit)]
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            key.tap()
        }
        XCTAssertEqual((field.value as? String)?.count, pin.count, "The test must deliver every PIN digit before submitting")
    }
    @MainActor
    func testImageStudioRestrictionRequiresParentPINToAllowCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image-parental-controls"]
        app.launch()
        XCTAssertTrue(app.staticTexts["image.parental-restriction"].waitForExistence(timeout: 5))
        let prompt = app.textViews["image.draft.prompt"]
        if prompt.exists { prompt.tap(); prompt.typeText("A green forest") }
        else {
            let field = app.textFields["image.draft.prompt"]
            field.tap(); field.typeText("A green forest")
        }
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        XCTAssertFalse(app.buttons["image.create"].isEnabled)
        let restrictedShot = XCTAttachment(screenshot: app.screenshot())
        restrictedShot.name = "image-studio-parent-restricted"
        restrictedShot.lifetime = .keepAlways
        add(restrictedShot)
        app.buttons["Parental controls"].tap()
        let current = app.secureTextFields["parent.pin.current"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        enterPIN("638192", into: current, in: app)
        app.buttons["parent.images.change"].tap()
        XCTAssertTrue(app.buttons["Restrict image generation"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.staticTexts["image.parental-restriction"].exists)
        XCTAssertTrue(app.buttons["image.create"].isEnabled)
        let allowedShot = XCTAttachment(screenshot: app.screenshot())
        allowedShot.name = "image-studio-parent-allowed"
        allowedShot.lifetime = .keepAlways
        add(allowedShot)
    }
    @MainActor
    func testParentPINControlsImagesAndRejectsWrongPIN() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "parental-controls"]
        app.launch()
        let newPIN = app.secureTextFields["parent.pin.new"]
        XCTAssertTrue(newPIN.waitForExistence(timeout: 5))
        enterPIN("638192", into: newPIN, in: app)
        let confirm = app.secureTextFields["parent.pin.confirm"]
        enterPIN("638192", into: confirm, in: app)
        app.buttons["parent.save"].tap()
        XCTAssertTrue(app.buttons["Allow image generation"].waitForExistence(timeout: 5))
        let current = app.secureTextFields["parent.pin.current"]
        enterPIN("000000", into: current, in: app)
        app.buttons["parent.images.change"].tap()
        XCTAssertTrue(app.staticTexts["Incorrect parent PIN."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Allow image generation"].exists)
        enterPIN("638192", into: current, in: app)
        app.buttons["parent.images.change"].tap()
        XCTAssertTrue(app.buttons["Restrict image generation"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "parent-controls-image-allowed"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testLargeTextSetupIsReadable() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "parental-controls", "-large-type", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Parental controls"].firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "parent-controls-large-text"
        shot.lifetime = .keepAlways
        add(shot)
        let save = app.buttons["parent.save"]
        app.swipeUp()
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable, "Large text must keep the setup action reachable by scrolling")
        XCTAssertTrue(app.secureTextFields["parent.pin.confirm"].exists)
        save.tap()
        XCTAssertTrue(app.staticTexts["Use a six-digit PIN containing only numbers 0–9."].waitForExistence(timeout: 5))
        let setup = XCTAttachment(screenshot: app.screenshot())
        setup.name = "parent-controls-large-text-setup-action"
        setup.lifetime = .keepAlways
        add(setup)
    }
}
