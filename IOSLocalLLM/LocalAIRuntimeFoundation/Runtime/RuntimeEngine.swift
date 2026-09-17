import Foundation

// MARK: - RuntimeEngine
//
// The uniform contract every local inference runtime implements. Callers
// (present and future) select an engine through `RuntimeEngineFactory` instead
// of branching on `ModelRuntime` identity.
//
// Implementations own the load/generate/cancel/unload lifecycle for one
// runtime. Heavy policy (memory admission, thermal refusal, residency) stays
// outside the engine — the engine executes what the policy already admitted.

protocol RuntimeEngine: Sendable {
    var id: String { get }
    var runtime: ModelRuntime { get }
    var capabilities: RuntimeCapabilities { get }

    func load(model: LocalModel) async throws
    func unload() async
    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<TokenEvent, Error>
    func cancel() async
    /// Runtime-specific diagnostic counters (privacy-safe: no prompt or
    /// generated content). nil for runtimes without instrumentation.
    func runtimeMetrics() async -> [String: String]?
    /// Developer parity probe (raw token ids, greedy). nil when the runtime
    /// has no frozen reference contract. Never used by user chat.
    func runParityProbe() async throws -> RuntimeParityProbe?
    /// Typed run-boundary resource snapshot (diagnostics only). Declared on
    /// the protocol so calls through `any RuntimeEngine` dispatch to the
    /// concrete engine instead of the nil extension default.
    func resourceSnapshot() async -> RuntimeResourceSnapshot?
}

extension RuntimeEngine {
    func runtimeMetrics() async -> [String: String]? { nil }
    func runParityProbe() async throws -> RuntimeParityProbe? { nil }
}

// MARK: - RuntimeParityProbe
//
// Frozen reference contract executed through the PRODUCTION runtime (raw
// token ids, greedy). Counts and ids only — no text.

struct RuntimeParityProbe: Sendable, Equatable {
    var family: String
    var promptTokenIDs: [Int]
    var expectedTokenIDs: [Int]
    var emittedTokenIDs: [Int]
    var passed: Bool
    var firstDifferingIndex: Int?
    var stopReason: String
    var eosHit: Bool
    var finalPosition: Int
}

/// Backends that can execute a frozen parity probe opt in to this protocol;
/// `ManagedRuntimeEngine` forwards to it when present.
protocol RuntimeParityProbing: Sendable {
    func runParityProbe() async throws -> RuntimeParityProbe
}

// MARK: - RuntimeResourceSnapshot
//
// Typed run-boundary state from the ACTIVE engine. Optional fields are nil
// when the runtime cannot measure them — never silently zero. `isComplete`
// marks the fields a benchmark boundary requires.

public struct RuntimeResourceSnapshot: Sendable, Equatable {
    public var family: String
    public var isGenerationActive: Bool
    public var activeExpertLeases: Int?
    public var pinnedExpertSlots: Int?
    public var inFlightExpertLoads: Int?
    public var queuedExpertRequests: Int?
    public var activeTensorReads: Int?
    public var configuredMaxConcurrentReads: Int?
    public var poolCapacitySlots: Int?
    public var poolOccupancySlots: Int?

    public init(
        family: String,
        isGenerationActive: Bool,
        activeExpertLeases: Int? = nil,
        pinnedExpertSlots: Int? = nil,
        inFlightExpertLoads: Int? = nil,
        queuedExpertRequests: Int? = nil,
        activeTensorReads: Int? = nil,
        configuredMaxConcurrentReads: Int? = nil,
        poolCapacitySlots: Int? = nil,
        poolOccupancySlots: Int? = nil
    ) {
        self.family = family
        self.isGenerationActive = isGenerationActive
        self.activeExpertLeases = activeExpertLeases
        self.pinnedExpertSlots = pinnedExpertSlots
        self.inFlightExpertLoads = inFlightExpertLoads
        self.queuedExpertRequests = queuedExpertRequests
        self.activeTensorReads = activeTensorReads
        self.configuredMaxConcurrentReads = configuredMaxConcurrentReads
        self.poolCapacitySlots = poolCapacitySlots
        self.poolOccupancySlots = poolOccupancySlots
    }

    /// Fields required for a trustworthy benchmark run boundary.
    public var isComplete: Bool {
        activeExpertLeases != nil
            && inFlightExpertLoads != nil
            && activeTensorReads != nil
    }

    /// True when a boundary field reports live work.
    public var hasLiveWork: Bool {
        isGenerationActive
            || (activeExpertLeases ?? 0) > 0
            || (inFlightExpertLoads ?? 0) > 0
            || (activeTensorReads ?? 0) > 0
    }

    /// Human-readable, privacy-safe description for diagnostics.
    public func describe() -> String {
        func field(_ value: Int?) -> String {
            value.map(String.init) ?? "unavailable"
        }
        return "family \(family)"
            + " · generation \(isGenerationActive ? "active" : "idle")"
            + " · leases \(field(activeExpertLeases))"
            + " · pinned \(field(pinnedExpertSlots))"
            + " · inFlight \(field(inFlightExpertLoads))"
            + " · queued \(field(queuedExpertRequests))"
            + " · reads \(field(activeTensorReads))/"
            + "\(field(configuredMaxConcurrentReads))"
            + " · pool \(field(poolOccupancySlots))/"
            + "\(field(poolCapacitySlots))"
    }
}

/// Backends that can report a typed run-boundary snapshot opt in.
protocol RuntimeResourceProviding: Sendable {
    func resourceSnapshot() async -> RuntimeResourceSnapshot?
}

extension RuntimeEngine {
    func resourceSnapshot() async -> RuntimeResourceSnapshot? { nil }
}

// MARK: - RuntimeEngineBackend
//
// Execution primitive behind `ManagedRuntimeEngine`. Backends may be
// app-service adapters (MLX/llama.cpp/Core AI today) or native engines
// (a future Edge0 expert-streaming backend).
//
// Contract:
//   • `unload()` must be idempotent and safe when nothing is loaded.
//   • `cancel()` must be safe when idle and must terminate any stream a prior
//     `generate` returned.
//   • `generate` must not start unless a matching `load` succeeded.

protocol RuntimeEngineBackend: Sendable {
    func load(model: LocalModel) async throws
    func unload() async
    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<TokenEvent, Error>
    func cancel() async
    func runtimeMetrics() async -> [String: String]?
}

extension RuntimeEngineBackend {
    func runtimeMetrics() async -> [String: String]? { nil }
}

// MARK: - ManagedRuntimeEngine
//
// Lifecycle-safe wrapper shared by every backend. It gives the app uniform
// semantics regardless of what executes underneath:
//   • load is a no-op for the already-loaded model, and switching models
//     drains the previous one first,
//   • unload is idempotent and cancels in-flight work before releasing,
//   • cancel is safe while idle,
//   • a failed load tears down partial state and stays recoverable, so a
//     retry or a different model can load next.

actor ManagedRuntimeEngine: RuntimeEngine {
    nonisolated let id: String
    nonisolated let runtime: ModelRuntime
    nonisolated let capabilities: RuntimeCapabilities

    private let backend: any RuntimeEngineBackend
    private var loadedModel: LocalModel?
    private var activeGeneration = false

    init(
        id: String,
        runtime: ModelRuntime,
        capabilities: RuntimeCapabilities,
        backend: any RuntimeEngineBackend
    ) {
        self.id = id
        self.runtime = runtime
        self.capabilities = capabilities
        self.backend = backend
    }

    var isLoaded: Bool { loadedModel != nil }

    var loadedModelID: String? { loadedModel?.id }

    var isGenerating: Bool { activeGeneration }

    // MARK: - Lifecycle

    func load(model: LocalModel) async throws {
        if loadedModel?.id == model.id { return }
        if loadedModel != nil {
            activeGeneration = false
            await backend.cancel()
            await backend.unload()
        }
        loadedModel = nil
        activeGeneration = false
        do {
            try await backend.load(model: model)
            loadedModel = model
        } catch {
            // A failed load must leave the system recoverable: release any
            // partial native state, then rethrow. A later load (same or
            // different model) starts from a clean backend.
            await backend.cancel()
            await backend.unload()
            loadedModel = nil
            activeGeneration = false
            throw error
        }
    }

    func unload() async {
        loadedModel = nil
        activeGeneration = false
        await backend.cancel()
        await backend.unload()
    }

    // MARK: - Generation

    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<TokenEvent, Error> {
        guard loadedModel != nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RuntimeError.noActiveModel)
            }
        }
        activeGeneration = true
        let backend = self.backend
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    let stream = try await backend.generate(
                        messages: messages,
                        options: options
                    )
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self?.markGenerationFinished()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { await self?.markGenerationFinished() }
            }
        }
    }

    func cancel() async {
        activeGeneration = false
        await backend.cancel()
    }

    func runtimeMetrics() async -> [String: String]? {
        await backend.runtimeMetrics()
    }

    func runParityProbe() async throws -> RuntimeParityProbe? {
        guard let probing = backend as? any RuntimeParityProbing else {
            return nil
        }
        return try await probing.runParityProbe()
    }

    func resourceSnapshot() async -> RuntimeResourceSnapshot? {
        guard let providing = backend as? any RuntimeResourceProviding else {
            return nil
        }
        return await providing.resourceSnapshot()
    }

    private func markGenerationFinished() {
        activeGeneration = false
    }
}

// MARK: - InferenceSessionActor

actor InferenceSessionActor {
    struct Cancelled: Error {}

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var generation: UInt64 = 0

    func run<T>(_ body: () async throws -> T) async throws -> T {
        let ticket = try await acquire()
        defer { release() }
        if ticket != generation { throw Cancelled() }
        if Task.isCancelled { throw Cancelled() }
        return try await body()
    }

    func cancelAll() {
        generation &+= 1
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.resume(throwing: Cancelled())
        }
    }

    private func acquire() async throws -> UInt64 {
        while isRunning {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isRunning = true
        return generation
    }

    private func release() {
        isRunning = false
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}
