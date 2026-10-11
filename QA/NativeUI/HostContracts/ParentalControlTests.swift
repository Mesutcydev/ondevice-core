import XCTest
@testable import NativeUIReview

@MainActor
final class ParentalControlTests: XCTestCase {
    private final class Storage: ParentalControlStorage {
        var data: Data?
        var fails = false
        func read() throws -> Data? {
            if fails { throw ParentalControlManager.Failure.storageUnavailable }
            return data
        }
        func write(_ data: Data?) throws {
            if fails { throw ParentalControlManager.Failure.storageUnavailable }
            self.data = data
        }
    }

    func testRestrictionsPersistAndChangesRequirePIN() throws {
        let storage = Storage()
        let controls = ParentalControlManager(storage: storage)
        XCTAssertFalse(controls.blocksImageGeneration)
        XCTAssertThrowsError(try controls.configure(pin: "123456", confirmation: "654321"))
        XCTAssertThrowsError(try controls.configure(pin: "１２３４５６", confirmation: "１２３４５６"))
        try controls.configure(pin: "123456", confirmation: "123456")
        XCTAssertTrue(controls.blocksImageGeneration)
        XCTAssertFalse(String(decoding: try XCTUnwrap(storage.data), as: UTF8.self).contains("123456"))
        let restarted = ParentalControlManager(storage: storage)
        XCTAssertTrue(restarted.blocksImageGeneration)
        XCTAssertThrowsError(try restarted.setImageRestriction(false, pin: "000000"))
        XCTAssertTrue(restarted.blocksImageGeneration)
        XCTAssertThrowsError(try restarted.remove(pin: "000000"))
        try restarted.setImageRestriction(false, pin: "123456")
        XCTAssertFalse(restarted.blocksImageGeneration)
        try restarted.changePIN(current: "123456", new: "654321", confirmation: "654321")
        XCTAssertThrowsError(try restarted.remove(pin: "123456"))
        try restarted.remove(pin: "654321")
        XCTAssertFalse(restarted.isEnabled)
    }

    func testRetryLimitSurvivesRestartAndCorrectPINCannotSkipDelay() throws {
        let storage = Storage()
        var time = Date(timeIntervalSince1970: 1_790_812_800)
        let controls = ParentalControlManager(storage: storage, now: { time })
        try controls.configure(pin: "123456", confirmation: "123456")
        for _ in 0..<5 { XCTAssertThrowsError(try controls.remove(pin: "000000")) }
        let restarted = ParentalControlManager(storage: storage, now: { time })
        XCTAssertThrowsError(try restarted.remove(pin: "123456"))
        XCTAssertTrue(restarted.blocksImageGeneration)
        time = time.addingTimeInterval(61)
        try restarted.remove(pin: "123456")
        XCTAssertFalse(restarted.isEnabled)
    }

    func testUnreadableOrCorruptStorageFailsClosedAndDoesNotUnlockOnWriteFailure() throws {
        let storage = Storage()
        let controls = ParentalControlManager(storage: storage)
        try controls.configure(pin: "123456", confirmation: "123456")
        storage.fails = true
        XCTAssertThrowsError(try controls.setImageRestriction(false, pin: "123456"))
        XCTAssertTrue(controls.blocksImageGeneration)
        XCTAssertTrue(controls.storageUnavailable)
        XCTAssertTrue(ParentalControlManager(storage: storage).blocksImageGeneration)
        storage.fails = false
        controls.reload()
        XCTAssertTrue(controls.blocksImageGeneration)
        storage.data = Data("broken".utf8)
        controls.reload()
        XCTAssertTrue(controls.storageUnavailable)
        XCTAssertTrue(controls.blocksImageGeneration)
        XCTAssertThrowsError(try controls.configure(pin: "123456", confirmation: "123456"))
    }

    func testProductionKeychainRoundTrip() throws {
        let storage = ParentalControlKeychain()
        // This test runs inside the separate QA app's Keychain access group.
        let original = try storage.read()
        defer { try? storage.write(original) }
        try storage.write(nil)
        let controls = ParentalControlManager(storage: storage)
        try controls.configure(pin: "638192", confirmation: "638192")
        let restored = ParentalControlManager(storage: storage)
        XCTAssertTrue(restored.blocksImageGeneration)
        try restored.remove(pin: "638192")
        XCTAssertNil(try storage.read())
    }
}
