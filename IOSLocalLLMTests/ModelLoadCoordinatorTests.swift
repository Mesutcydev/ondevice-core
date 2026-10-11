import XCTest
@testable import IOSLocalLLM

@MainActor
final class ModelLoadCoordinatorTests: XCTestCase {
    func testRepeatedRequestsJoinBeforePreparationFinishes() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), preparation = Latch()
        var nativeLoads = 0
        let first = Task {
            await coordinator.run {
                started.open()
                await preparation.wait()
                nativeLoads += 1
            }
        }
        await started.wait()
        let joined = Latch()
        var joins = 0
        let repeated = (0..<20).map { _ in
            Task {
                joins += 1
                if joins == 20 { joined.open() }
                await coordinator.run { nativeLoads += 1 }
            }
        }
        await joined.wait()
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertEqual(nativeLoads, 0)
        preparation.open()
        await first.value
        for request in repeated { await request.value }
        XCTAssertEqual(nativeLoads, 1)
        XCTAssertFalse(coordinator.isLoading)
    }

    func testUnloadDuringPreparationPreventsNativeAllocation() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), preparation = Latch()
        var nativeLoads = 0
        let request = Task {
            await coordinator.run {
                started.open()
                await preparation.wait()
                guard !Task.isCancelled else { return }
                nativeLoads += 1
            }
        }
        await started.wait()
        let retiring = coordinator.cancel()
        XCTAssertTrue(coordinator.isLoading)
        preparation.open()
        await retiring?.value
        XCTAssertEqual(nativeLoads, 0)
        await request.value
    }

    func testCancelledNonInterruptibleLoadBlocksReplacementUntilRetired() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), nativeCompletion = Latch()
        var nativeLoads = 0
        var published = false
        let first = Task {
            await coordinator.run {
                nativeLoads += 1
                started.open()
                // A native loader may ignore cancellation until it returns.
                await nativeCompletion.wait()
                if !Task.isCancelled { published = true }
            }
        }
        await started.wait()
        let retiring = coordinator.cancel()
        let duplicate = Task { await coordinator.run { nativeLoads += 1 } }
        await Task.yield()
        XCTAssertEqual(nativeLoads, 1)
        XCTAssertTrue(coordinator.isLoading)
        nativeCompletion.open()
        await retiring?.value
        await first.value
        await duplicate.value
        XCTAssertEqual(nativeLoads, 1)
        XCTAssertFalse(published)
    }

    func testTeardownWaitsForLoadLocalReferencesToRelease() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), nativeCompletion = Latch()
        weak var weights: Weights?
        var cleanupFinished = false
        let first = Task {
            await coordinator.run {
                let resource = Weights()
                weights = resource
                started.open()
                await nativeCompletion.wait()
                withExtendedLifetime(resource) {}
            }
        }
        await started.wait()
        let retiring = coordinator.cancel()
        let cleanup = Task {
            await retiring?.value
            XCTAssertNil(weights)
            cleanupFinished = true
        }
        await Task.yield()
        XCTAssertNotNil(weights)
        XCTAssertFalse(cleanupFinished)
        nativeCompletion.open()
        await cleanup.value
        await first.value
        XCTAssertTrue(cleanupFinished)
    }

    func testRetryCanStartImmediatelyAfterTeardownJoinsJob() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), nativeCompletion = Latch()
        let first = Task {
            await coordinator.run {
                started.open()
                await nativeCompletion.wait()
            }
        }
        await started.wait()
        let retiring = coordinator.cancel()
        nativeCompletion.open()
        await retiring?.value
        var reloaded = false
        await coordinator.run { reloaded = true }
        XCTAssertTrue(reloaded)
        await first.value
    }

    func testCancellingOwnerPropagatesToLoader() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), nativeCompletion = Latch()
        var cancelled = false
        let first = Task {
            await coordinator.run {
                started.open()
                await nativeCompletion.wait()
                cancelled = Task.isCancelled
            }
        }
        await started.wait()
        first.cancel()
        nativeCompletion.open()
        await first.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(coordinator.isLoading)
    }

    func testCancellingWaiterDoesNotCancelOwner() async {
        let coordinator = ModelLoadCoordinator()
        let started = Latch(), nativeCompletion = Latch()
        var cancelled = false
        let first = Task {
            await coordinator.run {
                started.open()
                await nativeCompletion.wait()
                cancelled = Task.isCancelled
            }
        }
        await started.wait()
        let waiter = Task { await coordinator.run { XCTFail("Duplicate native load") } }
        await Task.yield()
        waiter.cancel()
        nativeCompletion.open()
        await first.value
        await waiter.value
        XCTAssertFalse(cancelled)
    }

    func testCancelledVisionLoadKeepsAdmissionClosedUntilRetired() throws {
        var lifetime = PresentationRequestLifetime()
        let load = try XCTUnwrap(lifetime.begin())
        lifetime.cancel()
        XCTAssertFalse(lifetime.accepts(load))
        XCTAssertNil(lifetime.begin())
        XCTAssertTrue(lifetime.finish(load))
        XCTAssertNotNil(lifetime.begin())
    }

    func testOldVisionCompletionCannotPublishOrReleaseReload() throws {
        var lifetime = PresentationRequestLifetime()
        let oldLoad = try XCTUnwrap(lifetime.begin())
        lifetime.cancel()
        lifetime.finish(oldLoad)
        let reload = try XCTUnwrap(lifetime.begin())
        XCTAssertFalse(lifetime.accepts(oldLoad))
        XCTAssertFalse(lifetime.finish(oldLoad))
        XCTAssertTrue(lifetime.accepts(reload))
    }

    func testVisionLifetimeAllowsNormalCompletionAndReload() throws {
        var lifetime = PresentationRequestLifetime()
        let load = try XCTUnwrap(lifetime.begin())
        XCTAssertTrue(lifetime.accepts(load))
        XCTAssertTrue(lifetime.finish(load))
        XCTAssertFalse(lifetime.isRunning)
        XCTAssertFalse(lifetime.isCancelled)
        XCTAssertNotNil(lifetime.begin())
    }

    private final class Weights {}

    private final class Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
