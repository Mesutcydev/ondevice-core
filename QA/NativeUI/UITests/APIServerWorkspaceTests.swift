import XCTest

/// Production view and shell; review-only manager never binds a network socket.
final class APIServerWorkspaceTests: XCTestCase {
    @MainActor func testOperatorHomeShowsConnectionModelAndDiagnostics() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api", "-api-running"]
        app.launch()

        XCTAssertTrue(app.staticTexts["OnDevice Max"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["api.parser"].value as? String,
                       "READY, ON DEVICE")
        XCTAssertTrue(app.buttons["Copy IP"].exists)
        XCTAssertTrue(app.buttons["Copy API"].exists)
        XCTAssertTrue(app.buttons["Copy key"].exists)
        XCTAssertTrue(app.buttons["api.share.overview"].exists)
        XCTAssertTrue(app.buttons["api.model"].exists)
        XCTAssertTrue(app.buttons["api.lifecycle"].exists)

        app.buttons["api.debugger"].tap()
        XCTAssertTrue(app.staticTexts["Review destination: DiagnosticsView"].waitForExistence(timeout: 5))
    }

    @MainActor func testGenerationControlsUpdateOnTheServerPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api"]
        app.launch()

        let tools = app.switches["api.generation.tools"]
        for _ in 0..<10 where !tools.isHittable { app.swipeUp() }
        XCTAssertTrue(tools.isHittable)
        let parallel = app.switches["api.generation.parallel"]
        if tools.value as? String == "0" { tools.switches.firstMatch.tap() }
        XCTAssertTrue(parallel.isEnabled)
        tools.switches.firstMatch.tap()
        XCTAssertFalse(parallel.isEnabled)
        tools.switches.firstMatch.tap()
        XCTAssertTrue(parallel.isEnabled)
        XCTAssertTrue(app.steppers["api.generation.maxTokens"].exists)
    }

    @MainActor func testConnectionActionsInDarkLargeType() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api", "-api-running", "-dark", "-large-type"]
        app.launch()

        let share = app.buttons["api.share"]
        for _ in 0..<10 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.buttons["api.key.reveal"].exists)
        XCTAssertTrue(app.buttons["api.key.copy"].exists)
        XCTAssertTrue(app.buttons["api.key.rotate"].exists)

        let directory = URL.documentsDirectory.appendingPathComponent("APIServerScreenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: directory.appendingPathComponent("connection-actions-dark-large-type.png")
        )
    }

    @MainActor func testLiveParserMovesWhileGenerating() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api", "-api-running", "-api-generating"]
        app.launch()

        let parser = app.descendants(matching: .any)["api.parser"]
        XCTAssertTrue(parser.waitForExistence(timeout: 5))
        XCTAssertEqual(parser.value as? String, "STREAMING, 18 tokens per second, ON DEVICE")

        let first = parser.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.11)
        let second = parser.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.11)
        let third = parser.screenshot().pngRepresentation
        XCTAssertTrue(first != second || second != third,
                      "The parser should visibly move while streaming a response")
    }

    @MainActor func testPageNavigationPortEditAndServerLifecycle() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home"]
        app.launch()
        app.buttons["navigation.menu"].tap()
        XCTAssertFalse(app.buttons["sidebar.mac"].exists)
        app.buttons["sidebar.apiServer"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["api.status"].waitForExistence(timeout: 5), true)
        XCTAssertEqual(app.descendants(matching: .any)["api.status"].value as? String, "Stopped")
        XCTAssertEqual(app.sheets.count, 0)

        // The port edits in a focused sheet; Save stays disabled until the
        // value is valid AND changed.
        app.buttons.matching(NSPredicate(format: "identifier == %@", "api.port.row")).firstMatch.tap()
        let port = app.textFields["api.port"]
        XCTAssertTrue(port.waitForExistence(timeout: 5))
        let save = app.buttons["api.port.save"]
        XCTAssertFalse(save.isEnabled)
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "80")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["Enter a port from 1024 through 65535."].exists)
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "12000")
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.waitForExistence(timeout: 2) { hideKeyboard.tap() }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["12000"].waitForExistence(timeout: 5))

        // Navigation keeps the saved configuration.
        // The drawer animates; wait for it to open before choosing a destination.
        for destination in ["sidebar.home", "sidebar.apiServer"] {
            app.buttons["navigation.menu"].firstMatch.tap()
            let row = app.buttons[destination]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                   object: app.buttons["navigation.dismissMenu"])
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        }
        XCTAssertTrue(app.staticTexts["12000"].exists)

        // One lifecycle control owns start and stop.
        let lifecycle = app.buttons["api.lifecycle"]
        lifecycle.tap()
        XCTAssertEqual(app.descendants(matching: .any)["api.status"].value as? String, "Running on port 12000")
        app.buttons["api.restart"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["api.status"].value as? String, "Running on port 12000")

        app.buttons["api.model"].tap()
        XCTAssertTrue(app.staticTexts["Review fixture: downloaded model picker"].waitForExistence(timeout: 5))
        // Dismiss the way a user does: drag the sheet down first. Synthesized
        // events do not always drive iOS 26 interactive dismissal, so fall back
        // to the same Done button the production picker provides.
        let pickerText = app.staticTexts["Review fixture: downloaded model picker"]
        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        dragStart.press(forDuration: 0.2, thenDragTo: dragEnd)
        let dismissedByDrag = app.staticTexts["Review fixture: downloaded model picker"].waitForNonExistence(timeout: 3)
        print("interactive sheet dismissal by drag: \(dismissedByDrag)")
        if !dismissedByDrag {
            app.buttons["picker.done"].tap()
        }
        XCTAssertTrue(pickerText.waitForNonExistence(timeout: 5))

        lifecycle.tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Stopped"),
                                               object: app.descendants(matching: .any)["api.status"])
        let result = XCTWaiter.wait(for: [stopped], timeout: 5)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertEqual(result, .completed)
    }

    @MainActor func testRunningServerConnectionAndKeyControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api", "-api-running"]
        app.launch()
        // OpenAI base, shared Ollama/Anthropic origin, and the on-device address.
        XCTAssertTrue(app.staticTexts["http://192.0.2.1:11434/v1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["http://192.0.2.1:11434"].exists)
        XCTAssertTrue(app.staticTexts["http://localhost:11434"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["api.activity"].value as? String,
                       "Waiting for requests. Requests are answered by the loaded model.")
        XCTAssertTrue(app.descendants(matching: .any)["api.health"].exists)
        app.buttons.matching(NSPredicate(format: "identifier == %@", "api.copy.address")).firstMatch.tap()

        app.buttons["api.key.reveal"].tap()
        XCTAssertTrue(app.staticTexts["review-fixture-key"].exists)
        app.buttons["api.key.copy"].tap()

        // Rotation confirms first; Cancel keeps the working key.
        app.buttons["api.key.rotate"].tap()
        XCTAssertTrue(app.alerts.buttons["Cancel"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["review-fixture-key"].exists)
        app.buttons["api.key.rotate"].tap()
        XCTAssertTrue(app.alerts.buttons["Rotate"].waitForExistence(timeout: 5))
        app.alerts.buttons["Rotate"].tap()
        XCTAssertTrue(app.staticTexts["review-fixture-rotated-key"].waitForExistence(timeout: 5))

        // Connection actions share one visual language, and the sharing
        // surface makes its credential inclusion visible before opening iOS Share.
        let share = app.buttons["api.share"]
        for _ in 0..<6 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(app.staticTexts["Includes the API key"].exists)
        let directory = URL.documentsDirectory.appendingPathComponent("APIServerScreenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: directory.appendingPathComponent("connection-actions.png")
        )

        // Quick start follows the chosen client format and the revealed key.
        let example = app.staticTexts["api.client.example"]
        let copyExample = app.buttons["api.client.example.copy"]
        for _ in 0..<6 where !copyExample.isHittable { app.swipeUp() }
        XCTAssertTrue(example.label.contains("OPENAI_API_KEY=review-fixture-rotated-key"))
        app.segmentedControls.buttons["Anthropic"].tap()
        XCTAssertTrue(example.label.contains("x-api-key: review-fixture-rotated-key"))
        XCTAssertTrue(example.label.contains("local/local_Ornith-1.5-9B-Q5_K_M"))
        copyExample.tap()

        // The catalog includes discovery, model detail, and Ollama probes.
        let endpointCopies = app.buttons.matching(NSPredicate(format: "identifier == %@", "api.endpoint.copy"))
        XCTAssertEqual(endpointCopies.count, 14)
        for _ in 0..<10 where !endpointCopies.element(boundBy: 13).isHittable { app.swipeUp() }
        endpointCopies.element(boundBy: 13).tap()

        // Hiding the key masks both the key row and the example again.
        let reveal = app.buttons["api.key.reveal"]
        // Return to the top before locating the key row. Large endpoint
        // sections can make full-screen reverse swipes skip over that row.
        for _ in 0..<10 { app.swipeDown() }
        for _ in 0..<10 where !reveal.isHittable { app.swipeUp() }
        XCTAssertTrue(reveal.isHittable)
        reveal.tap()
        XCTAssertTrue(app.staticTexts["review-fixture-rotated-key"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(example.label.contains("<API_KEY>"))
    }

    @MainActor func testModelUnloadAndNearbyDevicesSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "api", "-api-running"]
        app.launch()
        let unload = app.buttons["api.model.unload"]
        XCTAssertTrue(unload.waitForExistence(timeout: 5))
        unload.tap()
        XCTAssertTrue(app.buttons["api.model.load"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["api.activity"].value as? String,
                       "Can’t answer yet. No model is loaded. Requests fail until a model loads.")

        let nearby = app.switches["api.peerToPeer"]
        for _ in 0..<10 where !nearby.isHittable { app.swipeUp() }
        XCTAssertEqual(nearby.value as? String, "1")
        nearby.switches.firstMatch.tap()
        XCTAssertEqual(nearby.value as? String, "0")
        // A running listener restarts to apply the setting and stays up.
        XCTAssertEqual(app.descendants(matching: .any)["api.status"].value as? String, "Running on port 11434")
    }

    @MainActor func testLightDarkLargeTextAndStartingFailureStates() {
        let app = XCUIApplication()
        for (name, options) in [("light", [String]()), ("dark", ["-dark"]),
                                ("large-type", ["-large-type"]), ("dark-large-type", ["-dark", "-large-type"]),
                                ("running", ["-api-running"]), ("starting", ["-api-starting"]),
                                ("generating", ["-api-running", "-api-generating"]),
                                ("running-dark-large-type", ["-api-running", "-dark", "-large-type"]),
                                ("failed", ["-api-failed", "Port 11434 is already in use."]),
                                ("model-loading", ["-api-model-loading"]), ("no-model", ["-api-no-model"])] {
            app.launchArguments = ["-screen", "api"] + options
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["api.status"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.sheets.count, 0)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "api-server-\(name)"
            capture.lifetime = .keepAlways
            add(capture)
            let directory = URL.documentsDirectory.appendingPathComponent("APIServerScreenshots")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("server-\(name).png"))
            if options.contains("-api-starting") {
                XCTAssertEqual(app.descendants(matching: .any)["api.status"].value as? String, "Starting")
                XCTAssertFalse(app.buttons["api.lifecycle"].isEnabled)
            }
            if options.contains("-api-no-model") {
                XCTAssertTrue(app.staticTexts["No model selected"].exists)
                XCTAssertTrue(app.staticTexts["Choose a model to serve"].exists)
            }
            app.terminate()
        }
    }
}
