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

    @MainActor func testAttachedImageKeepsItsFrameThroughStreamingPhases() {
        let app = launch(["-dark", "-agent-waiting", "-agent-image"])
        let image = app.buttons["chat.attached-image.fixture-0"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let initialFrame = image.frame
        // SwiftUI's accessibility frame can include surrounding layout on
        // this simulator runtime; it must remain usable and stable.
        XCTAssertGreaterThanOrEqual(initialFrame.width, 44)
        XCTAssertGreaterThanOrEqual(initialFrame.height, 44)
        app.buttons["chat.fixture.advance"].tap()
        XCTAssertTrue(image.exists)
        XCTAssertEqual(image.frame.minY, initialFrame.minY, accuracy: 2)
        XCTAssertEqual(image.frame.size, initialFrame.size)
        app.buttons["chat.fixture.advance"].tap()
        XCTAssertTrue(image.exists)
        XCTAssertEqual(image.frame.minY, initialFrame.minY, accuracy: 2)
        XCTAssertEqual(image.frame.size, initialFrame.size)
        image.tap()
        XCTAssertTrue(app.staticTexts["chat.fixture.imageSelected"].waitForExistence(timeout: 5))
        capture("agent-chat-image-streaming")
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
        let app = launch(["-agent-completed", "-large-type", "-dark"])
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

    @MainActor func testExpandedToolLogRetainsChoiceAfterDetailsAndShowsFailure() {
        let app = launch(["-agent-completed"])
        let summary = app.buttons["chat.tools.summary"]
        XCTAssertTrue(summary.label.contains("Used 3 tools"))
        XCTAssertTrue(summary.label.contains("1 failed"))
        summary.tap()
        XCTAssertEqual(summary.value as? String, "Expanded")
        app.buttons["chat.tool.00000000-0000-0000-0000-000000000102"].tap()
        XCTAssertEqual(app.staticTexts["chat.tool.details"].label, "Error: could not evaluate expression")
        app.buttons["chat.tool.copy"].tap()
        XCTAssertEqual(app.buttons["chat.tool.copy"].label, "Copied")
        app.buttons["Done"].tap()
        XCTAssertEqual(summary.value as? String, "Expanded")
        capture("agent-chat-tools-expanded")
        summary.tap()
        XCTAssertEqual(summary.value as? String, "Collapsed")
        XCTAssertTrue(app.buttons["chat.tool.00000000-0000-0000-0000-000000000101"].exists)
    }

    @MainActor func testConversationSheetPreservesDraftAndPinAtCompactWidth() {
        let app = launch(["-agent-completed", "-width", "320"])
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap()
        field.typeText("Keep my draft")
        let entered = NSPredicate { _, _ in field.value as? String == "Keep my draft" }
        expectation(for: entered, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["chat.session.open"].tap()
        XCTAssertTrue(app.staticTexts["chat.session.title"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts["chat.session.title"].frame.minY, app.frame.height * 0.35)
        XCTAssertTrue(app.buttons["chat.session.model"].label.contains("Qwen3 4B"))
        app.buttons["chat.session.pin"].tap()
        XCTAssertEqual(app.buttons["chat.session.pin"].label, "Unpin")
        capture("agent-chat-session-compact")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["chat.session.title"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Keep my draft")
        app.buttons["chat.session.open"].tap()
        XCTAssertEqual(app.buttons["chat.session.pin"].label, "Unpin")
        app.buttons["Done"].tap()
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
