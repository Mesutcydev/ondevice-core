import Foundation

// MARK: - Edge0EnginePreferences
//
// Developer/A-B configuration for the Edge0 runtime. Not user-facing: the
// Diagnostics validation runner (and future internal defaults) read this.
// Exact mode remains available for correctness diagnostics.

enum Edge0EnginePreferences {
    private static let lock = NSLock()
    /// Device-verified default (Phase 4B-3, iPhone18,2): stagedPrerouter
    /// prefill + boundedPrefetch decode, with staged/exact available in
    /// Diagnostics as fallbacks/oracles.
    private static var _executionMode: Edge0ExecutionMode = .stagedPrerouter
    private static var _componentProfilingEnabled = false
    private static var _poolCapacityBytesOverride: UInt64?

    /// Phase 4B-4 experiment knobs (developer diagnostics only). nil pool
    /// override means automatic tier selection; overrides are clamped to the
    /// admission allowance by the backend and can never overcommit.
    static var componentProfilingEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _componentProfilingEnabled }
        set { lock.lock(); defer { lock.unlock() }; _componentProfilingEnabled = newValue }
    }

    static var poolCapacityBytesOverride: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return _poolCapacityBytesOverride }
        set { lock.lock(); defer { lock.unlock() }; _poolCapacityBytesOverride = newValue }
    }
    private static var _expertLoadConcurrency = 4

    /// Generation execution mode. Exact is the correctness oracle.
    static var executionMode: Edge0ExecutionMode {
        get { lock.lock(); defer { lock.unlock() }; return _executionMode }
        set { lock.lock(); defer { lock.unlock() }; _executionMode = newValue }
    }

    /// 35B family execution mode. Exact and boundedPrefetch are supported;
    /// staged/stagedPrerouter are not implemented for this family and are
    /// resolved (and reported) as exact. The default is the device-verified
    /// Bounded Prefetch promotion; an explicit assignment (diagnostics,
    /// future UI) always overrides it.
    private static var _edge0_35BExecutionMode: Edge0ExecutionMode =
        Edge0_35BEngine.defaultExecutionMode

    static var edge0_35BExecutionMode: Edge0ExecutionMode {
        get {
            lock.lock(); defer { lock.unlock() }
            return _edge0_35BExecutionMode
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BExecutionMode = newValue
        }
    }

    /// Experimental (Phase 5G candidate): number of staged-prefill tokens
    /// whose routed graphs are evaluated together. 1 = production behavior
    /// (per-token eval). The math per token is unchanged (M=1 QMM); only the
    /// completion boundary and lease lifetime are windowed. Clamped 1...8
    /// and further bounded by pool capacity at runtime.
    private static var _edge0_35BStagedEvalWindow = 1

    static var edge0_35BStagedEvalWindow: Int {
        get { lock.lock(); defer { lock.unlock() }; return _edge0_35BStagedEvalWindow }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BStagedEvalWindow = min(8, max(1, newValue))
        }
    }

    /// Prompt tokens per routed-MoE microbatch. **4 is the promoted
    /// production default** (Phase 5H device A/B, iPhone18,2 · 118-token
    /// prompt · 64 output tokens · greedy · Thinking Off · 512 MiB / 303
    /// slots · reads 4 · eval window 1): prefill 8.649 → 6.973 s median
    /// (−19.4%), TTFT −19.5%, first visible −19.5%, decode +2.5%, engine
    /// completion −10.9%; peak high-water ~2.50 → ~2.71 GB (+~8.4%, below
    /// the frozen review threshold). 1 = per-token routed execution
    /// (diagnostic/reference, selectable). Effective group is further
    /// bounded by pool capacity / topK at runtime. Clamped 1...4.
    private static var _edge0_35BMicrobatchGroupSize = 4

    static var edge0_35BMicrobatchGroupSize: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return _edge0_35BMicrobatchGroupSize
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BMicrobatchGroupSize = min(4, max(1, newValue))
        }
    }

    /// Phase 5J candidate: advisory 35B prerouter. Default OFF until the
    /// device A/B accepts it: when enabled and the optional released
    /// artifact is present, decode steps issue speculative expert loads for
    /// the NEXT token off the critical path. The true router remains the
    /// sole authority; execution stays byte-identical either way.
    private static var _edge0_35BAdvisoryPrerouter = false

    static var edge0_35BAdvisoryPrerouter: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _edge0_35BAdvisoryPrerouter
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BAdvisoryPrerouter = newValue
        }
    }

    /// Phase 5K candidate: batched router readback. 0 = production (one
    /// forced CPU readback per token per layer); 1 = candidate (all pending
    /// router index readbacks materialized once per group). Per-token router
    /// math is unchanged; only the completion boundary moves. Default 0
    /// until the device A/B accepts it.
    private static var _edge0_35BRouterReadbackMode = 0

    static var edge0_35BRouterReadbackMode: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return _edge0_35BRouterReadbackMode
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BRouterReadbackMode = min(1, max(0, newValue))
        }
    }

    /// Phase 5M candidate (upstream `warm_willneed`): advisory kernel
    /// readahead (`F_RDADVISE`) over the byte ranges of expert slices just
    /// before their `pread`s. Numerically inert by construction — it only
    /// asks the kernel to start async reads earlier — and it captures the
    /// flag once per engine load, so toggling mid-flight does not change an
    /// in-progress generation. Default OFF until the device A/B accepts it.
    private static var _edge0_35BReadaheadHints = false

    static var edge0_35BReadaheadHints: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _edge0_35BReadaheadHints
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _edge0_35BReadaheadHints = newValue
        }
    }

    /// Hard bound on concurrent expert preads. Clamped to the verified safe
    /// range (2/4/6 experiment set); the tensor store enforces it with its
    /// read semaphore.
    static var expertLoadConcurrency: Int {
        get { lock.lock(); defer { lock.unlock() }; return _expertLoadConcurrency }
        set {
            lock.lock(); defer { lock.unlock() }
            _expertLoadConcurrency = min(6, max(1, newValue))
        }
    }
}
