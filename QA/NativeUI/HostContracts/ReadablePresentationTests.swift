import Foundation
import Testing
import OnDeviceUI

struct ReadablePresentationTests {
    @Test func importedModelLabelsKeepIdentityAndQuantization() {
        let id = "local/local_Ornith-1.5-9B-Q5_K_M"
        let raw = "local_Ornith-1.5-9B-Q5_K_M"
        let model = ODModel(id: id, name: raw, metadata: id, kind: .language)
        #expect(model.id == id)
        #expect(model.name == "Ornith 1.5 9B · Q5_K_M")
        #expect(model.metadata == "Imported on this device")
        #expect(ODPresentation.modelName(raw, compact: true) == "Ornith 1.5 9B")
        #expect(ODPresentation.modelName("model-IQ4_XS.gguf") == "model · IQ4_XS")
        #expect(ODPresentation.modelName("model-BF16.safetensors") == "model · BF16")
        #expect(ODPresentation.modelName("SmolVLM 2 500M (Q8 GGUF)") == "SmolVLM 2 500M (Q8 GGUF)")
        #expect(ODPresentation.modelName("İstanbul — Türkçe") == "İstanbul — Türkçe")
    }

    @Test func conversationDaysUseCalendarBoundariesAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30)))
        #expect(ODPresentation.conversationDate(now, now: now, calendar: calendar, locale: locale) == "Today")
        #expect(ODPresentation.conversationDate(yesterday, now: now, calendar: calendar, locale: locale) == "Yesterday")
        let older = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31)))
        #expect(ODPresentation.conversationDate(older, now: now, calendar: calendar, locale: locale).contains("2025"))
    }
}
