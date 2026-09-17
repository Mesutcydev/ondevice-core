import XCTest
@testable import IOSLocalLLM

// MARK: - RuntimeEngineLifecycleTests
//
// Exercises the shared lifecycle semantics every runtime inherits from
// `ManagedRuntimeEngine`: load, generate, cancel, unload, double unload,
// cancel while idle, load after unload, and recovery from a failed load.

final class RuntimeEngineLifecycleTests: XCTestCase {

    // MARK: - Lifecycle

    func testLoadThenGenerateStreamsTokenEvents() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)
        let model = makeModel()

        try await engine.load(model: model)
        let isLoaded = await engine.isLoaded
        XCTAssertTrue(isLoaded)

        let events = try await collect(
            await engine.generate(messages: [], options: .default)
        )
        XCTAssertEqual(events.first, .started)
        XCTAssertTrue(events.contains(.token("hi")))
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(backend.loads, [model.id])
    }

    func testLoadSameModelTwiceDoesNotReload() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)
        let model = makeModel()

        try await engine.load(model: model)
        try await engine.load(model: model)

        XCTAssertEqual(backend.loads, [model.id])
        XCTAssertEqual(backend.unloadCount, 0)
    }

    func testGenerateWithoutLoadFailsWithNoActiveModel() async {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)

        let stream = await engine.generate(messages: [], options: .default)
        do {
            for try await _ in stream {}
            XCTFail("Expected noActiveModel")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .noActiveModel)
        }
    }

    func testCancelWhileIdleIsSafe() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)

        await engine.cancel()
        await engine.cancel()

        // Still usable afterwards.
        try await engine.load(model: makeModel())
        let isLoaded = await engine.isLoaded
        XCTAssertTrue(isLoaded)
    }

    func testDoubleUnloadIsSafe() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)

        try await engine.load(model: makeModel())
        await engine.unload()
        await engine.unload()

        let isLoaded = await engine.isLoaded
        XCTAssertFalse(isLoaded)
        XCTAssertEqual(backend.unloadCount, 2)
    }

    func testCancelMidGenerationTerminatesStream() async throws {
        let backend = FakeRuntimeEngineBackend(mode: .waitsForCancel)
        let engine = makeEngine(backend: backend)
        try await engine.load(model: makeModel())

        let stream = await engine.generate(messages: [], options: .default)
        let consumer = Task { () -> [TokenEvent] in
            var events: [TokenEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        // Let the first tokens land before cancelling.
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.cancel()
        let events = try await consumer.value

        XCTAssertTrue(events.contains(.started))
        XCTAssertTrue(events.contains(.token("hi")))
        XCTAssertFalse(events.contains(.completed))
        XCTAssertGreaterThanOrEqual(backend.cancelCount, 1)
    }

    func testLoadAfterUnloadWorks() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)
        let model = makeModel()

        try await engine.load(model: model)
        await engine.unload()
        try await engine.load(model: model)

        let isLoaded = await engine.isLoaded
        XCTAssertTrue(isLoaded)
        XCTAssertEqual(backend.loads, [model.id, model.id])
    }

    func testFailedLoadLeavesEngineRecoverable() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)
        let model = makeModel()

        backend.failNextLoad()
        do {
            try await engine.load(model: model)
            XCTFail("Expected the injected load failure")
        } catch {
            XCTAssertEqual(error as? FakeRuntimeEngineBackend.Failure,
                           .init(message: "injected load failure"))
        }
        let loadedAfterFailure = await engine.isLoaded
        XCTAssertFalse(loadedAfterFailure)

        try await engine.load(model: model)
        let recovered = await engine.isLoaded
        XCTAssertTrue(recovered)
        XCTAssertEqual(backend.loads, [model.id])
    }

    func testSwitchingModelsDrainsPreviousBackend() async throws {
        let backend = FakeRuntimeEngineBackend()
        let engine = makeEngine(backend: backend)
        let first = makeModel(id: "first")
        let second = makeModel(id: "second")

        try await engine.load(model: first)
        try await engine.load(model: second)

        XCTAssertEqual(backend.loads, [first.id, second.id])
        XCTAssertGreaterThanOrEqual(backend.unloadCount, 1)
        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, second.id)
    }

    // MARK: - Helpers

    private func makeEngine(
        backend: FakeRuntimeEngineBackend
    ) -> ManagedRuntimeEngine {
        ManagedRuntimeEngine(
            id: "test-engine",
            runtime: .mlx,
            capabilities: RuntimeEngineFactory.capabilities(runtime: .mlx),
            backend: backend
        )
    }

    private func makeModel(id: String = "test-model") -> LocalModel {
        LocalModel(
            id: id,
            repoID: "example/\(id)",
            displayName: id,
            familyID: ModelFamily.inferID(from: "example/\(id)"),
            runtime: .mlx
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<TokenEvent, Error>
    ) async throws -> [TokenEvent] {
        var events: [TokenEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

// MARK: - FakeRuntimeEngineBackend

/// In-memory backend used to verify lifecycle semantics without loading a
/// real model. A production backend follows the same `RuntimeEngineBackend`
/// contract.
private final class FakeRuntimeEngineBackend: RuntimeEngineBackend, @unchecked Sendable {
    struct Failure: Error, Equatable {
        let message: String
    }

    enum Mode {
        /// Yields a short reply and completes.
        case completes
        /// Yields the first tokens and stays open until `cancel()`.
        case waitsForCancel
    }

    private let lock = NSLock()
    private let mode: Mode
    private var storedLoads: [String] = []
    private var storedUnloadCount = 0
    private var storedCancelCount = 0
    private var shouldFailNextLoad = false
    private var isCancelled = false
    private var openContinuations: [AsyncThrowingStream<TokenEvent, Error>.Continuation] = []

    init(mode: Mode = .completes) {
        self.mode = mode
    }

    var loads: [String] { lock.withLock { storedLoads } }
    var unloadCount: Int { lock.withLock { storedUnloadCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func failNextLoad() {
        lock.withLock { shouldFailNextLoad = true }
    }

    func load(model: LocalModel) async throws {
        let failure = lock.withLock {
            if shouldFailNextLoad {
                shouldFailNextLoad = false
                return true
            }
            storedLoads.append(model.id)
            isCancelled = false
            return false
        }
        if failure {
            throw Failure(message: "injected load failure")
        }
    }

    func unload() async {
        lock.withLock { storedUnloadCount += 1 }
    }

    func cancel() async {
        let continuations: [AsyncThrowingStream<TokenEvent, Error>.Continuation] =
            lock.withLock {
                storedCancelCount += 1
                isCancelled = true
                let open = openContinuations
                openContinuations.removeAll()
                return open
            }
        for continuation in continuations {
            continuation.finish()
        }
    }

    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<TokenEvent, Error> {
        let cancelled = lock.withLock { isCancelled }
        if cancelled {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RuntimeError.generationCancelled)
            }
        }
        let mode = self.mode
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.token("hi"))
            switch mode {
            case .completes:
                continuation.yield(.completed)
                continuation.finish()
            case .waitsForCancel:
                lock.withLock { openContinuations.append(continuation) }
            }
        }
    }
}
