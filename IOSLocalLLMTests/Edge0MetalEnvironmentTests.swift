import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0MetalEnvironmentTests
//
// Pure-logic coverage of the read-only MLX NAX gate mirror. The device
// snapshot itself is reported by Diagnostics; these tests pin the parsing
// and threshold behavior the mirror must keep in step with MLX's
// `is_nax_available()` implementation.

final class Edge0MetalEnvironmentTests: XCTestCase {

    func testGenerationAndClassParsing() {
        let phone = Edge0MetalEnvironment.parse(architecture: "applegpu_g18p")
        XCTAssertEqual(phone.generation, 18)
        XCTAssertEqual(phone.class, "p")

        let standard = Edge0MetalEnvironment.parse(architecture: "applegpu_g16s")
        XCTAssertEqual(standard.generation, 16)
        XCTAssertEqual(standard.class, "s")

        let base = Edge0MetalEnvironment.parse(architecture: "applegpu_g17g")
        XCTAssertEqual(base.generation, 17)
        XCTAssertEqual(base.class, "g")

        // Unparseable tails clamp to zero, like MLX's digit check.
        XCTAssertEqual(
            Edge0MetalEnvironment.parse(architecture: "short").generation, 0
        )
        XCTAssertEqual(
            Edge0MetalEnvironment.parse(architecture: "").generation, 0
        )
    }

    func testNaxGateMirrorsMlxCondition() {
        // Phone class needs gen >= 18 (A19 / A19 Pro qualify); A18 (g17p)
        // stays out — that exclusion is exactly the mlx#3083 fix.
        XCTAssertTrue(
            Edge0MetalEnvironment.isNaxEligible(
                architecture: "applegpu_g18p",
                osSatisfiesAvailability: true
            )
        )
        XCTAssertFalse(
            Edge0MetalEnvironment.isNaxEligible(
                architecture: "applegpu_g17p",
                osSatisfiesAvailability: true
            )
        )

        // Non-phone class needs gen >= 17 (M5-class; M4 g16s stays out).
        XCTAssertTrue(
            Edge0MetalEnvironment.isNaxEligible(
                architecture: "applegpu_g17s",
                osSatisfiesAvailability: true
            )
        )
        XCTAssertFalse(
            Edge0MetalEnvironment.isNaxEligible(
                architecture: "applegpu_g16s",
                osSatisfiesAvailability: true
            )
        )

        // The OS availability gate dominates everything (iOS < 26.2).
        XCTAssertFalse(
            Edge0MetalEnvironment.isNaxEligible(
                architecture: "applegpu_g18p",
                osSatisfiesAvailability: false
            )
        )
    }

    func testCurrentSnapshotIsSelfConsistent() {
        let snapshot = Edge0MetalEnvironment.current()
        XCTAssertEqual(
            snapshot.naxEligible,
            Edge0MetalEnvironment.isNaxEligible(
                architecture: snapshot.architecture,
                osSatisfiesAvailability: snapshot.osSatisfiesAvailability
            )
        )
        XCTAssertFalse(snapshot.summary.isEmpty)
    }
}
