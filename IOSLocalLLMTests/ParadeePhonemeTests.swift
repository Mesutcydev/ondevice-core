import XCTest
@testable import IOSLocalLLM

/// Paradee reads Kokoro's vocabulary spelled the way misaki writes it.
final class ParadeePhonemeTests: XCTestCase {
    func testDiphthongsBecomeOneSymbolAndKeepTheirStress() {
        XCTAssertEqual(KokoroPhonemizer.misakiSpelling(Array("ˈaɪ ɡˈoʊ hˈaʊ bˈɔɪ dˈeɪ")), Array("ˈI ɡˈO hˈW bˈY dˈA"))
    }

    func testRColouredVowelIsSpelledWithSymbolsInTheVocabulary() {
        XCTAssertEqual(KokoroPhonemizer.misakiSpelling(Array("hˈɝd")), Array("hˈɜɹd"))
    }

    func testUnrelatedNeighboursAreLeftAlone() {
        XCTAssertEqual(KokoroPhonemizer.misakiSpelling(Array("ɑɪ əʊ")), Array("ɑɪ əʊ"))
    }
}
