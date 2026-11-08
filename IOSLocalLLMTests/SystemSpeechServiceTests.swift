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

/// A recognizer that keeps failing right away backs off instead of spinning
/// up a new task per callback; an ordinary silence timeout restarts at once.
final class SpeechDictationRetryTests: XCTestCase {
    func testFastFailuresBackOffUpToTwoSeconds() {
        XCTAssertEqual(SpeechDictationService.recognitionRetryDelay(fastFailures: 0), 0)
        XCTAssertEqual(SpeechDictationService.recognitionRetryDelay(fastFailures: 1), 0.25)
        XCTAssertEqual(SpeechDictationService.recognitionRetryDelay(fastFailures: 2), 0.5)
        XCTAssertEqual(SpeechDictationService.recognitionRetryDelay(fastFailures: 4), 2)
        XCTAssertEqual(SpeechDictationService.recognitionRetryDelay(fastFailures: 500), 2)
    }
}
