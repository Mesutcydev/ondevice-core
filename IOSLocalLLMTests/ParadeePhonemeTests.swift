import XCTest
@testable import IOSLocalLLM

/// Phoneme spelling each speech model was trained on.
final class ParadeePhonemeTests: XCTestCase {
    func testDiphthongsBecomeOneSymbolAndKeepTheirStress() {
        XCTAssertEqual(KokoroPhonemizer.misakiSpelling(Array("ˈaɪ ɡˈoʊ hˈaʊ bˈɔɪ dˈeɪ")), Array("ˈI ɡˈO hˈW bˈY dˈA"))
    }

    /// The r-coloured vowel in each model's own spelling: misaki for Kokoro
    /// and Paradee (ɝ is not in their vocabulary), espeak for Kitten.
    func testKokoroSpellsErTheMisakiWay() {
        _ = KokoroPhonemizer.shared.phonemeIDs(for: "load")   // loads CMUdict
        let her = String(KokoroPhonemizer.shared.phonemes(for: "her"))
        let water = String(KokoroPhonemizer.shared.phonemes(for: "water"))
        XCTAssertTrue(her.contains("ɜɹ"), her)
        XCTAssertTrue(water.hasSuffix("əɹ"), water)
        XCTAssertFalse((her + water).contains("ɝ"))
    }

    func testKittenSpellsErTheEspeakWay() {
        let her = PhonemizerEN.shared.phonemeString(for: "her")
        let water = PhonemizerEN.shared.phonemeString(for: "water")
        XCTAssertTrue(her.contains("ɜː"), her)
        XCTAssertTrue(water.contains("ɚ"), water)
        XCTAssertFalse((her + water).contains("ɝ"))
    }

    func testUnrelatedNeighboursAreLeftAlone() {
        XCTAssertEqual(KokoroPhonemizer.misakiSpelling(Array("ɑɪ əʊ")), Array("ɑɪ əʊ"))
    }
}
