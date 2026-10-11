import XCTest

final class AgentChatFlows: XCTestCase {
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "agent-chat", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["chat.modelPicker"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testLiveTimerToolDetailsCompactionAndStop() {
        let app = launch(["-dark"])
        let notice = app.descendants(matching: .any).matching(identifier: "chat.contextCompaction").firstMatch
        XCTAssertTrue(notice.exists)
        assertCompactionAlignment(app)
        let timer = app.descendants(matching: .any).matching(identifier: "chat.activity.timer").firstMatch
        XCTAssertTrue(timer.exists)
        let original = timer.label
        let advanced = NSPredicate { _, _ in timer.label != original }
        expectation(for: advanced, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["chat.composer.send"].isEnabled)
        capture("agent-chat-live")
        app.buttons["chat.tool.00000000-0000-0000-0000-000000000101"].tap()
        let details = app.staticTexts["chat.tool.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertEqual(details.label, "Read portfolio-homepage.html")
        app.buttons["Done"].tap()
        app.buttons["chat.composer.stop"].tap()
        XCTAssertFalse(timer.exists)
        XCTAssertTrue(app.staticTexts["chat.fixture.completed"].exists)
        let reasoning = app.buttons["chat.reasoning"]
        XCTAssertTrue(reasoning.label.contains("Thought for"))
        reasoning.tap()
        XCTAssertTrue(app.staticTexts["Checking the project structure and existing navigation before proposing a focused update."].exists)
        capture("agent-chat-stopped")
    }

    @MainActor func testWaitingReasoningAndAnswerKeepStreamingIndicatorUntilStop() {
        let app = launch(["-dark", "-agent-waiting"])
        let streaming = app.descendants(matching: .any).matching(identifier: "chat.reply.streaming").firstMatch
        let reasoning = app.buttons["chat.reasoning"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 5))
        XCTAssertTrue(reasoning.label.contains("Reasoning"))
        capture("agent-chat-waiting")
        app.buttons["chat.fixture.advance"].tap()
        XCTAssertTrue(reasoning.label.contains("Reasoning"))
        let liveFrame = reasoning.frame
        XCTAssertEqual(reasoning.value as? String, "Collapsed")
        capture("agent-chat-reasoning")
        app.buttons["chat.fixture.advance"].tap()
        XCTAssertTrue(streaming.label.contains("The answer is streaming"))
        XCTAssertTrue(reasoning.label.contains("Thought for"))
        XCTAssertEqual(reasoning.value as? String, "Collapsed")
        XCTAssertEqual(reasoning.frame.minY, liveFrame.minY, accuracy: 2)
        XCTAssertEqual(reasoning.frame.height, liveFrame.height, accuracy: 2)
        capture("agent-chat-answer-streaming")
        app.buttons["chat.composer.stop"].tap()
        XCTAssertFalse(streaming.exists)
        XCTAssertTrue(app.staticTexts["chat.fixture.completed"].exists)
        XCTAssertTrue(reasoning.exists)
        reasoning.tap()
        XCTAssertTrue(app.staticTexts["Checking the project structure and existing navigation before proposing a focused update."].exists)
    }

    @MainActor func testLiveDisclosureStaysExpandedAcrossAnswerAndCompletion() {
        let app = launch(["-dark"])
        let reasoning = app.buttons["chat.reasoning"]
        reasoning.tap()
        XCTAssertEqual(reasoning.value as? String, "Expanded")
        app.buttons["chat.fixture.advance"].tap()
        XCTAssertEqual(reasoning.value as? String, "Expanded")
        app.buttons["chat.composer.stop"].tap()
        XCTAssertEqual(reasoning.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Checking the project structure and existing navigation before proposing a focused update."].exists)
        capture("agent-chat-reasoning-retained")
    }

    @MainActor func testModelPillAndKeyboardRemainReachableAtLargeType() {
        let app = launch(["-agent-completed", "-large-type"])
        let model = app.buttons["chat.modelPicker"]
        XCTAssertTrue(model.isHittable)
        model.tap()
        XCTAssertTrue(app.staticTexts["Qwen3 4B · UI fixture"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap()
        field.typeText("Keep my draft")
        let draftEntered = NSPredicate { _, _ in field.value as? String == "Keep my draft" }
        expectation(for: draftEntered, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let hide = app.buttons["keyboard.dismiss"]
        XCTAssertTrue(hide.isHittable)
        XCTAssertLessThanOrEqual(hide.frame.minX, field.frame.minX)
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let draftRetained = NSPredicate { _, _ in field.value as? String == "Keep my draft" }
        expectation(for: draftRetained, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(field.value as? String, "Keep my draft")
        assertCompactionAlignment(app)
        capture("agent-chat-large-type")
    }

    @MainActor func testCompactionFitsCompactWidthInLightAppearance() {
        let app = launch(["-agent-completed", "-width", "320"])
        assertCompactionAlignment(app)
        let notice = app.descendants(matching: .any).matching(identifier: "chat.contextCompaction").firstMatch
        XCTAssertEqual(notice.label, "Context compacted")
        XCTAssertTrue((notice.value as? String)?.contains("Qwen3 4B") == true)
        XCTAssertTrue(app.buttons["chat.composer.add"].isHittable)
        capture("agent-chat-compaction-compact-light")
    }

    @MainActor private func assertCompactionAlignment(_ app: XCUIApplication) {
        let notice = app.descendants(matching: .any).matching(identifier: "chat.contextCompaction").firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "chat.composer.panel").firstMatch
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(panel.exists)
        XCTAssertEqual(notice.frame.minX, panel.frame.minX, accuracy: 1)
        XCTAssertEqual(notice.frame.maxX, panel.frame.maxX, accuracy: 1)
        XCTAssertLessThan(notice.frame.maxY, panel.frame.minY)
        XCTAssertGreaterThan(notice.frame.height, 20)
    }

    @MainActor private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeUIReviewScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
