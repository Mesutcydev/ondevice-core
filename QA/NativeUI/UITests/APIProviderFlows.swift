import XCTest

final class APIProviderFlows: XCTestCase {
    @MainActor private func launch(_ screen: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", screen, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    @MainActor func testConfigureProviderMaskedKeyRefreshAndManualModel() {
        let app = launch("api-providers", extra: ["-api-empty", "-dark"])
        XCTAssertTrue(app.buttons["api.providers.add"].waitForExistence(timeout: 10))
        app.buttons["api.providers.add"].tap()
        let key = app.secureTextFields["api.provider.key"]
        reveal(key, in: app)
        key.tap()
        key.typeText("fixture-test-key")
        app.buttons["api.provider.save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'api.provider.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture("api-provider-settings")
        row.tap()
        let keyStatus = app.descendants(matching: .any).matching(identifier: "api.provider.keyStatus").firstMatch
        XCTAssertTrue(keyStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(keyStatus.label.contains("Saved in Keychain") || (keyStatus.value as? String ?? "").contains("Saved in Keychain"))
        app.buttons["api.models.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Project model"].waitForExistence(timeout: 5))
        capture("api-provider-models")
        let model = app.textFields["api.modelID"]
        reveal(model, in: app)
        model.tap()
        model.typeText("private-project-model")
        let add = app.buttons["api.models.add"]
        reveal(add, in: app)
        add.tap()
        XCTAssertTrue(app.staticTexts["private-project-model"].waitForExistence(timeout: 5))
        let configure = app.buttons["api.provider.configure"]
        reveal(configure, in: app)
        configure.tap()
        let replacement = app.secureTextFields["api.provider.key"]
        reveal(replacement, in: app)
        XCTAssertFalse((replacement.value as? String ?? "").contains("fixture-test-key"))
        XCTAssertTrue(app.staticTexts["API key saved in Keychain"].exists)
        capture("api-provider-configuration")
    }

    @MainActor func testAPIConsentSelectionAndLocalSwitchPreserveProjectDraft() {
        let app = launch("api-chat", extra: ["-dark"])
        let picker = app.buttons["chat.modelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "chat.modelPicker").count, 1)
        XCTAssertLessThan(picker.frame.maxY, app.frame.midY, "Local model selection belongs in the top bar")
        capture("api-provider-local-chat")
        picker.tap()
        let provider = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'api.provider.'")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["api.providers.manage"].isHittable)
        capture("api-provider-picker")
        app.buttons["api.providers.manage"].tap()
        XCTAssertTrue(app.buttons["api.providers.add"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        let model = app.buttons["api.model.fixture-chat"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(app.buttons["api.consent.cancel"].waitForExistence(timeout: 5))
        app.buttons["api.consent.cancel"].tap()
        model.tap()
        app.buttons["api.consent.accept"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Project model")
        XCTAssertEqual(app.buttons.matching(identifier: "chat.modelPicker").count, 1)
        XCTAssertLessThan(picker.frame.maxY, app.frame.midY, "API selection stays in the top bar")
        let draft = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        XCTAssertEqual(draft.value as? String, "Keep my project draft")
        capture("api-provider-chat")
        picker.tap()
        app.buttons["Qwen3 4B"].tap()
        XCTAssertEqual(picker.value as? String, "Qwen3 4B")
        XCTAssertEqual(app.buttons.matching(identifier: "chat.modelPicker").count, 1)
        XCTAssertLessThan(picker.frame.maxY, app.frame.midY, "Local selection stays in the top bar")
        XCTAssertEqual(draft.value as? String, "Keep my project draft")
        capture("api-provider-local-return")
    }

    @MainActor func testLargeTypeProviderPickerAndConsentRemainReachable() {
        let app = launch("api-chat", extra: ["-large-type"])
        app.buttons["chat.modelPicker"].tap()
        let provider = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'api.provider.'")).firstMatch
        reveal(provider, in: app)
        provider.tap()
        let model = app.buttons["api.model.fixture-vision"]
        reveal(model, in: app)
        model.tap()
        let accept = app.buttons["api.consent.accept"]
        reveal(accept, in: app)
        capture("api-provider-consent-large-type")
        accept.tap()
        let picker = app.buttons["chat.modelPicker"]
        let returnedToChat = NSPredicate { _, _ in picker.isHittable && picker.value as? String == "Project vision" }
        expectation(for: returnedToChat, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(picker.frame.maxY, app.frame.midY)
        capture("api-provider-chat-large-type")
    }

    @MainActor func testInvalidEndpointKeepsEditorOpenWithActionableError() {
        let app = launch("api-providers", extra: ["-api-empty"])
        app.buttons["api.providers.add"].tap()
        app.buttons["api.provider.kind"].tap()
        capture("api-provider-service-menu")
        app.buttons["Custom endpoint"].tap()
        let endpoint = app.textFields["api.provider.endpoint"]
        reveal(endpoint, in: app)
        endpoint.tap()
        endpoint.typeText("http://public.example.com/v1")
        app.buttons["api.provider.save"].tap()
        let error = app.staticTexts["api.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        reveal(error, in: app)
        XCTAssertTrue(error.label.contains("HTTPS"))
        XCTAssertTrue(app.buttons["api.provider.save"].exists)
        capture("api-provider-invalid-endpoint")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // List creates off-screen rows lazily, especially at accessibility sizes.
        // Scroll to the control before requiring its accessibility node to exist.
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1) && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeUIReviewScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
