import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0MemoryBudgetTests

final class Edge0MemoryBudgetTests: XCTestCase {

    private let closedCeiling: UInt64 = 6_200_000_000

    func testNoPoolWhenNothingFits() {
        let budget = Edge0MemoryBudget.resolve(
            availableBytes: 0,
            ceilingBytes: closedCeiling
        )
        XCTAssertEqual(budget.expertPoolBytes, 0)
        XCTAssertEqual(budget.expertPoolSlots, 0)
        XCTAssertFalse(budget.isPoolEnabled)
    }

    func testTierSelectionUsesRemainingHeadroom() {
        let baseline = Edge0MemoryBudget.resolve(
            availableBytes: UInt64.max / 2,
            ceilingBytes: closedCeiling
        )
        let committed = baseline.residentCommonBytes
            + baseline.stateKVBytes
            + baseline.scratchBytes
            + baseline.safetyReserveBytes
            + baseline.prerouterResidentBytes

        let small = Edge0MemoryBudget.resolve(
            availableBytes: committed + 100 * 1_048_576,
            ceilingBytes: closedCeiling
        )
        XCTAssertEqual(small.expertPoolBytes, 64 * 1_048_576)

        let medium = Edge0MemoryBudget.resolve(
            availableBytes: committed + 200 * 1_048_576,
            ceilingBytes: closedCeiling
        )
        XCTAssertEqual(medium.expertPoolBytes, 128 * 1_048_576)

        let large = Edge0MemoryBudget.resolve(
            availableBytes: committed + 300 * 1_048_576,
            ceilingBytes: closedCeiling
        )
        XCTAssertEqual(large.expertPoolBytes, 256 * 1_048_576)

        let huge = Edge0MemoryBudget.resolve(
            availableBytes: committed + 4_096 * 1_048_576,
            ceilingBytes: closedCeiling
        )
        XCTAssertEqual(huge.expertPoolBytes, 512 * 1_048_576)
    }

    func testTiersAreDiscreteAndSlotsDeriveFromBundleSize() {
        for extra in stride(from: 0, through: 2_048, by: 64) {
            let baseline = Edge0MemoryBudget.resolve(
                availableBytes: UInt64.max / 2,
                ceilingBytes: closedCeiling
            )
            let committed = baseline.residentCommonBytes
                + baseline.stateKVBytes
                + baseline.scratchBytes
                + baseline.safetyReserveBytes
                + baseline.prerouterResidentBytes
            let budget = Edge0MemoryBudget.resolve(
                availableBytes: committed + UInt64(extra) * 1_048_576,
                ceilingBytes: closedCeiling
            )
            let allowed: Set<UInt64> = Set([0] + Edge0MemoryBudget.poolTierBytes)
            XCTAssertTrue(
                allowed.contains(budget.expertPoolBytes),
                "pool bytes \(budget.expertPoolBytes) must be one of the discrete tiers"
            )
            XCTAssertEqual(
                budget.expertPoolSlots,
                Int(budget.expertPoolBytes / Edge0MemoryBudget.expertBundleBytes)
            )
            XCTAssertLessThanOrEqual(
                budget.expertPoolBytes,
                Edge0MemoryBudget.poolTierBytes.max() ?? 0
            )
        }
    }

    func testPoolBytesAreBoundedByTheLargestTier() {
        let budget = Edge0MemoryBudget.resolve(
            availableBytes: UInt64.max / 2,
            ceilingBytes: UInt64.max / 2
        )
        XCTAssertEqual(
            budget.expertPoolBytes,
            Edge0MemoryBudget.poolTierBytes.max()
        )
    }

    func testStateAndReserveScaleWithCeilingBounds() {
        let small = Edge0MemoryBudget.resolve(availableBytes: 0, ceilingBytes: 4_000_000_000)
        let large = Edge0MemoryBudget.resolve(availableBytes: 0, ceilingBytes: 17_000_000_000)

        XCTAssertGreaterThanOrEqual(
            small.stateKVBytes,
            Edge0MemoryBudget.minimumStateKVBytes
        )
        XCTAssertGreaterThanOrEqual(
            small.safetyReserveBytes,
            Edge0MemoryBudget.minimumSafetyReserveBytes
        )
        XCTAssertLessThan(small.stateKVBytes, large.stateKVBytes)
        XCTAssertLessThanOrEqual(
            large.stateKVBytes,
            Edge0MemoryBudget.maximumStateKVBytes
        )
        XCTAssertGreaterThan(
            large.safetyReserveBytes,
            small.safetyReserveBytes
        )
    }

    func testMeasuredCheckpointConstantsAreConsistent() {
        // 23 expert layers × 128 experts × 1,327,104 bytes.
        XCTAssertEqual(
            Edge0MemoryBudget.measuredRoutedExpertBytes,
            UInt64(23 * 128) * Edge0MemoryBudget.expertBundleBytes
        )
        XCTAssertEqual(
            Edge0MemoryBudget.measuredCheckpointBytes,
            Edge0MemoryBudget.measuredRoutedExpertBytes
                + Edge0MemoryBudget.measuredResidentCommonBytes
        )
    }
}
