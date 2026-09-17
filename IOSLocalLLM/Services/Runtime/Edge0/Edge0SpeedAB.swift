import Foundation
import SwiftUI

// MARK: - Edge0SpeedABRunner
//
// Controlled 35B diagnostic through the PRODUCTION Assistant path.
//
// Two modes of operation (picker in Diagnostics):
//   • AB — counterbalanced Exact → Bounded → Bounded → Exact, one unscored
//     warm-up per mode, a real minimum idle interval before every scored
//     trial, and a median comparison that stays labeled inconclusive under
//     progressive drift.
//   • Exact drift — three Exact trials with the same recovery protocol,
//     reporting per-component timings for the first vs last trial to locate
//     where the extra prefill time goes.
//
// Controls (documented, identical for every scored run):
//   family 35B · Thinking Off · greedy · max 64 output tokens · one fixed
//   public prompt · expert pool explicitly 512 MiB · read concurrency 4 ·
//   component profiling ON for diagnostics (never for scored speed claims).

@MainActor
final class Edge0SpeedABRunner: ObservableObject {

    static let benchmarkPrompt =
        "Write 12 numbered practical tips for organizing files on a computer. Use one complete sentence per tip."

    /// Wall-clock component timings for one run. Boundaries:
    /// • gatedDeltaNet / fullAttention / router / moe / embedding / lmHead
    ///   come from the model's profile hooks; MLX evaluates lazily, so MoE
    ///   includes its per-token `MLX.eval`, while the attention and head
    ///   timers mostly measure graph submission.
    /// • sampling often absorbs the completion of the previous step's graph.
    /// These are submission+completion wall-clock boundaries, not exclusive
    /// GPU kernel times, and they overlap.
    struct RunProfile: Equatable {
        var prefillGatedDeltaNet = 0.0
        var prefillFullAttention = 0.0
        var prefillRouter = 0.0
        var prefillMoE = 0.0
        var prefillEmbedding = 0.0
        var prefillLmHead = 0.0
        var prefillSampling = 0.0
        var decodeGatedDeltaNet = 0.0
        var decodeFullAttention = 0.0
        var decodeRouter = 0.0
        var decodeMoE = 0.0
        var decodeEmbedding = 0.0
        var decodeLmHead = 0.0
        var decodeSampling = 0.0
        var prefillMoEAcquire = 0.0
        var prefillMoERouted = 0.0
        var prefillMoEShared = 0.0
        var prefillMoECombine = 0.0
        var prefillMoEEval = 0.0
        var prefillMoEEarly = 0.0
        var prefillMoEMiddle = 0.0
        var prefillMoELate = 0.0
        var prefillMoEStackBuild = 0.0
        var prefillMoERelease = 0.0
        var decodeMoEAcquire = 0.0
        var decodeMoERouted = 0.0
        var decodeMoEShared = 0.0
        var decodeMoEEval = 0.0
        // Sample counts: zero means UNAVAILABLE, never 0.000 s.
        var prefillAcquireSamples = 0.0
        var prefillStackSamples = 0.0
        var prefillRoutedSamples = 0.0
        var prefillSharedSamples = 0.0
        var prefillCombineSamples = 0.0
        var prefillEvalSamples = 0.0
        var prefillReleaseSamples = 0.0

        init() {}

        init(metrics: [String: String]) {
            func value(_ key: String) -> Double {
                Double(metrics[key] ?? "") ?? 0
            }
            prefillGatedDeltaNet = value("profile.prefill.kdaSeconds")
            prefillFullAttention = value("profile.prefill.mlaSeconds")
            prefillRouter = value("profile.prefill.routerSeconds")
            prefillMoE = value("profile.prefill.moeSeconds")
            prefillEmbedding = value("profile.prefill.embeddingSeconds")
            prefillLmHead = value("profile.prefill.lmHeadSeconds")
            prefillSampling = value("profile.prefill.samplingSeconds")
            decodeGatedDeltaNet = value("profile.decode.kdaSeconds")
            decodeFullAttention = value("profile.decode.mlaSeconds")
            decodeRouter = value("profile.decode.routerSeconds")
            decodeMoE = value("profile.decode.moeSeconds")
            decodeEmbedding = value("profile.decode.embeddingSeconds")
            decodeLmHead = value("profile.decode.lmHeadSeconds")
            decodeSampling = value("profile.decode.samplingSeconds")
            prefillMoEAcquire = value("profile.prefill.moeAcquireSeconds")
            prefillMoERouted = value("profile.prefill.moeRoutedSeconds")
            prefillMoEShared = value("profile.prefill.moeSharedSeconds")
            prefillMoECombine = value("profile.prefill.moeCombineSeconds")
            prefillMoEEval = value("profile.prefill.moeEvalSeconds")
            prefillMoEEarly = value("profile.prefill.moeEarlySeconds")
            prefillMoEMiddle = value("profile.prefill.moeMiddleSeconds")
            prefillMoELate = value("profile.prefill.moeLateSeconds")
            prefillMoEStackBuild = value("profile.prefill.moeStackBuildSeconds")
            prefillMoERelease = value("profile.prefill.moeReleaseSeconds")
            prefillAcquireSamples = value("profile.prefill.acquire.samples")
            prefillStackSamples = value("profile.prefill.stack.samples")
            prefillRoutedSamples = value("profile.prefill.routed.samples")
            prefillSharedSamples = value("profile.prefill.shared.samples")
            prefillCombineSamples = value("profile.prefill.combine.samples")
            prefillEvalSamples = value("profile.prefill.eval.samples")
            prefillReleaseSamples = value("profile.prefill.release.samples")
            decodeMoEAcquire = value("profile.decode.moeAcquireSeconds")
            decodeMoERouted = value("profile.decode.moeRoutedSeconds")
            decodeMoEShared = value("profile.decode.moeSharedSeconds")
            decodeMoEEval = value("profile.decode.moeEvalSeconds")
        }

        var isEmpty: Bool { self == RunProfile() }
    }

    struct RunResult: Identifiable {
        let id = UUID()
        var label: String
        var mode: Edge0ExecutionMode
        var scored: Bool
        var promptTokens = 0
        var generatedTokens = 0
        var decodeCalls = 0
        var stopReason = ""
        var thinkingEnabled = false
        var requestedMode = ""
        var effectiveMode = ""
        var prefillMode = ""
        var decodeMode = ""
        var evalWindowRequested = 1
        var evalWindowEffective = 1
        var microbatchRequested = 1
        var microbatchEffective = 1
        var routedGroups = 0
        var peakActiveLeases = 0
        var modeFallback = ""
        var poolSlots = 0
        var poolBytes: UInt64 = 0
        var readsConfigured = "unavailable"
        var readsPeak = "unavailable"
        var readsActiveAtCompletion = "unavailable"
        var prefillSeconds = 0.0
        var ttftSeconds = 0.0
        var firstVisibleChunkSeconds = 0.0
        var chatOverheadSeconds = 0.0
        var decodeSeconds = 0.0
        var decodeTokensPerSecond = 0.0
        var endToEndTokensPerSecond = 0.0
        var prefillAcquireWaitSeconds = 0.0
        var decodeAcquireWaitSeconds = 0.0
        var footprintBefore: Int64 = 0
        var footprintAfter: Int64 = 0
        var peakFootprint: Int64 = 0
        var thermalStart = ""
        var thermalEnd = ""
        var idleSecondsBefore = 0.0
        var recoveryReason = ""
        var boundaryBefore = "unavailable"
        var positionAfterPrefill = 0
        var kvTokensAfterPrefill = 0
        var kvTokensFinal = 0
        var linearStateBytes = 0
        var layerInvocations = 0
        var expertLoads = 0
        var handoffInFlightBefore = 0
        var handoffInFlightAfter = 0
        var handoffAdvisoryLoads = 0
        var advisoryLoadsLifetime = 0
        var advisoryRequested = false
        var advisoryActive = false
        var advisoryPredictions = 0
        var advisoryPredictedExperts = 0
        var advisoryCorrect = 0
        var advisoryTrueExperts = 0
        var advisoryReady = 0
        var advisoryPrefetchStarted = 0
        var advisoryPrefetchCompleted = 0
        var advisoryPrefetchBytes: UInt64 = 0
        var advisoryRuntimeFallbacks = 0
        var advisoryArtifactPresent = false
        var advisoryArtifactValid = false
        var advisoryHeadCount = 0
        var advisoryLoadedBytes: UInt64 = 0
        var advisoryHeadInvocations = 0
        var advisoryPrefillPredictions = 0
        var advisoryDecodePredictions = 0
        var advisoryFallbackReason = ""
        var routerReadbackRequested = 0
        var routerReadbackEffective = 0
        /// Phase 5M: requested (generation-time preference) vs effective
        /// (engine-load-captured) readahead state for this run. A mismatch
        /// means the engine was not reloaded after the preference changed.
        var readaheadRequested = false
        var readaheadEffective = false
        var routerHash = ""
        var uniqueExpertTotal = 0
        var moeInvocations = 0
        var mlxActiveBytes = 0
        var mlxCacheBytes = 0
        var mlxPeakBytes = 0
        var sustainedEvidence = false
        var timedOut = false
        var sequenceMatch: Bool?
        var firstDifferingIndex: Int?
        var error: String?
        var profile = RunProfile()
        var fullText = ""
    }

    @Published private(set) var results: [RunResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var decision = ""
    @Published private(set) var driftDiagnosis = ""
    @Published private(set) var loadedSeconds = 0.0
    @Published private(set) var sessionLabel = ""
    @Published private(set) var driftDetected = false

    @Published var kind: Edge0DiagnosticKind = .ab

    // Explicit run state for exports and termination reporting.
    @Published private(set) var runID = UUID()
    @Published private(set) var phase: Edge0DiagnosticPhase = .preparing
    @Published private(set) var terminal: Edge0DiagnosticTerminal?
    @Published private(set) var terminalReason = ""
    @Published private(set) var lastCompletedStep = "not started"
    @Published private(set) var plannedTrials = 0
    @Published private(set) var completedTrials = 0
    @Published private(set) var trialIndex = 0
    /// Minimum idle interval before every scored trial. Experimental control;
    /// it does not prove full device recovery.
    @Published var recoverySeconds = 60

    private var task: Task<Void, Never>?

    private static let poolOverrideBytes: UInt64 = 512 * 1_048_576
    private static let expectedSlots = 303
    nonisolated private static let maximumOutputTokens = 64
    private static let minimumSustainedTokens = 32
    private static let runTimeoutSeconds: Double = 420
    private static let driftThreshold = 0.20

    var isCancelled: Bool { task?.isCancelled ?? false }

    // MARK: Run / cancel

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        runID = UUID()
        results = []
        decision = ""
        driftDiagnosis = ""
        sessionLabel = ""
        driftDetected = false
        phase = .preparing
        terminal = nil
        terminalReason = ""
        lastCompletedStep = "started"
        plannedTrials = kind.scoredPlan.count
        completedTrials = 0
        trialIndex = 0
        task = Task { await self.performRun() }
        await task?.value
        isRunning = false
    }

    func cancel() {
        task?.cancel()
        CodingAssistantService.shared.stopGeneration()
        status = "Cancelled."
    }

    // MARK: Orchestration

    private func performRun() async {
        let service = CodingAssistantService.shared
        guard let preset = AssistantModelCatalog.presets.first(where: {
            $0.repoID == Edge0ModelFamily.qwen35MoERepoID
        }) else {
            status = "No Edge0-35B preset in the catalog."
            return
        }
        if let reason = DeviceSafetyMonitor.shared.stopReason {
            status = "Device safety stop: \(reason.title)."
            return
        }

        let store = AssistantModelSettingsStore.shared
        let savedThinking = store.settings(for: preset.repoID)
        let scope = Edge0DiagnosticPreferences.Snapshot.capture()
        // Cleanup on every exit (completion, cancellation, thrown error):
        // restore exactly the values captured above.
        defer {
            scope.restore()
            if let savedThinking {
                store.save(
                    savedThinking,
                    for: preset.repoID,
                    supportsThinking: preset.supportsThinking
                )
            } else {
                store.reset(repositoryID: preset.repoID)
            }
        }

        var settings = store.effectiveSettings(
            for: preset.repoID,
            supportsThinking: preset.supportsThinking,
            appSettings: AppSettings.shared
        )
        settings.thinkingEnabled = false
        store.save(
            settings,
            for: preset.repoID,
            supportsThinking: preset.supportsThinking
        )
        Edge0EnginePreferences.poolCapacityBytesOverride = Self.poolOverrideBytes
        Edge0EnginePreferences.expertLoadConcurrency = 4
        Edge0EnginePreferences.edge0_35BExecutionMode = .exact
        // Profiling is diagnostic-only; scored A/B trials run unprofiled.
        Edge0EnginePreferences.componentProfilingEnabled = kind == .exactDrift
        // Phase 5M: readahead is frozen at engine load, so the readahead A/B
        // starts from the OFF arm (counterbalanced plan: off→on→on→off) and
        // reloads the engine on every arm CHANGE. All other kinds leave the
        // preference untouched here (the run scope captures and restores it).
        if kind == .readaheadAB {
            Edge0EnginePreferences.edge0_35BReadaheadHints = false
        }

        status = "Loading Edge0-35B (512 MiB pool)…"
        if service.isModelLoaded {
            await service.unloadAndWaitForCleanup()
        }
        let loadStarted = ContinuousClock.now
        await service.switchTo(preset, persistAsDefault: false)
        loadedSeconds = loadStarted.duration(to: .now).seconds
        guard service.isModelLoaded else {
            status = "Edge0-35B did not load."
            return
        }
        var previousReadaheadArm: Bool? = kind == .readaheadAB ? false : nil
        if let metrics = await service.edge0RuntimeMetrics() {
            let slots = metrics["pool.capacitySlots"] ?? "unavailable"
            let bytes = metrics["pool.capacityBytes"] ?? "unavailable"
            let reads = metrics["reads.configured"] ?? "unavailable"
            let readahead = metrics["mode.readaheadEffective"] ?? "unavailable"
            status = "Loaded in \(String(format: "%.2f", loadedSeconds))s"
                + " · pool \(slots) slots/\(bytes) B · reads configured \(reads)"
            if let slotsValue = Int(slots), slotsValue != Self.expectedSlots {
                status += " · WARNING: expected \(Self.expectedSlots) slots"
            }
            if kind == .readaheadAB {
                status += " · readahead \(readahead)"
            }
        }

        // Warm-ups (unscored, documented, one per distinct plan mode).
        phase = .warmUp
        status = "Warming up…"
        for mode in kind.warmUpModes {
            // Warm-ups are heavy work too: apply the SAME thermal admission
            // policy used for scored trials instead of starting them while
            // the device is already Serious/Critical.
            if ProcessInfo.processInfo.thermalState.rawValue
                >= ProcessInfo.ThermalState.serious.rawValue {
                finish(.blocked, reason: "thermal serious/critical")
                return
            }
            _ = await measuredRun(
                service: service,
                mode: mode,
                label: "Warm-up \(Self.label(for: mode))",
                scored: false, maximumTokens: 8
            )
            if isCancelled {
                finish(.cancelled, reason: "cancelled during warm-up")
                return
            }
        }
        lastCompletedStep = "warm-ups complete"
        status = "Warm-up complete."

        let order = kind.scoredPlan
        var blockedReason: String?
        var failedReason: String?
        var timedOut = false
        for (index, mode) in order.enumerated() {
            trialIndex = index + 1
            if isCancelled {
                finish(.cancelled, reason: "cancelled before trial \(index + 1)")
                return
            }
            phase = .recovery
            status = Edge0DiagnosticPlan.recoveryText(
                elapsedSeconds: 0,
                minimumSeconds: Double(recoverySeconds),
                nextMode: mode,
                nextIndex: index + 1,
                planned: order.count
            )
            let idle = await recoveryWait(
                nextMode: mode, nextIndex: index + 1, planned: order.count
            )
            if isCancelled {
                finish(.cancelled, reason: "cancelled during recovery")
                return
            }
            let boundary = await service.edge0ResourceSnapshot()
            let admission = Edge0DiagnosticPlan.admission(
                snapshotAvailable: boundary != nil,
                snapshotComplete: boundary?.isComplete ?? false,
                hasLiveWork: boundary?.hasLiveWork ?? false,
                thermalSeriousOrCritical: ProcessInfo.processInfo.thermalState.rawValue
                    >= ProcessInfo.ThermalState.serious.rawValue,
                recoveryTimedOut: idle.timedOut
            )
            if case .blocked(let reason) = admission {
                blockedReason = reason
                status = "Blocked before trial \(index + 1): \(reason)"
                break
            }
            guard let boundary else {
                blockedReason = "resource snapshot unavailable"
                break
            }
            let readaheadOverride: Bool? = kind == .readaheadAB
                ? [false, true, true, false][min(index, 3)] : nil
            // Phase 5M reload-per-arm: readahead is captured at engine load,
            // so an arm change REQUIRES unloading and reloading the model
            // before the trial. (The warm-up ran under the initial OFF arm.)
            // Reuse the same reload for both trials of an arm — only the
            // arm TRANSITION reloads, not every trial.
            if kind == .readaheadAB,
               let readaheadOverride,
               readaheadOverride != previousReadaheadArm {
                phase = .recovery
                status = "Reloading Edge0-35B for readahead "
                    + "\(readaheadOverride ? "ON" : "OFF") arm…"
                await service.unloadAndWaitForCleanup()
                Edge0EnginePreferences.edge0_35BReadaheadHints = readaheadOverride
                let reloadStarted = ContinuousClock.now
                await service.switchTo(preset, persistAsDefault: false)
                let reloadSeconds = reloadStarted.duration(to: .now).seconds
                guard service.isModelLoaded else {
                    failedReason = "engine reload failed for the readahead "
                        + "\(readaheadOverride ? "ON" : "OFF") arm"
                    status = "Stopped: \(failedReason ?? "reload failed")"
                    break
                }
                previousReadaheadArm = readaheadOverride
                status = "Reloaded in \(String(format: "%.2f", reloadSeconds))s"
                    + " · readahead arm \(readaheadOverride ? "ON" : "OFF")"
            }
            let windowOverride: Int? = kind == .evalWindowAB
                ? [1, 4, 4, 1][min(index, 3)] : nil
            let microbatchOverride: Int? = kind == .microbatchAB
                ? [1, 4, 4, 1][min(index, 3)] : nil
            let advisoryOverride: Bool? = kind == .prerouterAB
                ? [false, true, true, false][min(index, 3)] : nil
            let readbackOverride: Int? = kind == .computeAB
                ? [0, 1, 1, 0][min(index, 3)] : nil
            let planLabel: String
            if kind == .evalWindowAB {
                planLabel = "Staged w\(windowOverride ?? 1)"
            } else if kind == .microbatchAB {
                planLabel = "Staged g\(microbatchOverride ?? 1)"
            } else if kind == .prerouterAB {
                planLabel = "Staged advisory-\((advisoryOverride ?? false) ? "on" : "off")"
            } else if kind == .computeAB {
                planLabel = "Staged readback-\((readbackOverride ?? 0) == 1 ? "batched" : "per-token")"
            } else if kind == .readaheadAB {
                planLabel = "Staged readahead-\((readaheadOverride ?? false) ? "on" : "off")"
            } else {
                planLabel = Self.label(for: mode)
            }
            phase = .scoredTrial
            status = "Trial \(index + 1)/\(order.count) · \(planLabel) (idle \(Int(idle.seconds))s)…"
            var run = await measuredRun(
                service: service, mode: mode,
                label: "\(planLabel) #\(index + 1)", scored: true,
                evalWindow: windowOverride,
                microbatch: microbatchOverride,
                advisory: advisoryOverride,
                readback: readbackOverride,
                readahead: readaheadOverride
            )
            run.idleSecondsBefore = idle.seconds
            run.recoveryReason = idle.reason
            run.boundaryBefore = boundary.describe()
            if let position = results.lastIndex(where: { $0.id == run.id }) {
                results[position] = run
            }
            if let error = run.error {
                if run.timedOut { timedOut = true }
                failedReason = error
                status = "Stopped: \(error)"
                break
            }
            if run.effectiveMode != mode.rawValue {
                let reason = "\(mode.rawValue) fell back to \(run.effectiveMode)"
                failedReason = reason
                status = reason
                break
            }
            completedTrials += 1
            lastCompletedStep = "scored trial \(index + 1) (\(planLabel))"
        }

        compareSequences()
        computeDriftDiagnosis()
        let outcome = Edge0DiagnosticPlan.terminalStatus(
            completedScoredTrials: completedTrials,
            plannedScoredTrials: order.count,
            cancelled: false,
            blockedReason: blockedReason,
            failedReason: failedReason,
            timedOut: timedOut
        )
        finish(outcome.terminal, reason: outcome.reason)
    }

    private func finish(
        _ terminal: Edge0DiagnosticTerminal,
        reason: String
    ) {
        phase = .finished
        self.terminal = terminal
        terminalReason = reason
        computeDecision()
        switch terminal {
        case .completed:
            status = "Completed: \(reason)."
        case .cancelled, .blocked, .failed, .timedOut:
            status = "\(terminal.rawValue.capitalized): \(reason)."
        }
    }

    private struct RecoveryOutcome {
        var seconds: Double
        var thermalAfter: String
        var reason: String
        var timedOut: Bool
    }

    /// Minimum idle interval (experimental control) plus a bounded wait while
    /// the device is at Serious or Critical. Always honors the configured
    /// minimum, even when the thermal label is Nominal.
    private func recoveryWait(
        nextMode: Edge0ExecutionMode,
        nextIndex: Int,
        planned: Int
    ) async -> RecoveryOutcome {
        let started = ContinuousClock.now
        let minimum = Double(max(0, recoverySeconds))
        var timeout = false
        var reason = "minimum idle \(Int(minimum))s"
        while true {
            let elapsed = started.duration(to: .now).seconds
            let thermal = ProcessInfo.processInfo.thermalState
            let needsThermalWait =
                thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            let needsMinimum = elapsed < minimum
            if !needsThermalWait, !needsMinimum { break }
            if elapsed >= max(minimum * 3, 180) {
                timeout = needsThermalWait
                break
            }
            if needsThermalWait { reason = "thermal \(thermal.label) wait" }
            status = Edge0DiagnosticPlan.recoveryText(
                elapsedSeconds: elapsed,
                minimumSeconds: minimum,
                nextMode: nextMode,
                nextIndex: nextIndex,
                planned: planned
            )
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if isCancelled { break }
        }
        return RecoveryOutcome(
            seconds: started.duration(to: .now).seconds,
            thermalAfter: ProcessInfo.processInfo.thermalState.label,
            reason: reason,
            timedOut: timeout
        )
    }

    // MARK: One measured run

    private func measuredRun(
        service: CodingAssistantService,
        mode: Edge0ExecutionMode,
        label: String,
        scored: Bool,
        maximumTokens: Int = maximumOutputTokens,
        evalWindow: Int? = nil,
        microbatch: Int? = nil,
        advisory: Bool? = nil,
        readback: Int? = nil,
        readahead: Bool? = nil
    ) async -> RunResult {
        Edge0EnginePreferences.edge0_35BExecutionMode = mode
        if let evalWindow {
            Edge0EnginePreferences.edge0_35BStagedEvalWindow = evalWindow
        }
        if let microbatch {
            Edge0EnginePreferences.edge0_35BMicrobatchGroupSize = microbatch
        }
        if let advisory {
            Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = advisory
        }
        if let readback {
            Edge0EnginePreferences.edge0_35BRouterReadbackMode = readback
        }
        // Phase 5M: stamped before generation so the requested half of the
        // pair reflects the arm; the engine's load-captured state supplies
        // the effective half.
        if let readahead {
            Edge0EnginePreferences.edge0_35BReadaheadHints = readahead
        }
        var result = RunResult(label: label, mode: mode, scored: scored)
        result.footprintBefore = MemoryAdvisor.physFootprint
        result.thermalStart = ProcessInfo.processInfo.thermalState.label

        let collector = ABStreamCollector()
        let prompt = ChatMessage(role: .user, content: Self.benchmarkPrompt)
        let finished = await withGeneration(
            service: service,
            messages: [prompt],
            maximumTokens: maximumTokens,
            collector: collector
        )
        if !finished { result.timedOut = true }
        result.footprintAfter = MemoryAdvisor.physFootprint
        result.peakFootprint = max(collector.peakFootprint, result.footprintAfter)
        result.thermalEnd = ProcessInfo.processInfo.thermalState.label
        result.firstVisibleChunkSeconds = collector.firstChunkSeconds ?? 0
        result.fullText = collector.text
        if let error = collector.error {
            result.error = error
        }
        if result.timedOut {
            result.error = "Run exceeded \(Int(Self.runTimeoutSeconds))s"
        }

        if let metrics = await service.edge0RuntimeMetrics() {
            result.promptTokens = Int(metrics["generation.promptTokens"] ?? "") ?? 0
            result.generatedTokens = Int(metrics["generation.generatedTokens"] ?? "") ?? 0
            result.decodeCalls = Int(metrics["generation.decodeCalls"] ?? "") ?? 0
            result.stopReason = metrics["generation.stopReason"] ?? ""
            result.thinkingEnabled = metrics["generation.thinkingEnabled"] == "true"
            result.requestedMode = metrics["mode.requested"] ?? ""
            result.effectiveMode = metrics["mode.effective"] ?? ""
            result.prefillMode = metrics["mode.prefill"] ?? ""
            result.evalWindowRequested =
                Int(metrics["mode.evalWindowRequested"] ?? "") ?? 1
            result.evalWindowEffective =
                Int(metrics["mode.evalWindowEffective"] ?? "") ?? 1
            result.microbatchRequested =
                Int(metrics["mode.microbatchRequested"] ?? "") ?? 1
            result.microbatchEffective =
                Int(metrics["mode.microbatchEffective"] ?? "") ?? 1
            result.routedGroups =
                Int(metrics["state.routedGroups"] ?? "") ?? 0
            result.peakActiveLeases =
                Int(metrics["pool.peakActiveLeases"] ?? "") ?? 0
            result.handoffInFlightBefore =
                Int(metrics["handoff.inFlightBefore"] ?? "") ?? 0
            result.handoffInFlightAfter =
                Int(metrics["handoff.inFlightAfter"] ?? "") ?? 0
            result.handoffAdvisoryLoads =
                Int(metrics["handoff.advisoryLoads"] ?? "") ?? 0
            result.advisoryLoadsLifetime =
                Int(metrics["advisory.loads.lifetime"] ?? "") ?? 0
            result.advisoryRequested =
                metrics["advisory.requested"] == "true"
            result.advisoryActive = metrics["advisory.active"] == "true"
            result.advisoryPredictions =
                Int(metrics["advisory.predictions"] ?? "") ?? 0
            result.advisoryPredictedExperts =
                Int(metrics["advisory.predictedExperts"] ?? "") ?? 0
            result.advisoryCorrect =
                Int(metrics["advisory.correct"] ?? "") ?? 0
            result.advisoryTrueExperts =
                Int(metrics["advisory.trueExperts"] ?? "") ?? 0
            result.advisoryReady =
                Int(metrics["advisory.ready"] ?? "") ?? 0
            result.advisoryPrefetchStarted =
                Int(metrics["advisory.prefetchStarted"] ?? "") ?? 0
            result.advisoryPrefetchCompleted =
                Int(metrics["advisory.prefetchCompleted"] ?? "") ?? 0
            result.advisoryPrefetchBytes =
                UInt64(metrics["advisory.prefetchBytes"] ?? "") ?? 0
            result.advisoryRuntimeFallbacks =
                Int(metrics["advisory.runtimeFallbacks"] ?? "") ?? 0
            result.advisoryArtifactPresent =
                metrics["advisory.artifactPresent"] == "true"
            result.advisoryArtifactValid =
                metrics["advisory.artifactValid"] == "true"
            result.advisoryHeadCount =
                Int(metrics["advisory.headCount"] ?? "") ?? 0
            result.advisoryLoadedBytes =
                UInt64(metrics["advisory.loadedBytes"] ?? "") ?? 0
            result.advisoryHeadInvocations =
                Int(metrics["advisory.headInvocations"] ?? "") ?? 0
            result.advisoryPrefillPredictions =
                Int(metrics["advisory.prefillPredictions"] ?? "") ?? 0
            result.advisoryDecodePredictions =
                Int(metrics["advisory.decodePredictions"] ?? "") ?? 0
            result.advisoryFallbackReason =
                metrics["advisory.fallbackReason"] ?? ""
            result.routerReadbackRequested =
                Int(metrics["mode.routerReadbackRequested"] ?? "") ?? 0
            result.routerReadbackEffective =
                Int(metrics["mode.routerReadbackEffective"] ?? "") ?? 0
            result.readaheadRequested =
                metrics["mode.readaheadRequested"] == "true"
            result.readaheadEffective =
                metrics["mode.readaheadEffective"] == "true"
            result.decodeMode = metrics["mode.decode"] ?? ""
            result.modeFallback = metrics["mode.fallback"] ?? ""
            result.poolSlots = Int(metrics["pool.capacitySlots"] ?? "") ?? 0
            result.poolBytes = UInt64(metrics["pool.capacityBytes"] ?? "") ?? 0
            result.readsConfigured = metrics["reads.configured"] ?? "unavailable"
            result.readsPeak = metrics["reads.peak"] ?? "unavailable"
            result.readsActiveAtCompletion =
                metrics["reads.activeAtCompletion"] ?? "unavailable"
            result.prefillSeconds =
                Double(metrics["generation.prefillSeconds"] ?? "") ?? 0
            result.ttftSeconds =
                Double(metrics["generation.ttftSeconds"] ?? "") ?? 0
            result.decodeSeconds =
                Double(metrics["generation.decodeSeconds"] ?? "") ?? 0
            result.decodeTokensPerSecond =
                Double(metrics["generation.decodeTokensPerSecond"] ?? "") ?? 0
            result.endToEndTokensPerSecond =
                Double(metrics["generation.endToEndTokensPerSecond"] ?? "") ?? 0
            result.prefillAcquireWaitSeconds = Double(
                metrics["prefill.pool.aggregateAcquireWaitSeconds"] ?? ""
            ) ?? 0
            result.decodeAcquireWaitSeconds = Double(
                metrics["decode.pool.aggregateAcquireWaitSeconds"] ?? ""
            ) ?? 0
            result.chatOverheadSeconds = max(
                0, result.firstVisibleChunkSeconds - result.ttftSeconds
            )
            result.positionAfterPrefill =
                Int(metrics["state.positionAfterPrefill"] ?? "") ?? 0
            result.kvTokensAfterPrefill =
                Int(metrics["state.kvTokensAfterPrefill"] ?? "") ?? 0
            result.kvTokensFinal =
                Int(metrics["state.kvTokensFinal"] ?? "") ?? 0
            result.linearStateBytes =
                Int(metrics["state.linearStateBytes"] ?? "") ?? 0
            result.layerInvocations =
                Int(metrics["state.layerInvocations"] ?? "") ?? 0
            result.expertLoads =
                Int(metrics["state.expertLoads"] ?? "") ?? 0
            result.routerHash = metrics["state.routerHash"] ?? "unavailable"
            result.uniqueExpertTotal =
                Int(metrics["state.uniqueExpertTotal"] ?? "") ?? 0
            result.moeInvocations =
                Int(metrics["state.moeInvocations"] ?? "") ?? 0
            result.mlxActiveBytes =
                Int(metrics["mlx.activeBytes"] ?? "") ?? 0
            result.mlxCacheBytes =
                Int(metrics["mlx.cacheBytes"] ?? "") ?? 0
            result.mlxPeakBytes =
                Int(metrics["mlx.peakBytes"] ?? "") ?? 0
            result.profile = RunProfile(metrics: metrics)
        }
        result.sustainedEvidence =
            result.generatedTokens >= Self.minimumSustainedTokens
        results.append(result)
        return result
    }

    private func withGeneration(
        service: CodingAssistantService,
        messages: [ChatMessage],
        maximumTokens: Int,
        collector: ABStreamCollector
    ) async -> Bool {
        let generation = Task { @MainActor in
            await withCheckedContinuation { continuation in
                collector.attach(continuation)
                service.generate(
                    messages: messages,
                    maxTokensOverride: maximumTokens,
                    temperatureOverride: 0,
                    forceNoThinking: true,
                    onToken: { text in
                        collector.record(chunk: text)
                    },
                    onComplete: { _ in
                        collector.finish()
                    },
                    onError: { message in
                        collector.fail(message)
                    }
                )
            }
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.runTimeoutSeconds * 1_000_000_000)
            )
            if !Task.isCancelled, !collector.isFinished {
                service.stopGeneration()
                collector.fail("Timed out")
            }
        }
        await generation.value
        timeout.cancel()
        return !collector.didTimeOut
    }

    // MARK: Sequence comparison

    private func compareSequences() {
        let scored = results.filter { $0.scored && $0.error == nil }
        guard scored.count >= 2 else { return }
        // Compare every adjacent scored pair: preference-only A/B kinds
        // (eval window, microbatch, advisory prerouter) keep the same mode
        // for all trials and must still prove token-sequence parity.
        for index in 0..<(scored.count - 1) {
            let first = scored[index]
            let second = scored[index + 1]
            let matches = first.fullText == second.fullText
            var difference: Int?
            if !matches {
                let pairs = Array(zip(first.fullText, second.fullText))
                difference = pairs.firstIndex { $0 != $1 }
            }
            for id in [first.id, second.id] {
                if let position = results.firstIndex(where: { $0.id == id }) {
                    results[position].sequenceMatch = matches
                    results[position].firstDifferingIndex = difference
                }
            }
            if !matches {
                status = "Outputs differ at index \(difference ?? -1); comparison invalid."
                return
            }
        }
    }

    // MARK: Decision

    /// Arm groups for drift detection in knob kinds: the per-kind arm
    /// classifier (w1/w4, g1/g4, advisory off/on, readback, readahead
    /// off/on). Order preserves trial order so first→last change is
    /// meaningful within an arm.
    private func knobArmGroups(_ scored: [RunResult]) -> [[RunResult]] {
        switch kind {
        case .evalWindowAB:
            return [
                scored.filter { $0.evalWindowEffective <= 1 },
                scored.filter { $0.evalWindowEffective >= 2 },
            ]
        case .microbatchAB:
            return [
                scored.filter { $0.microbatchEffective <= 1 },
                scored.filter { $0.microbatchEffective >= 2 },
            ]
        case .prerouterAB:
            return [
                scored.filter { !$0.advisoryRequested },
                scored.filter { $0.advisoryRequested },
            ]
        case .computeAB:
            return [
                scored.filter { $0.routerReadbackRequested == 0 },
                scored.filter { $0.routerReadbackRequested == 1 },
            ]
        case .readaheadAB:
            return [
                scored.filter { !$0.readaheadRequested },
                scored.filter { $0.readaheadRequested },
            ]
        default:
            return []
        }
    }

    private var excludedTrials: [RunResult] {
        results.filter { $0.scored && $0.error != nil }
    }

    private func computeDecision() {
        let scored = results.filter { $0.scored && $0.error == nil }
        let exact = scored.filter { $0.mode == .exact }
        let bounded = scored.filter { $0.mode == .boundedPrefetch }

        // A single scored Exact run is a runner-completion check, not a
        // mode comparison.
        if kind == .singleExact {
            guard let run = scored.first else {
                decision = ""
                return
            }
            decision = String(
                format: "Runner completion check: %d/%d scored trial completed · "
                    + "prompt %d · generated %d · decode calls %d · stop %@ · "
                    + "prefill %.2fs · decode %.2f tok/s · effective %@",
                scored.count, kind.scoredPlan.count,
                run.promptTokens, run.generatedTokens, run.decodeCalls,
                run.stopReason, run.prefillSeconds,
                run.decodeTokensPerSecond, run.effectiveMode
            )
            return
        }

        // Population gate. Mode-pair kinds (.ab: exact vs bounded,
        // .prefillAB: bounded vs staged) need their mode populations.
        // Preference-only knob kinds run staged-only plans; their verdicts
        // come from their own arm labels and they gate themselves per arm
        // inside the decision blocks below — a mode-pair gate would
        // dead-end every completed knob run with an empty decision, which
        // is exactly what build 47's device exports showed (four
        // "FINAL — completed 4/4" sessions on 2026-09-17, none with a
        // DECISION section). exactDrift has no decision at all (its output
        // is the drift diagnosis) and intentionally fails this gate.
        let knobKinds: Set<Edge0DiagnosticKind> = [
            .evalWindowAB, .microbatchAB, .prerouterAB, .computeAB,
            .readaheadAB,
        ]
        let staged = scored.filter { $0.mode == .staged }
        guard Edge0DiagnosticPlan.populationGate(
            kind: kind,
            exactCount: exact.count,
            boundedCount: bounded.count,
            stagedCount: staged.count
        ) else {
            decision = ""
            return
        }
        let exactPrefill = exact.map(\.prefillSeconds)
        let boundedPrefill = bounded.map(\.prefillSeconds)
        let exactDecode = exact.map(\.decodeTokensPerSecond)
        let boundedDecode = bounded.map(\.decodeTokensPerSecond)
        let exactDrift = Edge0BenchmarkStatistics.firstToLastChange(exactPrefill)
        let boundedDrift = Edge0BenchmarkStatistics.firstToLastChange(boundedPrefill)
        let stagedDrift = Edge0BenchmarkStatistics.firstToLastChange(
            staged.map(\.prefillSeconds)
        )
        // Drift rule. Mode kinds: first→last prefill change per mode group.
        // Knob kinds: one mode, preference arms — first→last prefill change
        // WITHIN an arm group, so a session that slows overall cannot be
        // read as an arm effect and cannot silently pass either.
        if knobKinds.contains(kind) {
            driftDetected = knobArmGroups(scored).contains { arm in
                Edge0BenchmarkStatistics.firstToLastChange(
                    arm.map(\.prefillSeconds)
                ) > Self.driftThreshold
            }
        } else if kind == .prefillAB {
            driftDetected = boundedDrift > Self.driftThreshold
                || stagedDrift > Self.driftThreshold
        } else {
            driftDetected = exactDrift > Self.driftThreshold
                || boundedDrift > Self.driftThreshold
        }
        sessionLabel = driftDetected
            ? "PERFORMANCE DRIFT PRESENT — MODE COMPARISON INCONCLUSIVE"
            : "Stable session"

        let exactDecodeMedian =
            Edge0BenchmarkStatistics.median(exactDecode) ?? 0
        let boundedDecodeMedian =
            Edge0BenchmarkStatistics.median(boundedDecode) ?? 0
        let exactPrefillMedian =
            Edge0BenchmarkStatistics.median(exactPrefill) ?? 0
        let boundedPrefillMedian =
            Edge0BenchmarkStatistics.median(boundedPrefill) ?? 0
        let decodeDelta = exactDecodeMedian > 0
            ? (boundedDecodeMedian - exactDecodeMedian) / exactDecodeMedian * 100
            : 0
        let sustained = scored.allSatisfy(\.sustainedEvidence)

        var lines = [sessionLabel]
        if kind == .ab {
            lines.append(
                String(
                    format: "Exact: prefill median %.1fs (%@) · decode median %.2f tok/s (%@)",
                    exactPrefillMedian, Self.list(exactPrefill),
                    exactDecodeMedian, Self.list(exactDecode)
                )
            )
            lines.append(
                String(
                    format: "Bounded: prefill median %.1fs (%@) · decode median %.2f tok/s (%@) · %+.1f%% vs Exact",
                    boundedPrefillMedian, Self.list(boundedPrefill),
                    boundedDecodeMedian, Self.list(boundedDecode), decodeDelta
                )
            )
        }
        if kind == .microbatchAB {
            let group1 = scored.filter { $0.microbatchEffective <= 1 }
            let group4 = scored.filter { $0.microbatchEffective >= 2 }
            guard group1.count >= 2, group4.count >= 2 else {
                decision = "Insufficient g1/g4 trials for a decision."
                return
            }
            func gmed(_ values: [Double]) -> Double {
                Edge0BenchmarkStatistics.median(values) ?? 0
            }
            let g1Prefill = gmed(group1.map(\.prefillSeconds))
            let g4Prefill = gmed(group4.map(\.prefillSeconds))
            let g1TTFT = gmed(group1.map(\.ttftSeconds))
            let g4TTFT = gmed(group4.map(\.ttftSeconds))
            let g1Decode = gmed(group1.map(\.decodeTokensPerSecond))
            let g4Decode = gmed(group4.map(\.decodeTokensPerSecond))
            let prefillDelta = g1Prefill > 0
                ? (g4Prefill - g1Prefill) / g1Prefill * 100 : 0
            let ttftDelta = g1TTFT > 0
                ? (g4TTFT - g1TTFT) / g1TTFT * 100 : 0
            let decodeDelta = g1Decode > 0
                ? (g4Decode - g1Decode) / g1Decode * 100 : 0
            var lines = [
                "Staged microbatch A/B (g1 = production, g4 = candidate)",
                String(
                    format: "g1 prefill median %.2fs · TTFT %.2fs · decode %.2f tok/s · routed groups %@",
                    g1Prefill, g1TTFT, g1Decode,
                    group1.first.map { "\($0.routedGroups)" } ?? "?"
                ),
                String(
                    format: "g4 prefill median %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%) · routed groups %@",
                    g4Prefill, prefillDelta, g4TTFT, ttftDelta,
                    g4Decode, decodeDelta,
                    group4.first.map { "\($0.routedGroups)" } ?? "?"
                ),
                driftDetected
                    ? "drift present — treat the comparison as inconclusive"
                    : (prefillDelta <= -5 && decodeDelta >= -5
                        ? "candidate meets the acceptance rule; confirm on device before promotion"
                        : "candidate does not meet the prefill/decode acceptance rule; reject and keep g1"),
            ]
            let configurations = scored.map {
                "\($0.microbatchRequested)→\($0.microbatchEffective)"
            }
            lines.append("requested→effective groups: \(configurations)")
            decision = lines.joined(separator: "\n")
            return
        }

        if kind == .computeAB {
            let production = scored.filter { $0.routerReadbackRequested == 0 }
            let requested = scored.filter { $0.routerReadbackRequested == 1 }
            let blocked = requested.filter { $0.routerReadbackEffective != 1 }
            let candidate = requested.filter { $0.routerReadbackEffective == 1 }
            if !blocked.isEmpty && candidate.count < 2 {
                decision = [
                    "SETUP-BLOCKED — not a performance result.",
                    "Requested the candidate in \(requested.count) trial(s); it was INEFFECTIVE in \(blocked.count) (staged·microbatch prefill is required).",
                ].joined(separator: "\n")
                return
            }
            guard production.count >= 2, candidate.count >= 2 else {
                decision = "Insufficient production/candidate trials for a decision."
                return
            }
            func cmed(_ values: [Double]) -> Double {
                Edge0BenchmarkStatistics.median(values) ?? 0
            }
            let pPrefill = cmed(production.map(\.prefillSeconds))
            let cPrefill = cmed(candidate.map(\.prefillSeconds))
            let pTTFT = cmed(production.map(\.ttftSeconds))
            let cTTFT = cmed(candidate.map(\.ttftSeconds))
            let pVisible = cmed(production.map(\.firstVisibleChunkSeconds))
            let cVisible = cmed(candidate.map(\.firstVisibleChunkSeconds))
            let pDecode = cmed(production.map(\.decodeTokensPerSecond))
            let cDecode = cmed(candidate.map(\.decodeTokensPerSecond))
            let prefillDelta = pPrefill > 0
                ? (cPrefill - pPrefill) / pPrefill * 100 : 0
            let ttftDelta = pTTFT > 0 ? (cTTFT - pTTFT) / pTTFT * 100 : 0
            let visibleDelta = pVisible > 0
                ? (cVisible - pVisible) / pVisible * 100 : 0
            let decodeDelta = pDecode > 0
                ? (cDecode - pDecode) / pDecode * 100 : 0
            let seqProduction =
                production.filter { $0.sequenceMatch == true }.count
            let seqCandidate =
                candidate.filter { $0.sequenceMatch == true }.count
            let lines = [
                "35B Compute A/B (production = per-token router readback, candidate = batched readback)",
                String(
                    format: "production prefill %.2fs · TTFT %.2fs · first visible %.2fs · decode %.2f tok/s",
                    pPrefill, pTTFT, pVisible, pDecode
                ),
                String(
                    format: "candidate  prefill %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · first visible %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%)",
                    cPrefill, prefillDelta, cTTFT, ttftDelta,
                    cVisible, visibleDelta, cDecode, decodeDelta
                ),
                "token-sequence parity: production \(seqProduction)/\(production.count) · candidate \(seqCandidate)/\(candidate.count)",
                "requested→effective strategy: "
                    + scored.map { "\($0.routerReadbackRequested)→\($0.routerReadbackEffective)" }
                        .joined(separator: ", "),
                blocked.isEmpty
                    ? "all requested candidate trials were effective"
                    : "WARNING: \(blocked.count) candidate trial(s) were INACTIVE",
                driftDetected
                    ? "drift present — treat the comparison as inconclusive"
                    : (prefillDelta <= -5 && ttftDelta <= -5
                        && visibleDelta <= 0 && decodeDelta >= -5
                        ? "candidate meets the acceptance rule; confirm on device before promotion"
                        : "candidate does not meet the prefill/TTFT acceptance rule; reject and keep production"),
            ]
            decision = lines.joined(separator: "\n")
            return
        }

        if kind == .prerouterAB {
            let off = scored.filter { !$0.advisoryRequested }
            let requestedOn = scored.filter { $0.advisoryRequested }
            let blocked = requestedOn.filter { !$0.advisoryActive }
            let on = requestedOn.filter { $0.advisoryActive }
            if !blocked.isEmpty && on.count < 2 {
                let reasons = Set(blocked.map {
                    $0.advisoryFallbackReason.isEmpty
                        ? "unspecified" : $0.advisoryFallbackReason
                }).sorted().joined(separator: "; ")
                decision = [
                    "SETUP-BLOCKED — not a performance result.",
                    "Requested On in \(requestedOn.count) trial(s); the learned predictor was INACTIVE in \(blocked.count) of them.",
                    "Reason(s): \(reasons).",
                    "Artifact present: \(blocked.map { $0.advisoryArtifactPresent ? "yes" : "no" }.joined(separator: "/")) · valid: \(blocked.map { $0.advisoryArtifactValid ? "yes" : "no" }.joined(separator: "/")) · heads: \(blocked.map { "\($0.advisoryHeadCount)" }.joined(separator: "/")).",
                    "Fix the artifact/loading state, then deliver one correctly labeled testable build; do not compare timings.",
                ].joined(separator: "\n")
                return
            }
            guard off.count >= 2, on.count >= 2 else {
                decision = "Insufficient advisory off/on trials for a decision."
                return
            }
            func pmed(_ values: [Double]) -> Double {
                Edge0BenchmarkStatistics.median(values) ?? 0
            }
            let offPrefill = pmed(off.map(\.prefillSeconds))
            let onPrefill = pmed(on.map(\.prefillSeconds))
            let offTTFT = pmed(off.map(\.ttftSeconds))
            let onTTFT = pmed(on.map(\.ttftSeconds))
            let offDecode = pmed(off.map(\.decodeTokensPerSecond))
            let onDecode = pmed(on.map(\.decodeTokensPerSecond))
            let prefillDelta = offPrefill > 0
                ? (onPrefill - offPrefill) / offPrefill * 100 : 0
            let ttftDelta = offTTFT > 0
                ? (onTTFT - offTTFT) / offTTFT * 100 : 0
            let decodeDelta = offDecode > 0
                ? (onDecode - offDecode) / offDecode * 100 : 0
            let predicted = on.map(\.advisoryPredictedExperts).reduce(0, +)
            let correct = on.map(\.advisoryCorrect).reduce(0, +)
            let trueExperts = on.map(\.advisoryTrueExperts).reduce(0, +)
            let ready = on.map(\.advisoryReady).reduce(0, +)
            let started = on.map(\.advisoryPrefetchStarted).reduce(0, +)
            let completed = on.map(\.advisoryPrefetchCompleted).reduce(0, +)
            let runtimeFallbacks =
                on.map(\.advisoryRuntimeFallbacks).reduce(0, +)
            let headInvocations =
                on.map(\.advisoryHeadInvocations).reduce(0, +)
            let prefillPredictions =
                on.map(\.advisoryPrefillPredictions).reduce(0, +)
            let decodePredictions =
                on.map(\.advisoryDecodePredictions).reduce(0, +)
            let inferredMisses = on.map {
                $0.advisoryTrueExperts - $0.advisoryCorrect
            }.reduce(0, +)
            let seqOff = off.filter { $0.sequenceMatch == true }.count
            let seqOn = on.filter { $0.sequenceMatch == true }.count
            var lines = [
                "35B Prerouter A/B (off = production staged g4, on = advisory)",
                String(
                    format: "off prefill median %.2fs · TTFT %.2fs · decode %.2f tok/s",
                    offPrefill, offTTFT, offDecode
                ),
                String(
                    format: "on  prefill median %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%)",
                    onPrefill, prefillDelta, onTTFT, ttftDelta,
                    onDecode, decodeDelta
                ),
                String(
                    format: "advisory: heads %d · predictions %d (prefill %d / decode %d) · predicted %d · correct %d · true %d · ready %d · inferred misses %d · speculative reads %d/%d · runtime fallbacks %d",
                    headInvocations, decodePredictions + prefillPredictions,
                    prefillPredictions, decodePredictions,
                    predicted, correct, trueExperts, ready, inferredMisses,
                    completed, started, runtimeFallbacks
                ),
                "effective activation: artifact present "
                    + (on.allSatisfy(\.advisoryArtifactPresent) ? "yes" : "NO")
                    + " · valid " + (on.allSatisfy(\.advisoryArtifactValid)
                        ? "yes" : "NO")
                    + " · heads \(on.first.map { "\($0.advisoryHeadCount)" } ?? "?")"
                    + " · loaded \(Self.bytes(Int64(on.first?.advisoryLoadedBytes ?? 0)))",
                "phase scope: prefill predictions \(prefillPredictions == 0 ? "NONE — decode-only predictor" : "\(prefillPredictions)")",
                "token-sequence parity: off \(seqOff)/\(off.count) · on \(seqOn)/\(on.count)",
                blocked.isEmpty
                    ? "all requested-On trials were effective"
                    : "WARNING: \(blocked.count) requested-On trial(s) were INACTIVE and excluded",
                on.contains(where: { !$0.advisoryActive })
                    ? "advisory was requested but INACTIVE in an 'on' trial — artifact missing; treat as blocked, not a result"
                    : (driftDetected
                        ? "drift present — treat the comparison as inconclusive"
                        : (prefillDelta <= -5 && ttftDelta <= -5 && decodeDelta >= -5
                            ? "candidate meets the acceptance rule; confirm on device before promotion"
                            : "candidate does not meet the prefill/TTFT/decode acceptance rule; reject and keep advisory OFF")),
            ]
            let configurations = scored.map {
                "\($0.advisoryRequested ? "req" : "off")→\($0.advisoryActive ? "active" : "inactive")"
            }
            lines.append("requested→active: \(configurations)")
            decision = lines.joined(separator: "\n")
            return
        }

        if kind == .evalWindowAB {
            let window1 = scored.filter { $0.evalWindowEffective <= 1 }
            let window4 = scored.filter { $0.evalWindowEffective >= 2 }
            guard window1.count >= 2, window4.count >= 2 else {
                decision = "Insufficient w1/w4 trials for a decision."
                return
            }
            func med(_ values: [Double]) -> Double {
                Edge0BenchmarkStatistics.median(values) ?? 0
            }
            let w1Prefill = med(window1.map(\.prefillSeconds))
            let w4Prefill = med(window4.map(\.prefillSeconds))
            let w1TTFT = med(window1.map(\.ttftSeconds))
            let w4TTFT = med(window4.map(\.ttftSeconds))
            let w1Decode = med(window1.map(\.decodeTokensPerSecond))
            let w4Decode = med(window4.map(\.decodeTokensPerSecond))
            let prefillDelta = w1Prefill > 0
                ? (w4Prefill - w1Prefill) / w1Prefill * 100 : 0
            let ttftDelta = w1TTFT > 0
                ? (w4TTFT - w1TTFT) / w1TTFT * 100 : 0
            let decodeDelta = w1Decode > 0
                ? (w4Decode - w1Decode) / w1Decode * 100 : 0
            var lines = [
                "Staged eval-window A/B (w1 = production, w4 = candidate)",
                String(
                    format: "w1 prefill median %.2fs · TTFT %.2fs · decode %.2f tok/s",
                    w1Prefill, w1TTFT, w1Decode
                ),
                String(
                    format: "w4 prefill median %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%)",
                    w4Prefill, prefillDelta, w4TTFT, ttftDelta,
                    w4Decode, decodeDelta
                ),
                driftDetected
                    ? "drift present — treat the comparison as inconclusive"
                    : (prefillDelta <= -5 && decodeDelta >= -5
                        ? "candidate meets the acceptance rule; confirm on device before promotion"
                        : "candidate does not meet the prefill/decode acceptance rule; keep w1"),
            ]
            let windows = Set(scored.map(\.evalWindowEffective)).sorted()
            lines.append("effective windows observed: \(windows)")
            decision = lines.joined(separator: "\n")
            return
        }

        if kind == .readaheadAB {
            let off = scored.filter { !$0.readaheadRequested }
            let requestedOn = scored.filter { $0.readaheadRequested }
            // Effective half comes from the engine's load-captured state:
            // requested-on without effective-on means the arm's engine was
            // not reloaded after the preference changed — the number one
            // way this A/B would silently compare off-vs-off.
            let blocked = requestedOn.filter { !$0.readaheadEffective }
            let on = requestedOn.filter { $0.readaheadEffective }
            if !blocked.isEmpty {
                decision = [
                    "SETUP-BLOCKED — not a performance result.",
                    "Requested readahead ON in \(blocked.count) trial(s); the "
                    + "engine's load-captured state says hints were NOT "
                    + "active in them (arm requires an engine RELOAD after "
                    + "the preference change).",
                    "requested→effective: " + scored.map {
                        "\($0.readaheadRequested ? "on" : "off")→"
                            + "\($0.readaheadEffective ? "on" : "off")"
                    }.joined(separator: ", "),
                    "Fix the reload lifecycle, then rerun; do not compare timings.",
                ].joined(separator: "\n")
                return
            }
            guard off.count >= 2, on.count >= 2 else {
                decision = "Insufficient readahead off/on trials for a decision."
                return
            }
            func rmed(_ values: [Double]) -> Double {
                Edge0BenchmarkStatistics.median(values) ?? 0
            }
            let offPrefill = rmed(off.map(\.prefillSeconds))
            let onPrefill = rmed(on.map(\.prefillSeconds))
            let offTTFT = rmed(off.map(\.ttftSeconds))
            let onTTFT = rmed(on.map(\.ttftSeconds))
            let offDecode = rmed(off.map(\.decodeTokensPerSecond))
            let onDecode = rmed(on.map(\.decodeTokensPerSecond))
            let prefillDelta = offPrefill > 0
                ? (onPrefill - offPrefill) / offPrefill * 100 : 0
            let ttftDelta = offTTFT > 0
                ? (onTTFT - offTTFT) / offTTFT * 100 : 0
            let decodeDelta = offDecode > 0
                ? (onDecode - offDecode) / offDecode * 100 : 0
            let seqOff = off.filter { $0.sequenceMatch == true }.count
            let seqOn = on.filter { $0.sequenceMatch == true }.count
            let accepted = Edge0DiagnosticPlan.readaheadAcceptance(
                prefillDeltaPercent: prefillDelta,
                ttftDeltaPercent: ttftDelta,
                decodeDeltaPercent: decodeDelta
            )
            let lines = [
                "35B Readahead A/B (off = production, on = F_RDADVISE hints)",
                String(
                    format: "off prefill median %.2fs · TTFT %.2fs · decode %.2f tok/s",
                    offPrefill, offTTFT, offDecode
                ),
                String(
                    format: "on  prefill median %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%)",
                    onPrefill, prefillDelta, onTTFT, ttftDelta,
                    onDecode, decodeDelta
                ),
                "arm effectiveness: all requested-on trials load-captured ON",
                "token-sequence parity: off \(seqOff)/\(off.count) · on \(seqOn)/\(on.count)",
                driftDetected
                    ? "drift present — treat the comparison as inconclusive"
                    : (accepted
                        ? "candidate meets the readahead acceptance rule (decode +5%, prefill/TTFT ≥ −5%); confirm on device before promotion"
                        : "candidate does not meet the readahead acceptance rule; keep hints OFF"),
            ]
            decision = lines.joined(separator: "\n")
            return
        }

        if kind == .prefillAB {
            let boundedPrefill = bounded.map(\.prefillSeconds)
            let stagedPrefill = scored
                .filter { $0.mode == .staged }.map(\.prefillSeconds)
            let boundedTTFT = bounded.map(\.ttftSeconds)
            let stagedTTFT = scored
                .filter { $0.mode == .staged }.map(\.ttftSeconds)
            guard let boundedPrefillMedian = Edge0BenchmarkStatistics.median(boundedPrefill),
                  let stagedPrefillMedian = Edge0BenchmarkStatistics.median(stagedPrefill),
                  let boundedTTFTMedian = Edge0BenchmarkStatistics.median(boundedTTFT),
                  let stagedTTFTMedian = Edge0BenchmarkStatistics.median(stagedTTFT) else {
                decision = "Insufficient staged/bounded trials for a prefill decision."
                return
            }
            let boundedDecodeMedian = Edge0BenchmarkStatistics.median(boundedDecode) ?? 0
            let stagedDecode = scored.filter { $0.mode == .staged }
                .map(\.decodeTokensPerSecond)
            let stagedDecodeMedian = Edge0BenchmarkStatistics.median(stagedDecode) ?? 0
            let prefillDelta = boundedPrefillMedian > 0
                ? (stagedPrefillMedian - boundedPrefillMedian) / boundedPrefillMedian * 100
                : 0
            let ttftDelta = boundedTTFTMedian > 0
                ? (stagedTTFTMedian - boundedTTFTMedian) / boundedTTFTMedian * 100
                : 0
            let decodeDelta = boundedDecodeMedian > 0
                ? (stagedDecodeMedian - boundedDecodeMedian) / boundedDecodeMedian * 100
                : 0
            var lines = [
                "Prefill A/B — bounded vs staged (primary metric: prefill/TTFT)",
                String(
                    format: "bounded prefill median %.2fs · TTFT %.2fs · decode %.2f tok/s",
                    boundedPrefillMedian, boundedTTFTMedian, boundedDecodeMedian
                ),
                String(
                    format: "staged prefill median %.2fs (%+.1f%%) · TTFT %.2fs (%+.1f%%) · decode %.2f tok/s (%+.1f%%)",
                    stagedPrefillMedian, prefillDelta,
                    stagedTTFTMedian, ttftDelta,
                    stagedDecodeMedian, decodeDelta
                ),
                driftDetected
                    ? "drift present — treat the comparison as inconclusive"
                    : (prefillDelta <= -5
                        ? "staged prefill shows a repeatable improvement; candidate for promotion after device confirmation"
                        : "no demonstrated prefill benefit; keep boundedPrefetch"),
            ]
            if !excludedTrials.isEmpty {
                lines.append(
                    "Excluded trials: "
                        + excludedTrials.map { "\($0.label) — \($0.error ?? "unknown")" }
                            .joined(separator: "; ")
                )
            }
            decision = lines.joined(separator: "\n")
            return
        }

        if !excludedTrials.isEmpty {
            lines.append(
                "Excluded trials: "
                    + excludedTrials.map {
                        "\($0.label) — \($0.error ?? "unknown")"
                    }.joined(separator: "; ")
            )
        }
        if driftDetected {
            lines.append(
                "Both modes slowed across identical requests; the mode difference is not interpretable from this session."
            )
        } else if !sustained {
            lines.append(
                "Insufficient sustained-throughput evidence (<\(Self.minimumSustainedTokens) tokens in some runs)."
            )
        } else if decodeDelta >= 5 {
            lines.append(
                "Bounded Prefetch improved sustained decode; candidate for production after a repeat session."
            )
        } else {
            lines.append(
                "No reliable sustained-decode benefit demonstrated; keep Exact as the production default."
            )
        }
        decision = lines.joined(separator: "\n")
    }

    /// First-vs-last per-component comparison for the same mode: where did
    /// the extra time go during the degraded trial?
    private func computeDriftDiagnosis() {
        let scored = results.filter { $0.scored && $0.error == nil }
        guard scored.count >= 2 else {
            driftDiagnosis = ""
            return
        }
        for mode in [Edge0ExecutionMode.exact, .boundedPrefetch] {
            let runs = scored.filter { $0.mode == mode }
            guard let first = runs.first, let last = runs.last,
                  runs.count >= 2 else { continue }
            func delta(_ a: Double, _ b: Double) -> String {
                b - a >= 0.05
                    ? String(format: "%+.2fs", b - a)
                    : String(format: "%+.3fs", b - a)
            }
            var lines = [
                "\(mode == .exact ? "Exact" : "Bounded"): prefill "
                    + String(format: "%.2fs → %.2fs (%@)", first.prefillSeconds,
                             last.prefillSeconds,
                             delta(first.prefillSeconds, last.prefillSeconds))
                    + " · decode " + String(format: "%.2f → %.2f tok/s", first.decodeTokensPerSecond, last.decodeTokensPerSecond),
                "  workload identity: "
                    + (first.profile.prefillRoutedSamples > 0
                        ? (first.routerHash == last.routerHash
                            ? "router hash identical" : "router hash DIFFERS")
                        : "not collected (unprofiled run)")
                    + " · MoE invocations \(first.moeInvocations) → \(last.moeInvocations)"
                    + " · unique-expert selections \(first.uniqueExpertTotal) → \(last.uniqueExpertTotal)"
                    + " · expert loads \(first.expertLoads) → \(last.expertLoads)",
                "  MoE sub-phases prefill (first → last):"
                    + " acquire \(delta(first.profile.prefillMoEAcquire, last.profile.prefillMoEAcquire))"
                    + " · stack \(delta(first.profile.prefillMoEStackBuild, last.profile.prefillMoEStackBuild))"
                    + " · routed \(delta(first.profile.prefillMoERouted, last.profile.prefillMoERouted))"
                    + " · shared \(delta(first.profile.prefillMoEShared, last.profile.prefillMoEShared))"
                    + " · combine \(delta(first.profile.prefillMoECombine, last.profile.prefillMoECombine))"
                    + " · eval \(delta(first.profile.prefillMoEEval, last.profile.prefillMoEEval))"
                    + " · release \(delta(first.profile.prefillMoERelease, last.profile.prefillMoERelease))",
                "  MoE by layer band (first → last): early "
                    + delta(first.profile.prefillMoEEarly, last.profile.prefillMoEEarly)
                    + " · middle "
                    + delta(first.profile.prefillMoEMiddle, last.profile.prefillMoEMiddle)
                    + " · late "
                    + delta(first.profile.prefillMoELate, last.profile.prefillMoELate),
                "  MLX memory (first → last): active "
                    + Self.bytes(Int64(first.mlxActiveBytes)) + " → "
                    + Self.bytes(Int64(last.mlxActiveBytes))
                    + " · cache " + Self.bytes(Int64(first.mlxCacheBytes)) + " → "
                    + Self.bytes(Int64(last.mlxCacheBytes))
                    + " · peak " + Self.bytes(Int64(last.mlxPeakBytes)),
                "  prefill components (first → last):"
                    + " gatedDeltaNet \(delta(first.profile.prefillGatedDeltaNet, last.profile.prefillGatedDeltaNet))"
                    + " · fullAttention \(delta(first.profile.prefillFullAttention, last.profile.prefillFullAttention))"
                    + " · router \(delta(first.profile.prefillRouter, last.profile.prefillRouter))"
                    + " · moe \(delta(first.profile.prefillMoE, last.profile.prefillMoE))"
                    + " · embed \(delta(first.profile.prefillEmbedding, last.profile.prefillEmbedding))"
                    + " · lmHead \(delta(first.profile.prefillLmHead, last.profile.prefillLmHead))"
                    + " · sampling \(delta(first.profile.prefillSampling, last.profile.prefillSampling))",
                "  decode components (first → last):"
                    + " gatedDeltaNet \(delta(first.profile.decodeGatedDeltaNet, last.profile.decodeGatedDeltaNet))"
                    + " · fullAttention \(delta(first.profile.decodeFullAttention, last.profile.decodeFullAttention))"
                    + " · router \(delta(first.profile.decodeRouter, last.profile.decodeRouter))"
                    + " · moe \(delta(first.profile.decodeMoE, last.profile.decodeMoE))"
                    + " · lmHead \(delta(first.profile.decodeLmHead, last.profile.decodeLmHead))"
                    + " · sampling \(delta(first.profile.decodeSampling, last.profile.decodeSampling))",
            ]
            if let idle = runs.dropFirst().first?.idleSecondsBefore {
                lines.append(String(
                    format: "  recovery before the later trial: %.0fs idle", idle
                ))
            }
            driftDiagnosis = lines.joined(separator: "\n")
            return
        }
    }

    /// Accurate per-mode label for reports (never collapse staged into
    /// "Bounded").
    static func label(for mode: Edge0ExecutionMode) -> String {
        switch mode {
        case .exact: return "Exact"
        case .boundedPrefetch: return "Bounded"
        case .staged: return "Staged"
        case .stagedPrerouter: return "StagedPrerouter"
        }
    }

    private static func list(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    // MARK: Export

    var summaryText: String {
        let label = Edge0DiagnosticPlan.exportLabel(
            terminal: terminal, completedScoredTrials: completedTrials
        )
        var lines = [
            "Edge0-35B Speed Diagnostic",
            "run: \(runID.uuidString) · kind: \(kind.rawValue)",
            "export: \(label)",
            "phase: \(phase.rawValue) · terminal: \(terminal?.rawValue ?? "in progress")"
                + (terminalReason.isEmpty ? "" : " — \(terminalReason)"),
            "scored trials: \(completedTrials)/\(plannedTrials)"
                + " · last completed: \(lastCompletedStep)",
            "profile: 512 MiB pool (expected \(Self.expectedSlots) slots) · reads 4 · thinking off · greedy · max \(Self.maximumOutputTokens) tokens",
            "recovery: minimum \(recoverySeconds)s idle before every scored trial (bounded, cancellable)",
            "prompt: \(Self.benchmarkPrompt)",
            String(format: "load: %.2fs", loadedSeconds),
            sessionLabel,
            "",
        ]
        for run in results {
            lines.append("\(run.label) [\(run.mode.rawValue)]\(run.scored ? "" : " (unscored)")")
            if let error = run.error {
                lines.append("  ERROR: \(error)")
            }
            lines.append(
                "  prompt \(run.promptTokens) · generated \(run.generatedTokens)"
                + " · decode calls \(run.decodeCalls) · stop \(run.stopReason)"
                + " · thinking \(run.thinkingEnabled)"
            )
            lines.append(
                "  requested \(run.requestedMode) · effective \(run.effectiveMode)"
                + " · prefill \(run.prefillMode.isEmpty ? run.effectiveMode : run.prefillMode)"
                + " · decode \(run.decodeMode.isEmpty ? run.effectiveMode : run.decodeMode)"
                + " · eval window requested \(run.evalWindowRequested)/effective \(run.evalWindowEffective)"
                + " · microbatch requested \(run.microbatchRequested)/effective \(run.microbatchEffective)"
                + " · router readback requested \(run.routerReadbackRequested)/effective \(run.routerReadbackEffective)"
                + " · readahead requested \(run.readaheadRequested ? "on" : "off")/effective \(run.readaheadEffective ? "on" : "off")"
                + " · routed groups \(run.routedGroups)"
                + " · peak active leases \(run.peakActiveLeases)"
                + " · handoff inFlight \(run.handoffInFlightBefore)→\(run.handoffInFlightAfter)"
                + " · advisory loads this run \(run.handoffAdvisoryLoads)"
                + " (pool lifetime total \(run.advisoryLoadsLifetime))"
                + (run.modeFallback.isEmpty ? "" : " · fallback \(run.modeFallback)")
                + " · pool \(run.poolSlots)/\(run.poolBytes) B"
                + " · reads configured \(run.readsConfigured) peak \(run.readsPeak) active@end \(run.readsActiveAtCompletion)"
            )
            lines.append(String(
                format: "  prefill %.3fs · TTFT %.3fs · first visible %.3fs (chat overhead %.3fs) · decode %.3fs · %.2f tok/s · end-to-end %.2f tok/s",
                run.prefillSeconds, run.ttftSeconds,
                run.firstVisibleChunkSeconds, run.chatOverheadSeconds,
                run.decodeSeconds, run.decodeTokensPerSecond,
                run.endToEndTokensPerSecond
            ))
            lines.append(String(
                format: "  acquire wait (aggregate, overlapping): prefill %.3fs · decode %.3fs",
                run.prefillAcquireWaitSeconds, run.decodeAcquireWaitSeconds
            ))
            if run.moeInvocations == 0, run.profile.prefillEvalSamples == 0 {
                lines.append(
                    "  workload identity: not collected (unprofiled run)"
                )
            } else {
                lines.append(
                    "  workload: router-hash \(run.routerHash)"
                    + " · moe-invocations \(run.moeInvocations)"
                    + " · unique-expert \(run.uniqueExpertTotal)"
                    + " · mlx active/cache/peak "
                    + Self.bytes(Int64(run.mlxActiveBytes)) + "/"
                    + Self.bytes(Int64(run.mlxCacheBytes)) + "/"
                    + Self.bytes(Int64(run.mlxPeakBytes))
                )
            }
            lines.append(
                "  state: position-after-prefill \(run.positionAfterPrefill)"
                + " · kv-after-prefill \(run.kvTokensAfterPrefill)"
                + " · kv-final \(run.kvTokensFinal)"
                + " · linear-state-bytes \(run.linearStateBytes)"
                + " · layer-invocations \(run.layerInvocations)"
                + " · expert-loads \(run.expertLoads)"
            )
            lines.append(
                "  idle-before " + String(format: "%.0fs", run.idleSecondsBefore)
                + " (\(run.recoveryReason))"
                + " · boundary-before \(run.boundaryBefore)"
                + " · thermal \(run.thermalStart) → \(run.thermalEnd)"
                + " · footprint \(Self.bytes(run.footprintBefore))/\(Self.bytes(run.footprintAfter))/\(Self.bytes(run.peakFootprint))"
                + (run.sustainedEvidence ? "" : " · sustained evidence insufficient")
            )
            if let match = run.sequenceMatch {
                lines.append(
                    "  sequence match: \(match ? "identical" : "DIFFERS")"
                    + (match ? "" : " at \(run.firstDifferingIndex.map(String.init) ?? "?")")
                )
            }
        }
        let profiledRuns = results.filter { $0.scored && !$0.profile.isEmpty }
        if !profiledRuns.isEmpty {
            lines.append("")
            lines.append("MOE ABSOLUTE TIMES (profiled runs; UNAVAILABLE = timer had no samples)")
            func format(_ value: Double, samples: Double) -> String {
                samples > 0 ? String(format: "%.3f", value) : "UNAVAILABLE"
            }
            for run in profiledRuns {
                let p = run.profile
                let known = p.prefillMoEAcquire
                    + p.prefillMoEStackBuild
                    + p.prefillMoERouted
                    + p.prefillMoEShared
                    + p.prefillMoECombine
                    + p.prefillMoEEval
                    + p.prefillMoERelease
                let unclassified = p.prefillMoE - known
                lines.append("\(run.label):")
                lines.append(
                    "  total " + format(p.prefillMoE, samples: p.prefillEvalSamples)
                    + " · acquire " + format(p.prefillMoEAcquire, samples: p.prefillAcquireSamples)
                    + " · stack " + format(p.prefillMoEStackBuild, samples: p.prefillStackSamples)
                    + " · routed " + format(p.prefillMoERouted, samples: p.prefillRoutedSamples)
                    + " · shared " + format(p.prefillMoEShared, samples: p.prefillSharedSamples)
                    + " · combine " + format(p.prefillMoECombine, samples: p.prefillCombineSamples)
                    + " · eval " + format(p.prefillMoEEval, samples: p.prefillEvalSamples)
                    + " · release " + format(p.prefillMoERelease, samples: p.prefillReleaseSamples)
                )
                lines.append(String(
                    format: "  unclassified %.3f · layer bands early %.3f · middle %.3f · late %.3f · samples per timer: acq %.0f stack %.0f routed %.0f shared %.0f combine %.0f eval %.0f release %.0f",
                    unclassified,
                    p.prefillMoEEarly, p.prefillMoEMiddle, p.prefillMoELate,
                    p.prefillAcquireSamples, p.prefillStackSamples,
                    p.prefillRoutedSamples, p.prefillSharedSamples,
                    p.prefillCombineSamples, p.prefillEvalSamples,
                    p.prefillReleaseSamples
                ))
            }
        }
        if !driftDiagnosis.isEmpty {
            lines.append("")
            lines.append("DRIFT DIAGNOSIS")
            lines.append(driftDiagnosis)
        }
        if !decision.isEmpty {
            lines.append("")
            lines.append("DECISION")
            lines.append(decision)
        }
        return lines.joined(separator: "\n")
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

// MARK: - Stream collector

/// Lock-based (not actor-isolated) so token delivery takes no MainActor hop:
/// the production service already calls onToken from its main-actor task, and
/// this removes one scheduling hop per chunk from the measured delivery path.
private final class ABStreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var _text = ""
    private var _firstChunkSeconds: TimeInterval?
    private var _error: String?
    private var _peakFootprint: Int64 = 0
    private var _isFinished = false
    private var _didTimeOut = false
    private let started = ContinuousClock.now
    private var sampler: Task<Void, Never>?

    var firstChunkSeconds: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return _firstChunkSeconds
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return _text
    }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return _error
    }

    var peakFootprint: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _peakFootprint
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isFinished
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didTimeOut
    }

    func record(chunk: String) {
        lock.lock()
        if _isFinished {
            lock.unlock()
            return
        }
        let isFirst = _firstChunkSeconds == nil
        if isFirst { _firstChunkSeconds = started.duration(to: .now).seconds }
        _text += chunk
        lock.unlock()
        if isFirst { startSampler() }
    }

    func finish() {
        lock.lock()
        _isFinished = true
        _peakFootprint = max(_peakFootprint, MemoryAdvisor.physFootprint)
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        sampler?.cancel()
        continuation?.resume()
    }

    func fail(_ message: String) {
        lock.lock()
        if message == "Timed out" { _didTimeOut = true }
        _error = message
        _isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        sampler?.cancel()
        continuation?.resume()
    }

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func startSampler() {
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.samplePeakFootprint()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    /// Sync snapshot so the sampler task never touches `lock` from an
    /// asynchronous context (a Swift 6 error otherwise).
    private func samplePeakFootprint() {
        lock.lock()
        _peakFootprint = max(_peakFootprint, MemoryAdvisor.physFootprint)
        lock.unlock()
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

private extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
