import Foundation
import MLX

// MARK: - Edge0EngineError

enum Edge0EngineError: Error, Equatable, Sendable {
    case notLoaded
    case invalidModelDirectory(String)
    case tokenizerUnavailable(String)
    case generationAlreadyActive
    case cancelled
}

// MARK: - Edge0EngineOptions

struct Edge0EngineOptions: Sendable {
    var maxTokens: Int = 256
    var temperature: Double = 0
    var topP: Double = 1
    var topK: Int = 0
    var minP: Double = 0
    var repetitionPenalty: Double?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var penaltyContextSize: Int = 20
    var seed: UInt64?
    var mode: Edge0ExecutionMode = .exact
    var eosTokenID: Int = 156_895
    /// Additional family stop ids (e.g. the 35B `<|im_end|>` plus EOS).
    /// Empty for the 8B family, so its behavior is unchanged.
    var additionalEOSTokenIDs: [Int] = []
    /// Whether the family chat template should enable its thinking section.
    /// Honored by the 35B engine; the 8B template is unchanged.
    var enableThinking: Bool = false

    var sampler: Edge0Sampler {
        Edge0Sampler(
            temperature: Float(temperature),
            topP: Float(topP),
            topK: topK,
            minP: Float(minP),
            repetitionPenalty: repetitionPenalty.map(Float.init),
            presencePenalty: presencePenalty.map(Float.init),
            frequencyPenalty: frequencyPenalty.map(Float.init),
            penaltyContextSize: penaltyContextSize
        )
    }
}

// MARK: - Edge0GenerationMetrics
//
// Phase 4A baseline instrumentation. Timing boundaries:
//   • prefillSeconds        = the model.prefill call only
//   • timeToFirstToken      = generate() entry (template incl.) -> first
//                             sampled token, matching the app-visible TTFT
//   • decodeTokensPerSecond = (generated - 1) / (last - first token)

struct Edge0GenerationMetrics: Sendable, Equatable {
    var promptTokens = 0
    var generatedTokens = 0
    var prefillSeconds = 0.0
    var timeToFirstTokenSeconds = 0.0
    var decodeSeconds = 0.0
    var decodeTokensPerSecond = 0.0
    var totalSeconds = 0.0
    /// Expert-pool deltas, split by generation phase.
    var prefillPool = Edge0PhasePoolMetrics()
    var decodePool = Edge0PhasePoolMetrics()
    /// Scheduler-level counters for `.staged` (zero in other modes).
    var staging = Edge0StagingCollector.Snapshot()
    /// Advisory prerouter counters (zero unless `.stagedPrerouter` ran).
    var prerouter = Edge0PrerouterMetrics.Snapshot()
    /// Coarse component wall-time attribution (zero unless profiling is on).
    var profile = Edge0ComponentProfile.Snapshot()
    /// Thinking/final-answer separation (native template enable_thinking).
    var thinkingEnabled = false
    var reasoningTokens = 0
    var finalAnswerTokens = 0
    var endedWhileThinking = false

    var prefillBytesPerPromptToken: UInt64 {
        prefillPool.bytesPerToken(promptTokens)
    }
    var decodeBytesPerGeneratedToken: UInt64 {
        decodePool.bytesPerToken(generatedTokens)
    }
}

// MARK: - Edge0EngineEvent

enum Edge0EngineEvent: Sendable, Equatable {
    case started
    case token(String)
    case completed(generatedTokens: Int, tokensPerSecond: Double)
    case cancelled
}

// MARK: - Edge0Engine
//
// Exact-mode native Edge0-8B runtime core: immutable model + tokenizer +
// bounded expert pool, with generation-scoped state. Portable (Foundation +
// MLX only); the app-level `RuntimeEngineBackend` adapter wraps this.

final class Edge0Engine: @unchecked Sendable {
    struct Configuration: Sendable {
        let modelDirectory: URL
        let expertPoolSlots: Int
        let expertPoolBytes: UInt64
        /// Hard bound on concurrent expert preads; the tensor store's read
        /// semaphore enforces it. 4 is the verified default.
        var maxConcurrentReads: Int = 4
    }

    private(set) var configuration: Edge0ModelConfiguration?
    private(set) var engineConfiguration: Configuration?
    private var model: Edge0Model?
    private var tokenizer: Edge0Tokenizer?
    private(set) var stores: Edge0TensorStoreSet?
    private(set) var pool: Edge0ExpertPool<Edge0ExpertWeights>?

    // MARK: - Cross-thread generation state
    //
    // `generate()` runs on a non-isolated task while `cancel()` is invoked
    // from the MainActor backend, so the active-generation identity and the
    // published metrics snapshot are genuinely shared mutable state. Both are
    // guarded here; the class is `@unchecked Sendable`, so the compiler does
    // not check this for us. (Same pattern as `Edge0_35BEngine`.)

    private let generationLock = NSLock()
    private var _generationID: UUID?
    private var _lastGenerationMetrics: Edge0GenerationMetrics?

    /// Internal (not private) so the ownership semantics are unit-testable
    /// without a loaded checkpoint.
    var generationID: UUID? {
        get {
            generationLock.lock(); defer { generationLock.unlock() }
            return _generationID
        }
        set {
            generationLock.lock(); defer { generationLock.unlock() }
            _generationID = newValue
        }
    }

    /// Atomically clears the owner only if it is still `expected`, so a late
    /// completion cannot steal ownership from a newer generation.
    /// Returns whether the clear actually happened.
    @discardableResult
    func clearGeneration(if expected: UUID) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        guard _generationID == expected else { return false }
        _generationID = nil
        return true
    }

    private var lastGenerationMetrics: Edge0GenerationMetrics? {
        get {
            generationLock.lock(); defer { generationLock.unlock() }
            return _lastGenerationMetrics
        }
        set {
            generationLock.lock(); defer { generationLock.unlock() }
            _lastGenerationMetrics = newValue
        }
    }

    private var cachedPrerouter: Edge0Prerouter?
    private var activePrerouterRuntime: Edge0PrerouterRuntime<Edge0ExpertWeights>?
    private var thinkOpenTokenID: Int?
    private var thinkCloseTokenID: Int?

    /// Test-only injection point for wrong/zero/failure predictor safety
    /// tests. When set, `.stagedPrerouter` uses this predictor instead of
    /// the artifact.
    var prerouterPredictorOverride: (any Edge0ExpertPredictor)?

    var isLoaded: Bool { model != nil }

    func expertPoolStatistics() async -> Edge0ExpertPoolStats? {
        await pool?.statistics()
    }

    /// True while a generation owns the engine.
    var isGenerationInFlight: Bool { generationID != nil }

    /// Configured expert-read concurrency actually handed to the store.
    var configuredReadConcurrency: Int {
        engineConfiguration?.maxConcurrentReads ?? 0
    }

    /// Cheap store read counters (configured/peak/active).
    func readStatistics() -> Edge0TensorStoreReadStats? {
        stores?.readStatistics()
    }

    func generationMetrics() -> Edge0GenerationMetrics? {
        lastGenerationMetrics
    }

    // MARK: Load / unload

    func load(configuration engineConfiguration: Configuration) async throws {
        let directory = engineConfiguration.modelDirectory
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw Edge0EngineError.invalidModelDirectory(
                "config.json missing in \(directory.path)"
            )
        }
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: configURL)
        )
        try configuration.validateEdge0_8B()

        let index = try Edge0SafetensorsIndex.openSingleFile(
            at: directory.appendingPathComponent("model.safetensors")
        )
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: index.shardNames,
            maxConcurrentReads: engineConfiguration.maxConcurrentReads
        )
        let model = try await Edge0Model.load(
            configuration: configuration,
            index: index,
            stores: stores
        )
        let tokenizer: Edge0Tokenizer
        do {
            tokenizer = try await Edge0Tokenizer.load(from: directory)
        } catch {
            await stores.closeAll()
            throw Edge0EngineError.tokenizerUnavailable(
                error.localizedDescription
            )
        }
        let expertLoader = try Edge0ExpertLoader(index: index, stores: stores)
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(
                capacitySlots: engineConfiguration.expertPoolSlots,
                capacityBytes: engineConfiguration.expertPoolBytes
            ),
            loader: { key in try await expertLoader.load(key) },
            sizeOf: { $0.byteSize }
        )

        self.configuration = configuration
        self.engineConfiguration = engineConfiguration
        self.stores = stores
        self.model = model
        self.tokenizer = tokenizer
        self.pool = pool
        self.generationID = nil
        self.thinkOpenTokenID = tokenizer.convertTokenToId("<think>")
        self.thinkCloseTokenID = tokenizer.convertTokenToId("</think>")
    }

    func unload() async {
        generationID = nil
        // Drain advisory work before any runtime is torn down; a model switch
        // must never race an in-flight prediction or speculative read.
        activePrerouterRuntime?.cancel()
        await activePrerouterRuntime?.waitForQuiescence()
        activePrerouterRuntime = nil
        if let pool {
            await pool.close()
        }
        if let stores {
            await stores.closeAll()
        }
        model = nil
        tokenizer = nil
        stores = nil
        pool = nil
        configuration = nil
        engineConfiguration = nil
        cachedPrerouter = nil
        activePrerouterRuntime?.cancel()
        activePrerouterRuntime = nil
    }

    func cancel() {
        generationID = nil
        activePrerouterRuntime?.cancel()
    }

    // MARK: Generate

    /// Exact-mode generation: real chat template, real prefill, cached
    /// decode, greedy or temperature sampling. Greedy
    /// (`temperature <= 0`) is the parity mode.
    func generate(
        messages: [[String: String]],
        options: Edge0EngineOptions = Edge0EngineOptions(),
        onEvent: @escaping @Sendable (Edge0EngineEvent) -> Void
    ) async throws {
        guard let model, let tokenizer, let pool, let directory =
            engineConfiguration?.modelDirectory else {
            throw Edge0EngineError.notLoaded
        }
        let generation = UUID()
        generationID = generation
        let generationStarted = ContinuousClock.now
        onEvent(.started)

        let thinkingEnabled = options.enableThinking
            && thinkCloseTokenID != nil
        var tokenIDs: [Int]
        do {
            tokenIDs = try tokenizer.applyChatTemplate(
                messages: messages,
                templateDirectory: directory,
                additionalContext: ["enable_thinking": thinkingEnabled]
            )
        } catch {
            throw Edge0EngineError.tokenizerUnavailable(
                error.localizedDescription
            )
        }

        let sampler = options.sampler
        if let seed = options.seed {
            // Reproducible sampling: one seeding per generation, matching the
            // app's MLX path where `GenerateParameters.seed` fixes the RNG.
            MLXRandom.seed(seed)
        }

        var effectiveMode = options.mode
        var prerouterRuntime: Edge0PrerouterRuntime<Edge0ExpertWeights>?
        var prerouterFallbacks = 0
        if options.mode == .stagedPrerouter {
            if prerouterPredictorOverride == nil, cachedPrerouter == nil,
               let directory = engineConfiguration?.modelDirectory {
                cachedPrerouter = try? await Edge0Prerouter.load(
                    directory: directory,
                    configuration: model.configuration
                )
            }
            if let predictor = prerouterPredictorOverride ?? cachedPrerouter {
                prerouterRuntime = Edge0PrerouterRuntime(
                    predictor: predictor, pool: pool
                )
            } else {
                // Optional optimization unavailable: run as staged.
                effectiveMode = .staged
                prerouterFallbacks = 1
            }
        }
        activePrerouterRuntime = prerouterRuntime
        let profile = Edge0EnginePreferences.componentProfilingEnabled
            ? Edge0ComponentProfile() : nil
        let staging = (effectiveMode == .staged || effectiveMode == .stagedPrerouter)
            ? Edge0StagingCollector() : nil
        let poolBefore = await pool.statistics()
        let prefillStarted = ContinuousClock.now
        let prefill = try await model.prefill(
            tokenIDs: tokenIDs,
            pool: pool,
            mode: effectiveMode,
            staging: staging,
            prerouter: prerouterRuntime,
            profile: profile
        )
        let prefillSeconds = prefillStarted.duration(to: .now).timeInterval
        let poolAfterPrefill = await pool.statistics()
        var state = prefill.state
        var logits = prefill.logits[0, -1].asType(.float32)
        var generated: [Int] = []
        var context = tokenIDs
        var firstTokenAt: ContinuousClock.Instant?

        // Shared thinking/final-answer channel: the template opens the
        // thinking section in the prompt when enabled; markers emitted as
        // token ids or literal text are normalized to exactly one pair.
        var channel = Edge0ThinkingChannel(
            promptOpened: thinkingEnabled,
            openTokenID: thinkOpenTokenID,
            closeTokenID: thinkCloseTokenID
        )
        var lastDisplay = ""
        for marker in channel.initialMarkers {
            lastDisplay += marker.text
            onEvent(.token(marker.text))
        }

        while generated.count < options.maxTokens {
            if Task.isCancelled || generationID != generation {
                // Only clear if this generation still owns the engine;
                // otherwise a newer generation would lose its identity and
                // become uncancellable.
                _ = clearGeneration(if: generation)
                prerouterRuntime?.cancel()
                activePrerouterRuntime = nil
                onEvent(.cancelled)
                return
            }
            let token = sampler.sample(
                logits: logits,
                previousTokens: Array(context.suffix(sampler.penaltyContextSize))
            )
            if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
            generated.append(token)
            context.append(token)
            let decoded = tokenizer.decode(generated, skipSpecialTokens: true)
            channel.consume(tokenID: token, decodedCount: decoded.count)
            let display = channel.normalize(decoded: decoded)
            if display.hasPrefix(lastDisplay) {
                let delta = String(display.dropFirst(lastDisplay.count))
                if !delta.isEmpty { onEvent(.token(delta)) }
            } else if !display.isEmpty {
                onEvent(.token(display))
            }
            lastDisplay = display
            if token == options.eosTokenID { break }

            let stepLogits = try await model.decode(
                tokenID: token,
                state: &state,
                pool: pool,
                mode: effectiveMode,
                staging: staging,
                prerouter: prerouterRuntime,
                profile: profile
            )
            logits = stepLogits[0, -1].asType(.float32)
        }

        let finalDisplay = channel.finish(
            decoded: tokenizer.decode(generated, skipSpecialTokens: true)
        )
        if finalDisplay.hasPrefix(lastDisplay) {
            let delta = String(finalDisplay.dropFirst(lastDisplay.count))
            if !delta.isEmpty { onEvent(.token(delta)) }
        } else if !finalDisplay.isEmpty {
            onEvent(.token(finalDisplay))
        }

        let finished = ContinuousClock.now
        let totalSeconds = generationStarted.duration(to: finished).timeInterval
        let ttftSeconds = firstTokenAt.map {
            generationStarted.duration(to: $0).timeInterval
        } ?? totalSeconds
        let decodeSeconds = firstTokenAt.map {
            $0.duration(to: finished).timeInterval
        } ?? 0
        let decodeRate = generated.count >= 2 && decodeSeconds > 0
            ? Double(generated.count - 1) / decodeSeconds
            : 0
        let poolAfterDecode = await pool.statistics()
        var prerouterSnapshot = prerouterRuntime?.metrics.current
            ?? Edge0PrerouterMetrics.Snapshot()
        prerouterSnapshot.fallbacks += prerouterFallbacks
        lastGenerationMetrics = Edge0GenerationMetrics(
            promptTokens: tokenIDs.count,
            generatedTokens: generated.count,
            prefillSeconds: prefillSeconds,
            timeToFirstTokenSeconds: ttftSeconds,
            decodeSeconds: decodeSeconds,
            decodeTokensPerSecond: decodeRate,
            totalSeconds: totalSeconds,
            prefillPool: .delta(poolAfterPrefill, poolBefore),
            decodePool: .delta(poolAfterDecode, poolAfterPrefill),
            staging: staging?.current ?? Edge0StagingCollector.Snapshot(),
            prerouter: prerouterSnapshot,
            profile: profile?.current ?? Edge0ComponentProfile.Snapshot(),
            thinkingEnabled: thinkingEnabled,
            reasoningTokens: channel.reasoningTokens,
            finalAnswerTokens: channel.finalAnswerTokens,
            endedWhileThinking: channel.endedWhileThinking
        )
        activePrerouterRuntime = nil
        // Atomic compare-and-clear: a cancel() that already handed ownership
        // to a newer generation must not have it stolen by this completion.
        _ = clearGeneration(if: generation)
        onEvent(.completed(
            generatedTokens: generated.count,
            tokensPerSecond: Double(generated.count) / max(totalSeconds, 1e-6)
        ))
    }

}

private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
