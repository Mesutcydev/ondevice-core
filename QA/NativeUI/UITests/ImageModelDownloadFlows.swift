import XCTest

final class ImageModelDownloadFlows: XCTestCase {
    @MainActor func testImageDiscoveryAndDownloadsShowAllTransferOwners() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image", "-image-empty", "-image-no-model", "-image-catalog",
                               "-model-actions", "-model-downloading", "-coreai-transfer-fixture", "-action-probe",
                               "-AppleLanguages", "(en)"]
        app.launch()
        openImageModels(app)

        let first = "review/image-one"
        let second = "review/image-two"
        XCTAssertTrue(app.buttons["image.models.select.\(first)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["image.models.select.\(second)"].exists)
        app.buttons["image.models.download.\(first)"].tap()
        XCTAssertTrue(app.progressIndicators["image.models.progress.\(first)"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        app.buttons["navigation.menu"].tap()
        let models = app.buttons["sidebar.models"]
        for _ in 0..<5 where !models.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(models.isHittable)
        models.tap()
        let downloads = app.buttons["models.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        let hub = app.staticTexts["Review catalog model"]
        let core = app.buttons["downloads.pause.coreai:zoo-qwen3-0.6b-official-ios"]
        let image = app.progressIndicators["downloads.progress.\(first)"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5))
        XCTAssertTrue(core.exists)
        for _ in 0..<4 where !image.isHittable { app.swipeUp() }
        XCTAssertTrue(image.exists)
        XCTAssertFalse(app.staticTexts["No active downloads"].exists)
        for _ in 0..<4 where !app.buttons["downloads.pause.coreai:zoo-qwen3-0.6b-official-ios"].isHittable { app.swipeDown() }
        app.buttons["downloads.pause.coreai:zoo-qwen3-0.6b-official-ios"].tap()
        XCTAssertTrue(app.staticTexts["fixture.action"].label.contains("pauseDownload"))
    }

    @MainActor func testImagePickerSeparatesInstalledAndAvailableModels() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "image", "-image-catalog", "-image-mixed", "-AppleLanguages", "(en)"]
        app.launch()
        openImageModels(app)
        XCTAssertTrue(app.buttons["image.models.select.review/image-one"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["image.models.select.review/image-two"].exists)
        app.buttons["image.models.scope.discover"].tap()
        XCTAssertTrue(app.buttons["image.models.select.review/image-two"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["image.models.select.review/image-one"].exists)
        app.buttons["image.models.select.review/image-two"].tap()
        XCTAssertTrue(app.buttons["image.model"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["image.create"].label, "Download")
    }

    @MainActor func testModelsLibraryShowsImageCatalogWhenNoneAreInstalled() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "models", "-image-catalog", "-image-no-model", "-AppleLanguages", "(en)"]
        app.launch()
        tapCapability("image", in: app)
        XCTAssertTrue(app.buttons["models.scope.discover"].isSelected)
        XCTAssertTrue(app.buttons["model.row.review/image-one"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["model.download.review/image-one"].exists)
    }

    /// The capability row scrolls horizontally, so the Image chip can start
    /// offscreen. Drag the row itself rather than a chip that has no frame.
    @MainActor private func tapCapability(_ id: String, in app: XCUIApplication) {
        let chip = app.buttons["models.capability.\(id)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        if chip.isHittable { chip.tap(); return }
        let row = app.scrollViews["models.capability"].firstMatch
        let surface = row.exists ? row : app.scrollViews.firstMatch
        for _ in 0..<5 where !chip.isHittable { surface.swipeLeft() }
        XCTAssertTrue(chip.isHittable, "Capability chip \(id) unreachable")
        chip.tap()
    }

    @MainActor private func openImageModels(_ app: XCUIApplication) {
        let model = app.buttons["image.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image model")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Image models"].waitForExistence(timeout: 5))
    }
}
