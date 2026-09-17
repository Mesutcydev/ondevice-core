import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0ContextBudgetTests
//
// Pins the dynamic Edge0 context admission: exact state bytes, monotone
// behavior, output reservation, policy cap, and the architectural clamp.

final class Edge0ContextBudgetTests: XCTestCase {

    private let gib: UInt64 = 1_073_741_824
    private let mib: UInt64 = 1_048_576

    // MARK: State-cost model

    func testCacheCostConstantsMatchStateArchitecture() {
        // 6 MLA layers x 16 heads x (192 keys + 128 values) x 2 bytes (bf16).
        XCTAssertEqual(Edge0ContextBudget.mlaBytesPerToken, 61_440)
        // 18 layers x (3 conv rings [1,3,2048] bf16 + recurrent [1,16,128,128] fp32).
        XCTAssertEqual(Edge0ContextBudget.kdaFixedStateBytes, 19_537_920)
        XCTAssertEqual(
            Edge0ContextBudget.poolReservationBytes,
            Edge0MemoryBudget.poolTierBytes.max()
        )
    }

    // MARK: Dynamic admission

    func testExactInputForRepresentativePhoneBudget() {
        let ceiling: UInt64 = 12 * gib
        let available: UInt64 = 12 * gib
        let budget = Edge0ContextBudget.resolve(
            availableBytes: available,
            ceilingBytes: ceiling,
            outputTokens: 2_048
        )
        // state allowance = 12 GiB / 8 = 1.5 GiB; cache = min(live, 1.5 GiB).
        XCTAssertEqual(budget.cacheBudgetBytes, 1_610_612_736)
        XCTAssertEqual(budget.maxInputTokens, 24_166)
    }

    func testOutputReservationReducesInputExactly() {
        let ceiling: UInt64 = 12 * gib
        let available: UInt64 = 12 * gib
        let short = Edge0ContextBudget.resolve(
            availableBytes: available, ceilingBytes: ceiling, outputTokens: 2_048
        )
        let long = Edge0ContextBudget.resolve(
            availableBytes: available, ceilingBytes: ceiling, outputTokens: 4_096
        )
        XCTAssertEqual(short.maxInputTokens - long.maxInputTokens, 2_048)
    }

    func testLessAvailableMemoryNeverIncreasesContext() {
        let ceiling: UInt64 = 12 * gib
        let outputs = 2_048
        let sweep: [UInt64] = [
            12 * gib, 10 * gib, 8 * gib, 6 * gib, 5 * gib,
            4 * gib, 3 * gib, 2 * gib, 1 * gib, 512 * mib,
        ]
        var previous = Int.max
        for available in sweep {
            let limit = Edge0ContextBudget.resolve(
                availableBytes: available,
                ceilingBytes: ceiling,
                outputTokens: outputs
            ).maxInputTokens
            XCTAssertLessThanOrEqual(
                limit, previous,
                "available \(available) raised the limit above \(previous)"
            )
            XCTAssertGreaterThanOrEqual(
                limit, Edge0ContextBudget.minimumInputTokens
            )
            previous = limit
        }
    }

    func testTierStepsDoNotBreakMonotonicity() {
        // Sweep across pool-tier boundaries (64/128/256/512 MiB) where a
        // naive 'remaining after chosen pool' formula would step upwards as
        // memory decreases.
        let ceiling: UInt64 = 10 * gib
        var previous = Int.max
        var available: UInt64 = 6 * gib
        while available <= 8 * gib {
            let limit = Edge0ContextBudget.resolve(
                availableBytes: available,
                ceilingBytes: ceiling,
                outputTokens: 1_024
            ).maxInputTokens
            XCTAssertLessThanOrEqual(limit, previous)
            previous = limit
            available += 16 * mib
        }
    }

    func testArchitecturalClampAppliesOnLargeDevices() {
        let ceiling: UInt64 = 64 * gib
        let budget = Edge0ContextBudget.resolve(
            availableBytes: 64 * gib,
            ceilingBytes: ceiling,
            outputTokens: 2_048
        )
        XCTAssertEqual(
            budget.maxInputTokens,
            Edge0ContextBudget.architectureMaxContext
        )
    }

    func testCacheBudgetNeverExceedsStatePolicyAllowance() {
        let ceiling: UInt64 = 12 * gib
        let budget = Edge0ContextBudget.resolve(
            availableBytes: 64 * gib,
            ceilingBytes: ceiling,
            outputTokens: 1_024
        )
        XCTAssertEqual(budget.cacheBudgetBytes, 1_610_612_736)
        XCTAssertLessThanOrEqual(
            budget.cacheBudgetBytes,
            Edge0MemoryBudget.maximumStateKVBytes
        )
    }

    func testMinimumFloorForTinyHeadroom() {
        let budget = Edge0ContextBudget.resolve(
            availableBytes: 0,
            ceilingBytes: 6 * gib,
            outputTokens: 4_096
        )
        XCTAssertEqual(
            budget.maxInputTokens,
            Edge0ContextBudget.minimumInputTokens
        )
    }

    func testArchitecturalLimitIsNeverExceeded() {
        for ceiling in [6 * gib, 12 * gib, 32 * gib, 64 * gib] {
            let budget = Edge0ContextBudget.resolve(
                availableBytes: ceiling,
                ceilingBytes: ceiling,
                outputTokens: 128
            )
            XCTAssertLessThanOrEqual(
                budget.maxInputTokens,
                Edge0ContextBudget.architectureMaxContext
            )
        }
    }
}
