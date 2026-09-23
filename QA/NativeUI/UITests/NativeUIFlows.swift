import XCTest

final class NativeUIFlows: XCTestCase {
    @MainActor func testImageExamplesSetupAndDraftSurviveWorkspaceNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image", "-image-empty", "-image-no-model"]
        app.launch()
        let example = app.buttons["Lakeside cabin"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        capture("brief-image-empty-light")
        example.tap()
        let field = app.descendants(matching: .any).matching(identifier: "image.draft.prompt").firstMatch
        XCTAssertEqual(field.value as? String, "A quiet lakeside cabin at sunrise, soft watercolor")
        XCTAssertFalse(app.buttons["Cancel"].exists)
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Choose model"].tap()
        XCTAssertTrue(app.navigationBars["Image models"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        navigate(app, to: "models")
        navigate(app, to: "imageStudio")
        XCTAssertEqual(field.value as? String, "A quiet lakeside cabin at sunrise, soft watercolor")
    }

    @MainActor func testResponseActionsDiscloseMetadata() {
        let app = launch(["-response-actions", "-composer-voice"])
        XCTAssertFalse(app.staticTexts["local_Ornith-1.5-9B-Q5_K_M · 16s"].exists)
        app.buttons["Copy"].tap()
        XCTAssertEqual(app.staticTexts["submission.status"].label, "Copied")
        app.buttons["More response actions"].tap()
        XCTAssertTrue(app.buttons["Read aloud"].exists)
        XCTAssertTrue(app.buttons["Share response"].exists)
        app.buttons["Response details"].tap()
        XCTAssertTrue(app.staticTexts["local_Ornith-1.5-9B-Q5_K_M · 16s"].waitForExistence(timeout: 3))
        capture("brief-response-details")
    }

    @MainActor func testGenerationFailureRetryKeepsNextDraft() {
        let app = launch(["-generation-failed", "-dark", "-width", "320"])
        XCTAssertTrue(app.staticTexts["Couldn't finish the reply"].exists)
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap()
        field.typeText("Keep this next question")
        app.buttons["Hide keyboard"].tap()
        capture("audit-generation-failure-dark-320")
        app.buttons["chat.reply.retry"].tap()
        XCTAssertTrue(app.buttons["chat.composer.stop"].waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Keep this next question")
        XCTAssertFalse(app.staticTexts["Couldn't finish the reply"].exists)
    }
    @MainActor func testVoiceAndModelSearchStayAboveContentAndFooter() {
        let app = XCUIApplication()
        for screen in ["voice", "models"] {
            app.launchArguments = ["-screen", screen, "-dark", "-voice-active", "-AppleLanguages", "(en)"]
            app.launch()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertLessThan(field.frame.midY, app.frame.height * 0.45,
                              "Search must remain in the top navigation drawer, not stack with the bottom action")
            capture("audit-\(screen)-search-top-dark")
            field.tap()
            field.typeText(screen == "voice" ? "Alloy" : "Ornith")
            if screen == "voice" {
                XCTAssertTrue(app.buttons["Alloy, English, United States"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.buttons["session.return"].isHittable,
                              "The session remains reachable above the search keyboard")
            }
            capture("audit-\(screen)-search-keyboard-dark")
            app.terminate()
        }
    }
    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "composer", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons[arguments.contains("-composer-voice") && !arguments.contains("-image-attachments") ? "chat.composer.voice" : "chat.composer.send"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor func testEmptySendVisibleAndAttachmentRemoval() {
        let app = launch()
        XCTAssertFalse(app.buttons["chat.composer.send"].isEnabled)
        capture("composer-empty")
        app.buttons["chat.composer.add"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)
        XCTAssertTrue(app.buttons["chat.composer.send"].isEnabled)
        app.buttons["Remove notes.txt"].tap()
        XCTAssertFalse(app.staticTexts["notes.txt"].exists)
        XCTAssertFalse(app.buttons["chat.composer.send"].isEnabled)
    }
    @MainActor func testReturnInsertsNewlineAndSendTurnsIntoStop() {
        let app = launch(["-attachments"])
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("First line\nSecond line")
        XCTAssertTrue((field.value as? String ?? "").contains("First line\nSecond line"))
        XCTAssertFalse(app.buttons["chat.composer.stop"].exists)
        capture("composer-multiline-keyboard")
        app.buttons["chat.composer.send"].tap()
        XCTAssertTrue(app.buttons["chat.composer.stop"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["notes.txt"].exists)
        XCTAssertTrue(app.staticTexts["submission.status"].label.contains("file-1"))
        app.buttons["chat.composer.stop"].tap()
        XCTAssertTrue(app.buttons["chat.composer.send"].exists)
    }
    @MainActor func testRejectedSubmissionPreservesDraftAndAttachments() {
        let app = launch(["-reject", "-attachments"])
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap(); field.typeText("Keep this draft")
        XCTAssertEqual(field.value as? String, "Keep this draft", "Verify keyboard synthesis before testing rejection")
        app.buttons["chat.composer.send"].tap()
        XCTAssertEqual(field.value as? String, "Keep this draft")
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)
        XCTAssertEqual(app.staticTexts["submission.status"].label, "Not accepted")
    }
    @MainActor func testImageOriginalPromptSurvivesNextDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image"]
        app.launch()
        let caption = app.staticTexts["image.result.prompt"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        let original = caption.label
        let field = app.descendants(matching: .any).matching(identifier: "image.draft.prompt").firstMatch
        field.tap(); field.typeText("A different landscape")
        XCTAssertEqual(caption.label, original)
        capture("image-result-next-draft")
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.swipeUp()
        capture("image-result-caption")
    }
    @MainActor func testComposerVoiceSendStopAndImagePreviews() {
        let app = launch(["-composer-voice", "-image-attachments"])
        let first = app.descendants(matching: .any).matching(identifier: "chat.attachment.preview.image-1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(first.frame.height, 96)
        XCTAssertTrue(app.buttons["Remove Image 1"].isHittable)
        capture("reference-composer-images-light")
        app.buttons["Remove Image 1"].tap()
        XCTAssertFalse(first.exists)
        XCTAssertTrue(app.buttons["Remove Image 2"].exists)
        app.buttons["Remove Image 2"].tap()
        let voice = app.buttons["chat.composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        voice.tap()
        XCTAssertTrue(app.buttons["End voice conversation"].waitForExistence(timeout: 3))
        app.buttons["End voice conversation"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap(); field.typeText("A new thought")
        XCTAssertFalse(voice.exists)
        XCTAssertTrue(app.buttons["chat.composer.send"].isEnabled)
        capture("reference-composer-typing-light")
        app.buttons["chat.composer.send"].tap()
        XCTAssertTrue(app.buttons["chat.composer.stop"].exists)
        app.buttons["chat.composer.stop"].tap()
        XCTAssertTrue(voice.exists)
        app.terminate()
        app.launchArguments = ["-screen", "composer", "-composer-voice", "-image-attachments", "-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Remove Image 1"].waitForExistence(timeout: 5))
        capture("reference-composer-images-dark")
    }

    @MainActor func testChatsAndDrawerHaveDistinctPurposes() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home", "-short-history"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Workspaces"].exists)
        XCTAssertTrue(app.buttons["home.conversation.day"].exists)
        capture("brief-chats-light")
        openMenu(app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.conversation.'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Create"].exists)
        XCTAssertTrue(app.staticTexts["Manage"].exists)
        capture("brief-drawer-light")
        dismissMenu(app)
        for (route, title) in [("lens", "Lens"), ("voice", "Voices"), ("imageStudio", "Image studio"), ("models", "Models"), ("device", "Device")] {
            navigate(app, to: route)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
        }
    }

    @MainActor func testSidebarDarkOLEDAndAccessibleControls() {
        let app = XCUIApplication()
        for (name, options) in [("dark", ["-dark"]), ("oled-large", ["-oled", "-large-type", "-width", "320"])] {
            app.launchArguments = ["-screen", "home", "-short-history"] + options
            app.launch()
            XCTAssertTrue(app.buttons["home.newChat"].waitForExistence(timeout: 5))
            capture("reference-home-\(name)")
            openMenu(app)
            XCTAssertTrue(app.buttons["sidebar.newChat"].isHittable)
            XCTAssertTrue(app.buttons["sidebar.settings"].isHittable)
            XCTAssertLessThan(app.staticTexts["sidebar.title"].frame.height, 80, "The brand must not wrap into fragments")
            XCTAssertLessThan(app.buttons["sidebar.newChat"].frame.height, 120, "Chat must remain a readable control")
            capture("reference-sidebar-\(name)")
            let models = app.buttons["sidebar.models"]
            for _ in 0..<4 where !models.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(models.isHittable)
            models.tap()
            XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor private func capture(_ name: String) {
        // Xcode 27 beta can stall while finalizing large-simulator result bundles.
        // Keep the native PNG in this isolated runner's container and attach its
        // location as text; the validation script copies the originals to build/.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeUIReviewScreenshots", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
        } catch {
            XCTFail("Could not save native screenshot: \(error)")
        }
        let attachment = XCTAttachment(string: "Native screenshot: \(url.path)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["navigation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["navigation.dismissMenu"].waitForExistence(timeout: 3))
    }

    @MainActor private func dismissMenu(_ app: XCUIApplication) {
        let control = app.buttons["navigation.dismissMenu"]
        let visible = control.frame.intersection(app.frame)
        XCTAssertFalse(visible.isEmpty)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX, dy: visible.midY)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
    }

    @MainActor private func navigate(_ app: XCUIApplication, to destination: String) {
        openMenu(app)
        let row = app.buttons["sidebar.\(destination)"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
    }

    @MainActor func testSidebarDestinationsAndModelReadiness() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "conversation", "-model-unloaded", "-AppleLanguages", "(en)"]
        app.launch()
        openMenu(app)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        for id in ["home", "chat", "lens", "voice", "imageStudio", "models", "device", "settings", "newChat"] {
            XCTAssertTrue(app.buttons["sidebar.\(id)"].exists, "Missing sidebar destination: \(id)")
        }
        capture("sidebar-light")
        dismissMenu(app)
        navigate(app, to: "models")
        let modelRow = app.buttons["model.row.local/local_Ornith-1.5-9B-Q5_K_M"]
        modelRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Load model"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Loaded"].exists)
        capture("model-installed-unloaded")
    }

    @MainActor func testVoiceActionsStayIndependentAndMinimizePreservesSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "voice", "-reduce-motion", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["Preview Alloy"].waitForExistence(timeout: 10))
        // Xcode 27 beta reports a negative x for glass buttons inside List rows.
        // The row is the stable accessibility container; tap the visible trailing
        // preview control inside it, then assert selection did not change.
        let alloyRow = app.cells.containing(.button, identifier: "Preview Alloy").firstMatch
        XCTAssertTrue(alloyRow.isHittable)
        alloyRow.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["voice.current.name"].label, "Nicole")
        XCTAssertTrue(app.buttons["Stop Alloy preview"].exists)
        app.buttons["Alloy, English, United States"].tap()
        XCTAssertEqual(app.staticTexts["voice.current.name"].label, "Alloy")
        app.buttons["Start conversation"].tap()
        XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 3))
        app.buttons["Mute playback"].tap()
        XCTAssertTrue(app.buttons["Mute microphone"].exists)
        app.buttons["Mute microphone"].tap()
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        capture("voice-muted")
        app.buttons["Minimize voice conversation"].tap()
        XCTAssertTrue(app.buttons["session.return"].waitForExistence(timeout: 3))
        app.buttons["session.return"].tap()
        XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 3))
        app.buttons["End voice conversation"].tap()
        XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 3))
    }

    @MainActor func testCompactComposerAndCameraPermissionState() {
        let app = launch(["-compact", "-attachments", "-no-microphone"])
        XCTAssertFalse(app.buttons["Microphone"].exists)
        XCTAssertTrue(app.buttons["chat.composer.send"].isHittable)
        capture("composer-320-attachments-no-mic")
        app.terminate()
        app.launchArguments = ["-screen", "lens", "-camera-denied"]
        app.launch()
        XCTAssertTrue(app.buttons["Open camera settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Capture image"].isEnabled)
        capture("lens-camera-denied")
    }

    @MainActor func testLargeTypeComposerKeepsActionsReachable() {
        let app = launch(["-large-type", "-attachments", "-dark"])
        XCTAssertTrue(app.buttons["chat.composer.add"].isHittable)
        XCTAssertTrue(app.buttons["chat.composer.send"].isHittable)
        capture("composer-accessibility-xxxl-attachments")
    }

    @MainActor func testSidebarSelectionReachesHostCameraLifecycle() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "conversation", "-host-selection-probe"]
        app.launch()
        let selection = app.staticTexts["host.selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 10))
        XCTAssertEqual(selection.label, "chat")
        for (title, value) in [("lens", "lens"), ("voice", "voice"), ("lens", "lens"), ("chat", "chat"), ("models", "models"), ("home", "home")] {
            navigate(app, to: title)
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: selection)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 3), .completed,
                           "The visible page and host camera lifecycle must agree")
        }
    }

    @MainActor func testPolishedScreensAndActiveVoiceReturnFromModels() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "voice", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 10))
        capture("polish-voices-light")
        app.buttons["Start conversation"].tap()
        XCTAssertTrue(app.buttons["Minimize voice conversation"].waitForExistence(timeout: 3))
        capture("polish-voice-session-light")
        app.buttons["Minimize voice conversation"].tap()
        navigate(app, to: "models")
        let resume = app.buttons["session.return"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        XCTAssertTrue(resume.isHittable)
        capture("polish-models-active-voice")
        resume.tap()
        XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 3))
        app.buttons["Minimize voice conversation"].tap()
        app.buttons["session.end"].tap()
        XCTAssertFalse(resume.exists)
        capture("polish-models-light")
        navigate(app, to: "lens")
        let instructions = app.descendants(matching: .any).matching(identifier: "lens.instructions").firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 3))
        let surface = app.descendants(matching: .any).matching(identifier: "lens.instructions.container").firstMatch
        XCTAssertGreaterThanOrEqual(surface.frame.height, 44)
        capture("polish-lens-light")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["keyboard.dismiss"].tap()
    }

    @MainActor func testHomeSearchPinOpenAndNewChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home", "-AppleLanguages", "(en)"]
        app.launch()
        let day = app.buttons["home.conversation.day"]
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture("sidebar-home-light")
        app.buttons["home.pinned"].tap()
        XCTAssertFalse(day.exists)
        app.buttons["home.pinned"].tap()
        XCTAssertTrue(day.exists)
        day.press(forDuration: 1)
        app.buttons["Unpin conversation"].tap()
        app.buttons["home.pinned"].tap()
        XCTAssertTrue(day.exists, "Unpinned conversations remain in Recents")
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("reading")
        XCTAssertTrue(app.buttons["home.conversation.reading"].exists)
        XCTAssertFalse(day.exists)
        search.typeText("\n")
        app.buttons["home.conversation.reading"].tap()
        XCTAssertTrue(app.navigationBars["My reading list"].waitForExistence(timeout: 3))
        navigate(app, to: "home")
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "reading".count))
        // The system disables Search for an empty query; its native Close action ends search.
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["home.newChat"].waitForExistence(timeout: 3))
        app.buttons["home.newChat"].tap()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["chat.composer.add"].isHittable)
    }

    @MainActor func testSidebarRetainsHostDraftAndAttachments() {
        let app = launch(["-attachments"])
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap(); field.typeText("Keep this unfinished thought")
        navigate(app, to: "models")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        navigate(app, to: "home")
        navigate(app, to: "chat")
        XCTAssertEqual(field.value as? String, "Keep this unfinished thought")
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)
        capture("sidebar-returned-draft")
    }

    @MainActor func testSidebarWorkspacesAndVoiceShortcut() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home", "-AppleLanguages", "(en)", "-action-probe"]
        app.launch()
        for (id, title) in [("imageStudio", "Image studio"), ("device", "Device")] {
            navigate(app, to: id)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Done"].exists)
            navigate(app, to: "home")
        }
        navigate(app, to: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Close"].tap()
        navigate(app, to: "voice")
        capture("brief-start-voice-after-navigation")
        XCTAssertTrue(app.buttons["Start conversation"].isHittable)
        app.buttons["Start conversation"].tap()
        capture("brief-after-start-voice-navigation")
        XCTAssertEqual(app.staticTexts["fixture.action"].label, "beginVoiceSession")
        XCTAssertTrue(app.buttons["End voice conversation"].waitForExistence(timeout: 5))
        app.buttons["End voice conversation"].tap()
        openMenu(app)
        app.buttons["sidebar.newChat"].tap()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 3))
    }

    @MainActor func testSidebarSearchAndEdgeGestures() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home"]
        app.launch()
        XCTAssertTrue(app.buttons["home.newChat"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.buttons["sidebar.home"].waitForExistence(timeout: 3))
        app.buttons["Search conversations"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("Swift")
        XCTAssertTrue(app.buttons["home.conversation.swift"].exists)
        XCTAssertFalse(app.buttons["home.conversation.day"].exists)
        app.buttons["home.conversation.swift"].tap()
        XCTAssertTrue(app.navigationBars["Review a Swift function"].waitForExistence(timeout: 3))
        openMenu(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)))
        XCTAssertTrue(app.buttons["navigation.menu"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["sidebar.home"].exists)
    }

    @MainActor func testPolishedScreensDarkAndLargeText() {
        let app = XCUIApplication()
        for screen in ["lens", "models", "voice"] {
            app.launchArguments = ["-screen", screen, "-dark", "-large-type", "-voice-active", "-AppleLanguages", "(en)"]
            app.launch()
            XCTAssertTrue(app.buttons["navigation.menu"].waitForExistence(timeout: 10))
            capture("polish-\(screen)-dark-large-text")
            if screen == "lens" {
                let field = app.descendants(matching: .any).matching(identifier: "lens.instructions").firstMatch
                if !field.isHittable { app.swipeUp() }
                XCTAssertTrue(field.isHittable)
            } else if screen == "voice" {
                XCTAssertTrue(app.buttons["session.return"].isHittable)
            } else if screen == "models" {
                XCTAssertTrue(app.buttons["session.return"].isHittable)
                XCTAssertTrue(app.buttons["session.end"].isHittable)
            }
            app.terminate()
        }
    }

    @MainActor func testLensStopDispatchesCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lens", "-lens-analyzing"]
        app.launch()
        let stop = app.buttons["Stop image analysis"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Analysis cancelled"].waitForExistence(timeout: 3))
        XCTAssertFalse(stop.exists)
    }

    @MainActor func testMeasuredWidthsAndLongModelKeepFooterUsable() {
        for width in [320, 375, 393, 430] {
            let app = launch(["-width", String(width), "-long-model"])
            let add = app.buttons["chat.composer.add"]
            let send = app.buttons["chat.composer.send"]
            let model = app.buttons["Model"]
            XCTAssertTrue(add.isHittable)
            XCTAssertTrue(send.isHittable)
            XCTAssertTrue(model.isHittable)
            XCTAssertEqual(model.value as? String, "A deliberately long installed local model name Q5_K_M")
            XCTAssertGreaterThanOrEqual(add.frame.width, 44)
            XCTAssertGreaterThanOrEqual(add.frame.height, 44)
            XCTAssertGreaterThanOrEqual(send.frame.width, 44)
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            XCTAssertLessThanOrEqual(add.frame.maxX, model.frame.minX)
            XCTAssertLessThanOrEqual(model.frame.maxX, send.frame.minX)
            let writing = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
            XCTAssertEqual(writing.frame.width, CGFloat(width - 64), accuracy: 1)
            capture("composer-width-\(width)-long-model")
            app.terminate()
        }
    }

    @MainActor func testEditingUnicodeAndReturningFromModelMenuKeepsDraft() {
        let app = launch(["-long-model"])
        let field = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        field.tap()
        let draft = "İstanbul, ışık, şeker\nlet value = 1"
        field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Model"].tap()
        app.buttons["Model details"].tap()
        XCTAssertEqual(field.value as? String, draft)
        // Refocus at the end of the final line; a center tap intentionally
        // moves the native caret and can select the word under the touch.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        field.typeText("\nSecond block")
        XCTAssertEqual(field.value as? String, draft + "\nSecond block")
        capture("composer-unicode-refocused")
    }

    @MainActor func testSettingsAppearanceAndOnboardingRender() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        capture("settings-native-grouped")
        app.terminate()
        app.launchArguments = ["-screen", "onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 10))
        capture("host-onboarding")
    }

    @MainActor func testAppearanceChoicesAndTrueOLED() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "appearance", "-dark"]
        app.launch()
        for appearance in ["dark", "light", "oled"] {
            let choice = app.buttons["appearance.\(appearance)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isHittable)
            choice.tap()
            XCTAssertEqual(choice.value as? String, "Selected")
            capture("redesign-appearance-\(appearance)")
        }
        let system = app.switches["appearance.system"]
        XCTAssertTrue(system.isHittable)
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(system.waitForExistence(timeout: 3))
        XCTAssertEqual(system.value as? String, "1")
        XCTAssertEqual(app.buttons["appearance.oled"].value as? String, "Not selected")
    }

    @MainActor func testRedesignedLibraryFiltersAndStorage() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "models", "-dark"]
        app.launch()
        let model = app.buttons["model.row.local/local_Ornith-1.5-9B-Q5_K_M"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        capture("redesign-models-dark")
        app.buttons["models.capability"].tap()
        app.buttons["Image"].tap()
        XCTAssertTrue(app.staticTexts["No matching models"].waitForExistence(timeout: 3))
        XCTAssertFalse(model.exists)
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        app.buttons["models.storage"].tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 3))
    }

    @MainActor func testRedesignedHomeAndAppearanceAtAccessibleSizes() {
        let app = XCUIApplication()
        for screen in ["home", "appearance"] {
            app.launchArguments = ["-screen", screen, "-dark", "-large-type", "-width", "320"]
            app.launch()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
            capture("redesign-\(screen)-dark-large")
            if screen == "home" {
                let write = app.buttons["home.newChat"]
                for _ in 0..<5 where !write.isHittable { app.swipeUp() }
                XCTAssertTrue(write.isHittable)
            } else {
                let oled = app.buttons["appearance.oled"]
                for _ in 0..<5 where !oled.isHittable { app.swipeUp() }
                XCTAssertTrue(oled.isHittable)
                oled.tap()
                XCTAssertEqual(oled.value as? String, "Selected")
            }
            app.terminate()
        }
        app.launchArguments = ["-screen", "home", "-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["home.newChat"].waitForExistence(timeout: 5))
        capture("redesign-home-dark")
    }

    @MainActor func testSystemAccessibilityPreferences() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "voice", "-dark"]
        app.launch()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if settings.switches["REDUCE_MOTION"].exists || settings.switches["REDUCE_TRANSPARENCY"].exists {
            settings.navigationBars.buttons.firstMatch.tap()
        }
        if settings.buttons["com.apple.settings.accessibility"].exists {
            settings.buttons["com.apple.settings.accessibility"].tap()
        }
        settings.buttons["MOTION_TITLE"].tap()
        let motion = settings.switches.matching(NSPredicate(format: "label CONTAINS[c] %@", "Reduce Motion")).firstMatch
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        let motionWasOn = motion.value as? String == "1"
        setSystemSwitch(motion, enabled: true)
        settings.navigationBars.buttons.firstMatch.tap()
        settings.buttons["DISPLAY_AND_TEXT"].tap()
        let transparency = settings.switches.matching(NSPredicate(format: "label CONTAINS[c] %@", "Reduce Transparency")).firstMatch
        XCTAssertTrue(transparency.waitForExistence(timeout: 5))
        let transparencyWasOn = transparency.value as? String == "1"
        setSystemSwitch(transparency, enabled: true)
        defer {
            // Reopen Settings so restoration uses freshly resolved controls.
            settings.launch()
            if settings.switches["REDUCE_MOTION"].exists || settings.switches["REDUCE_TRANSPARENCY"].exists {
                settings.navigationBars.buttons.firstMatch.tap()
            }
            if settings.buttons["com.apple.settings.accessibility"].exists {
                settings.buttons["com.apple.settings.accessibility"].tap()
            }
            settings.buttons["DISPLAY_AND_TEXT"].tap()
            setSystemSwitch(transparency, enabled: transparencyWasOn)
            settings.navigationBars.buttons.firstMatch.tap()
            settings.buttons["MOTION_TITLE"].tap()
            setSystemSwitch(motion, enabled: motionWasOn)
            settings.navigationBars.buttons.firstMatch.tap()
        }
        app.activate()
        XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
        app.buttons["Start conversation"].tap()
        XCTAssertTrue(app.buttons["Mute microphone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["End voice conversation"].isHittable)
        capture("voice-reduce-motion-transparency")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        app.buttons["End voice conversation"].tap()
    }

    @MainActor private func setSystemSwitch(_ control: XCUIElement, enabled: Bool) {
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected {
            // Settings exposes the complete labeled row as the switch. Touch
            // the trailing toggle rather than the center of its text label.
            print("Settings switch \(control.identifier): \(control.frame)")
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let valueChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [valueChanged], timeout: 5), .completed)
        XCTAssertEqual(control.value as? String, expected)
    }

}
