import XCTest

final class GitHubFlows: XCTestCase {
    @MainActor private func launch(_ screen: String = "github-chat", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", screen, "-dark", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    @MainActor func testDefaultOffAndSettingsOptInKeepTheComposerAndTopModelPicker() {
        let app = launch()
        XCTAssertTrue(app.buttons["chat.modelPicker"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat.repositoryPicker"].exists)
        openSettings(app)
        let toggle = app.switches["github.tools.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        capture("github-settings-default-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["Done"].tap()
        let selector = app.buttons["chat.repositoryPicker"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        XCTAssertEqual(selector.value as? String, "No repository selected")
        XCTAssertLessThan(selector.frame.maxY, app.frame.midY)
        select(app, branch: "main")
        XCTAssertEqual(selector.value as? String, "preview/project · main")
        XCTAssertEqual(composer(app).value as? String, "Keep my repository draft")
        XCTAssertEqual(app.buttons.matching(identifier: "chat.modelPicker").count, 1)
        capture("github-repository-chat")
        openSettings(app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(selector.exists)
        XCTAssertEqual(composer(app).value as? String, "Keep my repository draft")
    }

    @MainActor func testReviewCancelRetainsDraftAndApprovalPublishesReviewedFiles() {
        let app = launch(extra: ["-github-enabled", "-github-selected"])
        XCTAssertTrue(app.buttons["chat.repositoryPicker"].waitForExistence(timeout: 10))
        app.buttons["github.fixture.menu"].tap()
        app.buttons["github.fixture.stage"].tap()
        let review = app.buttons["chat.repositoryReview"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let file = app.buttons["github.review.file.README.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        capture("github-review-draft")
        file.tap()
        let content = app.staticTexts["github.review.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(content.label.contains("After review."))
        app.buttons["Before"].tap()
        XCTAssertTrue(content.label.contains("Before."))
        capture("github-review-file")
        app.buttons["Review changes"].tap()
        app.buttons["github.review.cancel"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let approve = app.buttons["github.review.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        let result = app.staticTexts["github.fixture.result"]
        let committed = NSPredicate { _, _ in result.label.contains("Committed 1 reviewed file") && !review.exists }
        expectation(for: committed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(composer(app).value as? String, "Keep my repository draft")
        capture("github-reviewed-commit")
    }

    @MainActor func testLargeTypeRepoBranchPickerAndSettingsStayReachable() {
        let app = launch(extra: ["-github-enabled", "-large-type"])
        XCTAssertTrue(app.buttons["chat.repositoryPicker"].waitForExistence(timeout: 10))
        select(app, branch: "feature/ui", capturePicker: true)
        XCTAssertEqual(app.buttons["chat.repositoryPicker"].value as? String, "preview/project · feature/ui")
        XCTAssertEqual(composer(app).value as? String, "Keep my repository draft")
        capture("github-repository-large-type")
        openSettings(app)
        let toggle = app.switches["github.tools.enabled"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.isHittable)
        capture("github-settings-large-type")
    }

    @MainActor func testTokenFieldIsSecureAndNeverPrefilledWithStoredCredential() {
        let app = launch("github-settings", extra: ["-github-disconnected"])
        app.buttons["github.useToken"].tap()
        let token = app.secureTextFields["github.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields.matching(identifier: "github.token").allElementsBoundByIndex.isEmpty)
        token.tap()
        token.typeText("fixture-github-token-only")
        app.buttons["github.token.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "github.account").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(token.exists)
        XCTAssertEqual(app.switches["github.tools.enabled"].value as? String, "0")
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        app.buttons["github.fixture.menu"].tap()
        app.buttons["github.fixture.settings"].tap()
        XCTAssertTrue(app.switches["github.tools.enabled"].waitForExistence(timeout: 5))
    }
    @MainActor private func select(_ app: XCUIApplication, branch: String, capturePicker: Bool = false) {
        app.buttons["chat.repositoryPicker"].tap()
        let repository = app.buttons["github.repo.preview/project"]
        reveal(repository, in: app)
        if capturePicker { capture("github-repository-picker-large-type") }
        repository.tap()
        let branch = app.buttons["github.branch.\(branch)"]
        reveal(branch, in: app)
        if capturePicker { capture("github-branch-picker-large-type") }
        branch.tap()
        XCTAssertTrue(app.buttons["chat.repositoryPicker"].waitForExistence(timeout: 5))
    }
    @MainActor private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }
    @MainActor private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeUIReviewScreenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
