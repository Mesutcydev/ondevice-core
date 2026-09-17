import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0PrefetchTests
//
// Phase 4B-1: bounded-prefetch mode must produce byte-identical greedy output
// to exact mode on the real checkpoint, keep the expert pool hard-bounded,
// and survive cancel/reload. Also records a macOS A/B timing smoke (the
// physical-device A/B happens on iPhone18,2).

final class Edge0PrefetchTests: XCTestCase {

    // MARK: Model-level parity + timing

    func testPrefetchGreedyMatchesExactAndFixture() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("real_layers.safetensors")
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["real_layers.safetensors"]
        )
        let fixtureLoader = Edge0ResidentTensorLoader(
            index: fixtureIndex, stores: fixtureStores
        )

        let configURL = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("config.json")
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: configURL)
        )
        try configuration.validateEdge0_8B()
        let index = try Edge0SafetensorsIndex.openSingleFile(
            at: URL(fileURLWithPath: modelDirectory)
                .appendingPathComponent("model.safetensors")
        )
        let stores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: modelDirectory),
            shardNames: ["model.safetensors"]
        )
        let model = try await Edge0Model.load(
            configuration: configuration,
            index: index,
            stores: stores
        )

        let promptIDs = try await fixtureLoader
            .load(fixtureIndex.location("prompt_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let expectedGenerated = try await fixtureLoader
            .load(fixtureIndex.location("generated_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }

        // A 64-slot pool guarantees real cache misses on the 25-token prompt.
        let expertLoader = try Edge0ExpertLoader(index: index, stores: stores)
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(
                capacitySlots: 64,
                capacityBytes: 256 * 1_048_576
            ),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )

        func greedyRun(
            mode: Edge0ExecutionMode,
            prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>? = nil
        ) async throws -> (
            ids: [Int], prefillSeconds: Double, decodeSeconds: Double
        ) {
            let prefillStart = ContinuousClock.now
            let prefill = try await model.prefill(
                tokenIDs: promptIDs, pool: pool, mode: mode,
                prerouter: prerouter
            )
            let prefillSeconds = prefillStart.duration(to: .now).seconds

            func decodeStep(_ token: Int, _ state: inout Edge0ModelState) async throws -> Int {
                let logits = try await model.decode(
                    tokenID: token, state: &state, pool: pool, mode: mode,
                    prerouter: prerouter
                )
                return Int(
                    MLX.argMax(logits[0, -1].asType(.float32), axis: -1)
                        .asType(.int32).asArray(Int32.self)[0]
                )
            }
            var next = Int(
                MLX.argMax(prefill.logits[0, -1].asType(.float32), axis: -1)
                    .asType(.int32).asArray(Int32.self)[0]
            )
            var generated = [next]
            var state = prefill.state
            let decodeStart = ContinuousClock.now
            for _ in 0..<16 {
                next = try await decodeStep(next, &state)
                generated.append(next)
            }
            let decodeSeconds = decodeStart.duration(to: .now).seconds
            return (Array(generated.prefix(17)), prefillSeconds, decodeSeconds)
        }

        let exact = try await greedyRun(mode: .exact)
        let prefetched = try await greedyRun(mode: .boundedPrefetch)
        let staged = try await greedyRun(mode: .staged)
        let realPrerouter = try await Edge0Prerouter.load(
            directory: URL(fileURLWithPath: modelDirectory),
            configuration: configuration
        )
        let loadedPrerouter = try XCTUnwrap(realPrerouter)
        let prerouterRun = try await greedyRun(
            mode: .stagedPrerouter,
            prerouter: Edge0PrerouterRuntime<Edge0ExpertWeights>(
                predictor: loadedPrerouter, pool: pool
            )
        )

        print("[Edge0 prefetch] exact    prefill=\(exact.prefillSeconds)s decode16=\(exact.decodeSeconds)s")
        print("[Edge0 prefetch] prefetch prefill=\(prefetched.prefillSeconds)s decode16=\(prefetched.decodeSeconds)s")
        print("[Edge0 prefetch] staged   prefill=\(staged.prefillSeconds)s decode16=\(staged.decodeSeconds)s")
        print("[Edge0 prefetch] stagedPre prefill=\(prerouterRun.prefillSeconds)s decode16=\(prerouterRun.decodeSeconds)s")
        print("[Edge0 prefetch] exact IDs:    \(exact.ids)")
        print("[Edge0 prefetch] prefetch IDs: \(prefetched.ids)")
        print("[Edge0 prefetch] staged IDs:   \(staged.ids)")

        XCTAssertEqual(
            prefetched.ids, exact.ids,
            "bounded-prefetch greedy IDs must match exact"
        )
        XCTAssertEqual(
            staged.ids, exact.ids,
            "staged greedy IDs must match exact"
        )
        XCTAssertEqual(
            prerouterRun.ids, exact.ids,
            "stagedPrerouter greedy IDs must match exact"
        )
        XCTAssertEqual(
            exact.ids, Array(expectedGenerated.prefix(17)),
            "exact greedy IDs must still match the Python fixture"
        )

        let stats = await pool.statistics()
        // Unpinned entries legitimately stay cached; the invariant is that
        // nothing exceeds the hard bounds and no lease keeps a pin alive
        // (a leaked pin would block eviction on the next generation).
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)
    }

    // MARK: Engine lifecycle in prefetch mode

    func testPrefetchEngineCancelReloadStaysBounded() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let engine = Edge0Engine()
        try await engine.load(configuration: .init(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            expertPoolSlots: 64,
            expertPoolBytes: 256 * 1_048_576,
            maxConcurrentReads: 4
        ))
        let messages: [[String: String]] = [
            ["role": "user", "content": "The capital of France is"]
        ]
        let events = EventBox()
        let task = Task {
            try await engine.generate(
                messages: messages,
                options: Edge0EngineOptions(
                    maxTokens: 32, mode: .boundedPrefetch
                ),
                onEvent: { events.append($0) }
            )
        }
        try await waitForToken(events, timeout: 240)
        engine.cancel()
        _ = try? await task.value
        XCTAssertTrue(events.snapshot.contains(.cancelled))

        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 2, mode: .boundedPrefetch),
            onEvent: { events.append($0) }
        )
        let metrics = try XCTUnwrap(engine.generationMetrics())
        XCTAssertGreaterThan(metrics.promptTokens, 0)
        XCTAssertGreaterThanOrEqual(metrics.generatedTokens, 1)
        print("[Edge0 prefetch] engine metrics prefill=\(metrics.prefillSeconds)s decode=\(metrics.decodeSeconds)s acquireWait=\(metrics.decodePool.aggregateAcquireWaitSeconds)s")
        let rawStats = await engine.expertPoolStatistics()
        let stats = try XCTUnwrap(rawStats)
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)

        await engine.unload()
        XCTAssertFalse(engine.isLoaded)
    }

    // MARK: Predictor safety (wrong / zero / failure)

    private struct WrongPredictor: Edge0ExpertPredictor {
        func owns(owner: Int) -> Bool { true }
        func predictedExpertIDs(
            owner: Int, hidden: MLXArray, thisIDs: [Int], prevIDs: [Int], topK: Int
        ) throws -> [Int]? {
            Array(0..<8)
        }
    }

    private struct ZeroPredictor: Edge0ExpertPredictor {
        func owns(owner: Int) -> Bool { true }
        func predictedExpertIDs(
            owner: Int, hidden: MLXArray, thisIDs: [Int], prevIDs: [Int], topK: Int
        ) throws -> [Int]? {
            []
        }
    }

    private struct ThrowingPredictor: Edge0ExpertPredictor {
        func owns(owner: Int) -> Bool { true }
        func predictedExpertIDs(
            owner: Int, hidden: MLXArray, thisIDs: [Int], prevIDs: [Int], topK: Int
        ) throws -> [Int]? {
            throw CancellationError()
        }
    }

    private func assertPredictorSafety(
        _ predictor: any Edge0ExpertPredictor,
        modelDirectory: String
    ) async throws {
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_8B()
        let index = try Edge0SafetensorsIndex.openSingleFile(
            at: modelURL.appendingPathComponent("model.safetensors")
        )
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: ["model.safetensors"]
        )
        let model = try await Edge0Model.load(
            configuration: configuration, index: index, stores: stores
        )
        let expertLoader = try Edge0ExpertLoader(index: index, stores: stores)
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(capacitySlots: 64, capacityBytes: 256 * 1_048_576),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("real_layers.safetensors")
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["real_layers.safetensors"]
        )
        let fixtureLoader = Edge0ResidentTensorLoader(
            index: fixtureIndex, stores: fixtureStores
        )
        let promptIDs = try await fixtureLoader
            .load(fixtureIndex.location("prompt_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let expected = try await fixtureLoader
            .load(fixtureIndex.location("generated_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }

        let runtime = Edge0PrerouterRuntime<Edge0ExpertWeights>(predictor: predictor, pool: pool)
        let prefill = try await model.prefill(
            tokenIDs: promptIDs, pool: pool, mode: .stagedPrerouter,
            prerouter: runtime
        )
        var state = prefill.state
        var next = Int(
            MLX.argMax(prefill.logits[0, -1].asType(.float32), axis: -1)
                .asType(.int32).asArray(Int32.self)[0]
        )
        var generated = [next]
        for _ in 0..<16 {
            let logits = try await model.decode(
                tokenID: next, state: &state, pool: pool,
                mode: .stagedPrerouter, prerouter: runtime
            )
            next = Int(
                MLX.argMax(logits[0, -1].asType(.float32), axis: -1)
                    .asType(.int32).asArray(Int32.self)[0]
            )
            generated.append(next)
        }
        runtime.cancel()
        XCTAssertEqual(
            Array(generated.prefix(17)), Array(expected.prefix(17)),
            "true-router output must stay fixture-exact with an advisory predictor"
        )
    }

    func testWrongPredictorPreservesExactOutput() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        try await assertPredictorSafety(
            WrongPredictor(), modelDirectory: modelDirectory
        )
    }

    func testZeroPredictorPreservesExactOutput() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        try await assertPredictorSafety(
            ZeroPredictor(), modelDirectory: modelDirectory
        )
    }

    func testThrowingPredictorFallsBackAndPreservesExactOutput() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        try await assertPredictorSafety(
            ThrowingPredictor(), modelDirectory: modelDirectory
        )
    }

    // MARK: Longer-prefill stress (128 / 256 tokens)

    func testLongerPrefillStagedVsPrerouterCorrectAndBounded() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_8B()
        let index = try Edge0SafetensorsIndex.openSingleFile(
            at: modelURL.appendingPathComponent("model.safetensors")
        )
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: ["model.safetensors"]
        )
        let model = try await Edge0Model.load(
            configuration: configuration, index: index, stores: stores
        )
        let expertLoader = try Edge0ExpertLoader(index: index, stores: stores)
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(capacitySlots: 64, capacityBytes: 256 * 1_048_576),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("real_layers.safetensors")
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["real_layers.safetensors"]
        )
        let fixtureLoader = Edge0ResidentTensorLoader(
            index: fixtureIndex, stores: fixtureStores
        )
        let baseIDs = try await fixtureLoader
            .load(fixtureIndex.location("prompt_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let loaded = try await Edge0Prerouter.load(
            directory: modelURL, configuration: configuration
        )

        for length in [128, 256] {
            let ids = (0..<length).map { baseIDs[$0 % baseIDs.count] }

            let stagedStart = ContinuousClock.now
            let stagedPrefill = try await model.prefill(
                tokenIDs: ids, pool: pool, mode: .staged
            )
            let stagedSeconds = stagedStart.duration(to: .now).seconds
            let stagedArgmax = Int(
                MLX.argMax(stagedPrefill.logits[0, -1].asType(.float32), axis: -1)
                    .asType(.int32).asArray(Int32.self)[0]
            )

            let runtime = Edge0PrerouterRuntime<Edge0ExpertWeights>(
                predictor: try XCTUnwrap(loaded), pool: pool
            )
            let preStart = ContinuousClock.now
            let prePrefill = try await model.prefill(
                tokenIDs: ids, pool: pool, mode: .stagedPrerouter,
                prerouter: runtime
            )
            let preSeconds = preStart.duration(to: .now).seconds
            let preArgmax = Int(
                MLX.argMax(prePrefill.logits[0, -1].asType(.float32), axis: -1)
                    .asType(.int32).asArray(Int32.self)[0]
            )
            let metrics = runtime.metrics.current
            runtime.cancel()

            let stats = await pool.statistics()
            print("[Edge0 prerouter] prefill \(length): staged=\(stagedSeconds)s prerouter=\(preSeconds)s · precision=\(metrics.precision) recall=\(metrics.recall) fallbacks=\(metrics.fallbacks)")

            XCTAssertEqual(
                preArgmax, stagedArgmax,
                "advisory prerouting must not change the prefill result (\(length) tokens)"
            )
            XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
            XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)
        }
    }

    // MARK: Engine lifecycle with prerouter

    func testStagedPrerouterEngineLifecycleCancelReload() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let engine = Edge0Engine()
        try await engine.load(configuration: .init(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            expertPoolSlots: 64,
            expertPoolBytes: 256 * 1_048_576,
            maxConcurrentReads: 4
        ))
        engine.prerouterPredictorOverride = WrongPredictor()
        let messages: [[String: String]] = [
            ["role": "user", "content": "The capital of France is"]
        ]

        let first = EventBox()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 3, mode: .stagedPrerouter),
            onEvent: { first.append($0) }
        )
        XCTAssertEqual(first.completedTokens, 3)
        let firstMetrics = try XCTUnwrap(engine.generationMetrics())
        XCTAssertGreaterThan(firstMetrics.prerouter.predictions, 0)
        XCTAssertEqual(firstMetrics.prerouter.fallbacks, 0)

        let cancelled = EventBox()
        let task = Task {
            try await engine.generate(
                messages: messages,
                options: Edge0EngineOptions(maxTokens: 32, mode: .stagedPrerouter),
                onEvent: { cancelled.append($0) }
            )
        }
        try await waitForToken(cancelled, timeout: 240)
        engine.cancel()
        _ = try? await task.value
        XCTAssertTrue(cancelled.snapshot.contains(.cancelled))

        let second = EventBox()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 2, mode: .stagedPrerouter),
            onEvent: { second.append($0) }
        )
        XCTAssertEqual(second.completedTokens, 2)

        let rawStats = await engine.expertPoolStatistics()
        let stats = try XCTUnwrap(rawStats)
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)

        await engine.unload()
        XCTAssertFalse(engine.isLoaded)
        try await engine.load(configuration: .init(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            expertPoolSlots: 64,
            expertPoolBytes: 256 * 1_048_576,
            maxConcurrentReads: 4
        ))
        engine.prerouterPredictorOverride = WrongPredictor()
        let reloaded = EventBox()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 2, mode: .stagedPrerouter),
            onEvent: { reloaded.append($0) }
        )
        XCTAssertEqual(reloaded.completedTokens, 2)
        await engine.unload()
    }

    // MARK: Engine lifecycle in staged mode

    func testStagedEngineCancelReloadStaysBounded() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let engine = Edge0Engine()
        try await engine.load(configuration: .init(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            expertPoolSlots: 64,
            expertPoolBytes: 256 * 1_048_576,
            maxConcurrentReads: 4
        ))
        let messages: [[String: String]] = [
            ["role": "user", "content": "The capital of France is"]
        ]
        let events = EventBox()
        let task = Task {
            try await engine.generate(
                messages: messages,
                options: Edge0EngineOptions(maxTokens: 32, mode: .staged),
                onEvent: { events.append($0) }
            )
        }
        try await waitForToken(events, timeout: 240)
        engine.cancel()
        _ = try? await task.value
        XCTAssertTrue(events.snapshot.contains(.cancelled))

        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 2, mode: .staged),
            onEvent: { events.append($0) }
        )
        let metrics = try XCTUnwrap(engine.generationMetrics())
        XCTAssertGreaterThanOrEqual(metrics.generatedTokens, 1)
        print("[Edge0 staged] staging snapshot: \(metrics.staging)")
        XCTAssertGreaterThan(
            metrics.staging.banksScheduled, 0,
            "staged prefill must schedule banks"
        )
        XCTAssertLessThanOrEqual(
            metrics.staging.criticalStageWaitSeconds,
            metrics.prefillSeconds + metrics.decodeSeconds,
            "critical stage wait cannot exceed total generation time"
        )
        let rawStats = await engine.expertPoolStatistics()
        let stats = try XCTUnwrap(rawStats)
        XCTAssertLessThanOrEqual(stats.occupancySlots, stats.capacitySlots)
        XCTAssertLessThanOrEqual(stats.occupancyBytes, stats.capacityBytes)

        await engine.unload()
        XCTAssertFalse(engine.isLoaded)
    }

    // MARK: Phase 4B-4 hardening

    func testPrerouterQuiescenceAndIgnoredSchedulingAfterCancel() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_8B()
        let index = try Edge0SafetensorsIndex.openSingleFile(
            at: modelURL.appendingPathComponent("model.safetensors")
        )
        let stores = try Edge0TensorStoreSet(
            directory: modelURL, shardNames: ["model.safetensors"]
        )
        _ = try await Edge0Model.load(
            configuration: configuration, index: index, stores: stores
        )
        let expertLoader = try Edge0ExpertLoader(index: index, stores: stores)
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(capacitySlots: 64, capacityBytes: 256 * 1_048_576),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )
        let runtime = Edge0PrerouterRuntime<Edge0ExpertWeights>(
            predictor: WrongPredictor(), pool: pool
        )
        let ids = Array(0..<8)
        runtime.predictAndSchedule(
            owner: 7,
            hidden: MLXArray.zeros([1, 1, 1536], dtype: .float16),
            thisIDs: ids,
            token: 0,
            targetLayerCount: 24,
            topK: 8
        )
        runtime.cancel()
        await runtime.waitForQuiescence()

        // Scheduling after cancellation must be a no-op (closed runtime).
        let before = runtime.metrics.current.predictions
        runtime.predictAndSchedule(
            owner: 7,
            hidden: MLXArray.zeros([1, 1, 1536], dtype: .float16),
            thisIDs: ids,
            token: 1,
            targetLayerCount: 24,
            topK: 8
        )
        await runtime.waitForQuiescence()
        XCTAssertEqual(
            runtime.metrics.current.predictions, before,
            "a closed runtime must not accept new predictions"
        )
    }

    func testComponentProfileRecordsAggregateTimes() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let engine = Edge0Engine()
        Edge0EnginePreferences.componentProfilingEnabled = true
        defer { Edge0EnginePreferences.componentProfilingEnabled = false }
        try await engine.load(configuration: .init(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            expertPoolSlots: 64,
            expertPoolBytes: 256 * 1_048_576,
            maxConcurrentReads: 4
        ))
        let events = EventBox()
        try await engine.generate(
            messages: [["role": "user", "content": "The capital of France is"]],
            options: Edge0EngineOptions(maxTokens: 2, mode: .stagedPrerouter),
            onEvent: { events.append($0) }
        )
        let metrics = try XCTUnwrap(engine.generationMetrics())
        let profile = metrics.profile
        print("[Edge0 profile] prefill kda=\(profile.prefill.kdaSeconds) mla=\(profile.prefill.mlaSeconds) moe=\(profile.prefill.moeSeconds) router=\(profile.prefill.routerSeconds)")
        print("[Edge0 profile] decode  kda=\(profile.decode.kdaSeconds) mla=\(profile.decode.mlaSeconds) moe=\(profile.decode.moeSeconds) lmHead=\(profile.decode.lmHeadSeconds)")
        XCTAssertGreaterThan(profile.prefill.kdaSeconds, 0)
        XCTAssertGreaterThan(profile.prefill.moeSeconds, 0)
        XCTAssertGreaterThan(profile.decode.moeSeconds, 0)
        await engine.unload()
    }

    func testExperimentPreferenceClamps() {
        let originalReads = Edge0EnginePreferences.expertLoadConcurrency
        let originalProfile = Edge0EnginePreferences.componentProfilingEnabled
        defer {
            Edge0EnginePreferences.expertLoadConcurrency = originalReads
            Edge0EnginePreferences.componentProfilingEnabled = originalProfile
        }
        Edge0EnginePreferences.expertLoadConcurrency = 99
        XCTAssertEqual(Edge0EnginePreferences.expertLoadConcurrency, 6)
        Edge0EnginePreferences.expertLoadConcurrency = 0
        XCTAssertEqual(Edge0EnginePreferences.expertLoadConcurrency, 1)
    }

    // MARK: Helpers

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Edge0EngineEvent] = []
        func append(_ event: Edge0EngineEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }
        var snapshot: [Edge0EngineEvent] {
            lock.lock(); defer { lock.unlock() }; return events
        }
        var completedTokens: Int? {
            for event in snapshot.reversed() {
                if case .completed(let tokens, _) = event { return tokens }
            }
            return nil
        }
    }

    private func waitForToken(
        _ box: EventBox,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.snapshot.contains(where: {
                if case .token = $0 { return true }
                return false
            }) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("No token emitted before timeout")
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
