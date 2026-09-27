import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0RuntimeBackendTests
//
// Structural tests for the app-layer adapter. Full generation over the real
// checkpoint is exercised by the macOS harness (Edge0EngineLifecycleTests);
// these tests verify factory wiring and clean failure behavior.

final class Edge0RuntimeBackendTests: XCTestCase {

    @MainActor
    func testFactoryBuildsEdge0EngineThroughManagedLifecycle() throws {
        let model = LocalModel(
            id: "edge0-8b",
            repoID: "Edge0/Edge0-8B-A1B-preview",
            displayName: "Edge0-8B",
            familyID: "bailing",
            runtime: .edge0MLX
        )
        let engine = try RuntimeEngineFactory.makeEngine(for: model)
        XCTAssertEqual(engine.runtime, .edge0MLX)
        XCTAssertTrue(engine.capabilities.supportsExpertStreaming)
        XCTAssertFalse(engine.capabilities.supportsVision)
    }

    @MainActor
    func testLoadWithoutInstalledCheckpointFailsCleanly() async {
        let backend = Edge0RuntimeBackend()
        let model = LocalModel(
            id: "edge0-8b-missing",
            repoID: "Edge0/Edge0-8B-A1B-preview",
            displayName: "Edge0-8B",
            familyID: "bailing",
            runtime: .edge0MLX
        )
        do {
            try await backend.load(model: model)
            XCTFail("Expected load to fail without an installed checkpoint")
        } catch let error as RuntimeError {
            if case .invalidModelFiles = error {
                // expected
            } else if case .modelLoadBlocked = error {
                // also acceptable when the device refuses admission
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await backend.unload()
        await backend.unload()
    }

    // MARK: - Generation ownership (#7)
    //
    // The engines are `@unchecked Sendable` classes whose `cancel()` runs on
    // the MainActor while `generate()` runs on a non-isolated task. The
    // active-generation identity is therefore genuinely shared. These tests
    // pin the compare-and-clear semantics that replace the previous
    // check-then-act (`if generationID == generation { generationID = nil }`),
    // which could steal ownership from a newer generation.
    //
    // No checkpoint is needed: ownership is engine bookkeeping.

    func testGenerationIdentityIsClaimableAndObservable() {
        let engine = Edge0_35BEngine()
        XCTAssertNil(engine.generationID)
        XCTAssertFalse(engine.isGenerationInFlight)

        let id = UUID()
        engine.generationID = id
        XCTAssertEqual(engine.generationID, id)
        XCTAssertTrue(engine.isGenerationInFlight)
    }

    func testClearGenerationOnlyClearsTheMatchingOwner() {
        let engine = Edge0_35BEngine()
        let first = UUID()
        let second = UUID()

        engine.generationID = first
        XCTAssertTrue(engine.clearGeneration(if: first))
        XCTAssertNil(engine.generationID)

        // A stale completion for `first` must not clear a newer generation.
        engine.generationID = second
        XCTAssertFalse(engine.clearGeneration(if: first))
        XCTAssertEqual(engine.generationID, second, "stale clear stole ownership")

        XCTAssertTrue(engine.clearGeneration(if: second))
        XCTAssertNil(engine.generationID)
    }

    /// The race the fix exists for: a newer generation is claimed while an
    /// older one is completing. Under the old unconditional
    /// `generationID = nil` in the cancellation/completion paths, the newer
    /// generation would lose its identity and become uncancellable.
    func testSupersededGenerationCannotStealNewerOwnership() async {
        let engine = Edge0_35BEngine()
        let older = UUID()
        let newer = UUID()

        engine.generationID = older
        // Simulate the backend starting a second generation while the first is
        // still finishing (no checkpoint, so only the bookkeeping is tested).
        engine.generationID = newer

        // Older generation's deferred completion fires.
        let cleared = await Task.detached {
            engine.clearGeneration(if: older)
        }.value
        XCTAssertFalse(cleared)
        XCTAssertEqual(engine.generationID, newer)
        XCTAssertTrue(engine.isGenerationInFlight, "newer generation lost its identity")

        XCTAssertTrue(engine.clearGeneration(if: newer))
        XCTAssertFalse(engine.isGenerationInFlight)
    }

    /// `cancel()` is a force-stop: it clears whatever is current, matching the
    /// previous unconditional semantics.
    func testCancelForcesOwnershipClear() {
        let engine = Edge0_35BEngine()
        engine.generationID = UUID()
        engine.cancel()
        XCTAssertNil(engine.generationID)
        XCTAssertFalse(engine.isGenerationInFlight)
        // Idempotent when already idle.
        engine.cancel()
        XCTAssertNil(engine.generationID)
    }

    /// Concurrent claim/clear cycles must not corrupt the guarded state.
    func testConcurrentOwnershipAccessStaysConsistent() async {
        let engine = Edge0_35BEngine()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    let id = UUID()
                    engine.generationID = id
                    _ = engine.isGenerationInFlight
                    // Only the currently-claiming task can clear; the others
                    // race harmlessly because every path is lock-guarded.
                    if index.isMultiple(of: 2) {
                        engine.clearGeneration(if: id)
                    }
                }
            }
        }
        // The guarded invariant: `isGenerationInFlight` must agree with the
        // identity, and clearing whatever survived must leave it idle. A torn
        // or duplicated state would show up as a disagreement here.
        let current = engine.generationID
        XCTAssertEqual(engine.isGenerationInFlight, current != nil)
        if let current {
            XCTAssertTrue(engine.clearGeneration(if: current))
        }
        XCTAssertNil(engine.generationID)
        XCTAssertFalse(engine.isGenerationInFlight)
    }
}
