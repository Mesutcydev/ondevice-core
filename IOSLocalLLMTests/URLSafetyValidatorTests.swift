import XCTest
@testable import IOSLocalLLM

final class URLSafetyValidatorTests: XCTestCase {

    func test_isPrivateOrReserved_blocksLoopbackIPv4() {
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("127.0.0.1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("10.0.0.1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("192.168.1.1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("169.254.169.254"))
    }

    func test_isPrivateOrReserved_blocksLoopbackIPv6() {
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("::1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("fe80::1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("fd12:3456:789a:1::1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("2001:db8::1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("::ffff:10.0.0.1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("64:ff9b::192.168.1.1"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("2002:7f00:1::"))
        XCTAssertTrue(URLSafetyValidator.isPrivateOrReserved("not-an-ipv6::literal"))
    }

    func test_isPrivateOrReserved_allowsPublicIPv6() {
        XCTAssertFalse(URLSafetyValidator.isPrivateOrReserved("2606:4700:4700::1111"))
        XCTAssertFalse(URLSafetyValidator.isPrivateOrReserved("2001:4860:4860::8888"))
    }

    func test_isPrivateOrReserved_allowsPublicIPv4() {
        XCTAssertFalse(URLSafetyValidator.isPrivateOrReserved("8.8.8.8"))
        XCTAssertFalse(URLSafetyValidator.isPrivateOrReserved("1.1.1.1"))
    }

    func test_validate_rejectsNonHTTPScheme() async {
        let validator = URLSafetyValidator()
        let verdict = await validator.validate(URL(string: "file:///etc/passwd")!)
        XCTAssertFalse(verdict.isSafe)
        XCTAssertTrue(verdict.reason.contains("scheme"))
    }

    func test_validate_rejectsLocalhostHostname() async {
        let validator = URLSafetyValidator()
        let verdict = await validator.validate(URL(string: "http://localhost/admin")!)
        XCTAssertFalse(verdict.isSafe)
        XCTAssertTrue(verdict.reason.contains("localhost") || verdict.reason.contains("private"))
    }

    func test_validateStable_agreesWithSingleValidateOnPublicHost() async {
        let validator = URLSafetyValidator()
        let url = URL(string: "https://example.com")!
        let single = await validator.validate(url)
        let stable = await validator.validateStable(url)
        XCTAssertEqual(single.isSafe, stable.isSafe)
        if single.isSafe {
            XCTAssertEqual(Set(single.resolvedIPs), Set(stable.resolvedIPs))
        }
    }

    func testRedirectGuardRejectsRedirectToLoopback() async {
        let guardDelegate = WebRedirectGuard(validator: URLSafetyValidator())
        let request = URLRequest(url: URL(string: "http://127.0.0.1/admin")!)

        let accepted = await guardDelegate.validatedRedirectRequest(request)

        XCTAssertNil(accepted)
    }
}
