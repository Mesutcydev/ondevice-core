import Foundation
import XCTest
@testable import IOSLocalLLM

@MainActor
final class PrivacyAndWebBoundaryTests: XCTestCase {
    func testWipeClearsWebActivityAndDisplayedAPIKey() async {
        WebActivityLogger.shared.record(.init(
            kind: .search,
            provider: nil,
            queryOrURL: "private audit query",
            statusCode: nil,
            bytesIn: nil,
            durationMs: nil,
            fromCache: false,
            note: nil
        ))
        LocalAPIManager.shared.rotateKey()
        XCTAssertFalse(WebActivityLogger.shared.entries.isEmpty)
        XCTAssertFalse(LocalAPIManager.shared.apiKey.isEmpty)

        _ = await WipeAllDataService.wipeAll(includeCloud: false)

        XCTAssertTrue(WebActivityLogger.shared.entries.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: "ioslocalllm.webtool.activity.v1"))
        XCTAssertEqual(LocalAPIManager.shared.apiKey, "")
        XCTAssertFalse(AppSettings.shared.localAPIEnabled)
    }

    func testPreWipeDownloadDescriptionsCannotRestoreFiles() {
        let old = "odc-generation:legacy:/tmp/model.bin"
        let current = "odc-generation:new:/tmp/model.bin"
        XCTAssertEqual(BackgroundDownloadCoordinator.destinationPath(
            for: old, currentGeneration: "legacy"
        ), "/tmp/model.bin")
        XCTAssertNil(BackgroundDownloadCoordinator.destinationPath(
            for: old, currentGeneration: "new"
        ))
        XCTAssertNil(BackgroundDownloadCoordinator.destinationPath(
            for: "/tmp/older-model.bin", currentGeneration: "new"
        ))
        XCTAssertEqual(BackgroundDownloadCoordinator.destinationPath(
            for: current, currentGeneration: "new"
        ), "/tmp/model.bin")
    }

    func testWebFetchStopsAtByteLimit() async throws {
        let withinLimit = AsyncStream<UInt8> { continuation in
            for byte in [UInt8(1), 2, 3] { continuation.yield(byte) }
            continuation.finish()
        }
        let data = try await WebPageFetchService.collectBounded(withinLimit, maximumBytes: 3)
        XCTAssertEqual(data, Data([1, 2, 3]))

        let overLimit = AsyncStream<UInt8> { continuation in
            for byte in [UInt8(1), 2, 3, 4] { continuation.yield(byte) }
            continuation.finish()
        }
        do {
            _ = try await WebPageFetchService.collectBounded(overLimit, maximumBytes: 3)
            XCTFail("Expected the oversized response to stop")
        } catch WebToolError.tooLarge(let bytes) {
            XCTAssertEqual(bytes, 4)
        }
    }
}
