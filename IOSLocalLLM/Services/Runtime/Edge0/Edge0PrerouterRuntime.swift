import Foundation
import MLX

// MARK: - Edge0ExpertPredictor
//
// Advisory expert predictor. Implementations predict expert IDs for a
// TARGET layer; the true router remains the sole authority on execution.

protocol Edge0ExpertPredictor: Sendable {
    /// Whether this predictor has a trained head for `owner`. Owners without
    /// a head are skipped silently — they are NOT prediction failures.
    func owns(owner: Int) -> Bool
    /// - Parameters:
    ///   - owner: owner layer whose MoE input produced the features
    ///   - hidden: `[1, 1, hidden]` MoE input for one token
    ///   - thisIDs: executed top-k expert IDs of the owner layer, this token
    ///   - prevIDs: executed top-k expert IDs of the owner layer, previous token
    /// - Returns: predicted expert IDs for `owner + 1` (may be empty), or nil.
    func predictedExpertIDs(
        owner: Int,
        hidden: MLXArray,
        thisIDs: [Int],
        prevIDs: [Int],
        topK: Int
    ) throws -> [Int]?
}

extension Edge0ExpertPredictor {
    /// Fail-closed default: a predictor must EXPLICITLY claim an owner. A
    /// wildcard default silently routed non-owner layers into prediction
    /// scheduling (and counted them as missing-head fallbacks).
    func owns(owner: Int) -> Bool { false }
}

extension Edge0Prerouter: Edge0ExpertPredictor {
    func owns(owner: Int) -> Bool {
        heads[owner] != nil
    }

    func predictedExpertIDs(
        owner: Int,
        hidden: MLXArray,
        thisIDs: [Int],
        prevIDs: [Int],
        topK: Int
    ) throws -> [Int]? {
        guard let result = predict(
            owner: owner,
            hidden: hidden,
            thisOneHot: Self.oneHot(
                ids: thisIDs, numExperts: configuration.numExperts
            ),
            prevOneHot: Self.oneHot(
                ids: prevIDs, numExperts: configuration.numExperts
            ),
            topK: topK
        ) else {
            return nil
        }
        return result.indices
            .asType(.int32)
            .asArray(Int32.self)
            .map { Int($0) }
    }
}

// MARK: - Edge0PrerouterMetrics
//
// Advisory-prediction counters. Definitions are deliberately conservative:
//   correctPredictions   predicted experts that the true router also selected
//   actualMissesAvoided  correct predictions already loaded by the prefetch
//                        ledger when the true selection was reconciled
//   readyFromPrediction  same event as actualMissesAvoided (kept separate for
//                        the report's vocabulary)
//   lateDespitePrediction correct predictions NOT yet loaded at reconcile
//   unusedPrefetchedBytes wrong predictions whose speculative read completed
// No prompt or generated content ever enters these counters.

final class Edge0PrerouterMetrics: @unchecked Sendable {
    static let expertBundleBytes: UInt64 = 1_327_104

    /// Phase in which a prediction was scheduled. Prefill-only scheduling is
    /// currently unimplemented; decode predictions target the NEXT token.
    enum PredictionPhase: String, Sendable {
        case prefill
        case decode
    }

    /// Fixed, bounded fallback taxonomy (never free text from a predictor).
    enum FallbackReason: String, CaseIterable, Sendable {
        case missingHead = "missing-head"
        case predictionFailed = "prediction-failed"
        case runtimeClosed = "runtime-closed"
    }

    struct Layer: Sendable, Equatable {
        var predictions = 0
        var predicted = 0
        var correct = 0
        var actual = 0
        var missesAvoided = 0
        var unused = 0
    }

    struct Snapshot: Sendable, Equatable {
        var predictions = 0
        var predictedExperts = 0
        var correctPredictions = 0
        var trueExperts = 0

        /// Heads that actually executed and produced a prediction.
        var headInvocations = 0
        var prefillPredictions = 0
        var decodePredictions = 0
        var fallbackReasons: [String: Int] = [:]

        var prefetchRequests = 0
        var prefetchAlreadyResident = 0
        var prefetchLoadsStarted = 0
        var prefetchLoadsCompleted = 0
        var prefetchBytes: UInt64 = 0

        var unusedPredictedExperts = 0
        /// Wrong predictions that were ACTUALLY read by the speculative
        /// prefetch ledger (not a theoretical bundle-size estimate).
        var unusedPrefetchedBytes: UInt64 = 0

        var actualMissesAvoided = 0
        var readyFromPrediction = 0
        var lateDespitePrediction = 0
        var fallbacks = 0

        var perLayer: [Int: Layer] = [:]

        var precision: Double {
            predictedExperts > 0
                ? Double(correctPredictions) / Double(predictedExperts) : 0
        }
        var recall: Double {
            trueExperts > 0
                ? Double(correctPredictions) / Double(trueExperts) : 0
        }
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    private func mutate(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        body(&snapshot)
        lock.unlock()
    }

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func recordHeadInvocation(phase: PredictionPhase) {
        mutate {
            $0.headInvocations += 1
            switch phase {
            case .prefill: $0.prefillPredictions += 1
            case .decode: $0.decodePredictions += 1
            }
        }
    }

    func recordFallback(reason: FallbackReason) {
        mutate {
            $0.fallbacks += 1
            $0.fallbackReasons[reason.rawValue, default: 0] += 1
        }
    }

    func recordPrediction(targetLayer: Int, predicted: Int) {
        mutate {
            $0.predictions += 1
            $0.predictedExperts += predicted
            var layer = $0.perLayer[targetLayer] ?? Layer()
            layer.predictions += 1
            layer.predicted += predicted
            $0.perLayer[targetLayer] = layer
        }
    }

    func recordReconcile(
        targetLayer: Int,
        actualCount: Int,
        correct: [Int],
        ready: Set<Int>,
        unused: [Int],
        unusedPrefetchedCount: Int
    ) {
        mutate {
            $0.correctPredictions += correct.count
            $0.trueExperts += actualCount
            $0.unusedPredictedExperts += unused.count
            $0.unusedPrefetchedBytes += UInt64(unusedPrefetchedCount)
                * Self.expertBundleBytes
            let readyCount = correct.filter { ready.contains($0) }.count
            $0.actualMissesAvoided += readyCount
            $0.readyFromPrediction += readyCount
            $0.lateDespitePrediction += correct.count - readyCount
            var layer = $0.perLayer[targetLayer] ?? Layer()
            layer.correct += correct.count
            layer.actual += actualCount
            layer.missesAvoided += readyCount
            layer.unused += unused.count
            $0.perLayer[targetLayer] = layer
        }
    }

    func recordPrefetchRequest(alreadyResident: Bool, started: Bool) {
        mutate {
            $0.prefetchRequests += 1
            if alreadyResident { $0.prefetchAlreadyResident += 1 }
            if started {
                $0.prefetchLoadsStarted += 1
                $0.prefetchBytes += Self.expertBundleBytes
            }
        }
    }

    func recordPrefetchCompleted() {
        mutate { $0.prefetchLoadsCompleted += 1 }
    }

    func recordFallback() {
        mutate { $0.fallbacks += 1 }
    }
}

// MARK: - Edge0PrerouterRuntime
//
// Generation-scoped advisory state: per-owner previous-token top-k IDs,
// pending predictions keyed by (target layer, token), a load ledger for
// reconcile-time residency, a single-flight bounded prefetch scheduler, and
// metrics. Predictions never pin experts: a satisfied prefetch becomes an
// ordinary unpinned LRU entry.

/// Bounded diagnostic event for harness evidence only. Production leaves
/// the sink nil (zero cost); no payload, prompt, or content is included.
enum Edge0PrerouterEvent: Sendable {
    /// Emitted synchronously on the engine task when scheduling begins.
    case requested(
        owner: Int, targetLayer: Int,
        sourceToken: Int, targetToken: Int, phase: String
    )
    /// Emitted off the hot path once a head produced predictions.
    case produced(
        owner: Int, targetLayer: Int, targetToken: Int, predicted: [Int]
    )
    /// Emitted synchronously when the true router reconciles a target.
    case reconciled(
        targetLayer: Int, targetToken: Int, predicted: [Int],
        actual: [Int], ready: [Int], late: [Int], unused: [Int]
    )
}

final class Edge0PrerouterRuntime<Payload: Sendable>: @unchecked Sendable {
    struct TargetKey: Hashable, Sendable {
        let layer: Int
        let token: Int
    }

    /// Diagnostic trace sink (nil in production). Events are bounded by the
    /// caller's sink; the runtime never retains them.
    nonisolated(unsafe) var eventSink:
        (@Sendable (Edge0PrerouterEvent) -> Void)?

    let predictor: any Edge0ExpertPredictor
    let pool: Edge0ExpertPool<Payload>
    let metrics = Edge0PrerouterMetrics()

    private let lock = NSLock()
    private var previousIDs: [Int: [Int]] = [:]
    private var pending: [TargetKey: Set<Int>] = [:]
    private var prefetched: Set<Edge0ExpertKey> = []
    private var inFlightPredictions = 0
    private var closed = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private let scheduler: Edge0SpeculativeScheduler<Payload>

    init(
        predictor: any Edge0ExpertPredictor,
        pool: Edge0ExpertPool<Payload>
    ) {
        self.predictor = predictor
        self.pool = pool
        self.scheduler = Edge0SpeculativeScheduler(pool: pool)
        scheduler.onLoadCompleted = { [weak self] key in
            self?.notePrefetched(key)
        }
        scheduler.onRequest = { [weak self] alreadyResident, started in
            self?.metrics.recordPrefetchRequest(
                alreadyResident: alreadyResident, started: started
            )
        }
    }

    /// Records the owner's current/previous top-k immediately (ordering
    /// matters), then runs the advisory head OFF the generation hot path so
    /// prediction GPU work never blocks true-router execution.
    func predictAndSchedule(
        owner: Int,
        hidden: MLXArray,
        thisIDs: [Int],
        token: Int,
        targetLayerCount: Int,
        topK: Int,
        phase: Edge0PrerouterMetrics.PredictionPhase = .decode,
        sourceToken: Int? = nil
    ) {
        // Owners outside the trained range (e.g. layers 1...6) are expected
        // and skipped without touching GPU work or the failure counter.
        guard predictor.owns(owner: owner) else { return }
        guard owner + 1 < targetLayerCount else { return }

        let previous = withLock { previousIDs[owner] ?? [] }
        withLock { previousIDs[owner] = thisIDs }
        let target = owner + 1
        if let sourceToken, let eventSink {
            eventSink(.requested(
                owner: owner, targetLayer: target,
                sourceToken: sourceToken, targetToken: token,
                phase: phase.rawValue
            ))
        }
        beginPrediction()
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishPrediction() }
            if self.isClosed {
                self.metrics.recordFallback(reason: .runtimeClosed)
                return
            }
            let predicted: [Int]
            do {
                guard let result = try self.predictor.predictedExpertIDs(
                    owner: owner,
                    hidden: hidden,
                    thisIDs: thisIDs,
                    prevIDs: previous,
                    topK: topK
                ) else {
                    self.metrics.recordFallback(reason: .missingHead)
                    return
                }
                self.metrics.recordHeadInvocation(phase: phase)
                predicted = Array(Set(result)).sorted()
                self.eventSink?(.produced(
                    owner: owner, targetLayer: target,
                    targetToken: token, predicted: predicted
                ))
            } catch {
                // Optional optimization: failure never propagates.
                self.metrics.recordFallback(reason: .predictionFailed)
                return
            }
            self.metrics.recordPrediction(
                targetLayer: target, predicted: predicted.count
            )
            self.withLock {
                guard !self.closed else { return }
                self.pending[TargetKey(layer: target, token: token)] = Set(predicted)
            }
            let keys = predicted.map {
                Edge0ExpertKey(layer: target, expert: $0)
            }
            await self.scheduler.enqueue(keys)
        }
    }

    /// Suspends until every scheduled prediction task has finished. Used by
    /// engine unload / model switching so no speculative work can outlive or
    /// interleave with a runtime transition. Cancellation-aware.
    func waitForQuiescence() async {
        await withCheckedContinuation { continuation in
            let done: Bool = withLock {
                if inFlightPredictions == 0 || closed { return true }
                quiescenceWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func beginPrediction() {
        withLock { inFlightPredictions += 1 }
    }

    private func finishPrediction() {
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            inFlightPredictions = max(0, inFlightPredictions - 1)
            guard inFlightPredictions == 0 else { return [] }
            let pending = quiescenceWaiters
            quiescenceWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    private var isClosed: Bool {
        withLock { closed }
    }

    /// Called when the true router for `targetLayer` token `token` produces
    /// its actual selection. Compares against the recorded prediction and
    /// updates quality/residency counters. Never blocks the hot path.
    func reconcile(targetLayer: Int, token: Int, actualIDs: [Int]) {
        let predicted = withLock {
            pending.removeValue(
                forKey: TargetKey(layer: targetLayer, token: token)
            ) ?? []
        }
        let actual = Set(actualIDs)
        let correct = predicted.intersection(actual)
        let unused = predicted.subtracting(actual)
        let ready = withLock { correct.filter { prefetched.contains(
            Edge0ExpertKey(layer: targetLayer, expert: $0)
        ) } }
        let late = correct.subtracting(ready)
        let unusedPrefetched = withLock { unused.filter { prefetched.contains(
            Edge0ExpertKey(layer: targetLayer, expert: $0)
        ) } }
        eventSink?(.reconciled(
            targetLayer: targetLayer, targetToken: token,
            predicted: predicted.sorted(), actual: actualIDs.sorted(),
            ready: ready.sorted(), late: late.sorted(),
            unused: unused.sorted()
        ))
        metrics.recordReconcile(
            targetLayer: targetLayer,
            actualCount: actualIDs.count,
            correct: correct.sorted(),
            ready: Set(ready),
            unused: unused.sorted(),
            unusedPrefetchedCount: unusedPrefetched.count
        )
    }

    func cancel() {
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            closed = true
            previousIDs.removeAll()
            pending.removeAll()
            prefetched.removeAll()
            let pending = quiescenceWaiters
            quiescenceWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
        Task { [scheduler] in
            await scheduler.cancelAll()
        }
    }

    private func notePrefetched(_ key: Edge0ExpertKey) {
        withLock { _ = prefetched.insert(key) }
        metrics.recordPrefetchCompleted()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Edge0SpeculativeScheduler
//
// Bounded single-flight prefetch queue. At most ONE speculative load runs at
// any time, so true-router (actual/staged) loads always retain at least three
// of the four tensor-store read slots. The queue is capped; overflow is
// dropped rather than queued unboundedly, and cancellation drops everything.

/// Bounded queue cap shared by every payload specialization.
private let edge0SpeculativeQueueCapacity = 128

actor Edge0SpeculativeScheduler<Payload: Sendable> {

    private let pool: Edge0ExpertPool<Payload>
    private var queue: [Edge0ExpertKey] = []
    private var draining = false
    private var closed = false

    nonisolated(unsafe) var onLoadCompleted: (@Sendable (Edge0ExpertKey) -> Void)?
    nonisolated(unsafe) var onRequest: (@Sendable (Bool, Bool) -> Void)?

    init(pool: Edge0ExpertPool<Payload>) {
        self.pool = pool
    }

    func enqueue(_ keys: [Edge0ExpertKey]) {
        guard !closed else { return }
        for key in keys where queue.count < edge0SpeculativeQueueCapacity {
            queue.append(key)
        }
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await self.drain() }
    }

    func cancelAll() {
        closed = true
        queue.removeAll()
    }

    private func drain() async {
        while !closed, !queue.isEmpty {
            let key = queue.removeFirst()
            let resident = await pool.contains(key)
            onRequest?(resident, !resident)
            guard !resident else { continue }
            await pool.prefetch(key)
            // `prefetch` installs an unpinned resident on success; the ledger
            // records intent, reconcile re-checks actual residency separately.
            if await pool.contains(key) {
                onLoadCompleted?(key)
            }
        }
        draining = false
    }
}
