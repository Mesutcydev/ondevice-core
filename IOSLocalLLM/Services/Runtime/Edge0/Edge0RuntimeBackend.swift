import Foundation
import MLX

// MARK: - Edge0RuntimeBackend
//
// App-layer adapter from `RuntimeEngineBackend` to the proven native Edge0
// families. Admission and lifecycle policy stay in the existing app services
// (DeviceSafetyMonitor, MemoryAdvisor via the family budget,
// MLXGenerationGate); each engine owns model weights, expert pool, tokenizer,
// generation state and cancellation. `ManagedRuntimeEngine` remains the
// generic lifecycle wrapper.
//
// Family resolution is by curated repo identity (`Edge0ModelFamily.resolve`),
// never by architecture string. The 8B path is unchanged; the 35B path runs
// exact true-router + Recover-LoRA + bounded per-token expert loading only.

@MainActor
final class Edge0RuntimeBackend: RuntimeEngineBackend, RuntimeParityProbing {
    private(set) var engine8B: Edge0Engine?
    private(set) var engine35B: Edge0_35BEngine?
    private(set) var loadedFamily: Edge0ModelFamily?
    private var generationTask: Task<Void, Never>?

    // MARK: - Directory resolution

    /// Resolves the installed model directory for a descriptor. A candidate
    /// is accepted only when it passes the family artifact validation
    /// (architecture identity, tokenizer, quantized geometry), never by
    /// filename alone.
    static func resolveModelDirectory(for model: LocalModel) throws -> URL {
        guard let family = Edge0ModelFamily.resolve(repoID: model.repoID) else {
            throw RuntimeError.invalidModelFiles(
                "'\(model.repoID)' is not a curated Edge0 native release."
            )
        }
        return try resolveModelDirectory(for: model, family: family)
    }

    static func resolveModelDirectory(
        for model: LocalModel,
        family: Edge0ModelFamily
    ) throws -> URL {
        let docs = ModelStoragePaths.documents
        let tail = ModelStoragePaths.directoryName(forRepoID: model.repoID)
        let flattened = ModelStoragePaths.flattenedRepoID(model.repoID)
        let candidates = [
            ModelStoragePaths.llmModelDirectory(named: tail),
            ModelStoragePaths.llmModelDirectory(named: flattened),
            docs.appendingPathComponent("Edge0Models").appendingPathComponent(tail),
            docs.appendingPathComponent("Edge0Models").appendingPathComponent(flattened),
            docs.appendingPathComponent("HFModels").appendingPathComponent(flattened),
            docs.appendingPathComponent("HFModels").appendingPathComponent(model.repoID),
            docs.appendingPathComponent("HFModels").appendingPathComponent(tail),
        ]
        var lastError: Error = Edge0ModelArtifactError.missingFile("model.safetensors")
        for directory in candidates {
            do {
                switch family {
                case .bailing8B:
                    try Edge0ModelArtifacts.validate(directory: directory)
                case .qwen35MoE:
                    _ = try Edge0_35BModelArtifacts.validateInstall(
                        directory: directory
                    )
                }
                return directory
            } catch {
                lastError = error
            }
        }
        throw RuntimeError.invalidModelFiles(
            "No complete \(family.displayName) checkpoint found. \(lastError.localizedDescription)"
        )
    }

    // MARK: - RuntimeEngineBackend

    func load(model: LocalModel) async throws {
        guard let family = Edge0ModelFamily.resolve(repoID: model.repoID) else {
            throw RuntimeError.invalidModelFiles(
                "'\(model.repoID)' is not a curated Edge0 native release."
            )
        }
        if let reason = DeviceSafetyMonitor.shared.stopReason {
            throw RuntimeError.modelLoadBlocked(reason: reason.detail)
        }
        switch family {
        case .bailing8B:
            try await load8B(model)
        case .qwen35MoE:
            try await load35B(model)
        }
    }

    private func load8B(_ model: LocalModel) async throws {
        let budget = Edge0MemoryBudget.current()
        guard budget.isPoolEnabled else {
            throw RuntimeError.insufficientMemory(
                requiredBytes: Int64(budget.residentCommonBytes),
                availableBytes: MemoryAdvisor.availableMemoryForModel
            )
        }
        let directory = try Self.resolveModelDirectory(
            for: model, family: .bailing8B
        )
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        // Phase 4B-4 experiment: an explicit pool tier may only shrink the
        // admission-approved allowance, never overcommit it.
        var poolBytes = budget.expertPoolBytes
        var poolSlots = max(8, budget.expertPoolSlots)
        if let override = Edge0EnginePreferences.poolCapacityBytesOverride {
            let clamped = min(override, budget.expertPoolBytes)
            let slots = Int(clamped / Edge0MemoryBudget.expertBundleBytes)
            if slots >= 8 {
                poolBytes = clamped
                poolSlots = slots
            }
        }
        let engine = Edge0Engine()
        try await engine.load(configuration: .init(
            modelDirectory: directory,
            expertPoolSlots: poolSlots,
            expertPoolBytes: poolBytes,
            maxConcurrentReads: Edge0EnginePreferences.expertLoadConcurrency
        ))
        engine8B = engine
        loadedFamily = .bailing8B
        Diagnostics.shared.breadcrumb(
            "Edge0 runtime ready · \(model.repoID) · poolSlots=\(budget.expertPoolSlots) · poolBytes=\(budget.expertPoolBytes) · resident=\(budget.residentCommonBytes)",
            category: "assistant"
        )
    }

    private func load35B(_ model: LocalModel) async throws {
        let budget = Edge0_35BMemoryBudget.current()
        guard budget.isPoolEnabled else {
            throw RuntimeError.insufficientMemory(
                requiredBytes: Int64(
                    budget.residentBytes
                        + Edge0_35BMemoryBudget.expertBundleBytes
                        * UInt64(Edge0_35BMemoryBudget.minimumPoolSlots)
                ),
                availableBytes: MemoryAdvisor.availableMemoryForModel
            )
        }
        let directory = try Self.resolveModelDirectory(
            for: model, family: .qwen35MoE
        )
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        // Pool overrides may only shrink the admission-approved allowance.
        var poolBytes = budget.expertPoolBytes
        var poolSlots = budget.expertPoolSlots
        if let override = Edge0EnginePreferences.poolCapacityBytesOverride {
            let clamped = min(override, budget.expertPoolBytes)
            let slots = Int(clamped / Edge0_35BMemoryBudget.expertBundleBytes)
            if slots >= Edge0_35BMemoryBudget.minimumPoolSlots {
                poolBytes = clamped
                poolSlots = slots
            }
        }
        // Read concurrency is the same developer knob the 8B honors. It was
        // previously hardcoded to 4 here, so the Diagnostics "reads" picker
        // (and any 2/4/6 experiment) never reached this family.
        let readConcurrency = Edge0EnginePreferences.expertLoadConcurrency
        let engine = Edge0_35BEngine()
        try await engine.load(configuration: .init(
            modelDirectory: directory,
            expertPoolSlots: poolSlots,
            expertPoolBytes: poolBytes,
            maxConcurrentReads: readConcurrency
        ))
        engine35B = engine
        loadedFamily = .qwen35MoE
        Diagnostics.shared.breadcrumb(
            "Edge0-35B runtime ready · \(model.repoID) · exact mode · router K=\(engine.routerTopK)"
                + " · loraModules=\(engine.loraModuleCount)"
                + " · poolSlots=\(budget.expertPoolSlots) · poolBytes=\(budget.expertPoolBytes)"
                + " · resident=\(budget.residentBytes)"
                + " · reads=\(readConcurrency)"
                + " · readahead=\(Edge0EnginePreferences.edge0_35BReadaheadHints)",
            category: "assistant"
        )
    }

    func unload() async {
        generationTask?.cancel()
        generationTask = nil
        if let engine8B {
            await engine8B.unload()
        }
        if let engine35B {
            await engine35B.unload()
        }
        engine8B = nil
        engine35B = nil
        loadedFamily = nil
    }

    /// Developer parity probe (35B frozen reference). nil for families
    /// without a frozen probe contract.
    func runParityProbe() async throws -> RuntimeParityProbe {
        guard let family = loadedFamily else {
            throw RuntimeError.noActiveModel
        }
        switch family {
        case .qwen35MoE:
            guard let engine35B else { throw RuntimeError.noActiveModel }
            return try await engine35B.runExactReferenceProbe()
        case .bailing8B:
            throw RuntimeError.unsupportedOperation(
                "No frozen parity probe for the 8B family."
            )
        }
    }

    /// Developer session-reuse parity probe (35B prompt cache). nil for
    /// families without session-state reuse.
    func runSessionReuseProbe() async throws -> Edge0SessionReuseProbeResult? {
        guard let family = loadedFamily else {
            throw RuntimeError.noActiveModel
        }
        switch family {
        case .qwen35MoE:
            guard let engine35B else { throw RuntimeError.noActiveModel }
            return try await engine35B.runSessionReuseProbe()
        case .bailing8B:
            return nil
        }
    }

    /// Family-aware diagnostic counters. Counters only — never prompt or
    /// generated text.
    func runtimeMetrics() async -> [String: String]? {
        switch loadedFamily {
        case .bailing8B:
            return await metrics8B()
        case .qwen35MoE:
            return await metrics35B()
        case nil:
            return nil
        }
    }

    /// Single source of truth for profile metric keys. Both families use it
    /// so a key can never be wired into only one of them.
    private static func profileKeys(
        phase: String, components: Edge0ComponentProfile.Components
    ) -> [String: String] {
        func value(_ number: Double) -> String {
            String(format: "%.4f", number)
        }
        return [
            "profile.\(phase).kdaSeconds": value(components.kdaSeconds),
            "profile.\(phase).mlaSeconds": value(components.mlaSeconds),
            "profile.\(phase).moeSeconds": value(components.moeSeconds),
            "profile.\(phase).routerSeconds": value(components.routerSeconds),
            "profile.\(phase).embeddingSeconds": value(components.embeddingSeconds),
            "profile.\(phase).lmHeadSeconds": value(components.lmHeadSeconds),
            "profile.\(phase).samplingSeconds": value(components.samplingSeconds),
            "profile.\(phase).moeAcquireSeconds": value(components.moeAcquireSeconds),
            "profile.\(phase).moeStackBuildSeconds": value(components.moeStackBuildSeconds),
            "profile.\(phase).moeRoutedSeconds": value(components.moeRoutedSeconds),
            "profile.\(phase).moeSharedSeconds": value(components.moeSharedSeconds),
            "profile.\(phase).moeCombineSeconds": value(components.moeCombineSeconds),
            "profile.\(phase).moeEvalSeconds": value(components.moeEvalSeconds),
            "profile.\(phase).moeReleaseSeconds": value(components.moeReleaseSeconds),
            "profile.\(phase).moeEarlySeconds": value(components.moeEarlySeconds),
            "profile.\(phase).moeMiddleSeconds": value(components.moeMiddleSeconds),
            "profile.\(phase).moeLateSeconds": value(components.moeLateSeconds),
            "profile.\(phase).acquire.samples": value(components.moeAcquireSamples),
            "profile.\(phase).stack.samples": value(components.moeStackBuildSamples),
            "profile.\(phase).routed.samples": value(components.moeRoutedSamples),
            "profile.\(phase).shared.samples": value(components.moeSharedSamples),
            "profile.\(phase).combine.samples": value(components.moeCombineSamples),
            "profile.\(phase).eval.samples": value(components.moeEvalSamples),
            "profile.\(phase).release.samples": value(components.moeReleaseSamples),
        ]
    }

    private func metrics8B() async -> [String: String]? {
        guard let engine = engine8B else { return nil }
        var metrics: [String: String] = [:]
        metrics["family"] = Edge0ModelFamily.bailing8B.rawValue

        if let pool = await engine.expertPoolStatistics() {
            metrics["pool.capacitySlots"] = "\(pool.capacitySlots)"
            metrics["pool.capacityBytes"] = "\(pool.capacityBytes)"
            metrics["pool.hits"] = "\(pool.hits)"
            metrics["pool.misses"] = "\(pool.misses)"
            metrics["pool.loads"] = "\(pool.loads)"
            metrics["pool.evictions"] = "\(pool.evictions)"
            metrics["pool.coalescedLoads"] = "\(pool.coalescedLoads)"
            metrics["pool.bytesLoaded"] = "\(pool.bytesLoaded)"
            metrics["pool.occupancySlots"] = "\(pool.occupancySlots)"
            metrics["pool.occupancyBytes"] = "\(pool.occupancyBytes)"
            metrics["pool.peakOccupancySlots"] = "\(pool.peakOccupancySlots)"
            metrics["pool.peakOccupancyBytes"] = "\(pool.peakOccupancyBytes)"
            metrics["pool.pinnedSlots"] = "\(pool.pinnedSlots)"
            metrics["pool.activeLeases"] = "\(pool.activeLeases)"
            metrics["pool.readLatencyAvgMs"] = String(
                format: "%.2f", pool.readLatencySecondsAvg * 1_000
            )
            metrics["pool.readLatencyP95Ms"] = String(
                format: "%.2f", pool.readLatencySecondsP95 * 1_000
            )
        }

        if let generation = engine.generationMetrics() {
            for (phase, phasePool) in [
                ("prefill", generation.prefillPool),
                ("decode", generation.decodePool),
            ] {
                metrics["\(phase).pool.hits"] = "\(phasePool.hits)"
                metrics["\(phase).pool.misses"] = "\(phasePool.misses)"
                metrics["\(phase).pool.loads"] = "\(phasePool.loads)"
                metrics["\(phase).pool.evictions"] = "\(phasePool.evictions)"
                metrics["\(phase).pool.bytesLoaded"] = "\(phasePool.bytesLoaded)"
                metrics["\(phase).pool.readSeconds"] = String(
                    format: "%.4f", phasePool.readSeconds
                )
                metrics["\(phase).pool.aggregateAcquireWaitSeconds"] = String(
                    format: "%.4f", phasePool.aggregateAcquireWaitSeconds
                )
                metrics["\(phase).pool.hitRate"] = String(
                    format: "%.4f", phasePool.hitRate
                )
                metrics["\(phase).pool.occupancySlots"] = "\(phasePool.occupancySlots)"
                metrics["\(phase).pool.occupancyBytes"] = "\(phasePool.occupancyBytes)"
            }
            metrics["prefill.bytesPerPromptToken"] = "\(generation.prefillBytesPerPromptToken)"
            metrics["decode.bytesPerGeneratedToken"] = "\(generation.decodeBytesPerGeneratedToken)"
            let staging = generation.staging
            metrics["staging.banksScheduled"] = "\(staging.banksScheduled)"
            metrics["staging.banksCompleted"] = "\(staging.banksCompleted)"
            metrics["staging.bankSwitches"] = "\(staging.bankSwitches)"
            metrics["staging.readyBeforeUse"] = "\(staging.readyBeforeUse)"
            metrics["staging.lateAtUse"] = "\(staging.lateAtUse)"
            metrics["staging.readyBeforeUseRate"] = String(
                format: "%.4f", staging.readyBeforeUseRate
            )
            metrics["staging.criticalStageWaitSeconds"] = String(
                format: "%.4f", staging.criticalStageWaitSeconds
            )
            metrics["staging.cancellations"] = "\(staging.cancellations)"
            metrics["staging.staleBanksDiscarded"] = "\(staging.staleBanksDiscarded)"
            metrics["staging.loadsCompleted"] = "\(generation.prefillPool.loads + generation.decodePool.loads)"
            metrics["staging.bytes"] = "\(generation.prefillPool.bytesLoaded + generation.decodePool.bytesLoaded)"
            let prerouter = generation.prerouter
            metrics["prerouter.predictions"] = "\(prerouter.predictions)"
            metrics["prerouter.predictedExperts"] = "\(prerouter.predictedExperts)"
            metrics["prerouter.correctPredictions"] = "\(prerouter.correctPredictions)"
            metrics["prerouter.trueExperts"] = "\(prerouter.trueExperts)"
            metrics["prerouter.precision"] = String(format: "%.4f", prerouter.precision)
            metrics["prerouter.recall"] = String(format: "%.4f", prerouter.recall)
            metrics["prerouter.prefetchRequests"] = "\(prerouter.prefetchRequests)"
            metrics["prerouter.prefetchAlreadyResident"] = "\(prerouter.prefetchAlreadyResident)"
            metrics["prerouter.prefetchLoadsStarted"] = "\(prerouter.prefetchLoadsStarted)"
            metrics["prerouter.prefetchLoadsCompleted"] = "\(prerouter.prefetchLoadsCompleted)"
            metrics["prerouter.prefetchBytes"] = "\(prerouter.prefetchBytes)"
            metrics["prerouter.unusedPredictedExperts"] = "\(prerouter.unusedPredictedExperts)"
            metrics["prerouter.unusedPrefetchedBytes"] = "\(prerouter.unusedPrefetchedBytes)"
            metrics["prerouter.actualMissesAvoided"] = "\(prerouter.actualMissesAvoided)"
            metrics["prerouter.readyFromPrediction"] = "\(prerouter.readyFromPrediction)"
            metrics["prerouter.lateDespitePrediction"] = "\(prerouter.lateDespitePrediction)"
            metrics["prerouter.fallbacks"] = "\(prerouter.fallbacks)"
            for (layer, layerMetrics) in prerouter.perLayer.sorted(by: { $0.key < $1.key }) {
                let precision = layerMetrics.predicted > 0
                    ? Double(layerMetrics.correct) / Double(layerMetrics.predicted) : 0
                let recall = layerMetrics.actual > 0
                    ? Double(layerMetrics.correct) / Double(layerMetrics.actual) : 0
                metrics["prerouter.layer.\(layer).precision"] = String(format: "%.4f", precision)
                metrics["prerouter.layer.\(layer).recall"] = String(format: "%.4f", recall)
                metrics["prerouter.layer.\(layer).missesAvoided"] = "\(layerMetrics.missesAvoided)"
                metrics["prerouter.layer.\(layer).unused"] = "\(layerMetrics.unused)"
            }
            metrics["runtime.readConcurrency"] = "\(Edge0EnginePreferences.expertLoadConcurrency)"
            let profile = generation.profile
            for (phase, components) in [
                ("prefill", profile.prefill),
                ("decode", profile.decode),
            ] {
                for (key, value) in Self.profileKeys(
                    phase: phase, components: components
                ) {
                    metrics[key] = value
                }
            }
            metrics["prefill.loadsPerPromptToken"] = String(
                format: "%.4f", generation.prefillPool.loadsPerToken(generation.promptTokens)
            )
            metrics["decode.loadsPerGeneratedToken"] = String(
                format: "%.4f", generation.decodePool.loadsPerToken(generation.generatedTokens)
            )
            metrics["generation.promptTokens"] = "\(generation.promptTokens)"
            metrics["generation.generatedTokens"] = "\(generation.generatedTokens)"
            metrics["generation.prefillSeconds"] = String(
                format: "%.4f", generation.prefillSeconds
            )
            metrics["generation.ttftSeconds"] = String(
                format: "%.4f", generation.timeToFirstTokenSeconds
            )
            metrics["generation.decodeSeconds"] = String(
                format: "%.4f", generation.decodeSeconds
            )
            metrics["generation.decodeTokensPerSecond"] = String(
                format: "%.2f", generation.decodeTokensPerSecond
            )
            metrics["generation.totalSeconds"] = String(
                format: "%.4f", generation.totalSeconds
            )
            metrics["generation.thinkingEnabled"] = "\(generation.thinkingEnabled)"
            metrics["generation.reasoningTokens"] = "\(generation.reasoningTokens)"
            metrics["generation.finalAnswerTokens"] = "\(generation.finalAnswerTokens)"
            metrics["generation.endedWhileThinking"] = "\(generation.endedWhileThinking)"
            metrics["generation.endToEndTokensPerSecond"] = String(
                format: "%.2f",
                Double(generation.generatedTokens)
                    / max(generation.totalSeconds, 1e-6)
            )
        }

        return metrics.isEmpty ? nil : metrics
    }

    private func metrics35B() async -> [String: String]? {
        guard let engine = engine35B else { return nil }
        var metrics: [String: String] = [:]
        metrics["family"] = Edge0ModelFamily.qwen35MoE.rawValue
        metrics["router.k"] = "\(engine.routerTopK)"
        metrics["lora.modules"] = "\(engine.loraModuleCount)"
        metrics["eos.ids"] = engine.eosTokenIDs.map(String.init).joined(separator: ",")
        metrics["runtime.readConcurrency"] = "\(engine.configuredReadConcurrency)"
        // Phase 5M: the load-captured readahead state, available as soon as
        // the engine is loaded (before any generation ran). The requested
        // half is only meaningful per generation and is exported there.
        metrics["mode.readaheadEffective"] = engine.readaheadHintsEnabled
            ? "true" : "false"
        if let reads = engine.readStatistics() {
            metrics["reads.configured"] = "\(reads.configuredMaxConcurrentReads)"
            metrics["reads.peak"] = "\(reads.peakConcurrentReads)"
            metrics["reads.activeAtCompletion"] = "\(reads.activeReadsAtSnapshot)"
            metrics["reads.total"] = "\(reads.totalReads)"
        } else {
            metrics["reads.configured"] = "unavailable"
            metrics["reads.peak"] = "unavailable"
            metrics["reads.activeAtCompletion"] = "unavailable"
        }
        if let generation = engine.generationMetrics() {
            // Authoritative snapshot: the requested/effective pair that the
            // engine actually executed, not a live preference read.
            metrics["mode.requested"] = generation.requestedMode
            metrics["mode.effective"] = generation.effectiveMode
            if !generation.modeFallback.isEmpty {
                metrics["mode.fallback"] = generation.modeFallback
            }
            metrics["session.reuseApplied"] =
                generation.sessionReuseApplied ? "true" : "false"
            metrics["session.reusedTokens"] = "\(generation.sessionReusedTokens)"
            metrics["session.prefillTokens"] = "\(generation.sessionPrefillTokens)"
        } else {
            metrics["mode.requested"] = Edge0EnginePreferences.edge0_35BExecutionMode.rawValue
            metrics["mode.effective"] = Edge0ExecutionMode.exact.rawValue
        }
        if let summary = engine.installSummary {
            metrics["install.shards"] = "\(summary.shardCount)"
            metrics["install.residentTensors"] = "\(summary.residentTensorCount)"
            metrics["install.expertTensors"] = "\(summary.expertTensorCount)"
            metrics["install.residentBytes"] = "\(summary.residentPayloadBytes)"
            metrics["install.expertBytes"] = "\(summary.expertPayloadBytes)"
            metrics["install.loraTensors"] = "\(summary.loraTensorCount)"
            metrics["install.loraBytes"] = "\(summary.loraPayloadBytes)"
            metrics["install.prerouterPresent"] = "\(summary.prerouterPresent)"
        }

        if let pool = await engine.expertPoolStatistics() {
            metrics["pool.capacitySlots"] = "\(pool.capacitySlots)"
            metrics["pool.capacityBytes"] = "\(pool.capacityBytes)"
            metrics["pool.hits"] = "\(pool.hits)"
            metrics["pool.misses"] = "\(pool.misses)"
            metrics["pool.loads"] = "\(pool.loads)"
            metrics["pool.evictions"] = "\(pool.evictions)"
            metrics["pool.coalescedLoads"] = "\(pool.coalescedLoads)"
            metrics["pool.bytesLoaded"] = "\(pool.bytesLoaded)"
            metrics["pool.occupancySlots"] = "\(pool.occupancySlots)"
            metrics["pool.occupancyBytes"] = "\(pool.occupancyBytes)"
            metrics["pool.peakOccupancySlots"] = "\(pool.peakOccupancySlots)"
            metrics["pool.peakOccupancyBytes"] = "\(pool.peakOccupancyBytes)"
            metrics["pool.pinnedSlots"] = "\(pool.pinnedSlots)"
            metrics["pool.activeLeases"] = "\(pool.activeLeases)"
            metrics["pool.statisticsCalls"] = "\(pool.statisticsCalls)"
            metrics["pool.readLatencyWindowSamples"] = "\(pool.readLatencyWindowSamples)"
            metrics["pool.readLatencyTotalSamples"] = "\(pool.readLatencyTotalSamples)"
            metrics["pool.peakActiveLeases"] = "\(pool.peakActiveLeases)"
            metrics["pool.advisoryLoads"] = "\(pool.advisoryLoads)"
            metrics["pool.readLatencyAvgMs"] = String(
                format: "%.2f", pool.readLatencySecondsAvg * 1_000
            )
            metrics["pool.readLatencyP95Ms"] = String(
                format: "%.2f", pool.readLatencySecondsP95 * 1_000
            )
        }

        if let generation = engine.generationMetrics() {
            for (phase, phasePool) in [
                ("prefill", generation.prefillPool),
                ("decode", generation.decodePool),
            ] {
                metrics["\(phase).pool.hits"] = "\(phasePool.hits)"
                metrics["\(phase).pool.misses"] = "\(phasePool.misses)"
                metrics["\(phase).pool.loads"] = "\(phasePool.loads)"
                metrics["\(phase).pool.evictions"] = "\(phasePool.evictions)"
                metrics["\(phase).pool.bytesLoaded"] = "\(phasePool.bytesLoaded)"
                metrics["\(phase).pool.readSeconds"] = String(
                    format: "%.4f", phasePool.readSeconds
                )
                metrics["\(phase).pool.aggregateAcquireWaitSeconds"] = String(
                    format: "%.4f", phasePool.aggregateAcquireWaitSeconds
                )
                metrics["\(phase).pool.hitRate"] = String(
                    format: "%.4f", phasePool.hitRate
                )
                metrics["\(phase).pool.occupancySlots"] = "\(phasePool.occupancySlots)"
                metrics["\(phase).pool.occupancyBytes"] = "\(phasePool.occupancyBytes)"
            }
            metrics["prefill.bytesPerPromptToken"] = "\(generation.prefillBytesPerPromptToken)"
            metrics["decode.bytesPerGeneratedToken"] = "\(generation.decodeBytesPerGeneratedToken)"
            metrics["prefill.loadsPerPromptToken"] = String(
                format: "%.4f", generation.prefillPool.loadsPerToken(generation.promptTokens)
            )
            metrics["decode.loadsPerGeneratedToken"] = String(
                format: "%.4f", generation.decodePool.loadsPerToken(generation.generatedTokens)
            )
            metrics["generation.promptTokens"] = "\(generation.promptTokens)"
            metrics["generation.generatedTokens"] = "\(generation.generatedTokens)"
            metrics["generation.prefillSeconds"] = String(
                format: "%.4f", generation.prefillSeconds
            )
            metrics["generation.ttftSeconds"] = String(
                format: "%.4f", generation.timeToFirstTokenSeconds
            )
            metrics["generation.decodeSeconds"] = String(
                format: "%.4f", generation.decodeSeconds
            )
            metrics["generation.decodeTokensPerSecond"] = String(
                format: "%.2f", generation.decodeTokensPerSecond
            )
            metrics["generation.totalSeconds"] = String(
                format: "%.4f", generation.totalSeconds
            )
            metrics["generation.stopReason"] = generation.stopReason
            metrics["generation.finalPosition"] = "\(generation.finalPosition)"
            metrics["generation.eosHit"] = "\(generation.eosHit)"
            metrics["generation.thinkingEnabled"] = "\(generation.thinkingEnabled)"
            metrics["generation.reasoningTokens"] = "\(generation.reasoningTokens)"
            metrics["generation.finalAnswerTokens"] = "\(generation.finalAnswerTokens)"
            metrics["generation.timeToFirstAnswerTokenSeconds"] = String(
                format: "%.4f", generation.timeToFirstAnswerTokenSeconds
            )
            metrics["generation.endedWhileThinking"] = "\(generation.endedWhileThinking)"
            metrics["generation.decodeCalls"] = "\(generation.decodeCalls)"
            metrics["generation.controlTokens"] = "\(generation.controlTokens)"
            metrics["generation.endToEndTokensPerSecond"] = String(
                format: "%.2f", generation.endToEndTokensPerSecond
            )
            metrics["prompt.systemTokens"] = "\(generation.promptSystemTokens)"
            metrics["prompt.historyTokens"] = "\(generation.promptHistoryTokens)"
            metrics["prompt.userTokens"] = "\(generation.promptUserTokens)"
            metrics["prompt.templateOverheadTokens"] = "\(generation.promptTemplateOverheadTokens)"
            metrics["state.positionAfterPrefill"] = "\(generation.positionAfterPrefill)"
            metrics["state.kvTokensAfterPrefill"] = "\(generation.kvTokensAfterPrefill)"
            metrics["state.kvTokensFinal"] = "\(generation.kvTokensFinal)"
            metrics["state.linearStateBytes"] = "\(generation.linearStateBytes)"
            metrics["state.layerInvocations"] = "\(generation.layerInvocations)"
            metrics["state.expertLoads"] = "\(generation.expertLoads)"
            metrics["state.activeOutputConsumers"] = "\(generation.activeOutputConsumers)"
            metrics["state.routerHash"] = "\(generation.routerHash)"
            metrics["state.uniqueExpertTotal"] = "\(generation.uniqueExpertTotal)"
            metrics["state.moeInvocations"] = "\(generation.moeInvocations)"
            metrics["mode.prefill"] = generation.prefillMode
            metrics["mode.evalWindowRequested"] = "\(generation.evalWindowRequested)"
            metrics["mode.evalWindowEffective"] = "\(generation.evalWindowEffective)"
            metrics["mode.microbatchRequested"] = "\(generation.microbatchRequested)"
            metrics["mode.microbatchEffective"] = "\(generation.microbatchEffective)"
            metrics["state.routedGroups"] = "\(generation.routedGroups)"
            metrics["handoff.inFlightBefore"] = "\(generation.handoffInFlightBefore)"
            metrics["handoff.inFlightAfter"] = "\(generation.handoffInFlightAfter)"
            metrics["handoff.advisoryLoads"] = "\(generation.handoffAdvisoryLoads)"
            metrics["advisory.loads.lifetime"] = "\(generation.advisoryLoadsLifetime)"
            metrics["advisory.requested"] = generation.advisoryRequested
                ? "true" : "false"
            metrics["advisory.active"] = generation.advisoryActive
                ? "true" : "false"
            metrics["advisory.fallbacks"] = "\(generation.advisoryFallbacks)"
            metrics["advisory.predictions"] = "\(generation.advisory.predictions)"
            metrics["advisory.predictedExperts"] =
                "\(generation.advisory.predictedExperts)"
            metrics["advisory.correct"] =
                "\(generation.advisory.correctPredictions)"
            metrics["advisory.trueExperts"] =
                "\(generation.advisory.trueExperts)"
            metrics["advisory.ready"] =
                "\(generation.advisory.readyFromPrediction)"
            metrics["advisory.prefetchStarted"] =
                "\(generation.advisory.prefetchLoadsStarted)"
            metrics["advisory.prefetchCompleted"] =
                "\(generation.advisory.prefetchLoadsCompleted)"
            metrics["advisory.prefetchBytes"] = "\(generation.advisory.prefetchBytes)"
            metrics["advisory.runtimeFallbacks"] =
                "\(generation.advisory.fallbacks)"
            metrics["advisory.artifactPresent"] = generation.advisoryArtifactPresent
                ? "true" : "false"
            metrics["advisory.artifactValid"] = generation.advisoryArtifactValid
                ? "true" : "false"
            metrics["advisory.headCount"] = "\(generation.advisoryHeadCount)"
            metrics["advisory.loadedBytes"] = "\(generation.advisoryLoadedBytes)"
            metrics["advisory.fallbackReason"] = generation.advisoryFallbackReason
            metrics["advisory.headInvocations"] =
                "\(generation.advisory.headInvocations)"
            metrics["advisory.prefillPredictions"] =
                "\(generation.advisory.prefillPredictions)"
            metrics["advisory.decodePredictions"] =
                "\(generation.advisory.decodePredictions)"
            metrics["mode.routerReadbackRequested"] =
                "\(generation.routerReadbackRequested)"
            metrics["mode.routerReadbackEffective"] =
                "\(generation.routerReadbackEffective)"
            metrics["mode.readaheadRequested"] = generation.readaheadRequested
                ? "true" : "false"
            metrics["mode.readaheadEffective"] = generation.readaheadEffective
                ? "true" : "false"
            metrics["advisory.fallbackReasons"] =
                generation.advisory.fallbackReasons
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",")
            metrics["mode.decode"] = generation.decodeMode
            metrics["mlx.activeBytes"] = "\(generation.mlxActiveBytes)"
            metrics["mlx.cacheBytes"] = "\(generation.mlxCacheBytes)"
            metrics["mlx.peakBytes"] = "\(generation.mlxPeakBytes)"
            for (phase, components) in [
                ("prefill", generation.profile.prefill),
                ("decode", generation.profile.decode),
            ] {
                for (key, value) in Self.profileKeys(
                    phase: phase, components: components
                ) {
                    metrics[key] = value
                }
            }
        }

        return metrics.isEmpty ? nil : metrics
    }

    func generate(
        messages: [ChatMessage],
        options: GenerationOptions
    ) async throws -> AsyncThrowingStream<TokenEvent, Error> {
        guard let family = loadedFamily else {
            throw RuntimeError.noActiveModel
        }
        let templatedMessages = messages.map { message in
            [
                "role": message.role.rawValue,
                "content": message.contentForModel,
            ]
        }
        var engineOptions = Edge0EngineOptions(
            maxTokens: max(1, options.maxTokens),
            temperature: options.temperature,
            topP: options.topP,
            topK: options.topK ?? 0,
            minP: options.minP ?? 0,
            repetitionPenalty: options.repetitionPenalty,
            presencePenalty: options.presencePenalty,
            frequencyPenalty: options.frequencyPenalty,
            seed: options.seed,
            mode: Edge0EnginePreferences.executionMode,
            eosTokenID: 156_895
        )
        switch family {
        case .bailing8B:
            // Native 8B template supports enable_thinking; honor the
            // service's effective preference for the active model.
            engineOptions.enableThinking = options.thinkingMode != .disabled
        case .qwen35MoE:
            // Family stop metadata. The requested mode comes from the 35B
            // diagnostic preference; the engine resolves support and records
            // the authoritative requested/effective snapshot.
            let eos = engine35B?.eosTokenIDs ?? [248_046, 248_044]
            engineOptions.eosTokenID = eos.first ?? 248_046
            engineOptions.additionalEOSTokenIDs = Array(eos.dropFirst())
            engineOptions.mode = Edge0EnginePreferences.edge0_35BExecutionMode
            // The service decides from settings; the engine only receives
            // the effective boolean and renders it into the real template.
            engineOptions.enableThinking = options.thinkingMode != .disabled
        }

        return AsyncThrowingStream { [engine8B, engine35B] continuation in
            continuation.yield(.started)
            let task = Task { @MainActor in
                do {
                    let relay: @Sendable (Edge0EngineEvent) -> Void = { event in
                        switch event {
                        case .started:
                            break
                        case .token(let text):
                            continuation.yield(.token(text))
                        case .completed(let tokens, let rate):
                            continuation.yield(.usage(
                                tokensPerSecond: rate,
                                inputTokens: nil,
                                outputTokens: tokens > 0 ? tokens : nil
                            ))
                            continuation.yield(.completed)
                            continuation.finish()
                        case .cancelled:
                            continuation.finish()
                        }
                    }
                    switch family {
                    case .bailing8B:
                        guard let engine8B else {
                            throw RuntimeError.noActiveModel
                        }
                        try await engine8B.generate(
                            messages: templatedMessages,
                            options: engineOptions,
                            onEvent: relay
                        )
                    case .qwen35MoE:
                        guard let engine35B else {
                            throw RuntimeError.noActiveModel
                        }
                        try await engine35B.generate(
                            messages: templatedMessages,
                            options: engineOptions,
                            onEvent: relay
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.generationTask = task
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.generationTask?.cancel()
                    self?.engine8B?.cancel()
                    self?.engine35B?.cancel()
                }
            }
        }
    }

    func cancel() async {
        generationTask?.cancel()
        generationTask = nil
        engine8B?.cancel()
        engine35B?.cancel()
    }
}
