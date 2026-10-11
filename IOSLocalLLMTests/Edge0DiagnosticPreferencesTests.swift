import XCTest
@testable import IOSLocalLLM

@MainActor
final class Edge0DiagnosticPreferencesTests: XCTestCase {
    private enum Exit: CaseIterable {
        case completed, failed, cancelled
    }

    private struct ExpectedFailure: Error {}

    /// Simulates settings frozen at model load. A drain continuation makes
    /// the release barrier observable without model weights or sleep timing.
    private final class LoadedRuntime {
        var configuration: Edge0DiagnosticPreferences.Snapshot?
        var drainCount = 0
        var drainContinuation: CheckedContinuation<Void, Never>?

        func drain(started: XCTestExpectation) async {
            drainCount += 1
            await withCheckedContinuation { continuation in
                drainContinuation = continuation
                started.fulfill()
            }
            configuration = nil
        }

        func finishDrain() {
            drainContinuation?.resume()
            drainContinuation = nil
        }
    }

    func testCleanupDrainsFrozenConfigurationBeforeRestorationOnEveryExit() async {
        let original = Edge0DiagnosticPreferences.Snapshot.capture()
        defer { original.restore() }

        for exit in Exit.allCases {
            Edge0EnginePreferences.poolCapacityBytesOverride = nil
            Edge0EnginePreferences.expertLoadConcurrency = 4
            Edge0EnginePreferences.edge0_35BPoolAccounting = .legacy
            // Intentional non-default setting must survive the diagnostic.
            Edge0EnginePreferences.edge0_35BSessionReuse = false
            let saved = Edge0DiagnosticPreferences.Snapshot.capture()
            let runtime = LoadedRuntime()
            let bodyStarted = expectation(description: "body started: \(exit)")
            let drainStarted = expectation(description: "drain started: \(exit)")
            var returned = false
            let task = Task { () -> String in
                defer { returned = true }
                do {
                    return try await Edge0DiagnosticPreferences.withRestoration(
                        cleanup: { await runtime.drain(started: drainStarted) }
                    ) {
                        Edge0EnginePreferences.poolCapacityBytesOverride = 512 * 1_048_576
                        Edge0EnginePreferences.expertLoadConcurrency = 6
                        Edge0EnginePreferences.edge0_35BPoolAccounting = .reclaimed
                        Edge0EnginePreferences.edge0_35BSessionReuse = true
                        runtime.configuration = Edge0DiagnosticPreferences.Snapshot.capture()
                        bodyStarted.fulfill()
                        switch exit {
                        case .completed:
                            return "completed"
                        case .failed:
                            throw ExpectedFailure()
                        case .cancelled:
                            while !Task.isCancelled { await Task.yield() }
                            try Task.checkCancellation()
                            return "unexpected completion"
                        }
                    }
                } catch is CancellationError {
                    return "cancelled"
                } catch is ExpectedFailure {
                    return "failed"
                } catch {
                    XCTFail("unexpected error: \(error)")
                    return "unexpected error"
                }
            }
            await fulfillment(of: [bodyStarted], timeout: 2)
            if exit == .cancelled { task.cancel() }
            await fulfillment(of: [drainStarted], timeout: 2)

            XCTAssertFalse(returned, "chat must not resume before runtime drain")
            XCTAssertEqual(runtime.drainCount, 1)
            XCTAssertEqual(runtime.configuration?.poolCapacityBytesOverride, 512 * 1_048_576)
            XCTAssertEqual(runtime.configuration?.expertLoadConcurrency, 6)
            XCTAssertEqual(runtime.configuration?.poolAccounting, .reclaimed)
            XCTAssertEqual(Edge0DiagnosticPreferences.Snapshot.capture(), runtime.configuration,
                           "preferences must remain scoped until the diagnostic engine is released")

            runtime.finishDrain()
            let outcome = await task.value
            XCTAssertEqual(outcome, String(describing: exit))
            XCTAssertTrue(returned)
            XCTAssertNil(runtime.configuration, "a loaded benchmark cache must not survive cleanup")
            XCTAssertEqual(runtime.drainCount, 1, "cleanup must run exactly once")
            XCTAssertEqual(Edge0DiagnosticPreferences.Snapshot.capture(), saved)
        }
    }

    func testSessionReuseRestoresBothCapturedValues() async {
        let original = Edge0DiagnosticPreferences.Snapshot.capture()
        defer { original.restore() }
        for saved in [false, true] {
            Edge0EnginePreferences.edge0_35BSessionReuse = saved
            await Edge0DiagnosticPreferences.withRestoration {
                Edge0EnginePreferences.edge0_35BSessionReuse = !saved
            }
            XCTAssertEqual(Edge0EnginePreferences.edge0_35BSessionReuse, saved)
        }
    }
}
