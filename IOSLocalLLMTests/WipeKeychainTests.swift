import XCTest
@testable import IOSLocalLLM

@MainActor
final class WipeKeychainTests: XCTestCase {

    func test_wipeAll_clearsWebAPIKeys() async {
        KeychainStore.set("test-brave", account: "brave.apiKey")
        KeychainStore.set("test-tavily", account: "tavily.apiKey")
        XCTAssertTrue(KeychainStore.has(account: "brave.apiKey"))
        XCTAssertTrue(KeychainStore.has(account: "tavily.apiKey"))

        let receipt = await WipeAllDataService.wipeAll(includeCloud: false)

        XCTAssertFalse(KeychainStore.has(account: "brave.apiKey"))
        XCTAssertFalse(KeychainStore.has(account: "tavily.apiKey"))
        XCTAssertGreaterThanOrEqual(receipt.keychainItemsCleared, 2)
    }

    func test_wipeAll_clearsHFToken() async {
        _ = HFTokenStore.shared.save("hf_test_token_12345678")
        XCTAssertTrue(HFTokenStore.shared.hasToken)

        let receipt = await WipeAllDataService.wipeAll(includeCloud: false)

        XCTAssertFalse(HFTokenStore.shared.hasToken)
        XCTAssertGreaterThanOrEqual(receipt.keychainItemsCleared, 1)
    }
}
