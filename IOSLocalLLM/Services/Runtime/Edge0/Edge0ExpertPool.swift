import Foundation

// MARK: - Edge0ExpertPoolStats

/// Aggregate pool metrics. No prompt/content ever enters these values.
struct Edge0ExpertPoolStats: Sendable, Equatable {
    var hits = 0
    var misses = 0
    var evictions = 0
    var coalescedLoads = 0
    var staleLoadsRejected = 0
    var capacityWaitCycles = 0
    var bytesLoaded: UInt64 = 0
    var occupancySlots = 0
    var occupancyBytes: UInt64 = 0
    var inFlightLoads = 0
    var capacitySlots: Int = 0
    var capacityBytes: UInt64 = 0
    // Phase 4A instrumentation: read-cost baseline for Phase 4B decisions.
    var loads = 0
    var readLatencySecondsAvg = 0.0
    var readLatencySecondsP95 = 0.0
    var peakOccupancySlots = 0
    var peakOccupancyBytes: UInt64 = 0
    /// Summed acquire wait across all (possibly concurrent) loads. In
    /// bounded-prefetch mode concurrent tasks overlap, so this is NOT
    /// wall-clock stall time — a true critical-path metric is future work.
    /// Rising aggregate wait while wall-clock prefill falls confirms the
    /// overlap is working.
    var aggregateAcquireWaitSeconds = 0.0
    /// Total time spent in the loader (sum of per-load latencies).
    var readSecondsTotal = 0.0
    /// Lease visibility: entries pinned by at least one live lease, and the
    /// total live lease count. Both must return to zero after a generation.
    var pinnedSlots = 0
    var activeLeases = 0
    /// Acquire calls currently waiting for a slot or an in-flight install.
    var waitingAcquireCalls = 0
    /// Diagnostics: how many times the (potentially expensive) statistics
    /// snapshot was taken, and the bounded read-latency window size.
    var statisticsCalls = 0
    var readLatencyWindowSamples = 0
    var readLatencyTotalSamples = 0
    /// Peak simultaneous pinned leases (staging must stay well under
    /// capacity; two token sets is the design bound).
    var peakActiveLeases = 0
    /// Advisory (staged-prefill) loads actually started.
    var advisoryLoads = 0
}

// MARK: - Edge0PhasePoolMetrics
//
// Per-generation-phase delta of the pool counters (prefill vs decode), so
// expert I/O can be attributed to the phase that caused it.

struct Edge0PhasePoolMetrics: Sendable, Equatable {
    var hits = 0
    var misses = 0
    var loads = 0
    var evictions = 0
    var bytesLoaded: UInt64 = 0
    var readSeconds = 0.0
    var aggregateAcquireWaitSeconds = 0.0
    var occupancySlots = 0
    var occupancyBytes: UInt64 = 0

    static func delta(
        _ after: Edge0ExpertPoolStats,
        _ before: Edge0ExpertPoolStats
    ) -> Edge0PhasePoolMetrics {
        Edge0PhasePoolMetrics(
            hits: max(0, after.hits - before.hits),
            misses: max(0, after.misses - before.misses),
            loads: max(0, after.loads - before.loads),
            evictions: max(0, after.evictions - before.evictions),
            bytesLoaded: after.bytesLoaded >= before.bytesLoaded
                ? after.bytesLoaded - before.bytesLoaded : 0,
            readSeconds: max(0, after.readSecondsTotal - before.readSecondsTotal),
            aggregateAcquireWaitSeconds: max(
                0, after.aggregateAcquireWaitSeconds - before.aggregateAcquireWaitSeconds
            ),
            occupancySlots: after.occupancySlots,
            occupancyBytes: after.occupancyBytes
        )
    }

    var hitRate: Double {
        let total = hits + misses
        return total > 0 ? Double(hits) / Double(total) : 0
    }

    func bytesPerToken(_ tokens: Int) -> UInt64 {
        guard tokens > 0 else { return 0 }
        return bytesLoaded / UInt64(tokens)
    }

    func loadsPerToken(_ tokens: Int) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(loads) / Double(tokens)
    }
}

// MARK: - Reservation / lease

/// Slot reservation token. `generation` is bumped on every reservation so a
/// late load can detect that its slot was reclaimed and discard its result.
struct Edge0SlotReservation: Sendable, Equatable {
    let slotIndex: Int
    let generation: UInt64
    let key: Edge0ExpertKey
}

/// Pinned handle to a resident expert payload. The entry cannot be evicted
/// until `release` is called.
struct Edge0ExpertLease<Payload: Sendable>: Sendable {
    let key: Edge0ExpertKey
    let payload: Payload
    let slotIndex: Int
    let generation: UInt64
    let leaseID: UInt64
}

// MARK: - Edge0ExpertPoolError

enum Edge0ExpertPoolError: Error, Equatable, Sendable {
    case poolDisabled
    case closed
    case capacityExceeded(payloadBytes: UInt64, capacityBytes: UInt64)
    case staleReservationDiscarded(Edge0ExpertKey)
}

extension Edge0ExpertPoolError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .poolDisabled:
            return "The Edge0 expert pool is disabled by the memory budget."
        case .closed:
            return "The Edge0 expert pool is closed."
        case .capacityExceeded(let payloadBytes, let capacityBytes):
            return "Expert payload (\(payloadBytes) bytes) exceeds pool capacity (\(capacityBytes) bytes)."
        case .staleReservationDiscarded(let key):
            return "Discarded a stale Edge0 load for layer \(key.layer) expert \(key.expert)."
        }
    }
}

// MARK: - Edge0ExpertPool
//
// Hard-bounded cache of expert payloads shared across all MoE layers.
//
// Properties the rest of the runtime relies on:
//   • capacity is fixed at construction (slots AND bytes) and never grows
//     with request count;
//   • identical concurrent requests coalesce onto one load;
//   • pinned (leased) entries are never evicted; requests wait for a slot;
//   • a load installs only if its slot reservation is still current (ABA);
//   • `clear()` invalidates in-flight reservations so late results are
//     discarded instead of overwriting newer occupants.

actor Edge0ExpertPool<Payload: Sendable> {
    typealias Loader = @Sendable (Edge0ExpertKey) async throws -> Payload
    typealias SizeProvider = @Sendable (Payload) -> UInt64

    struct Configuration: Sendable {
        let capacitySlots: Int
        let capacityBytes: UInt64

        init(capacitySlots: Int, capacityBytes: UInt64) {
            self.capacitySlots = max(0, capacitySlots)
            self.capacityBytes = capacityBytes
        }

        var isEnabled: Bool { capacitySlots > 0 && capacityBytes > 0 }
    }

    private struct Entry {
        let key: Edge0ExpertKey
        let payload: Payload
        let bytes: UInt64
        let generation: UInt64
        var pins: Int
        var leaseIDs: Set<UInt64>
        var lastUsed: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    /// One in-flight expert load plus the waiters that coalesced onto it.
    /// Coalesced callers suspend on an explicit install signal instead of
    /// awaiting the load task directly — awaiting an already-completed task
    /// does not suspend, which turned duplicate requests into a busy spin
    /// that could starve the installer.
    private struct InFlight {
        let task: Task<Payload, Error>
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private struct Counters {
        var hits = 0
        var misses = 0
        var evictions = 0
        var coalescedLoads = 0
        var staleLoadsRejected = 0
        var capacityWaitCycles = 0
        var bytesLoaded: UInt64 = 0
        var loads = 0
        var readLatency = Edge0LatencyRing()
        var statisticsCalls = 0
        var liveLeases = 0
        var peakActiveLeases = 0
        var advisoryLoads = 0
        var peakOccupancySlots = 0
        var peakOccupancyBytes: UInt64 = 0
        var aggregateAcquireWaitSeconds = 0.0
        var readSecondsTotal = 0.0
    }

    let configuration: Configuration
    private let loader: Loader
    private let sizeOf: SizeProvider

    private var entries: [Int: Entry] = [:]
    private var slotOfKey: [Edge0ExpertKey: Int] = [:]
    private var reservations: [Int: Edge0SlotReservation] = [:]
    private var inFlight: [Edge0ExpertKey: InFlight] = [:]
    private var waiters: [Waiter] = []
    private var capacityWaiters = 0
    private var advisoryTasks: [Task<Void, Never>] = []
    private var nextGeneration: UInt64 = 1
    private var nextLeaseID: UInt64 = 1
    private var nextWaiterID: UInt64 = 1
    private var accessClock: UInt64 = 0
    private var currentBytes: UInt64 = 0
    private var counters = Counters()
    private var isClosed = false

    init(
        configuration: Configuration,
        loader: @escaping Loader,
        sizeOf: @escaping SizeProvider = { _ in 0 }
    ) {
        self.configuration = configuration
        self.loader = loader
        self.sizeOf = sizeOf
    }

    // MARK: - Acquire / release

    func acquire(_ key: Edge0ExpertKey) async throws -> Edge0ExpertLease<Payload> {
        while true {
            try Task.checkCancellation()
            if isClosed { throw Edge0ExpertPoolError.closed }

            if let slot = slotOfKey[key], var entry = entries[slot] {
                counters.hits += 1
                let leaseID = nextLeaseID
                nextLeaseID &+= 1
                accessClock &+= 1
                entry.pins += 1
                entry.leaseIDs.insert(leaseID)
                entry.lastUsed = accessClock
                entries[slot] = entry
                counters.liveLeases += 1
                counters.peakActiveLeases = max(
                    counters.peakActiveLeases, counters.liveLeases
                )
                return Edge0ExpertLease(
                    key: key,
                    payload: entry.payload,
                    slotIndex: slot,
                    generation: entry.generation,
                    leaseID: leaseID
                )
            }

            // Duplicate in-flight request: suspend until the owner installs
            // (or discards) the payload instead of reading the same expert
            // into a second slot.
            if inFlight[key] != nil {
                counters.coalescedLoads += 1
                await waitForInstall(key)
                continue
            }

            // One "miss" means one actual checkpoint read; coalesced lookups
            // are tracked separately and count as hits once they re-check.
            counters.misses += 1
            // Stall accounting: from the miss decision until this acquire
            // returns its lease (or throws).
            let acquireWaitStarted = ContinuousClock.now
            defer {
                counters.aggregateAcquireWaitSeconds += acquireWaitStarted
                    .duration(to: .now).timeInterval
            }

            guard configuration.isEnabled else {
                throw Edge0ExpertPoolError.poolDisabled
            }

            guard let slot = try await reserveSlot(for: key) else {
                continue
            }

            let reservation = Edge0SlotReservation(
                slotIndex: slot,
                generation: nextGeneration,
                key: key
            )
            nextGeneration &+= 1
            reservations[slot] = reservation

            let loadStarted = ContinuousClock.now
            let task = Task { [loader] in
                try await loader(key)
            }
            inFlight[key] = InFlight(task: task, waiters: [])

            do {
                let payload = try await task.value

                // ABA guard: discard a result whose reservation was
                // invalidated (clear/close/reclaim) while it was loading.
                guard reservations[slot] == reservation else {
                    counters.staleLoadsRejected += 1
                    throw Edge0ExpertPoolError.staleReservationDiscarded(key)
                }
                reservations[slot] = nil

                let bytes = sizeOf(payload)
                guard bytes <= configuration.capacityBytes else {
                    throw Edge0ExpertPoolError.capacityExceeded(
                        payloadBytes: bytes,
                        capacityBytes: configuration.capacityBytes
                    )
                }
                try evictForByteCapacity(neededBytes: bytes)

                let leaseID = nextLeaseID
                nextLeaseID &+= 1
                accessClock &+= 1
                entries[slot] = Entry(
                    key: key,
                    payload: payload,
                    bytes: bytes,
                    generation: reservation.generation,
                    pins: 1,
                    leaseIDs: [leaseID],
                    lastUsed: accessClock
                )
                slotOfKey[key] = slot
                currentBytes += bytes
                counters.bytesLoaded += bytes
                counters.loads += 1
                let readSeconds = loadStarted.duration(to: .now).timeInterval
                counters.readLatency.record(readSeconds)
                counters.readSecondsTotal += readSeconds
                counters.peakOccupancySlots = max(
                    counters.peakOccupancySlots, entries.count
                )
                counters.peakOccupancyBytes = max(
                    counters.peakOccupancyBytes, currentBytes
                )
                finishInFlight(key)
                wakeWaiters()
                return Edge0ExpertLease(
                    key: key,
                    payload: payload,
                    slotIndex: slot,
                    generation: reservation.generation,
                    leaseID: leaseID
                )
            } catch {
                if reservations[slot] == reservation {
                    reservations[slot] = nil
                }
                finishInFlight(key)
                wakeWaiters()
                throw error
            }
        }
    }

    /// Releases a lease. Safe to call twice or with a stale lease.
    func release(_ lease: Edge0ExpertLease<Payload>) {
        counters.liveLeases = max(0, counters.liveLeases - 1)
        guard var entry = entries[lease.slotIndex],
              entry.generation == lease.generation,
              entry.leaseIDs.contains(lease.leaseID) else {
            return
        }
        entry.leaseIDs.remove(lease.leaseID)
        entry.pins = max(0, entry.pins - 1)
        entries[lease.slotIndex] = entry
        wakeWaiters()
    }

    // MARK: - Advisory prefetch

    /// True when a speculative load can start without waiting for capacity:
    /// a free slot exists, or an unpinned (evictable) resident can be
    /// replaced. Speculative callers must never queue behind pinned work.
    func hasCapacityForPrefetch() -> Bool {
        guard !isClosed, configuration.isEnabled else { return false }
        if entries.count + reservations.count < configuration.capacitySlots {
            return true
        }
        return leastRecentlyUsedEvictableSlot() != nil
    }

    /// Loads an expert into the pool as an ordinary UNPINNED cache resident.
    /// Used only for advisory prerouter prefetch: it takes no long-lived
    /// lease, so a wrong prediction can never exhaust pin capacity and the
    /// entry ages out through the normal LRU.
    func prefetch(_ key: Edge0ExpertKey) async {
        if contains(key) || inFlight[key] != nil { return }
        guard hasCapacityForPrefetch() else { return }
        do {
            let lease = try await acquire(key)
            release(lease)
        } catch {
            // Advisory only: failure is never fatal and never propagates.
        }
    }

    // MARK: - Staged prefill

    /// Starts advisory (unpinned) loads for a token's selected experts
    /// without blocking the caller: the loads overlap the token currently
    /// computing. This is staging, not prediction — the keys come from the
    /// true router on real token input, so a wrong guess is impossible.
    func beginPrefetch(_ keys: [Edge0ExpertKey]) {
        let pending = keys.filter {
            !contains($0) && inFlight[$0] == nil && hasCapacityForPrefetch()
        }
        guard !pending.isEmpty else { return }
        counters.advisoryLoads += pending.count
        let task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for key in pending {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        if let lease = try? await self.acquire(key) {
                            await self.release(lease)
                        }
                    }
                }
                await group.waitForAll()
            }
        }
        advisoryTasks.append(task)
        if advisoryTasks.count > 32 {
            advisoryTasks.removeFirst(advisoryTasks.count - 32)
        }
    }

    /// Cancels queued advisory (staged-prefill) loads at the prefill→decode
    /// handoff. Loads already reading complete and remain as ordinary
    /// unpinned cache entries (safely reusable); queued work stops before it
    /// starts, so decode acquisitions are never delayed behind prefill-only
    /// work. Never touches resident payloads or leases.
    func cancelAdvisoryLoads() {
        for task in advisoryTasks {
            task.cancel()
        }
        advisoryTasks.removeAll()
    }

    // MARK: - Inspection

    func peek(_ key: Edge0ExpertKey) -> Payload? {
        guard let slot = slotOfKey[key], let entry = entries[slot] else {
            return nil
        }
        return entry.payload
    }

    func contains(_ key: Edge0ExpertKey) -> Bool {
        slotOfKey[key] != nil
    }

    func residentKeys() -> [Edge0ExpertKey] {
        entries.values.map(\.key)
    }

    func statistics() -> Edge0ExpertPoolStats {
        counters.statisticsCalls += 1
        return Edge0ExpertPoolStats(
            hits: counters.hits,
            misses: counters.misses,
            evictions: counters.evictions,
            coalescedLoads: counters.coalescedLoads,
            staleLoadsRejected: counters.staleLoadsRejected,
            capacityWaitCycles: counters.capacityWaitCycles,
            bytesLoaded: counters.bytesLoaded,
            occupancySlots: entries.count,
            occupancyBytes: currentBytes,
            inFlightLoads: inFlight.count,
            capacitySlots: configuration.capacitySlots,
            capacityBytes: configuration.capacityBytes,
            loads: counters.loads,
            readLatencySecondsAvg: counters.readLatency.average,
            readLatencySecondsP95: counters.readLatency.p95,
            peakOccupancySlots: counters.peakOccupancySlots,
            peakOccupancyBytes: counters.peakOccupancyBytes,
            aggregateAcquireWaitSeconds: counters.aggregateAcquireWaitSeconds,
            readSecondsTotal: counters.readSecondsTotal,
            pinnedSlots: entries.values.filter { $0.pins > 0 }.count,
            activeLeases: entries.values.reduce(0) { $0 + $1.pins },
            waitingAcquireCalls: capacityWaiters,
            statisticsCalls: counters.statisticsCalls,
            readLatencyWindowSamples: counters.readLatency.samples.count,
            readLatencyTotalSamples: counters.readLatency.totalRecorded,
            peakActiveLeases: counters.peakActiveLeases,
            advisoryLoads: counters.advisoryLoads
        )
    }

    /// Cheap, allocation-free capacity read for per-token guards. Never
    /// takes the statistics snapshot.
    nonisolated var configuredCapacitySlots: Int {
        configuration.capacitySlots
    }

    // MARK: - Lifecycle

    /// Drops all unpinned entries and invalidates in-flight reservations.
    /// A load that completes after `clear` is discarded, never installed.
    func clear() {
        for slot in reservations.keys {
            reservations[slot] = nil
        }
        let pending = inFlight
        inFlight.removeAll()
        for (_, entry) in pending {
            entry.task.cancel()
            for waiter in entry.waiters {
                waiter.resume()
            }
        }
        for (slot, entry) in entries where entry.pins == 0 {
            evict(slot: slot)
        }
        wakeWaiters()
    }

    func close() {
        isClosed = true
        clear()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: Edge0ExpertPoolError.closed)
        }
    }

    // MARK: - Internal

    /// Suspends a coalesced caller until the owning load installs its
    /// payload or is discarded. Resuming instead of awaiting the load task
    /// directly is what prevents the duplicate-request busy spin.
    private func waitForInstall(_ key: Edge0ExpertKey) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if var entry = inFlight[key] {
                entry.waiters.append(continuation)
                inFlight[key] = entry
            } else {
                continuation.resume()
            }
        }
    }

    private func finishInFlight(_ key: Edge0ExpertKey) {
        guard let entry = inFlight.removeValue(forKey: key) else { return }
        for waiter in entry.waiters {
            waiter.resume()
        }
    }

    private func reserveSlot(for key: Edge0ExpertKey) async throws -> Int? {
        if entries.count + reservations.count < configuration.capacitySlots {
            var slot = 0
            while entries[slot] != nil || reservations[slot] != nil {
                slot += 1
            }
            return slot
        }
        if let victim = leastRecentlyUsedEvictableSlot() {
            evict(slot: victim)
            return victim
        }
        counters.capacityWaitCycles += 1
        capacityWaiters += 1
        defer { capacityWaiters -= 1 }
        try await waitForSlot()
        return nil
    }

    private func leastRecentlyUsedEvictableSlot() -> Int? {
        entries
            .filter { $0.value.pins == 0 }
            .min { $0.value.lastUsed < $1.value.lastUsed }?
            .key
    }

    private func evictForByteCapacity(neededBytes: UInt64) throws {
        while currentBytes + neededBytes > configuration.capacityBytes {
            guard let victim = leastRecentlyUsedEvictableSlot() else {
                throw Edge0ExpertPoolError.capacityExceeded(
                    payloadBytes: neededBytes,
                    capacityBytes: configuration.capacityBytes
                )
            }
            evict(slot: victim)
        }
    }

    private func evict(slot: Int) {
        guard let entry = entries[slot] else { return }
        entries[slot] = nil
        slotOfKey[entry.key] = nil
        currentBytes = currentBytes >= entry.bytes
            ? currentBytes - entry.bytes
            : 0
        counters.evictions += 1
    }

    private func waitForSlot() async throws {
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func wakeWaiters() {
        guard !isClosed, !waiters.isEmpty else { return }
        let hasCapacity = entries.count + reservations.count < configuration.capacitySlots
            || leastRecentlyUsedEvictableSlot() != nil
        guard hasCapacity else { return }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }
}

private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
