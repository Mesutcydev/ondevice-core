import XCTest

/// Presentation fixtures: these tests never claim physical sensor cleanup.
final class RoundTwoFlowTests: XCTestCase {
    @MainActor func testMinimizedVoiceHasOneReturnAndEndOnEveryWorkspaceAndDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "voice", "-image-empty", "-composer-voice"]
        app.launch()
        app.buttons["Start conversation"].tap()
        XCTAssertTrue(app.buttons["End voice conversation"].waitForExistence(timeout: 5))
        app.buttons["Minimize voice conversation"].tap()
        for route in ["home", "chat", "lens", "imageStudio", "models", "device", "apiServer", "voice"] {
            XCTAssertTrue(app.buttons["session.return"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "session.return").count, 1)
            XCTAssertTrue(app.buttons["session.end"].isHittable)
            app.buttons["navigation.menu"].tap()
            capture(app, name: "session-drawer-\(route)")
            XCTAssertTrue(app.buttons["session.end"].isHittable)
            let destination = app.buttons["sidebar.\(route)"]
            for _ in 0..<5 where !destination.isHittable { app.swipeUp() }
            destination.tap()
            XCTAssertTrue(app.buttons["session.return"].waitForExistence(timeout: 5))
            capture(app, name: "session-\(route)")
        }
        XCTAssertFalse(app.buttons["Start conversation"].exists)
        app.buttons["session.return"].tap()
        XCTAssertTrue(app.buttons["End voice conversation"].waitForExistence(timeout: 5))
        app.buttons["Minimize voice conversation"].tap()
        app.buttons["session.end"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["session.return"].exists)
    }

    @MainActor func testLensReviewAnalyzeCancelAndRetakePreserveQuestion() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lens"]
        app.launch()
        let editor = app.descendants(matching: .any).matching(identifier: "lens.instructions").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("What is shown?")
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["lens.primary"].tap()
        capture(app, name: "lens-selected-fixture")
        XCTAssertTrue(app.buttons["Analyze selected image"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Analyzing image"].exists)
        XCTAssertEqual(editor.value as? String, "What is shown?")
        app.buttons["lens.primary"].tap()
        XCTAssertTrue(app.buttons["Stop image analysis"].waitForExistence(timeout: 3))
        app.buttons["Stop image analysis"].tap()
        app.buttons["Retake image"].tap()
        XCTAssertTrue(app.buttons["Capture image"].exists)
        XCTAssertEqual(editor.value as? String, "What is shown?")
    }

    @MainActor func testImageExampleDoesNotSilentlyReplaceDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image", "-image-empty"]
        app.launch()
        app.buttons["Lakeside cabin"].tap()
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Botanical sketch"].tap()
        XCTAssertTrue(app.buttons["Keep draft"].waitForExistence(timeout: 3))
        app.buttons["Keep draft"].tap()
        let editor = app.descendants(matching: .any).matching(identifier: "image.draft.prompt").firstMatch
        XCTAssertEqual(editor.value as? String, "A quiet lakeside cabin at sunrise, soft watercolor")
        app.buttons["Botanical sketch"].tap()
        app.buttons["Replace prompt"].tap()
        XCTAssertEqual(editor.value as? String, "A small botanical garden, detailed pencil illustration")
        XCTAssertFalse(app.buttons["Cancel"].exists)
    }
    @MainActor func testRefinedVoiceDensityAndImageRowsAtMatchedSizes() {
        let app = XCUIApplication()
        for (appearance, options) in [("light", [String]()), ("dark", ["-dark"]),
                                      ("light-large", ["-large-type"]), ("dark-large", ["-dark", "-large-type"])] {
            for route in ["voice", "image"] {
                app.launchArguments = ["-screen", route, "-image-empty", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + options
                app.launch()
                XCTAssertTrue(app.buttons["navigation.menu"].waitForExistence(timeout: 5))
                capture(app, name: "matrix-\(Int(app.frame.width))-\(route)-\(appearance)", folder: "NativeUIReviewScreenshots")
                if route == "voice" {
                    let primary = app.buttons["Start conversation"]
                    if !options.contains("-large-type") {
                        let completeRows = ["Alloy", "Aoede", "Bella", "Heart", "Jessica", "Nicole"].filter {
                            let row = app.buttons["\($0), English, United States"]
                            return row.exists && row.isHittable && row.frame.maxY <= primary.frame.minY
                        }
                        XCTAssertGreaterThanOrEqual(completeRows.count, app.frame.width >= 440 ? 6 : 5)
                    }
                    let last = app.cells.containing(.button, identifier: "Nicole, English, United States").firstMatch.buttons["Preview Nicole"]
                    for _ in 0..<10 where !last.isHittable || last.frame.maxY > primary.frame.minY { app.swipeUp() }
                    XCTAssertTrue(last.isHittable)
                    XCTAssertLessThanOrEqual(last.frame.maxY, primary.frame.minY)
                    capture(app, name: "matrix-\(Int(app.frame.width))-voice-bottom-\(appearance)", folder: "NativeUIReviewScreenshots")
                }
                app.terminate()
            }
        }
    }

    @MainActor func testSessionAccessoryStaysAboveEveryEditorKeyboard() {
        let app = XCUIApplication()
        for options in [[String](), ["-large-type", "-dark"]] {
            for (route, identifier) in [("composer", "chat.composer.text"), ("lens", "lens.instructions"), ("image", "image.draft.prompt")] {
                app.launchArguments = ["-screen", route, "-image-empty", "-voice-active", "-composer-voice"] + options
                app.launch()
                let editor = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                editor.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                let end = app.buttons["session.end"]
                XCTAssertEqual(app.buttons.matching(identifier: "session.return").count, 1)
                XCTAssertTrue(end.isHittable)
                XCTAssertLessThanOrEqual(end.frame.maxY, app.keyboards.firstMatch.frame.minY)
                capture(app, name: "session-keyboard-\(route)-\(options.isEmpty ? "standard" : "large")")
                app.buttons["keyboard.dismiss"].tap()
                if route == "lens" {
                    let primary = app.buttons["lens.primary"]
                    for _ in 0..<6 where !primary.isHittable { app.scrollViews.firstMatch.swipeUp() }
                    XCTAssertTrue(primary.isHittable)
                    XCTAssertTrue(app.buttons["session.end"].isHittable)
                    capture(app, name: "session-lens-controls-\(options.isEmpty ? "standard" : "large")")
                }
                app.terminate()
            }
        }
    }

    @MainActor func testSettingsKeepsOngoingSessionReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home", "-voice-active"]
        app.launch()
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["session.return"].waitForExistence(timeout: 5))
        capture(app, name: "session-settings")
        app.buttons["session.return"].tap()
        XCTAssertTrue(app.buttons["Minimize voice conversation"].waitForExistence(timeout: 5))
        capture(app, name: "session-return-from-settings")
        app.buttons["Minimize voice conversation"].tap()
        XCTAssertTrue(app.buttons["session.end"].waitForExistence(timeout: 5))
        app.buttons["session.end"].tap()
        XCTAssertFalse(app.buttons["session.return"].exists)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String, folder: String = "RoundTwoScreenshots") {
        Thread.sleep(forTimeInterval: 0.6) // Let the native drawer spring settle before saving pixels.
        let directory = URL.documentsDirectory.appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

}
