import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0SpeedABRunnerCleanupTests
//
// Phase 5K closeout: the 35B speed diagnostic overrides several engine
// preferences for the duration of a run. Its cleanup path (the
// `PreferenceScope` restore executed from the runner's `defer`) must put the
// ORIGINAL values back on every exit class — normal completion, thrown
// error, and cancellation — and must never write harcoded defaults over a
// user's intentional setting.
//
// These tests drive the real scope wrapper the runner uses
// (`withPreferenceScope`), plus one end-to-end `run()`/`cancel()` check.

@MainActor
final class Edge0SpeedABRunnerCleanupTests: XCTestCase {

    private func resetPreferences() {
        Edge0EnginePreferences.edge0_35BRouterReadbackMode = 0
        Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = false
        Edge0EnginePreferences.edge0_35BStagedEvalWindow = 1
        Edge0EnginePreferences.edge0_35BMicrobatchGroupSize = 4
        Edge0EnginePreferences.edge0_35BExecutionMode = .staged
        Edge0EnginePreferences.componentProfilingEnabled = false
        Edge0EnginePreferences.edge0_35BReadaheadHints = false
        Edge0EnginePreferences.expertLoadConcurrency = 4
        Edge0EnginePreferences.edge0_35BPoolAccounting = .legacy
    }

    override func tearDown() {
        resetPreferences()
        super.tearDown()
    }

    /// The scope restores whichever value was captured, for both possible
    /// originals — it does not force zero.
    func testScopeRestoresCapturedZeroAndOneOnCompletion() async {
        for original in [0, 1] {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BRouterReadbackMode = original
            await Edge0DiagnosticPreferences.withRestoration {
                Edge0EnginePreferences.edge0_35BRouterReadbackMode = 1 - original
                Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = true
            }
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BRouterReadbackMode, original,
                "normal completion must restore \(original)"
            )
            XCTAssertFalse(Edge0EnginePreferences.edge0_35BAdvisoryPrerouter)
        }
    }

    /// A thrown error inside the run body still restores the original.
    func testScopeRestoresWhenBodyThrows() async {
        struct Boom: Error {}
        for original in [0, 1] {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BRouterReadbackMode = original
            do {
                try await Edge0DiagnosticPreferences.withRestoration { () async throws -> Void in
                    Edge0EnginePreferences.edge0_35BRouterReadbackMode = 1 - original
                    throw Boom()
                }
                XCTFail("expected the body to throw")
            } catch {
                // expected
            }
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BRouterReadbackMode, original,
                "a thrown error must restore \(original)"
            )
        }
    }

    /// Cancellation inside the run body still restores the original.
    func testScopeRestoresWhenBodyIsCancelled() async {
        for original in [0, 1] {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BRouterReadbackMode = original
            let task = Task { () -> Void in
                await Edge0DiagnosticPreferences.withRestoration {
                    Edge0EnginePreferences.edge0_35BRouterReadbackMode = 1 - original
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            task.cancel()
            await task.value
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BRouterReadbackMode, original,
                "cancellation must restore \(original)"
            )
        }
    }

    /// Restoration writes the CAPTURED value, never a default: a user's
    /// intentional non-default setting survives when nothing changed.
    func testRestoreDoesNotOverwriteIntentionalUserPreference() {
        resetPreferences()
        Edge0EnginePreferences.edge0_35BRouterReadbackMode = 1
        Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = true
        let scope = Edge0DiagnosticPreferences.Snapshot.capture()
        // Nothing mutates during this window; restore must be a faithful
        // write-back of the captured (user) values.
        scope.restore()
        XCTAssertEqual(Edge0EnginePreferences.edge0_35BRouterReadbackMode, 1)
        XCTAssertTrue(Edge0EnginePreferences.edge0_35BAdvisoryPrerouter)
        XCTAssertEqual(Edge0EnginePreferences.edge0_35BStagedEvalWindow, 1)
    }

    /// End-to-end: the actual runner's cleanup path restores the preference
    /// whether the run ends by cancellation or by the early
    /// "model did not load" failure, for both original values.
    func testRunnerRunTerminationRestoresPreference() async {
        for original in [0, 1] {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BRouterReadbackMode = original
            let runner = Edge0SpeedABRunner()
            runner.kind = .computeAB
            let task = Task { await runner.run() }
            // Give the run time to capture its scope (it will either be
            // cancelled here or fail early because the 35B model is not
            // installed on this host).
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(
                runner.isRunning || runner.terminal != nil
                    || runner.status.contains("did not load"),
                "runner must have started or finished cleanly"
            )
            runner.cancel()
            await task.value
            XCTAssertFalse(runner.isRunning)
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BRouterReadbackMode, original,
                "run termination (cancel or early failure) must restore \(original)"
            )
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BExecutionMode, .staged,
                "production execution mode must be restored"
            )
        }
    }

    /// Phase 5M: readahead is captured and restored like every other candidate
    /// knob, for both possible originals. It is set at model load, so a leaked
    /// value would silently change the NEXT run's engine configuration.
    func testScopeRestoresReadaheadAndReadConcurrency() async {
        for original in [false, true] {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BReadaheadHints = original
            Edge0EnginePreferences.expertLoadConcurrency = 2
            await Edge0DiagnosticPreferences.withRestoration {
                Edge0EnginePreferences.edge0_35BReadaheadHints = !original
                Edge0EnginePreferences.expertLoadConcurrency = 6
            }
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BReadaheadHints, original,
                "readahead must restore \(original)"
            )
            XCTAssertEqual(
                Edge0EnginePreferences.expertLoadConcurrency, 2,
                "read concurrency must restore its captured value, not a default"
            )
        }
    }

    /// The snapshot type must expose readahead so callers can assert on what
    /// was captured; this guards against the field being dropped from
    /// `capture()`/`restore()` in a future edit.
    func testSnapshotIncludesReadahead() {
        resetPreferences()
        Edge0EnginePreferences.edge0_35BReadaheadHints = true
        let snapshot = Edge0DiagnosticPreferences.Snapshot.capture()
        XCTAssertTrue(snapshot.readaheadHints)

        Edge0EnginePreferences.edge0_35BReadaheadHints = false
        snapshot.restore()
        XCTAssertTrue(Edge0EnginePreferences.edge0_35BReadaheadHints)
    }

    /// Audit findings 1+2: pool accounting is captured and restored like
    /// every other candidate knob — a leaked arm would change the budget the
    /// NEXT load resolves.
    func testScopeRestoresPoolAccounting() async {
        for original in Edge0_35BPoolAccounting.allCases {
            resetPreferences()
            Edge0EnginePreferences.edge0_35BPoolAccounting = original
            await Edge0DiagnosticPreferences.withRestoration {
                Edge0EnginePreferences.edge0_35BPoolAccounting =
                    original == .legacy ? .reclaimed : .legacy
            }
            XCTAssertEqual(
                Edge0EnginePreferences.edge0_35BPoolAccounting, original,
                "pool accounting must restore \(original.rawValue)"
            )
        }
    }

    func testSnapshotIncludesPoolAccounting() {
        resetPreferences()
        Edge0EnginePreferences.edge0_35BPoolAccounting = .reclaimed
        let snapshot = Edge0DiagnosticPreferences.Snapshot.capture()
        XCTAssertEqual(snapshot.poolAccounting, .reclaimed)

        Edge0EnginePreferences.edge0_35BPoolAccounting = .legacy
        snapshot.restore()
        XCTAssertEqual(Edge0EnginePreferences.edge0_35BPoolAccounting, .reclaimed)
    }

    /// The single-active-diagnostic guard must stay intact: a second `run()`
    /// while one is active is ignored (run identity unchanged).
    func testSecondRunWhileActiveIsIgnored() async throws {        resetPreferences()
        let runner = Edge0SpeedABRunner()
        runner.kind = .computeAB
        let first = Task { await runner.run() }

        var observedActive = false
        for _ in 0..<40 {
            if runner.isRunning { observedActive = true; break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard observedActive else {
            // The early model-load failure finished before the guard could be
            // observed on this host; the guard itself is unchanged.
            runner.cancel()
            await first.value
            throw XCTSkip(
                "runner terminated before the active state was observable"
            )
        }
        let runID = runner.runID
        await runner.run()
        XCTAssertEqual(
            runner.runID, runID,
            "a second run() while active must be ignored"
        )
        XCTAssertTrue(runner.isRunning)
        runner.cancel()
        await first.value
        XCTAssertFalse(runner.isRunning)
    }
}
