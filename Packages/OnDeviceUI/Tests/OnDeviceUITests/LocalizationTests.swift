import Foundation
import Testing
@testable import OnDeviceUI

struct LocalizationTests {
    @Test func resolvesRegionalAndOrderedSystemPreferences() {
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["hi-IN"]) == .hindi)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["de_DE"]) == .german)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["es-MX"]) == .spanish)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["ar-SA"]) == .arabic)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["tr-TR"]) == .turkish)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["ja-JP"]) == .japanese)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["nl-NL", "de-DE"]) == .german)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: ["nl-NL"]) == .english)
        #expect(ODLocalization.resolvedLanguage(.system, preferredLanguages: []) == .english)
        #expect(ODLocalization.resolvedLanguage(.turkish, preferredLanguages: ["en-US"]) == .turkish)
    }

    @Test func requestedLanguagesHaveRealBundleTranslations() {
        let expectations: [(ODAppLanguage, String, String)] = [
            (.hindi, "चैट", "भाषा"), (.german, "Chats", "Sprache"),
            (.spanish, "Chats", "Idioma"), (.arabic, "المحادثات", "اللغة"),
            (.turkish, "Sohbetler", "Dil"), (.japanese, "チャット", "言語")
        ]
        for (language, chats, picker) in expectations {
            #expect(ODLocalization.string("Chats", language: language) == chats)
            #expect(ODLocalization.string("Language", language: language) == picker)
            #expect(ODLocalization.string("Image studio", language: language) != "Image studio")
            #expect(ODLocalization.string("Not active", language: language) != "Not active")
            #expect(ODLocalization.string("unknown.key", language: language) == "unknown.key")
            #expect(ODLocalization.string("", language: language).isEmpty)
        }
    }

    @Test func arabicAloneMirrorsAmongRequestedLanguages() {
        #expect(ODAppLanguage.arabic.isRightToLeft)
        for language in [ODAppLanguage.hindi, .german, .spanish, .turkish, .japanese, .english] {
            #expect(!language.isRightToLeft)
        }
        #expect(ODAppLanguage.hindi.nativeName == "हिन्दी")
        #expect(ODAppLanguage.turkish.nativeName == "Türkçe")
        #expect(ODAppLanguage.japanese.nativeName == "日本語")
    }

    @Test func templatesKeepRuntimeValuesOutOfTheTranslationKey() {
        for language in [ODAppLanguage.hindi, .german, .spanish, .arabic, .turkish, .japanese] {
            let template = ODLocalization.string("Delete %@", language: language)
            #expect(template != "Delete %@")
            #expect(template.components(separatedBy: "%@").count == 2)
            #expect(ODLocalization.string("Voices · %lld", language: language).contains("%lld"))
        }
    }
}
