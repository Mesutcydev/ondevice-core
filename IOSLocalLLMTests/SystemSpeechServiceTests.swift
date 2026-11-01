import XCTest
@testable import IOSLocalLLM

/// Apple's voices load off the main thread (speechVoices() can block it on
/// iOS 27.2); screens that cache the list rebuild it when the version moves.
@MainActor
final class SystemSpeechServiceTests: XCTestCase {
    func testRefreshFillsTheVoiceListAndBumpsItsVersion() async {
        let service = SystemSpeechService()
        let before = service.voicesVersion
        await service.refreshVoices()
        XCTAssertGreaterThan(service.voicesVersion, before)
        XCTAssertFalse(service.availableVoices.isEmpty)
    }
}
