import Foundation

// MARK: - Edge0DiagnosticPreferences
//
// Preference scope for the 35B speed diagnostic. The runner captures a
// snapshot before overriding anything, drains the diagnostic runtime, then
// restores it on every exit — completion, cancellation, and thrown errors.
// Restoring preferences alone cannot change a loaded engine's cache or read
// concurrency. The next chat must load a fresh engine with the saved values.
//
// Kept free of app-layer types so the restoration path is executable in the
// macOS real-checkpoint harness (the app's CodingAssistantService cannot be
// built for the simulator on every host).

enum Edge0DiagnosticPreferences {
    struct Snapshot: Sendable, Equatable {
        let poolCapacityBytesOverride: UInt64?
        let expertLoadConcurrency: Int
        let executionMode: Edge0ExecutionMode
        let stagedEvalWindow: Int
        let microbatchGroupSize: Int
        let advisoryPrerouter: Bool
        let routerReadbackMode: Int
        let componentProfilingEnabled: Bool
        let sessionReuse: Bool
        /// Phase 5M candidate. Captured here so a diagnostic run can never
        /// leave kernel readahead enabled behind it, and so both arms of an
        /// A/B observe the same readahead state (it is set at model load).
        let readaheadHints: Bool
        /// Audit findings 1+2 candidate. Load-captured like readahead:
        /// captured here so a diagnostic run can never leave an arm's
        /// accounting behind it (it changes the budget the NEXT load
        /// resolves).
        let poolAccounting: Edge0_35BPoolAccounting

        static func capture() -> Snapshot {
            Snapshot(
                poolCapacityBytesOverride:
                    Edge0EnginePreferences.poolCapacityBytesOverride,
                expertLoadConcurrency:
                    Edge0EnginePreferences.expertLoadConcurrency,
                executionMode:
                    Edge0EnginePreferences.edge0_35BExecutionMode,
                stagedEvalWindow:
                    Edge0EnginePreferences.edge0_35BStagedEvalWindow,
                microbatchGroupSize:
                    Edge0EnginePreferences.edge0_35BMicrobatchGroupSize,
                advisoryPrerouter:
                    Edge0EnginePreferences.edge0_35BAdvisoryPrerouter,
                routerReadbackMode:
                    Edge0EnginePreferences.edge0_35BRouterReadbackMode,
                componentProfilingEnabled:
                    Edge0EnginePreferences.componentProfilingEnabled,
                sessionReuse:
                    Edge0EnginePreferences.edge0_35BSessionReuse,
                readaheadHints:
                    Edge0EnginePreferences.edge0_35BReadaheadHints,
                poolAccounting:
                    Edge0EnginePreferences.edge0_35BPoolAccounting
            )
        }

        func restore() {
            Edge0EnginePreferences.poolCapacityBytesOverride =
                poolCapacityBytesOverride
            Edge0EnginePreferences.expertLoadConcurrency =
                expertLoadConcurrency
            Edge0EnginePreferences.edge0_35BExecutionMode = executionMode
            Edge0EnginePreferences.edge0_35BStagedEvalWindow =
                stagedEvalWindow
            Edge0EnginePreferences.edge0_35BMicrobatchGroupSize =
                microbatchGroupSize
            Edge0EnginePreferences.edge0_35BAdvisoryPrerouter =
                advisoryPrerouter
            Edge0EnginePreferences.edge0_35BRouterReadbackMode =
                routerReadbackMode
            Edge0EnginePreferences.componentProfilingEnabled =
                componentProfilingEnabled
            Edge0EnginePreferences.edge0_35BSessionReuse = sessionReuse
            Edge0EnginePreferences.edge0_35BReadaheadHints = readaheadHints
            Edge0EnginePreferences.edge0_35BPoolAccounting = poolAccounting
        }
    }

    /// Await cleanup before restoring preferences or returning control to
    /// chat. Cleanup must drain even when the body throws or is cancelled.
    @MainActor
    static func withRestoration<T>(
        cleanup: () async -> Void = {},
        _ body: () async throws -> T
    ) async rethrows -> T {
        let snapshot = Snapshot.capture()
        defer { snapshot.restore() }
        let result: T
        do {
            result = try await body()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        return result
    }
}
