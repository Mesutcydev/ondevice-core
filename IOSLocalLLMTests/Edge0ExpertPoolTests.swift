import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0ExpertPoolTests

final class Edge0ExpertPoolTests: XCTestCase {

    private func key(_ layer: Int, _ expert: Int) -> Edge0ExpertKey {
        Edge0ExpertKey(layer: layer, expert: expert)
    }

    private func makePool(
        slots: Int,
        bytes: UInt64 = 10_000_000,
        loader: @escaping Edge0ExpertPool<Int>.Loader,
        sizeOf: @escaping Edge0ExpertPool<Int>.SizeProvider = { _ in 1_000 }
    ) -> Edge0ExpertPool<Int> {
        Edge0ExpertPool(
            configuration: .init(capacitySlots: slots, capacityBytes: bytes),
            loader: loader,
            sizeOf: sizeOf
        )
    }

    // MARK: - Hit / miss

    func testHitMissAndLoaderInvocationCount() async throws {
        let counter = LockedCounter()
        let pool = makePool(slots: 4) { key in
            counter.increment()
            return key.expert
        }
        let target = key(1, 1)

        let first = try await pool.acquire(target)
        await pool.release(first)
        let second = try await pool.acquire(target)
        await pool.release(second)

        XCTAssertEqual(counter.value, 1)
        let stats = await pool.statistics()
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.occupancySlots, 1)
    }

    // MARK: - Capacity and eviction

    func testCapacityIsHardAndEvictsLRU() async throws {
        let pool = makePool(slots: 2) { key in key.expert }
        for layer in 1...10 {
            for expert in 0..<10 {
                let lease = try await pool.acquire(key(layer, expert))
                await pool.release(lease)
            }
        }
        let stats = await pool.statistics()
        XCTAssertEqual(stats.capacitySlots, 2)
        XCTAssertLessThanOrEqual(stats.occupancySlots, 2)
        XCTAssertGreaterThanOrEqual(stats.evictions, 98)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)
    }

    func testSlotRecyclingStaysDeterministic() async throws {
        let pool = makePool(slots: 2) { key in
            key.layer * 1_000 + key.expert
        }
        let keys = [key(1, 1), key(1, 2), key(2, 1)]

        for _ in 0..<30 {
            for expected in keys {
                let lease = try await pool.acquire(expected)
                XCTAssertEqual(lease.payload, expected.layer * 1_000 + expected.expert)
                await pool.release(lease)
            }
        }

        let stats = await pool.statistics()
        XCTAssertLessThanOrEqual(stats.occupancySlots, 2)
        XCTAssertEqual(stats.occupancyBytes, UInt64(stats.occupancySlots) * 1_000)
    }

    // MARK: - Duplicate coalescing

    func testConcurrentDuplicateRequestsCoalesceOntoOneLoad() async throws {
        let counter = LockedCounter()
        let gate = AsyncGate()
        let pool = makePool(slots: 4) { key in
            counter.increment()
            await gate.waitOnce()
            return key.expert
        }
        let target = key(2, 5)

        let tasks = (0..<3).map { _ in
            Task { try await pool.acquire(target) }
        }
        try await waitUntil("loader started") { counter.value >= 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        await gate.open()

        var leases: [Edge0ExpertLease<Int>] = []
        for task in tasks {
            leases.append(try await task.value)
        }
        for lease in leases {
            await pool.release(lease)
        }

        XCTAssertEqual(counter.value, 1, "one expert must be read once")
        let stats = await pool.statistics()
        XCTAssertEqual(stats.misses, 1)
        XCTAssertGreaterThanOrEqual(stats.coalescedLoads, 2)
        XCTAssertEqual(stats.hits, 2, "coalesced callers hit after the install signals them")
        XCTAssertEqual(stats.occupancySlots, 1)
    }

    // MARK: - Pinning

    func testPinnedEntryIsNotEvictedUntilReleased() async throws {
        let pool = makePool(slots: 1) { key in key.expert }
        let pinned = key(1, 1)
        let waiting = key(2, 2)

        let lease = try await pool.acquire(pinned)
        let waiter = Task { try await pool.acquire(waiting) }

        var observedWait = false
        for _ in 0..<400 {
            let stats = await pool.statistics()
            if stats.capacityWaitCycles >= 1 {
                observedWait = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observedWait, "second acquire must wait for the pinned slot")
        let pinnedStillResident = await pool.contains(pinned)
        XCTAssertTrue(pinnedStillResident)

        await pool.release(lease)
        let second = try await waiter.value
        await pool.release(second)

        let stillResident = await pool.contains(waiting)
        XCTAssertTrue(stillResident)
    }

    // MARK: - ABA / stale async loads

    func testStaleAsyncLoadCannotOverwriteReassignedSlot() async throws {
        let counter = LockedCounter()
        let gate = AsyncGate()
        let pool = makePool(slots: 1) { key in
            counter.increment()
            if key.expert == 10 {
                await gate.waitOnce()
            }
            return key.expert
        }
        let staleKey = key(1, 10)
        let newKey = key(2, 20)

        let staleTask = Task { try await pool.acquire(staleKey) }
        try await waitUntil("stale load started") { counter.value >= 1 }

        // Invalidate the in-flight reservation and hand the slot to another
        // expert before the first load completes.
        await pool.clear()
        let fresh = try await pool.acquire(newKey)

        await gate.open()

        do {
            _ = try await staleTask.value
            XCTFail("Expected the stale load to be discarded")
        } catch {
            XCTAssertEqual(
                error as? Edge0ExpertPoolError,
                .staleReservationDiscarded(staleKey)
            )
        }

        let stats = await pool.statistics()
        XCTAssertEqual(stats.staleLoadsRejected, 1)
        let freshPayload = await pool.peek(newKey)
        XCTAssertNotNil(freshPayload, "the newer expert must not be overwritten")
        XCTAssertEqual(freshPayload, newKey.expert)
        await pool.release(fresh)
    }

    // MARK: - Clear

    func testClearDropsUnpinnedEntries() async throws {
        let pool = makePool(slots: 4) { key in key.expert }
        let target = key(3, 3)
        let lease = try await pool.acquire(target)
        await pool.release(lease)

        await pool.clear()

        let stats = await pool.statistics()
        XCTAssertEqual(stats.occupancySlots, 0)
        XCTAssertEqual(stats.occupancyBytes, 0)
        let contains = await pool.contains(target)
        XCTAssertFalse(contains)
    }

    // MARK: - Cancellation

    func testWaitingForSlotHonoursCancellation() async throws {
        let pool = makePool(slots: 1) { key in key.expert }
        let lease = try await pool.acquire(key(1, 1))
        let waiter = Task { try await pool.acquire(key(2, 2)) }

        var observedWait = false
        for _ in 0..<400 {
            let stats = await pool.statistics()
            if stats.capacityWaitCycles >= 1 {
                observedWait = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observedWait)

        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Expected CancellationError, got \(error)"
            )
        }
        await pool.release(lease)
    }

    // MARK: - Disabled pool

    func testDisabledPoolRefusesAcquire() async {
        let pool = makePool(slots: 0) { key in key.expert }
        do {
            _ = try await pool.acquire(key(1, 1))
            XCTFail("Expected poolDisabled")
        } catch {
            XCTAssertEqual(error as? Edge0ExpertPoolError, .poolDisabled)
        }
    }
}
