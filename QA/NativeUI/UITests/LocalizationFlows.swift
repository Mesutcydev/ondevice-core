import XCTest

final class LocalizationFlows: XCTestCase {
    private let translations: [(String, String, String, String)] = [
        ("hi", "चैट", "मॉडल", "नई चैट"),
        ("de", "Chats", "Modelle", "Neuer Chat"),
        ("es", "Chats", "Modelos", "Nuevo chat"),
        ("ar", "المحادثات", "النماذج", "محادثة جديدة"),
        ("tr", "Sohbetler", "Modeller", "Yeni sohbet"),
        ("ja", "チャット", "モデル", "新しいチャット")
    ]

    @MainActor func testRequestedLanguagesTranslateTheProductionSidebar() {
        for (language, chats, models, newChat) in translations {
            let app = XCUIApplication()
            app.launchArguments = ["-screen", "home", "-review-language", language,
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.navigationBars[chats].waitForExistence(timeout: 10), language)
            let menu = app.buttons["navigation.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5), language)
            menu.tap()
            let modelButton = app.buttons["sidebar.models"]
            XCTAssertTrue(modelButton.waitForExistence(timeout: 5), language)
            XCTAssertEqual(modelButton.label, models, language)
            XCTAssertEqual(app.buttons["sidebar.newChat"].label, newChat, language)
            // Fixture conversation text is user content and must remain verbatim.
            XCTAssertTrue(app.staticTexts["Plan a focused workday"].exists, language)
            capture("sidebar-\(language)", app: app)
            app.terminate()
        }
    }

    @MainActor func testChangingLanguageKeepsTheConversationDraftAndMirrorsArabic() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "home", "-review-language", "en",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["home.newChat"].tap()
        let draft = "Draft محفوظ 日本語"
        let input = app.descendants(matching: .any).matching(identifier: "chat.composer.text").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(draft)
        app.buttons["navigation.menu"].tap()
        app.buttons["sidebar.settings"].tap()
        let picker = app.buttons["settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.navigationBars["الإعدادات"].waitForExistence(timeout: 5))
        capture("settings-ar-live", app: app)
        app.buttons["إغلاق"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft)
        let menu = app.buttons["navigation.menu"]
        XCTAssertGreaterThan(menu.frame.midX, app.frame.midX)
        menu.tap()
        let models = app.buttons["sidebar.models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        XCTAssertEqual(models.label, "النماذج")
        capture("sidebar-ar-live", app: app)
        app.buttons["sidebar.home"].tap()
        XCTAssertTrue(app.navigationBars["المحادثات"].waitForExistence(timeout: 5))
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalizationScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
