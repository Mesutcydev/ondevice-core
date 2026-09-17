import Foundation
import MLX

// MARK: - Edge0_35BEngineError

enum Edge0_35BEngineError: Error, Equatable, Sendable {
    case notLoaded
    case generationAlreadyActive
    case unsupportedExecutionMode(String)
    case tokenizerUnavailable(String)
}

extension Edge0_35BEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The Edge0-35B model is not loaded."
        case .generationAlreadyActive:
            return "A generation is already active."
        case .unsupportedExecutionMode(let mode):
            return "Edge0-35B does not support execution mode '\(mode)' in this release."
        case .tokenizerUnavailable(let detail):
            return "Edge0-35B tokenizer is unavailable: \(detail)"
        }
    }
}

// MARK: - Edge0_35BGenerationMetrics

/// Family metrics for one generation. Timings mirror the 8B engine so the
/// app-visible semantics stay identical; pool deltas are split by phase.
struct Edge0_35BGenerationMetrics: Sendable, Equatable {
    var promptTokens = 0
    var generatedTokens = 0
    var prefillSeconds = 0.0
    var timeToFirstTokenSeconds = 0.0
    var decodeSeconds = 0.0
    var decodeTokensPerSecond = 0.0
    var totalSeconds = 0.0
    var prefillPool = Edge0PhasePoolMetrics()
    var decodePool = Edge0PhasePoolMetrics()
    var requestedMode = Edge0ExecutionMode.exact.rawValue
    var effectiveMode = Edge0ExecutionMode.exact.rawValue
    var stopReason = ""
    var finalPosition = 0
    var eosHit = false
    var thinkingEnabled = false
    var reasoningTokens = 0
    var finalAnswerTokens = 0
    var timeToFirstAnswerTokenSeconds = 0.0
    var endedWhileThinking = false
    var decodeCalls = 0
    var controlTokens = 0
    var endToEndTokensPerSecond = 0.0
    var promptSystemTokens = 0
    var promptHistoryTokens = 0
    var promptUserTokens = 0
    var promptTemplateOverheadTokens = 0
    var modeFallback = ""
    var profile = Edge0ComponentProfile.Snapshot()
    var positionAfterPrefill = 0
    var kvTokensAfterPrefill = 0
    var kvTokensFinal = 0
    var linearStateBytes = 0
    var layerInvocations = 0
    var expertLoads = 0
    var activeOutputConsumers = 0
    var routerHash: UInt64 = 0
    var uniqueExpertTotal = 0
    var moeInvocations = 0
    var mlxActiveBytes = 0
    var mlxCacheBytes = 0
    var mlxPeakBytes = 0
    var prefillMode = ""
    var decodeMode = ""
    var evalWindowRequested = 1
    var evalWindowEffective = 1
    var microbatchRequested = 1
    var microbatchEffective = 1
    var routedGroups = 0
    var handoffInFlightBefore = 0
    var handoffInFlightAfter = 0
    /// Advisory expert loads issued BY THIS GENERATION (delta, not lifetime).
    var handoffAdvisoryLoads = 0
    /// Pool lifetime advisory load count at generation end (labeled total).
    var advisoryLoadsLifetime = 0
    /// Phase 5J advisory prerouter: requested (preference), active (artifact
    /// present), fallback count, and full prediction/residency metrics.
    var advisoryRequested = false
    var advisoryActive = false
    var advisoryFallbacks = 0
    var advisory = Edge0PrerouterMetrics.Snapshot()
    /// Effective predictor provenance (requested is not evidence of active).
    var advisoryArtifactPresent = false
    var advisoryArtifactValid = false
    var advisoryHeadCount = 0
    var advisoryLoadedBytes: UInt64 = 0
    var advisoryFallbackReason = ""
    /// Phase 5K candidate: requested/effective router-readback strategy
    /// (1 = batched readback; only the staged·microbatch prefill uses it).
    var routerReadbackRequested = 0
    var routerReadbackEffective = 0
    /// Phase 5M candidate: requested (preference read at generation time) vs
    /// effective (engine-load-captured) kernel readahead. A mismatch means
    /// the arm's engine was not reloaded after the preference changed —
    /// requested alone is not evidence the loaders issue hints.
    var readaheadRequested = false
    var readaheadEffective = false
    /// Session-state reuse (prompt cache): whether the turn restored the
    /// previous prompt-boundary snapshot, how many tokens it reused, and how
    /// many tokens it actually prefilled.
    var sessionReuseApplied = false
    var sessionReusedTokens = 0
    var sessionPrefillTokens = 0

    var prefillBytesPerPromptToken: UInt64 {
        prefillPool.bytesPerToken(promptTokens)
    }
    var decodeBytesPerGeneratedToken: UInt64 {
        decodePool.bytesPerToken(generatedTokens)
    }
}

// MARK: - Edge0SessionSnapshot
//
// Prompt-boundary snapshot for session-state reuse (prompt cache). The
// generation state and its arrays are updated functionally (new arrays per
// step, never in-place mutation), so a snapshot taken at the prompt boundary
// stays valid while decode proceeds.

struct Edge0SessionSnapshot: @unchecked Sendable {
    var state: Edge0_35BModelState
    var logits: MLXArray
    /// Exact prompt tokens this snapshot was taken at.
    var tokens: [Int]
    /// Scheduling key: reuse requires identical effective knobs.
    var mode: String
    var microbatch: Int
    var evalWindow: Int
}

/// Result of the in-app session-reuse parity probe.
struct Edge0SessionReuseProbeResult: Sendable {
    var passed = false
    var firstDifferingIndex: Int?
    var reuseAppliedOnTurn2 = false
    var reusedTokens = 0
    var prefilledTokens = 0
    var emittedTokens = 0
    var turn2PromptTokens = 0
}

// MARK: - Edge0_35BEngine
//
// Exact-mode native Edge0-35B runtime core: pinned artifact validation,
// immutable model (quantized base + 310 unmerged Recover-LoRA adapters),
// real tokenizer, and a bounded expert pool executing one token at a time.
//
// This release executes ONLY the exact true-router path:
//   • Recover-LoRA applied, router K=4 (normalized top-k), no prerouter.
//   • No staging/fused/cache tuning; requested optimization modes are
//     resolved to exact and reported honestly.
//   • Fresh full prefill plus single-token cached decode (no chunked
//     prefill, no unverified mask/state path).

final class Edge0_35BEngine: @unchecked Sendable {
    struct Configuration: Sendable {
        let modelDirectory: URL
        let expertPoolSlots: Int
        let expertPoolBytes: UInt64
        /// Hard bound on concurrent expert preads.
        var maxConcurrentReads: Int = 4
    }

    /// Production default for this family, promoted from the device A/Bs:
    /// staged prefill with bounded decode. Build-34 confirmation (iPhone18,2
    /// · 118-token prompt · 64 output tokens · greedy · Thinking Off ·
    /// 512 MiB / 303-slot pool · reads 4): prefill 10.435 → 8.314 s median
    /// (−20.3%), first visible answer 10.500 → 8.373 s, engine completion
    /// 19.917 → 17.902 s, decode 6.66 vs 6.58 tok/s (staged inside the
    /// bounded range), identical sequences, ~2.50 GB peak, thermal nominal.
    /// Exact and Bounded Prefetch stay selectable.
    static let defaultExecutionMode: Edge0ExecutionMode = .staged

    /// Frozen reference contract (Phase 5B). Developer parity probe only.
    static let exactReferencePromptIDs = [760, 6511, 314, 9338, 369]
    static let exactReferenceEmittedIDs = [
        11751, 13, 271, 248068, 271, 248069, 271, 4639, 369,
    ]

    let family = Edge0ModelFamily.qwen35MoE

    private(set) var configuration: Edge0_35BModelConfiguration?
    private(set) var engineConfiguration: Configuration?
    private(set) var installSummary: Edge0_35BInstallSummary?
    private(set) var eosTokenIDs: [Int] = [248_046, 248_044]
    private(set) var loraModuleCount = 0
    private(set) var routerTopK = 4

    private var model: Edge0_35BModel?
    private var tokenizer: Edge0Tokenizer?
    private(set) var stores: Edge0TensorStoreSet?
    /// Optional advisory predictor + its off-critical-path runtime. Loaded
    /// lazily, never required; nil disables advisory behavior entirely.
    private var cachedAdvisoryPrerouter: Edge0_35BPrerouter?
    /// Prompt-cache snapshot (see `Edge0EnginePreferences.edge0_35BSessionReuse`).
    private var sessionSnapshot: Edge0SessionSnapshot?
    private var activeAdvisoryRuntime:
        Edge0PrerouterRuntime<Edge0_35BExpertWeights>?
    /// Test injection point (deterministic or failing predictor).
    var advisoryPredictorOverride: (any Edge0ExpertPredictor)?
    /// Diagnostic-only per-prediction trace (nil in production).
    var advisoryTraceSink: (@Sendable (Edge0PrerouterEvent) -> Void)?
    private(set) var pool: Edge0ExpertPool<Edge0_35BExpertWeights>?

    // MARK: - Cross-thread generation state
    //
    // `generate()` runs on a non-isolated task while `cancel()` is invoked
    // from the MainActor backend, so the active-generation identity and the
    // published metrics snapshot are genuinely shared mutable state. Both are
    // guarded here; the class is `@unchecked Sendable`, so the compiler does
    // not check this for us.

    private let generationLock = NSLock()
    private var _generationID: UUID?
    private var _lastGenerationMetrics: Edge0_35BGenerationMetrics?

    /// Identity of the generation that currently owns this engine.
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

    private var lastGenerationMetrics: Edge0_35BGenerationMetrics? {
        get {
            generationLock.lock(); defer { generationLock.unlock() }
            return _lastGenerationMetrics
        }
        set {
            generationLock.lock(); defer { generationLock.unlock() }
            _lastGenerationMetrics = newValue
        }
    }

    private var exactMode = true
    private var thinkOpenTokenID: Int?
    private var thinkCloseTokenID: Int?

    var isLoaded: Bool { model != nil }

    func expertPoolStatistics() async -> Edge0ExpertPoolStats? {
        await pool?.statistics()
    }

    /// True while a generation owns the engine.
    var isGenerationInFlight: Bool { generationID != nil }

    /// Phase 5M: value the expert loaders froze at load time. Authoritative
    /// "effective" half of the readahead requested/effective pair.
    private(set) var readaheadHintsEnabled = false

    /// Configured expert-read concurrency actually handed to the store.
    var configuredReadConcurrency: Int {
        engineConfiguration?.maxConcurrentReads ?? 0
    }

    /// Cheap store read counters (configured/peak/active).
    func readStatistics() -> Edge0TensorStoreReadStats? {
        stores?.readStatistics()
    }

    func generationMetrics() -> Edge0_35BGenerationMetrics? {
        lastGenerationMetrics
    }

    // MARK: Load / unload

    func load(configuration engineConfiguration: Configuration) async throws {
        let directory = engineConfiguration.modelDirectory

        // 1. Pinned-artifact validation (files, sizes, index containment,
        //    config identity, LoRA target contract).
        let summary = try Edge0_35BModelArtifacts.validateInstall(
            directory: directory
        )
        let requestedEOS = Self.readEOSTokenIDs(
            at: directory.appendingPathComponent("generation_config.json")
        )
        let configuration = try Edge0_35BModelConfiguration.decode(
            from: Data(contentsOf: directory.appendingPathComponent("config.json"))
        )

        // 2. Open shard stores (headers only) and the bounded expert pool.
        // The index is already parsed for loading, so tensor/payload
        // accounting comes for free.
        let index = try Edge0SafetensorsIndex.openSharded(in: directory)
        var enrichedSummary = summary
        Edge0_35BModelArtifacts.applyWeightAccounting(
            Edge0_35BModelArtifacts.weightAccounting(for: index),
            to: &enrichedSummary
        )
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: index.shardNames,
            maxConcurrentReads: engineConfiguration.maxConcurrentReads
        )
        // Captured once per load: the readahead A/B runner switches arms by
        // RELOADING the engine (the loaders freeze this flag), and
        // generation metrics report it back as `readaheadEffective`.
        let readaheadEnabled = Edge0EnginePreferences.edge0_35BReadaheadHints
        do {
            let loaders = try (0..<configuration.numHiddenLayers).map { layer in
                try Edge0_35BExpertLoader(
                    index: index,
                    stores: stores,
                    layer: layer,
                    readaheadHints: readaheadEnabled
                )
            }
            let pool = Edge0ExpertPool<Edge0_35BExpertWeights>(
                configuration: .init(
                    capacitySlots: engineConfiguration.expertPoolSlots,
                    capacityBytes: engineConfiguration.expertPoolBytes
                ),
                loader: { key in try await loaders[key.layer].load(key) },
                sizeOf: { $0.byteSize }
            )

            // 3. Immutable model: resident quantized tensors + adapters.
            let model = try await Edge0_35BModel.load(
                directory: directory,
                index: index,
                stores: stores,
                pool: pool
            )

            // 4. Real tokenizer/template for the chat path.
            let tokenizer: Edge0Tokenizer
            do {
                tokenizer = try await Edge0Tokenizer.load(from: directory)
            } catch {
                throw Edge0_35BEngineError.tokenizerUnavailable(
                    error.localizedDescription
                )
            }

            self.configuration = configuration
            self.engineConfiguration = engineConfiguration
            self.readaheadHintsEnabled = readaheadEnabled
            self.installSummary = enrichedSummary
            self.eosTokenIDs = requestedEOS
            self.loraModuleCount = summary.loraModuleCount
            self.stores = stores
            self.model = model
            self.tokenizer = tokenizer
            self.pool = pool
            self.generationID = nil
            self.lastGenerationMetrics = nil
            self.thinkOpenTokenID = tokenizer.convertTokenToId("<think>")
            self.thinkCloseTokenID = tokenizer.convertTokenToId("</think>")
        } catch {
            await stores.closeAll()
            throw error
        }
    }

    func unload() async {
        generationID = nil
        activeAdvisoryRuntime?.cancel()
        await activeAdvisoryRuntime?.waitForQuiescence()
        activeAdvisoryRuntime = nil
        cachedAdvisoryPrerouter = nil
        sessionSnapshot = nil
        if let pool {
            await pool.cancelAdvisoryLoads()
            await pool.close()
        }
        if let model {
            await model.close()
        }
        model = nil
        tokenizer = nil
        stores = nil
        pool = nil
        configuration = nil
        engineConfiguration = nil
        installSummary = nil
        lastGenerationMetrics = nil
    }

    func cancel() {
        generationID = nil
        Task { [pool] in await pool?.cancelAdvisoryLoads() }
    }

    // MARK: Generate

    /// Pure prefix-reuse decision (unit-tested on the simulator). Reuse
    /// requires the feature to be enabled, a scheduling-key match, and the
    /// new prompt to be an exact token-level extension of (or equal to) the
    /// snapshot's prompt. Returns the number of tokens reused, or nil for a
    /// fresh full prefill. Anything else — divergence, truncation, a key
    /// change — falls back; a partial rewind of the recurrent state is never
    /// attempted.
    nonisolated static func sessionReuseCount(
        enabled: Bool,
        snapshotTokens: [Int]?,
        keyMatches: Bool,
        promptTokens: [Int]
    ) -> Int? {
        guard enabled, keyMatches, let snapshotTokens else { return nil }
        guard promptTokens.count >= snapshotTokens.count else { return nil }
        guard Array(promptTokens.prefix(snapshotTokens.count)) == snapshotTokens
        else { return nil }
        return snapshotTokens.count
    }

    /// Exact-mode generation: real chat template, fresh generation state,
    /// full prefill, cached single-token decode. Sampler knobs never change
    /// expert routing (K stays 4).
    func generate(
        messages: [[String: String]],
        options: Edge0EngineOptions = Edge0EngineOptions(),
        onEvent: @escaping @Sendable (Edge0EngineEvent) -> Void
    ) async throws {
        guard let model, let tokenizer, let pool, let directory =
            engineConfiguration?.modelDirectory else {
            throw Edge0_35BEngineError.notLoaded
        }
        // Exact true-router execution is the only 35B mode in this release;
        // requested optimization modes are resolved to exact and never
        // reported as active.
        let resolvedMode = Self.resolveExecutionMode(options.mode)
        let generation = UUID()
        generationID = generation
        let generationStarted = ContinuousClock.now
        onEvent(.started)

        let thinkingEnabled = options.enableThinking
            && thinkCloseTokenID != nil
        // Privacy-safe prompt accounting (per-role encode, no template text).
        var systemTokens = 0
        var historyTokens = 0
        var userTokens = 0
        for message in messages {
            let count = tokenizer.encode(message["content"] ?? "").count
            switch message["role"] {
            case "system": systemTokens += count
            case "assistant": historyTokens += count
            default: userTokens += count
            }
        }
        var tokenIDs: [Int]
        do {
            tokenIDs = try tokenizer.applyChatTemplate(
                messages: messages,
                templateDirectory: directory,
                additionalContext: ["enable_thinking": thinkingEnabled]
            )
        } catch {
            throw Edge0_35BEngineError.tokenizerUnavailable(
                error.localizedDescription
            )
        }

        let sampler = options.sampler
        if let seed = options.seed {
            MLXRandom.seed(seed)
        }
        let stopTokens = Set([options.eosTokenID] + options.additionalEOSTokenIDs)

        let poolBefore = await pool.statistics()
        let prefillStarted = ContinuousClock.now
        let effectiveMode = resolvedMode.effective
        let windowRequested = Edge0EnginePreferences.edge0_35BStagedEvalWindow
        let capacityWindow = routerTopK > 0
            ? max(1, pool.configuredCapacitySlots / routerTopK) : 1
        let windowEffective = effectiveMode == .staged
            ? max(1, min(windowRequested, capacityWindow)) : 1
        let microbatchRequested =
            Edge0EnginePreferences.edge0_35BMicrobatchGroupSize
        let microbatchEffective: Int = effectiveMode == .staged
            ? max(1, min(microbatchRequested, capacityWindow)) : 1
        let profile = Edge0EnginePreferences.componentProfilingEnabled
            ? Edge0ComponentProfile() : nil
        // Session-state reuse (prompt cache): restore the previous
        // prompt-boundary snapshot when the new prompt is an exact token
        // extension with identical scheduling knobs; otherwise start fresh.
        // A reused turn prefills only the new suffix — the same tokens at
        // the same positions — so numerics are unchanged by construction.
        let reuseEnabled = Edge0EnginePreferences.edge0_35BSessionReuse
        let snapshotKeyMatches = sessionSnapshot.map {
            $0.mode == effectiveMode.rawValue
                && $0.microbatch == microbatchEffective
                && $0.evalWindow == windowEffective
        } ?? false
        let reusedCount = Self.sessionReuseCount(
            enabled: reuseEnabled,
            snapshotTokens: sessionSnapshot?.tokens,
            keyMatches: snapshotKeyMatches,
            promptTokens: tokenIDs
        )
        var state: Edge0_35BModelState
        var prefillTokens = tokenIDs
        var reusedLogits: MLXArray?
        if let reusedCount, let snapshot = sessionSnapshot {
            state = snapshot.state
            if reusedCount == tokenIDs.count {
                // Identical prompt (regeneration): decode straight from the
                // snapshot's prompt-boundary logits — zero prefill.
                prefillTokens = []
                reusedLogits = snapshot.logits
            } else {
                prefillTokens = Array(tokenIDs.dropFirst(reusedCount))
            }
        } else {
            state = model.makeState()
        }
        let reusedTokenCount = reusedCount ?? 0
        let prefillTokenCount = prefillTokens.count
        // Workload identity (diagnostic only): hash the actual router
        // selections so an early and a late run can be compared.
        var routerHash: UInt64 = 0xcbf2_9ce4_8422_2325
        var uniqueExpertTotal = 0
        var moeInvocations = 0
        let identityHook: ((Int, [Int]) -> Void)? = profile == nil
            ? nil
            : { _, ids in
                moeInvocations += 1
                uniqueExpertTotal += Set(ids).count
                for id in ids {
                    routerHash = (routerHash ^ UInt64(bitPattern: Int64(id)))
                        &* 0x0000_0100_0000_01b3
                }
            }
        var logits: MLXArray
        if let reusedLogits {
            logits = reusedLogits
        } else {
            logits = try await model.prefill(
                tokenIDs: prefillTokens, state: &state, mode: effectiveMode,
                profile: profile, onSelectedExperts: identityHook
            ).asType(.float32)
        }
        let prefillSeconds = prefillStarted.duration(to: .now).timeInterval
        // Prompt-cache: keep the prompt-boundary state for the next turn.
        // State updates are functional (arrays are replaced, never mutated
        // in place), so this snapshot stays valid while decode proceeds.
        sessionSnapshot = reuseEnabled
            ? Edge0SessionSnapshot(
                state: state,
                logits: logits,
                tokens: tokenIDs,
                mode: effectiveMode.rawValue,
                microbatch: microbatchEffective,
                evalWindow: windowEffective
            )
            : nil
        var poolAfterPrefill = await pool.statistics()
        // Prefill→decode handoff: staged prefill leaves advisory loads in
        // flight; cancel queued ones so decode acquisitions cannot queue
        // behind prefill-only work. Completed entries stay cached.
        var handoffBefore = 0
        var handoffAdvisory = 0
        if effectiveMode == .staged {
            handoffBefore = poolAfterPrefill.inFlightLoads
            // Per-generation delta: the pool counter itself is a lifetime
            // total (per model load), never a per-request work measure.
            handoffAdvisory = max(
                0,
                poolAfterPrefill.advisoryLoads - poolBefore.advisoryLoads
            )
            await pool.cancelAdvisoryLoads()
            if handoffBefore > 0 {
                poolAfterPrefill = await pool.statistics()
            }
        }
        let handoffAfter = poolAfterPrefill.inFlightLoads
        let prefillState = model.stateSummary(state)
        profile?.begin(.decode)

        // Phase 5J advisory prerouter (default OFF): decode-side only, off
        // the critical path. A missing or unreadable artifact is a
        // fallback, never an error; the true router still decides.
        let advisoryRequested =
            Edge0EnginePreferences.edge0_35BAdvisoryPrerouter
        var advisoryFallbacks = 0
        var advisoryRuntime:
            Edge0PrerouterRuntime<Edge0_35BExpertWeights>?
        var advisoryArtifactPresent = false
        var advisoryArtifactValid = false
        var advisoryFallbackReason = ""
        if advisoryRequested {
            if let override = advisoryPredictorOverride {
                advisoryRuntime = Edge0PrerouterRuntime(
                    predictor: override, pool: pool
                )
                advisoryArtifactValid = true
            } else {
                advisoryArtifactPresent =
                    Edge0_35BPrerouter.isAvailable(in: directory)
                if cachedAdvisoryPrerouter == nil {
                    if advisoryArtifactPresent {
                        do {
                            cachedAdvisoryPrerouter = try await
                                Edge0_35BPrerouter.load(directory: directory)
                        } catch {
                            advisoryFallbackReason =
                                "artifact invalid: \(error)"
                        }
                    } else {
                        advisoryFallbackReason =
                            "artifact not installed (optional predictor)"
                    }
                }
                if let predictor = cachedAdvisoryPrerouter {
                    advisoryArtifactValid = true
                    advisoryRuntime = Edge0PrerouterRuntime(
                        predictor: predictor, pool: pool
                    )
                } else {
                    advisoryFallbacks = 1
                    if advisoryFallbackReason.isEmpty {
                        advisoryFallbackReason = "predictor unavailable"
                    }
                }
            }
        }
        advisoryRuntime?.eventSink = advisoryTraceSink
        activeAdvisoryRuntime = advisoryRuntime
        let advisoryCapture = Edge0PrerouterStepCapture()

        var generated: [Int] = []
        var context = tokenIDs
        var firstTokenAt: ContinuousClock.Instant?
        var firstAnswerTokenAt: ContinuousClock.Instant?
        var stopReason = "max_tokens"
        var eosHit = false
        var decodeCalls = 0

        // The 35B template opens the thinking section IN THE PROMPT when
        // thinking is enabled; synthesize the markers around the decoded
        // stream so the app can separate reasoning from the final answer.
        var channel = Edge0ThinkingChannel(
            promptOpened: thinkingEnabled,
            openTokenID: thinkOpenTokenID,
            closeTokenID: thinkCloseTokenID
        )
        // The channel normalizes the cumulative decoded text into
        // `<think>reasoning</think>answer` regardless of whether the markers
        // arrive as special token ids, literal text, or are already opened by
        // the prompt. Structural markers never render as prose.
        var lastDisplay = ""
        for marker in channel.initialMarkers {
            lastDisplay += marker.text
            onEvent(.token(marker.text))
        }

        func emit(display: String) {
            if display.hasPrefix(lastDisplay) {
                let delta = String(display.dropFirst(lastDisplay.count))
                if !delta.isEmpty { onEvent(.token(delta)) }
            } else if !display.isEmpty {
                onEvent(.token(display))
            }
            lastDisplay = display
        }

        while generated.count < options.maxTokens {
            if Task.isCancelled || generationID != generation {
                advisoryRuntime?.cancel()
                await advisoryRuntime?.waitForQuiescence()
                activeAdvisoryRuntime = nil
                // Only clear if this generation still owns the engine;
                // otherwise a newer generation would lose its identity and
                // become uncancellable.
                _ = clearGeneration(if: generation)
                onEvent(.cancelled)
                return
            }
            let samplingStarted = ContinuousClock.now
            let token = sampler.sample(
                logits: logits,
                previousTokens: Array(context.suffix(sampler.penaltyContextSize))
            )
            profile?.record(
                \.samplingSeconds,
                seconds: samplingStarted.duration(to: .now).timeInterval
            )
            if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
            generated.append(token)
            context.append(token)

            let decoded = tokenizer.decode(
                generated, skipSpecialTokens: true
            )
            channel.consume(
                tokenID: token, decodedCount: decoded.count
            )
            if firstAnswerTokenAt == nil, channel.finalAnswerTokens > 0 {
                firstAnswerTokenAt = ContinuousClock.now
            }
            emit(display: channel.normalize(decoded: decoded))

            if stopTokens.contains(token) {
                eosHit = true
                stopReason = "eos"
                break
            }
            if generated.count >= options.maxTokens { break }

            let stepPosition = state.position
            advisoryCapture.reset()
            let advisoryTap: ((Int, MLXArray, [Int]) -> Void)? =
                advisoryRuntime == nil ? nil : { layer, hidden, ids in
                    advisoryRuntime?.reconcile(
                        targetLayer: layer, token: stepPosition,
                        actualIDs: ids
                    )
                    advisoryCapture.record(
                        layer: layer, hidden: hidden, ids: ids
                    )
                }
            logits = try await model.decode(
                tokenID: token, state: &state, mode: effectiveMode,
                profile: profile, prerouterTap: advisoryTap
            ).asType(.float32)
            if let advisoryRuntime {
                // Predictions for the NEXT decode token are scheduled after
                // this step's logits, off the generation hot path.
                let consumerToken = state.position
                for entry in advisoryCapture.entries {
                    advisoryRuntime.predictAndSchedule(
                        owner: entry.layer, hidden: entry.hidden,
                        thisIDs: entry.ids, token: consumerToken,
                        targetLayerCount: 40, topK: routerTopK,
                        phase: .decode, sourceToken: stepPosition
                    )
                }
            }
            decodeCalls += 1
        }

        // Advisory shutdown: queued speculative work is dropped; in-flight
        // unpinned reads finish and remain cached for the true router.
        advisoryRuntime?.cancel()
        await advisoryRuntime?.waitForQuiescence()
        activeAdvisoryRuntime = nil

        // Close an unfinished thinking section so the UI presents it
        // honestly (no final answer) instead of leaking raw reasoning.
        emit(display: channel.finish(decoded: tokenizer.decode(
            generated, skipSpecialTokens: true
        )))

        let finished = ContinuousClock.now
        let totalSeconds = generationStarted.duration(to: finished).timeInterval
        let ttftSeconds = firstTokenAt.map {
            generationStarted.duration(to: $0).timeInterval
        } ?? totalSeconds
        let answerTtftSeconds = firstAnswerTokenAt.map {
            generationStarted.duration(to: $0).timeInterval
        } ?? 0
        let decodeSeconds = firstTokenAt.map {
            $0.duration(to: finished).timeInterval
        } ?? 0
        let decodeRate = generated.count >= 2 && decodeSeconds > 0
            ? Double(generated.count - 1) / decodeSeconds
            : 0
        let poolAfterDecode = await pool.statistics()
        let finalState = model.stateSummary(state)

        lastGenerationMetrics = Edge0_35BGenerationMetrics(
            promptTokens: tokenIDs.count,
            generatedTokens: generated.count,
            prefillSeconds: prefillSeconds,
            timeToFirstTokenSeconds: ttftSeconds,
            decodeSeconds: decodeSeconds,
            decodeTokensPerSecond: decodeRate,
            totalSeconds: totalSeconds,
            prefillPool: .delta(poolAfterPrefill, poolBefore),
            decodePool: .delta(poolAfterDecode, poolAfterPrefill),
            requestedMode: resolvedMode.requested,
            effectiveMode: effectiveMode.rawValue,
            stopReason: stopReason,
            finalPosition: state.position,
            eosHit: eosHit,
            thinkingEnabled: thinkingEnabled,
            reasoningTokens: channel.reasoningTokens,
            finalAnswerTokens: channel.finalAnswerTokens,
            timeToFirstAnswerTokenSeconds: answerTtftSeconds,
            endedWhileThinking: channel.endedWhileThinking,
            decodeCalls: decodeCalls,
            controlTokens: eosHit ? 1 : 0,
            endToEndTokensPerSecond: Double(generated.count)
                / max(totalSeconds, 1e-6),
            promptSystemTokens: systemTokens,
            promptHistoryTokens: historyTokens,
            promptUserTokens: userTokens,
            promptTemplateOverheadTokens: max(
                0, tokenIDs.count - systemTokens - historyTokens - userTokens
            ),
            modeFallback: resolvedMode.fallback ?? "",
            profile: profile?.current ?? Edge0ComponentProfile.Snapshot(),
            positionAfterPrefill: prefillState.position,
            kvTokensAfterPrefill: prefillState.kvTokens,
            kvTokensFinal: finalState.kvTokens,
            linearStateBytes: finalState.linearStateBytes,
            layerInvocations: 40 * (
                prefillTokenCount + decodeCalls
            ),
            expertLoads: max(0, poolAfterDecode.loads - poolBefore.loads),
            activeOutputConsumers: 0,
            routerHash: routerHash,
            uniqueExpertTotal: uniqueExpertTotal,
            moeInvocations: moeInvocations,
            mlxActiveBytes: Memory.activeMemory,
            mlxCacheBytes: Memory.cacheMemory,
            mlxPeakBytes: Memory.peakMemory,
            prefillMode: effectiveMode == .staged && microbatchEffective > 1
                ? "staged·microbatch\(microbatchEffective)"
                : Self.modeLabels(effectiveMode).prefill,
            decodeMode: Self.modeLabels(effectiveMode).decode,
            evalWindowRequested: windowRequested,
            evalWindowEffective: windowEffective,
            microbatchRequested: microbatchRequested,
            microbatchEffective: microbatchEffective,
            routedGroups: microbatchEffective > 1
                ? 40 * ((tokenIDs.count + microbatchEffective - 1)
                    / microbatchEffective)
                : tokenIDs.count * 40,
            handoffInFlightBefore: handoffBefore,
            handoffInFlightAfter: handoffAfter,
            handoffAdvisoryLoads: handoffAdvisory,
            advisoryLoadsLifetime: poolAfterDecode.advisoryLoads,
            advisoryRequested: advisoryRequested,
            advisoryActive: advisoryRuntime != nil,
            advisoryFallbacks: advisoryFallbacks,
            advisory: advisoryRuntime?.metrics.current
                ?? Edge0PrerouterMetrics.Snapshot(),
            advisoryArtifactPresent: advisoryArtifactPresent,
            advisoryArtifactValid: advisoryArtifactValid,
            advisoryHeadCount: cachedAdvisoryPrerouter?.headCount ?? 0,
            advisoryLoadedBytes:
                cachedAdvisoryPrerouter?.loadedPayloadBytes ?? 0,
            advisoryFallbackReason: advisoryFallbackReason,
            routerReadbackRequested:
                Edge0EnginePreferences.edge0_35BRouterReadbackMode,
            routerReadbackEffective:
                effectiveMode == .staged && microbatchEffective > 1
                    ? Edge0EnginePreferences.edge0_35BRouterReadbackMode : 0,
            readaheadRequested:
                Edge0EnginePreferences.edge0_35BReadaheadHints,
            readaheadEffective: readaheadHintsEnabled,
            sessionReuseApplied: reusedTokenCount > 0,
            sessionReusedTokens: reusedTokenCount,
            sessionPrefillTokens: prefillTokenCount
        )
        // Atomic compare-and-clear: a cancel() that already handed ownership
        // to a newer generation must not have it stolen by this completion.
        _ = clearGeneration(if: generation)
        onEvent(.completed(
            generatedTokens: generated.count,
            tokensPerSecond: Double(generated.count) / max(totalSeconds, 1e-6)
        ))
    }

    /// Requested vs effective execution mode for the 35B family. Supported:
    /// exact (reference), boundedPrefetch (production default), and staged
    /// (experimental: staged prefill with bounded decode). `.stagedPrerouter`
    /// resolves to `.staged` and reports the fallback; prerouter prediction
    /// is not implemented for this family.
    static func resolveExecutionMode(
        _ requested: Edge0ExecutionMode
    ) -> (requested: String, effective: Edge0ExecutionMode, fallback: String?) {
        switch requested {
        case .exact:
            return (requested.rawValue, .exact, nil)
        case .boundedPrefetch:
            return (requested.rawValue, .boundedPrefetch, nil)
        case .staged:
            return (requested.rawValue, .staged, nil)
        case .stagedPrerouter:
            return (requested.rawValue, .staged, "stagedPrerouter→staged")
        }
    }

    /// Effective prefill/decode labels for diagnostics: staged runs staged
    /// prefill with the validated bounded decode path.
    static func modeLabels(
        _ effective: Edge0ExecutionMode
    ) -> (prefill: String, decode: String) {
        switch effective {
        case .staged:
            return ("staged", "boundedPrefetch")
        default:
            return (effective.rawValue, effective.rawValue)
        }
    }

    // MARK: Exact reference probe

    /// Executes the frozen nine-token greedy reference through the loaded
    /// production model/state/pool. Developer diagnostics only.
    func runExactReferenceProbe() async throws -> RuntimeParityProbe {
        try await runReferenceParity(mode: .exact)
    }

    /// Same frozen reference under a chosen execution mode (exact vs
    /// boundedPrefetch parity for the 35B family).
    func runReferenceParity(
        mode: Edge0ExecutionMode
    ) async throws -> RuntimeParityProbe {
        guard let model, let pool else {
            throw Edge0_35BEngineError.notLoaded
        }
        let generation = UUID()
        generationID = generation
        // Compare-and-clear so a probe that was cancelled after a newer
        // generation took ownership cannot steal it.
        defer { _ = clearGeneration(if: generation) }

        let prompt = Self.exactReferencePromptIDs
        let expected = Self.exactReferenceEmittedIDs
        let stopTokens = Set(eosTokenIDs)

        var state = model.makeState()
        var logits = try await model.prefill(
            tokenIDs: prompt, state: &state, mode: mode
        ).asType(.float32)

        var emitted: [Int] = []
        var eosHit = false
        // One prefill-selected token plus eight decode calls.
        for step in 0..<expected.count {
            if Task.isCancelled || generationID != generation {
                break
            }
            let token = MLX.argMax(logits, axis: -1).item(Int.self)
            emitted.append(token)
            if stopTokens.contains(token) {
                eosHit = true
                break
            }
            if step == expected.count - 1 { break }
            logits = try await model.decode(
                tokenID: token, state: &state, mode: mode
            ).asType(.float32)
        }
        _ = await pool.statistics()

        var firstDifference: Int?
        for (index, value) in emitted.enumerated()
        where index < expected.count && value != expected[index] {
            firstDifference = index
            break
        }
        if firstDifference == nil, emitted.count != expected.count {
            firstDifference = min(emitted.count, expected.count)
        }
        return RuntimeParityProbe(
            family: family.rawValue,
            promptTokenIDs: prompt,
            expectedTokenIDs: expected,
            emittedTokenIDs: emitted,
            passed: emitted == expected,
            firstDifferingIndex: firstDifference,
            stopReason: "max_decode_steps_reached",
            eosHit: eosHit,
            finalPosition: state.position
        )
    }

    // MARK: Helpers

    // MARK: Session-reuse parity probe

    /// Session-reuse exactness probe. Drives the REAL `generate` path:
    /// turn 1 establishes the prompt-boundary snapshot, turn 2 extends the
    /// same conversation (reuse must apply), then the identical turn-2
    /// conversation is regenerated from a cleared snapshot (full prefill).
    /// The two answers must be byte-identical, and reuse must have applied
    /// on turn 2 — a probe that silently fell back would prove nothing.
    func runSessionReuseProbe() async throws -> Edge0SessionReuseProbeResult {
        let previousReuse = Edge0EnginePreferences.edge0_35BSessionReuse
        Edge0EnginePreferences.edge0_35BSessionReuse = true
        defer {
            Edge0EnginePreferences.edge0_35BSessionReuse = previousReuse
            sessionSnapshot = nil
        }
        let turnOne: [[String: String]] = [
            ["role": "system", "content": "You are a concise assistant."],
            ["role": "user", "content": "Name the three primary colors."],
        ]
        let turnTwoUser = "Now name three secondary colors."
        var options = Edge0EngineOptions()
        options.maxTokens = 24
        if let first = eosTokenIDs.first { options.eosTokenID = first }
        options.additionalEOSTokenIDs = Array(eosTokenIDs.dropFirst())

        // Turn 1: fresh state; establishes the snapshot.
        sessionSnapshot = nil
        let first = try await probeText(messages: turnOne, options: options)

        // Turn 2: the same conversation extended — reuse must apply.
        var turnTwo = turnOne
        turnTwo.append(["role": "assistant", "content": first.text])
        turnTwo.append(["role": "user", "content": turnTwoUser])
        let reused = try await probeText(messages: turnTwo, options: options)

        // Turn 2 again, from a cleared snapshot (full prefill).
        sessionSnapshot = nil
        let fresh = try await probeText(messages: turnTwo, options: options)

        var result = Edge0SessionReuseProbeResult()
        result.reuseAppliedOnTurn2 =
            reused.metrics?.sessionReuseApplied ?? false
        result.reusedTokens = reused.metrics?.sessionReusedTokens ?? 0
        result.prefilledTokens = reused.metrics?.sessionPrefillTokens ?? 0
        result.emittedTokens = reused.metrics?.generatedTokens ?? 0
        result.turn2PromptTokens = reused.metrics?.promptTokens ?? 0
        if reused.text == fresh.text {
            result.passed = result.reuseAppliedOnTurn2
        } else {
            let a = Array(reused.text)
            let b = Array(fresh.text)
            result.firstDifferingIndex = (0..<max(a.count, b.count)).first {
                $0 >= a.count || $0 >= b.count || a[$0] != b[$0]
            }
        }
        return result
    }

    private final class ProbeTextCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            text += chunk
        }
        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }

    private func probeText(
        messages: [[String: String]],
        options: Edge0EngineOptions
    ) async throws -> (text: String, metrics: Edge0_35BGenerationMetrics?) {
        let collector = ProbeTextCollector()
        try await generate(messages: messages, options: options) { event in
            if case .token(let chunk) = event {
                collector.append(chunk)
            }
        }
        return (collector.value, generationMetrics())
    }


    /// Family stop metadata comes from the checkpoint's generation config,
    /// never from the 8B EOS ids.
    static func readEOSTokenIDs(at url: URL) -> [Int] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let value = root["eos_token_id"] else {
            return [248_046, 248_044]
        }
        if let single = value as? Int { return [single] }
        if let list = value as? [Int], !list.isEmpty { return list }
        return [248_046, 248_044]
    }

}

// MARK: - RuntimeParityProbing

extension Edge0_35BEngine: RuntimeParityProbing {
    func runParityProbe() async throws -> RuntimeParityProbe {
        try await runExactReferenceProbe()
    }
}

private extension Duration {
    var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}


// MARK: - Edge0PrerouterStepCapture
//
// Per-step capture for the advisory tap. The tap closure is escaping
// (optional closures are), so it writes into this box; it is reset each
// step and only ever touched when advisory prediction is active.
private final class Edge0PrerouterStepCapture: @unchecked Sendable {
    struct Entry {
        let layer: Int
        let hidden: MLXArray
        let ids: [Int]
    }

    private let lock = NSLock()
    private var storage: [Int: Entry] = [:]

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }

    func record(layer: Int, hidden: MLXArray, ids: [Int]) {
        lock.lock(); defer { lock.unlock() }
        storage[layer] = Entry(layer: layer, hidden: hidden, ids: ids)
    }

    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.values)
    }
}
