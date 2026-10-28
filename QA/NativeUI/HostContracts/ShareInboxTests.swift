import XCTest
@testable import NativeUIReview

final class ShareInboxTests: XCTestCase {
    @MainActor
    func testPreservesMultipleSharesAndConsumesEachOnce() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date()
        let first = try handoff("first & second? # + % Türkçe")
        let second = try handoff("another share")
        try ShareInbox.enqueue(first, in: container, now: now)
        try ShareInbox.enqueue(second, in: container, now: now.addingTimeInterval(1))
        let received = try XCTUnwrap(ShareInbox.consumeNext(in: container, now: now.addingTimeInterval(2)))
        XCTAssertEqual(received, first)
        XCTAssertEqual(URLComponents(url: received, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "first & second? # + % Türkçe")
        XCTAssertEqual(try ShareInbox.consumeNext(in: container, now: now.addingTimeInterval(2)), second)
        XCTAssertNil(try ShareInbox.consumeNext(in: container, now: now.addingTimeInterval(2)))
    }

    @MainActor
    func testExpiredAndCorruptSharesDoNotBlockValidContent() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date()
        try ShareInbox.enqueue(handoff("expired"), in: container, now: now.addingTimeInterval(-90_000))
        let directory = container.appendingPathComponent(ShareInbox.directoryName)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("000-corrupt.json"))
        try Data(count: 70_000).write(to: directory.appendingPathComponent("001-oversized.json"))
        let valid = try handoff("retained")
        try ShareInbox.enqueue(valid, in: container, now: now)
        XCTAssertEqual(try ShareInbox.consumeNext(in: container, now: now), valid)
        // A corrupt filename may sort after the valid item. The next read
        // clears remaining invalid entries without returning another share.
        XCTAssertNil(try ShareInbox.consumeNext(in: container, now: now))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor
    func testRejectsOtherSchemesAndOversizedEntries() throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        XCTAssertThrowsError(try ShareInbox.enqueue(URL(string: "https://example.com")!, in: container))
        XCTAssertThrowsError(try ShareInbox.enqueue(handoff(String(repeating: "x", count: 70_000)), in: container))
        XCTAssertNil(try ShareInbox.consumeNext(in: container))
    }

    private func temporaryContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func handoff(_ text: String) throws -> URL {
        var url = URLComponents()
        url.scheme = "tokenai"
        url.host = "share"
        url.queryItems = [URLQueryItem(name: "text", value: text)]
        return try XCTUnwrap(url.url)
    }
}
