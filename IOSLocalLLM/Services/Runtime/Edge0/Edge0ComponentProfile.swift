import Foundation

// MARK: - Edge0ComponentProfile
//
// Coarse, aggregate wall-time attribution for the production runtime.
// Deliberately gated behind `Edge0EnginePreferences.componentProfilingEnabled`
// (default OFF) so normal generation pays nothing beyond nil checks.
//
// Components are intentionally coarse: router and shared-expert time are
// inside `moeSeconds`, and expert I/O wait is already reported by the
// staging/prerouter metrics. No per-operation logging.

enum Edge0ProfilePhase: String, Sendable {
    case prefill
    case decode
}

final class Edge0ComponentProfile: @unchecked Sendable {
    struct Components: Sendable, Equatable {
        var kdaSeconds = 0.0
        var mlaSeconds = 0.0
        var moeSeconds = 0.0
        var routerSeconds = 0.0
        var embeddingSeconds = 0.0
        var lmHeadSeconds = 0.0
        /// Time inside the sampler call. MLX evaluates lazily, so this often
        /// absorbs the completion of the previous step's graph; it is a
        /// submission+completion boundary, not exclusive GPU time.
        var samplingSeconds = 0.0
        // MoE sub-phases (35B). Acquisition includes pool waits; routed,
        // shared, and combine are graph submission; eval is the explicit
        // completion boundary before expert leases are released.
        var moeAcquireSeconds = 0.0
        var moeStackBuildSeconds = 0.0
        var moeSelectSeconds = 0.0
        var moeRoutedSeconds = 0.0
        var moeSharedSeconds = 0.0
        var moeCombineSeconds = 0.0
        var moeEvalSeconds = 0.0
        var moeReleaseSeconds = 0.0
        // Sample counts: a missing timer must never be read as 0.000 s.
        var moeAcquireSamples = 0.0
        var moeStackBuildSamples = 0.0
        var moeRoutedSamples = 0.0
        var moeSharedSamples = 0.0
        var moeCombineSamples = 0.0
        var moeEvalSamples = 0.0
        var moeReleaseSamples = 0.0
        /// Expert-stack accounting: 9 stacks (3 projections × weight/scales/
        /// biases) are rebuilt per invocation. `moeStackBytes` sums the
        /// SOURCE array bytes (the copy happens at eval, not here).
        var moeStacksBuilt = 0.0
        var moeStackBytes = 0.0
        /// Last observed gathered-QMM geometry (not accumulated).
        var gatherM = 0.0
        var gatherRows = 0.0
        var gatherExperts = 0.0
        /// MoE time by layer band (0–9 / 10–29 / 30–39), same boundary as
        /// `moeSeconds`.
        var moeEarlySeconds = 0.0
        var moeMiddleSeconds = 0.0
        var moeLateSeconds = 0.0
        var moeInvocations = 0.0
    }

    struct Snapshot: Sendable, Equatable {
        var prefill = Components()
        var decode = Components()
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var phase: Edge0ProfilePhase = .prefill

    /// Set by the model before each phase's layer loop (generation is
    /// serialized, so a single mutable phase tag is safe).
    func begin(_ phase: Edge0ProfilePhase) {
        lock.lock()
        self.phase = phase
        lock.unlock()
    }

    func record(_ component: WritableKeyPath<Components, Double>, seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock()
        switch phase {
        case .prefill:
            snapshot.prefill[keyPath: component] += seconds
        case .decode:
            snapshot.decode[keyPath: component] += seconds
        }
        lock.unlock()
    }

    /// Assign (not accumulate) a scalar — for last-observed geometry.
    func recordLast(
        _ component: WritableKeyPath<Components, Double>, value: Double
    ) {
        guard value > 0 else { return }
        lock.lock()
        switch phase {
        case .prefill:
            snapshot.prefill[keyPath: component] = value
        case .decode:
            snapshot.decode[keyPath: component] = value
        }
        lock.unlock()
    }

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
