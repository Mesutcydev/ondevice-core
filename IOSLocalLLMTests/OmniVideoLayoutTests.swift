import XCTest
@testable import IOSLocalLLM

/// The Omni video prompt must match llama.cpp b11960's mtmd-helper reader.
final class OmniVideoLayoutTests: XCTestCase {
    func test_framePicksMatchRoundedLinspace() {
        XCTAssertEqual(OmniVideoLayout.frameIndices(sourceFrames: 61, count: 5), [0, 15, 30, 45, 60])
        let picks = OmniVideoLayout.frameIndices(sourceFrames: 300, count: 20)
        XCTAssertEqual(picks.first, 0)
        XCTAssertEqual(picks[1], 16)   // 299 / 19 = 15.74
        XCTAssertEqual(picks.last, 299)
        XCTAssertEqual(OmniVideoLayout.frameIndices(sourceFrames: 10, count: 1), [0])
        XCTAssertEqual(OmniVideoLayout.frameIndices(sourceFrames: 0, count: 4), [])
    }

    func test_groupsOfTwoFramesGetAStampThenTheirSoundtrack() {
        let items = OmniVideoLayout.items(frameIndices: [0, 15, 30, 45, 60], sourceFPS: 25,
                                          sampleRate: 16_000, soundtrackSamples: 40_000)
        XCTAssertEqual(items, [
            .text("<0.3 seconds>"), .frame(0), .frame(1), .audio(0..<19_200),
            .text("<1.5 seconds>"), .frame(2), .frame(3), .audio(19_200..<38_400),
            .text("<2.4 seconds>"), .frame(4), .audio(38_400..<40_000),
        ])
    }

    func test_framesOnlyWithoutASoundtrack() {
        let items = OmniVideoLayout.items(frameIndices: [0, 15, 30, 45], sourceFPS: 25,
                                          sampleRate: 16_000, soundtrackSamples: 0)
        XCTAssertEqual(items, [.text("<0.3 seconds>"), .frame(0), .frame(1),
                               .text("<1.5 seconds>"), .frame(2), .frame(3)])
    }

    func test_aShortSoundtrackEndsWithTheGroupItReaches() {
        let items = OmniVideoLayout.items(frameIndices: [0, 15, 30, 45, 60], sourceFPS: 25,
                                          sampleRate: 16_000, soundtrackSamples: 10_000)
        XCTAssertEqual(items.filter { if case .audio = $0 { true } else { false } }, [.audio(0..<10_000)])
    }
}
