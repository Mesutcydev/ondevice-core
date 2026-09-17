import Foundation

// MARK: - Edge0DiagnosticPreferences
//
// Preference scope for the 35B speed diagnostic. The runner captures a
// snapshot before overriding anything and restores it from its `defer` on
// EVERY exit — normal completion, cancellation, and thrown errors. The
// restore always writes back the captured values (a user's intentional
// setting), never hard-coded defaults.
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
        /// Phase 5M candidate. Captured here so a diagnostic run can never
        /// leave kernel readahead enabled behind it, and so both arms of an
        /// A/B observe the same readahead state (it is set at model load).
        let readaheadHints: Bool

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
                readaheadHints:
                    Edge0EnginePreferences.edge0_35BReadaheadHints
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
            Edge0EnginePreferences.edge0_35BReadaheadHints = readaheadHints
        }
    }

    /// Runs `body` inside a captured scope. This is the same capture +
    /// `defer restore` pair the runner uses in `performRun`.
    static func withRestoration<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        let snapshot = Snapshot.capture()
        defer { snapshot.restore() }
        return try await body()
    }
}
