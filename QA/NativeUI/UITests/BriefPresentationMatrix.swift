import XCTest

/// Actual app-owned views with explicitly review-only service snapshots.
/// Run on compact and large iPhones; no inference or microphone results are implied.
final class BriefPresentationMatrix: XCTestCase {
    @MainActor func testVoiceSessionControlsAndLargeTextScroll() {
        let app = XCUIApplication()
        for (appearance, options) in [("light", [String]()), ("dark", ["-dark"]),
                                      ("light-large", ["-large-type"]), ("dark-large", ["-dark", "-large-type"])] {
            app.launchArguments = ["-screen", "voice", "-AppleLanguages", "(en)"] + options
            app.launch()
            app.buttons["Start conversation"].tap()
            let end = app.buttons["End voice conversation"]
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            XCTAssertTrue(end.isHittable)
            capture("matrix-\(Int(app.frame.width))-session-\(appearance)")
            // At accessibility sizes, identity/notice and live state scroll
            // while playback, microphone and End remain independently usable.
            let state = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Go ahead")).firstMatch
            for _ in 0..<5 where !state.isHittable || state.frame.maxY > end.frame.minY { app.swipeUp() }
            XCTAssertTrue(state.isHittable)
            XCTAssertLessThanOrEqual(state.frame.maxY, end.frame.minY)
            capture("matrix-\(Int(app.frame.width))-session-scrolled-\(appearance)")
            app.buttons["Mute playback"].tap()
            XCTAssertTrue(app.buttons["Unmute playback"].exists)
            XCTAssertTrue(app.buttons["Mute microphone"].exists)
            app.buttons["Mute microphone"].tap()
            XCTAssertTrue(app.buttons["Unmute microphone"].exists)
            end.tap()
            XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor func testEightScreensInLightDarkAndLargeText() {
        let app = XCUIApplication()
        for (appearance, options) in [("light", [String]()), ("dark", ["-dark"]),
                                      ("light-large", ["-large-type"]), ("dark-large", ["-dark", "-large-type"])] {
            for screen in ["home", "drawer", "conversation", "voice", "session", "image", "models", "device"] {
                let route = screen == "drawer" ? "home" : screen == "session" ? "voice" : screen == "conversation" ? "composer" : screen
                app.launchArguments = ["-screen", route, "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-image-empty", "-response-actions", "-composer-voice"] + options
                app.launch()
                XCTAssertTrue(app.buttons["navigation.menu"].waitForExistence(timeout: 10))
                if screen == "drawer" { app.buttons["navigation.menu"].tap() }
                if screen == "session" {
                    app.buttons["Start conversation"].tap()
                    XCTAssertTrue(app.buttons["End voice conversation"].waitForExistence(timeout: 5))
                }
                capture("matrix-\(Int(app.frame.width))-\(screen)-\(appearance)")
                if screen == "voice" {
                    // List virtualizes offscreen rows. Counting currently exposed
                    // buttons would only prove the last visible row, not the end.
                    let last = app.cells.containing(.button, identifier: "Nicole, English, United States")
                        .firstMatch.buttons["Preview Nicole"]
                    for _ in 0..<10 where !last.isHittable || last.frame.maxY > app.buttons["Start conversation"].frame.minY {
                        app.swipeUp()
                    }
                    XCTAssertTrue(last.isHittable)
                    XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["Start conversation"].frame.minY)
                    capture("matrix-\(Int(app.frame.width))-voice-bottom-\(appearance)")
                }
                if screen == "drawer" {
                    let last = app.buttons["sidebar.apiServer"]
                    for _ in 0..<10 where !last.isHittable {
                        app.swipeUp()
                    }
                    XCTAssertTrue(last.isHittable)
                    capture("matrix-\(Int(app.frame.width))-drawer-bottom-\(appearance)")
                }
                if screen == "device" {
                    let advanced = app.descendants(matching: .any).matching(identifier: "device.advanced").firstMatch
                    for _ in 0..<10 where !advanced.isHittable { app.swipeUp() }
                    if !app.buttons["Quality evaluation"].exists { advanced.tap() }
                    for _ in 0..<10 where !app.buttons["Quality evaluation"].isHittable { app.swipeUp() }
                    XCTAssertTrue(app.buttons["Quality evaluation"].isHittable)
                    capture("matrix-\(Int(app.frame.width))-device-bottom-\(appearance)")
                }
                app.terminate()
            }
        }
    }

    @MainActor func testImageFailureRetryCancellationAndPermissionState() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image", "-image-empty", "-image-failure"]
        app.launch()
        app.buttons["Lakeside cabin"].tap()
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Review fixture: image model could not load."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry"].isEnabled)
        let field = app.descendants(matching: .any).matching(identifier: "image.draft.prompt").firstMatch
        XCTAssertEqual(field.value as? String, "A quiet lakeside cabin at sunrise, soft watercolor")
        capture("brief-image-failure")
        app.terminate()
        app.launchArguments = ["-screen", "image", "-image-empty"]
        app.launch()
        app.buttons["Lakeside cabin"].tap()
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "A quiet lakeside cabin at sunrise, soft watercolor")
        app.terminate()
        app.launchArguments = ["-screen", "voice", "-voice-denied"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "permission denied")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mute microphone"].isEnabled)
        capture("brief-voice-permission-denied-fixture")
    }

    @MainActor func testVoiceSetupAPIServerAndDeviceDetailsDispatch() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "voice", "-voice-setup", "-action-probe"]
        app.launch()
        XCTAssertFalse(app.buttons["Start conversation"].isEnabled)
        app.buttons["Voice setup"].tap()
        XCTAssertEqual(app.staticTexts["fixture.action"].label, "selectEngine")
        app.buttons["navigation.menu"].tap()
        let mac = app.buttons["sidebar.apiServer"]
        for _ in 0..<5 where !mac.isHittable { app.swipeUp() }
        XCTAssertTrue(mac.isHittable)
        mac.tap()
        XCTAssertTrue(app.buttons["api.lifecycle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0)
        app.terminate()
        app.launchArguments = ["-screen", "device"]
        app.launch()
        XCTAssertFalse(app.staticTexts["device.model.identifier"].exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ornith 1.5 9B")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["device.model.identifier"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["App memory footprint"].exists)
    }

    @MainActor func testImageOptionsMatchEngineCapabilities() {
        let app = XCUIApplication()
        for turbo in [false, true] {
            app.launchArguments = ["-screen", "image"] + (turbo ? ["-image-turbo"] : [])
            app.launch()
            app.buttons["image.model"].tap()
            app.buttons["Generation options"].tap()
            XCTAssertTrue(app.staticTexts["Generation steps"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.textFields["Negative prompt"].exists, !turbo)
            app.terminate()
        }
    }

    @MainActor func testModelPreparationFailureAndDownloadActions() {
        let app = XCUIApplication()
        for state in ["-model-loading", "-model-failed"] {
            app.launchArguments = ["-screen", "models", "-model-actions", "-action-probe", state]
            app.launch()
            app.buttons["model.row.local/local_Ornith-1.5-9B-Q5_K_M"].tap()
            if state == "-model-loading" {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Preparing model")).firstMatch.waitForExistence(timeout: 3))
                XCTAssertFalse(app.buttons["Try again"].exists)
            } else {
                XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 3))
                app.buttons["Try again"].tap()
                let action = app.staticTexts["fixture.action"]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                XCTAssertTrue(action.label.contains("loadModel"))
            }
            capture("brief-model\(state)")
            app.terminate()
        }
        for downloading in [false, true] {
            app.launchArguments = ["-screen", "models", "-model-actions", "-action-probe"]
                + (downloading ? ["-model-downloading"] : [])
            app.launch()
            app.buttons["models.scope.discover"].tap()
            let download = app.buttons["Download Review catalog model"]
            if downloading {
                XCTAssertFalse(download.exists)
                app.buttons["model.row.review/catalog-model"].tap()
                XCTAssertTrue(app.progressIndicators["Model download progress"].waitForExistence(timeout: 3))
                XCTAssertFalse(app.buttons["Open catalog"].exists)
            } else {
                XCTAssertTrue(download.isHittable)
                capture("brief-model-discover-card")
                download.tap()
                XCTAssertTrue(app.staticTexts["fixture.action"].label.contains("download"))
                app.buttons["model.row.review/catalog-model"].tap()
                XCTAssertTrue(app.staticTexts["Not provided"].exists)
            }
            capture(downloading ? "brief-model-downloading" : "brief-model-download-details")
            app.terminate()
        }
    }

    @MainActor private func capture(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeUIReviewScreenshots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
            let attachment = XCTAttachment(string: "Native screenshot: \(url.path)")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        } catch { XCTFail("Screenshot could not be saved: \(error)") }
    }
}
