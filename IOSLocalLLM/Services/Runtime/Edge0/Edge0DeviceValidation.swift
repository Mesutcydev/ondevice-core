import Foundation
import SwiftUI
import Darwin

// MARK: - Edge0DeviceValidationRunner
//
// Physical-device A→Z validation for the Edge0-8B product flow. Every stage
// drives the PRODUCTION path — CodingAssistantService → RuntimeEngineFactory
// → ManagedRuntimeEngine → Edge0RuntimeBackend → Edge0Engine — never a
// test-only model instance.
//
// Privacy: the runner records counts, timings, and state only. It never logs
// prompt text, generated text, or conversation contents. The one prompt it
// sends is a hardcoded public developer string.
//
// Measurement boundaries (Phase 4A baseline):
//   load      = switchTo() call -> service reports the model resident
//   TTFT      = generate() call -> first streamed chunk (app-visible)
//   prefill   = engine `model.prefill` call only (engine metrics)
//   decode    = first sampled token -> generation end; tok/s = (n-1)/decode
//   footprint = MemoryAdvisor.physFootprint samples during the stream

@MainActor
final class Edge0DeviceValidationRunner: ObservableObject {

    // MARK: Stages

    enum Stage: Int, CaseIterable, Identifiable, Sendable {
        case modelDiscovered = 1
        case artifactsValidated
        case admissionAccepted
        case runtimeConstructed
        case modelLoadCompleted
        case promptTokenized
        case prefillCompleted
        case firstTokenEmitted
        case tokensGenerated
        case exactReferenceParity
        case sessionReuseParity
        case cancellationWorked
        case generationAfterCancellation
        case unloadCompleted
        case mlxSwitchSucceeded
        case edge0SwitchBackSucceeded

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .modelDiscovered: return "Model discovered"
            case .artifactsValidated: return "Artifacts validated"
            case .admissionAccepted: return "Admission accepted"
            case .runtimeConstructed: return "Runtime constructed"
            case .modelLoadCompleted: return "Model load complete"
            case .promptTokenized: return "Prompt tokenized"
            case .prefillCompleted: return "Prefill complete"
            case .firstTokenEmitted: return "First token emitted"
            case .tokensGenerated: return "N tokens generated"
            case .exactReferenceParity: return "Exact reference parity (9 IDs)"
            case .sessionReuseParity: return "Session reuse parity (turn 2 vs fresh)"
            case .cancellationWorked: return "Cancellation works"
            case .generationAfterCancellation: return "Generation after cancel"
            case .unloadCompleted: return "Unload completes"
            case .mlxSwitchSucceeded: return "MLX switch succeeds"
            case .edge0SwitchBackSucceeded: return "Switch back to Edge0"
            }
        }
    }

    enum Status: Equatable, Sendable {
        case pending
        case running
        case passed(String)
        case failed(String)
        case skipped(String)
    }

    struct StageResult: Equatable, Sendable {
        var status: Status = .pending
        var duration: TimeInterval = 0
    }

    /// Phase 4A exact-mode baseline captured from one fixed short run.
    struct Baseline: Sendable {
        var mode = "exact"
        var family = Edge0ModelFamily.bailing8B.rawValue
        var effectiveMode = "exact"
        var loraModules = 0
        var routerK = 0
        var loadSeconds = 0.0
        var promptTokens = 0
        var generatedTokens = 0
        var parityPassed: Bool?
        var parityFirstDifferingIndex: Int?
        var parityEmittedTokens = 0

        // PREFILL
        var prefillSeconds = 0.0
        var prefillHitRate = 0.0
        var prefillBytesPerPromptToken: UInt64 = 0
        var prefillLoadsPerPromptToken = 0.0
        var prefillAcquireWaitSeconds = 0.0

        // DECODE
        var ttftSeconds = 0.0
        var decodeSeconds = 0.0
        var decodeTokensPerSecond = 0.0
        var decodeHitRate = 0.0
        var decodeBytesPerGeneratedToken: UInt64 = 0
        var decodeLoadsPerGeneratedToken = 0.0
        var decodeAcquireWaitSeconds = 0.0

        var footprintBeforeLoad: Int64 = 0
        var footprintAfterLoad: Int64 = 0
        var peakFootprint: Int64 = 0
        var thermalBeforeLoad = ""
        var thermalAfterLoad = ""
        var thermalEnd = ""
        var metrics: [String: String] = [:]
    }

    @Published private(set) var results: [Stage: StageResult] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var deviceSummary = ""
    @Published private(set) var baseline: Baseline?
    /// Family under test. 8B remains the default; 35B is the experimental
    /// bring-up family (exact true-router execution only).
    @Published var family: Edge0ModelFamily = .bailing8B
    /// Developer A/B selection. Staged+prerouter is the device-verified
    /// production default (Phase 4B-3); exact remains the oracle and
    /// staged/boundedPrefetch stay available as fallbacks.
    @Published var executionMode: Edge0ExecutionMode = .stagedPrerouter
    /// Phase 4B-4 experiment knobs (0 = automatic pool tier).
    @Published var poolCapacityMiB = 0
    @Published var readConcurrency = 4
    @Published var profilingEnabled = false
    /// Phase 5M candidate: advisory kernel readahead (`F_RDADVISE`) over
    /// expert slices before their preads. Numerically inert; the engine
    /// captures it once per load, so it must be set BEFORE the model loads.
    @Published var readaheadHints = false
    /// Phase 5J candidate: advisory prerouter decode-side prefetch. Default
    /// OFF; the true router stays authoritative either way.
    @Published var advisoryPrerouter = false

    private static let probePrompt = "The capital of France is"
    /// Fixed public performance prompt: normally yields a substantial answer
    /// so decode throughput is measured over many tokens, not EOS after two.
    private static let benchmarkPrompt =
        "List three practical benefits of running an AI model locally on a phone. Keep it under 60 words."

    // MARK: Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        results = Dictionary(
            uniqueKeysWithValues: Stage.allCases.map { ($0, StageResult()) }
        )
        if family == .qwen35MoE {
            // Only exact and boundedPrefetch exist for the 35B family; any
            // other selection is resolved and reported by the engine.
            switch executionMode {
            case .boundedPrefetch:
                Edge0EnginePreferences.edge0_35BExecutionMode = .boundedPrefetch
            case .staged:
                Edge0EnginePreferences.edge0_35BExecutionMode = .staged
            default:
                Edge0EnginePreferences.edge0_35BExecutionMode = .exact
            }
        } else {
            Edge0EnginePreferences.executionMode = executionMode
        }
        Edge0EnginePreferences.expertLoadConcurrency = readConcurrency
        Edge0EnginePreferences.poolCapacityBytesOverride = poolCapacityMiB > 0
            ? UInt64(poolCapacityMiB) * 1_048_576
            : nil
        Edge0EnginePreferences.componentProfilingEnabled = profilingEnabled
        // Phase 5M / 5J candidates: set BEFORE the model loads. The engine
        // captures `readaheadHints` once per load and builds the advisory
        // runtime per generation, so both must be in place here.
        Edge0EnginePreferences.edge0_35BReadaheadHints = readaheadHints
        Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = advisoryPrerouter
        // Measurement semantics: every validation stage must pay its own
        // prefill. The prompt cache is a chat-path optimization; the
        // session-reuse parity stage re-enables it internally.
        Edge0EnginePreferences.edge0_35BSessionReuse = false
        var initial = Baseline()
        initial.family = family.rawValue
        // Report the actual 35B selection (exact / boundedPrefetch / staged;
        // stagedPrerouter is 8B-only and reset by the picker) so the export
        // cannot read "requested exact" while the engine ran staged.
        initial.mode = executionMode.rawValue
        initial.effectiveMode = initial.mode
        baseline = initial
        deviceSummary = "\(describeDevice()) · family \(family.displayName)"
            + " · mode \(initial.mode)"
            + " · pool \(poolCapacityMiB > 0 ? "\(poolCapacityMiB) MiB" : "auto")"
            + " · reads \(readConcurrency)"
            + (family == .qwen35MoE
                ? " · experimental input cap \(Edge0_35BContextBudget.experimentalMaximumInputTokens) tok"
                : "")
            + (profilingEnabled ? " · profiling on" : "")
            // Provenance for the Phase 5M/5J candidates: the summary must
            // record what was REQUESTED, because the engine reports what was
            // effective (an artifact can be absent, or a mode resolved).
            + (family == .qwen35MoE && readaheadHints ? " · readahead on" : "")
            + (family == .qwen35MoE && advisoryPrerouter
                ? " · advisory prerouter on" : "")

        guard let preset = Self.edge0Preset(family: family) else {
            fail(.modelDiscovered, "No \(family.displayName) preset declared in AssistantModelCatalog.")
            finish()
            return
        }

        await stage(.modelDiscovered) {
            guard let entry = ModelDownloadCenter.shared.models.first(where: {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            }) else {
                throw ValidationError("Catalog entry missing for \(preset.repoID).")
            }
            guard entry.isReady else {
                throw ValidationError("Model is not downloaded/ready yet.")
            }
            return "ready · \(entry.sizeLabel)"
        }

        await stage(.artifactsValidated) {
            let local = LocalModel(assistantModel: preset)
            let directory = try Edge0RuntimeBackend.resolveModelDirectory(
                for: local, family: family
            )
            switch family {
            case .bailing8B:
                try Edge0ModelArtifacts.validate(directory: directory)
                return "validated \(directory.lastPathComponent)"
            case .qwen35MoE:
                let summary = try Edge0_35BModelArtifacts.validateForRuntime(
                    directory: directory
                )
                let resident = "\(summary.residentTensorCount) tensors/"
                    + "\(summary.residentPayloadBytes) B"
                let experts = "\(summary.expertTensorCount) tensors/"
                    + "\(summary.expertPayloadBytes) B"
                let prerouter = summary.prerouterPresent
                    ? "present (unused)" : "absent (optional)"
                let validated = "validated \(directory.lastPathComponent)"
                return validated
                    + " · resident \(resident)"
                    + " · experts \(experts)"
                    + " · LoRA modules \(summary.loraModuleCount)"
                    + " · prerouter \(prerouter)"
            }
        }

        await stage(.admissionAccepted) {
            if let reason = DeviceSafetyMonitor.shared.stopReason {
                throw ValidationError("Device safety stop: \(reason.title).")
            }
            let output = DeviceSafetyMonitor.shared.recommendedMaxTokens
            switch family {
            case .bailing8B:
                let budget = Edge0MemoryBudget.current()
                guard budget.isPoolEnabled else {
                    throw ValidationError("Expert pool admission refused (no headroom).")
                }
                let context = Edge0ContextBudget.current(outputTokens: output)
                return "pool slots \(budget.expertPoolSlots)"
                    + " · safe input \(context.maxInputTokens) tok"
                    + " · prerouter residency \(budget.prerouterResidentBytes) B"
            case .qwen35MoE:
                let budget = Edge0_35BMemoryBudget.current()
                guard budget.isPoolEnabled else {
                    throw ValidationError(
                        "35B expert pool admission refused: need at least "
                        + "\(Edge0_35BMemoryBudget.minimumPoolSlots) slots."
                    )
                }
                let context = Edge0_35BContextBudget.current(outputTokens: output)
                return "resident \(budget.residentBytes) B"
                    + " · pool slots \(budget.expertPoolSlots)"
                    + " · safe input \(context.maxInputTokens) tok"
                    + (context.experimentalLimitApplied ? " (experimental cap)" : "")
            }
        }

        await stage(.runtimeConstructed) {
            let engine = try RuntimeEngineFactory.makeEngine(for: preset)
            guard engine.runtime == .edge0MLX else {
                throw ValidationError("Factory resolved \(engine.runtime.label), not Edge0.")
            }
            return "Edge0RuntimeBackend"
        }

        let service = CodingAssistantService.shared

        await stage(.modelLoadCompleted) {
            // Force a real load: a no-op switch to an already-resident model
            // would report 0.0s and tell us nothing about load cost.
            if service.isModelLoaded {
                await service.unloadAndWaitForCleanup()
            }
            var sample = self.baseline ?? Baseline()
            sample.footprintBeforeLoad = MemoryAdvisor.physFootprint
            sample.thermalBeforeLoad = ProcessInfo.processInfo.thermalState.label

            let started = ContinuousClock.now
            await service.switchTo(preset, persistAsDefault: false)
            guard service.isModelLoaded else {
                throw ValidationError("Service did not report the Edge0 model as loaded.")
            }
            sample.loadSeconds = started.duration(to: .now).seconds
            sample.footprintAfterLoad = MemoryAdvisor.physFootprint
            sample.thermalAfterLoad = ProcessInfo.processInfo.thermalState.label
            self.baseline = sample

            let output = DeviceSafetyMonitor.shared.recommendedMaxTokens
            let poolSlots: Int
            let poolBytes: Int64
            let safeInput: Int
            switch family {
            case .bailing8B:
                let budget = Edge0MemoryBudget.current()
                let context = Edge0ContextBudget.current(outputTokens: output)
                poolSlots = budget.expertPoolSlots
                poolBytes = Int64(clamping: budget.expertPoolBytes)
                safeInput = context.maxInputTokens
            case .qwen35MoE:
                let budget = Edge0_35BMemoryBudget.current()
                let context = Edge0_35BContextBudget.current(outputTokens: output)
                poolSlots = budget.expertPoolSlots
                poolBytes = Int64(clamping: budget.expertPoolBytes)
                safeInput = context.maxInputTokens
            }
            let requestedPool = poolCapacityMiB > 0
                ? "\(poolCapacityMiB) MiB" : "auto"
            return String(
                format: "%.2fs · footprint %@→%@ · pool requested %@ → actual %d slots/%@ · safe input %d tok · thermal %@→%@",
                sample.loadSeconds,
                Self.bytes(sample.footprintBeforeLoad),
                Self.bytes(sample.footprintAfterLoad),
                requestedPool,
                poolSlots,
                Self.bytes(poolBytes),
                safeInput,
                sample.thermalBeforeLoad,
                sample.thermalAfterLoad
            )
        }

        let first: StreamOutcome
        if family == .qwen35MoE {
            first = await streamOnce(
                service: service, maxTokens: 64,
                cancelAfterFirstToken: false,
                prompt: Self.benchmarkPrompt
            )
        } else {
            first = await streamOnce(
                service: service, maxTokens: 8,
                cancelAfterFirstToken: false
            )
        }
        updateBaseline(with: first)

        guard first.error == nil, first.tokens >= 1 else {
            let detail = first.error ?? "No token emitted."
            results[.promptTokenized] = StageResult(status: .failed(detail), duration: 0)
            results[.prefillCompleted] = StageResult(status: .failed(detail), duration: 0)
            results[.firstTokenEmitted] = StageResult(status: .failed(detail), duration: 0)
            results[.tokensGenerated] = StageResult(status: .failed(detail), duration: 0)
            skipRemaining(from: .cancellationWorked)
            finish()
            return
        }

        let captured = baseline ?? Baseline()
        results[.promptTokenized] = StageResult(
            status: .passed("chat template applied · prompt \(captured.promptTokens) tok"),
            duration: 0
        )
        results[.prefillCompleted] = StageResult(
            status: .passed(String(format: "engine prefill %.3fs", captured.prefillSeconds)),
            duration: captured.prefillSeconds
        )
        results[.firstTokenEmitted] = StageResult(
            status: .passed(String(
                format: "TTFT %.2fs · %d chunk(s)", captured.ttftSeconds, first.tokens
            )),
            duration: captured.ttftSeconds
        )
        results[.tokensGenerated] = StageResult(
            status: .passed(String(
                format: "%d tok · prefill %.2fs (hit %.0f%%, %.1f KB/tok, aggregate wait %.2fs) · decode %.2fs · %.2f tok/s (hit %.0f%%, aggregate wait %.2fs)",
                captured.generatedTokens,
                captured.prefillSeconds,
                captured.prefillHitRate * 100,
                Double(captured.prefillBytesPerPromptToken) / 1024,
                captured.prefillAcquireWaitSeconds,
                captured.decodeSeconds,
                captured.decodeTokensPerSecond,
                captured.decodeHitRate * 100,
                captured.decodeAcquireWaitSeconds
            )),
            duration: captured.decodeSeconds
        )

        await stage(.exactReferenceParity) {
            guard self.family == .qwen35MoE else {
                throw ValidationSkip(
                    "8B has no frozen raw-token reference probe."
                )
            }
            let probe = try await service.runEdge0ParityProbe()
            guard let probe else {
                throw ValidationError("Parity probe unavailable.")
            }
            var sample = self.baseline ?? Baseline()
            sample.parityPassed = probe.passed
            sample.parityFirstDifferingIndex = probe.firstDifferingIndex
            sample.parityEmittedTokens = probe.emittedTokenIDs.count
            self.baseline = sample
            guard probe.passed else {
                let first = probe.firstDifferingIndex
                    .map(String.init) ?? "n/a"
                throw ValidationError(
                    "Parity mismatch · first differing index \(first)"
                        + " · emitted \(probe.emittedTokenIDs.count)/\(probe.expectedTokenIDs.count)"
                )
            }
            return "9/9 exact ids · position \(probe.finalPosition)"
                + " · \(probe.stopReason) · eos \(probe.eosHit)"
        }

        await stage(.sessionReuseParity) {
            guard self.family == .qwen35MoE else {
                throw ValidationSkip("35B-only session-reuse probe.")
            }
            guard let probe = try await service.runEdge0SessionReuseProbe() else {
                throw ValidationError("Session-reuse probe unavailable.")
            }
            let detail = "reuse \(probe.reuseAppliedOnTurn2 ? "applied" : "NOT APPLIED")"
                + " · reused \(probe.reusedTokens) tok · prefilled \(probe.prefilledTokens) tok"
                + " · emitted \(probe.emittedTokens)"
            guard probe.passed else {
                throw ValidationError(
                    detail + " · answers differ at "
                        + (probe.firstDifferingIndex.map(String.init) ?? "n/a")
                )
            }
            return detail + " · answers byte-identical"
        }

        await stage(.cancellationWorked) {
            let cancelled = await streamOnce(
                service: service, maxTokens: 64, cancelAfterFirstToken: true
            )
            guard cancelled.didCancel else {
                throw ValidationError(
                    cancelled.error ?? "Stop did not end the stream."
                )
            }
            guard service.state != .generating else {
                throw ValidationError("Generating state survived Stop.")
            }
            let started = cancelled.firstTokenLatency.map {
                String(format: "first token %.2fs", $0)
            } ?? "no first token"
            let latency = cancelled.cancelLatency.map {
                String(format: "stop→end %.2fs", $0)
            } ?? "stop→end n/a"
            return "stream ended cleanly · \(started) · \(latency)"
        }

        await stage(.generationAfterCancellation) {
            let second = await streamOnce(
                service: service, maxTokens: 8, cancelAfterFirstToken: false
            )
            guard second.tokens >= 1, second.error == nil else {
                throw ValidationError(second.error ?? "Second generation produced no tokens.")
            }
            let decodeOnly = second.metrics["generation.decodeTokensPerSecond"]
                ?? "n/a"
            return String(
                format: "%d chunk(s) · engine decode %@ tok/s · stage end-to-end %.2f tok/s without restart",
                second.tokens,
                decodeOnly,
                second.tokensPerSecond
            )
        }

        await stage(.unloadCompleted) {
            await service.unloadAndWaitForCleanup()
            guard !service.isModelLoaded else {
                throw ValidationError("Model still resident after unload.")
            }
            if var sample = self.baseline {
                sample.thermalEnd = ProcessInfo.processInfo.thermalState.label
                self.baseline = sample
            }
            return "unloaded"
        }

        await stage(.mlxSwitchSucceeded) {
            guard let mlx = Self.firstReadyMLXPreset() else {
                throw ValidationSkip("No installed MLX model available on this device.")
            }
            await service.switchTo(mlx, persistAsDefault: false)
            guard service.isModelLoaded else {
                throw ValidationError("MLX model did not load after Edge0.")
            }
            return mlx.displayName
        }

        await stage(.edge0SwitchBackSucceeded) {
            await service.switchTo(preset, persistAsDefault: false)
            guard service.isModelLoaded else {
                throw ValidationError("Edge0 did not reload after the MLX model.")
            }
            return "\(preset.displayName) resident again"
        }

        finish()
    }

    // MARK: - Stream collection

    private struct StreamOutcome {
        var tokens = 0
        var firstTokenLatency: TimeInterval?
        var cancelLatency: TimeInterval?
        var tokensPerSecond: Double = 0
        var error: String?
        var didCancel = false
        var metrics: [String: String] = [:]
        var footprintBefore: Int64 = 0
        var footprintAfter: Int64 = 0
        var peakFootprint: Int64 = 0
        var thermalBefore = ""
        var thermalDuring = ""
        var thermalAfter = ""
    }

    private func streamOnce(
        service: CodingAssistantService,
        maxTokens: Int,
        cancelAfterFirstToken: Bool,
        prompt: String? = nil
    ) async -> StreamOutcome {
        let collector = StreamCollector(
            cancelAfterFirstToken: cancelAfterFirstToken,
            service: service
        )
        let message = ChatMessage(
            role: .user, content: prompt ?? Self.probePrompt
        )
        await withCheckedContinuation { continuation in
            collector.continuation = continuation
            service.generate(
                messages: [message],
                maxTokensOverride: maxTokens,
                temperatureOverride: 0,
                forceNoThinking: true,
                onToken: { text in
                    Task { @MainActor in collector.record(chunk: text) }
                },
                onComplete: { rate in
                    Task { @MainActor in collector.complete(rate: rate) }
                },
                onError: { message in
                    Task { @MainActor in collector.record(error: message) }
                }
            )
        }
        var outcome = collector.outcome
        outcome.metrics = await service.edge0RuntimeMetrics() ?? [:]
        return outcome
    }

    @MainActor
    private final class StreamCollector {
        let cancelAfterFirstToken: Bool
        weak var service: CodingAssistantService?
        var continuation: CheckedContinuation<Void, Never>?

        private var started = ContinuousClock.now
        private(set) var outcome = StreamOutcome()
        private var sawStop = false
        private var cancelRequestedAt: ContinuousClock.Instant?
        private var footprintSampler: Task<Void, Never>?

        init(cancelAfterFirstToken: Bool, service: CodingAssistantService) {
            self.cancelAfterFirstToken = cancelAfterFirstToken
            self.service = service
            self.outcome.footprintBefore = MemoryAdvisor.physFootprint
            self.outcome.thermalBefore = ProcessInfo.processInfo.thermalState.label
        }

        func record(chunk: String) {
            guard continuation != nil else { return }
            if outcome.firstTokenLatency == nil {
                outcome.firstTokenLatency = started.duration(to: .now).seconds
                outcome.thermalDuring = ProcessInfo.processInfo.thermalState.label
                startFootprintSampler()
            }
            outcome.tokens += 1
            if cancelAfterFirstToken && outcome.tokens >= 1 && !sawStop {
                sawStop = true
                outcome.didCancel = true
                cancelRequestedAt = ContinuousClock.now
                service?.stopGeneration()
            }
        }

        func complete(rate: Double) {
            if let requested = cancelRequestedAt {
                outcome.cancelLatency = requested.duration(to: .now).seconds
            }
            outcome.tokensPerSecond = rate
            footprintSampler?.cancel()
            outcome.footprintAfter = MemoryAdvisor.physFootprint
            outcome.peakFootprint = max(outcome.peakFootprint, outcome.footprintAfter)
            outcome.thermalAfter = ProcessInfo.processInfo.thermalState.label
            resumeOnce()
        }

        func record(error message: String) {
            if let requested = cancelRequestedAt {
                outcome.cancelLatency = requested.duration(to: .now).seconds
            }
            outcome.error = message
            footprintSampler?.cancel()
            // A failure without a trailing onComplete must not hang the
            // runner; resume is idempotent.
            resumeOnce()
        }

        private func startFootprintSampler() {
            footprintSampler = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self {
                        self.outcome.peakFootprint = max(
                            self.outcome.peakFootprint,
                            MemoryAdvisor.physFootprint
                        )
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }

        private func resumeOnce() {
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Stage plumbing

    private func updateBaseline(with outcome: StreamOutcome) {
        guard var sample = baseline else { return }
        let metrics = outcome.metrics
        sample.promptTokens = Int(metrics["generation.promptTokens"] ?? "") ?? sample.promptTokens
        sample.generatedTokens = Int(metrics["generation.generatedTokens"] ?? "") ?? outcome.tokens
        sample.prefillSeconds = Double(metrics["generation.prefillSeconds"] ?? "") ?? 0
        sample.decodeSeconds = Double(metrics["generation.decodeSeconds"] ?? "") ?? 0
        sample.decodeTokensPerSecond = Double(
            metrics["generation.decodeTokensPerSecond"] ?? ""
        ) ?? 0
        sample.ttftSeconds = outcome.firstTokenLatency
            ?? Double(metrics["generation.ttftSeconds"] ?? "")
            ?? 0

        // Phase-split expert metrics (fixes the total-bytes / generated-token
        // artifact: prefill I/O is no longer attributed to decode).
        sample.prefillHitRate = Double(metrics["prefill.pool.hitRate"] ?? "") ?? 0
        sample.decodeHitRate = Double(metrics["decode.pool.hitRate"] ?? "") ?? 0
        sample.prefillBytesPerPromptToken = UInt64(
            metrics["prefill.bytesPerPromptToken"] ?? ""
        ) ?? 0
        sample.decodeBytesPerGeneratedToken = UInt64(
            metrics["decode.bytesPerGeneratedToken"] ?? ""
        ) ?? 0
        sample.prefillLoadsPerPromptToken = Double(
            metrics["prefill.loadsPerPromptToken"] ?? ""
        ) ?? 0
        sample.decodeLoadsPerGeneratedToken = Double(
            metrics["decode.loadsPerGeneratedToken"] ?? ""
        ) ?? 0
        sample.prefillAcquireWaitSeconds = Double(
            metrics["prefill.pool.aggregateAcquireWaitSeconds"] ?? ""
        ) ?? 0
        sample.decodeAcquireWaitSeconds = Double(
            metrics["decode.pool.aggregateAcquireWaitSeconds"] ?? ""
        ) ?? 0
        sample.peakFootprint = max(sample.peakFootprint, outcome.peakFootprint)
        sample.thermalEnd = outcome.thermalAfter
        sample.metrics = metrics
        if let lora = Int(metrics["lora.modules"] ?? "") {
            sample.loraModules = lora
        }
        if let routerK = Int(metrics["router.k"] ?? "") {
            sample.routerK = routerK
        }
        if let effective = metrics["mode.effective"] {
            sample.effectiveMode = effective
        }
        baseline = sample
    }

    private func skipRemaining(from stage: Stage) {
        for candidate in Stage.allCases where candidate.rawValue >= stage.rawValue {
            if results[candidate]?.status == .pending {
                results[candidate] = StageResult(
                    status: .skipped("Not reached."), duration: 0
                )
            }
        }
    }

    private struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct ValidationSkip: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func stage(
        _ stage: Stage,
        _ body: () async throws -> String
    ) async {
        let started = ContinuousClock.now
        results[stage] = StageResult(status: .running, duration: 0)
        do {
            let detail = try await body()
            results[stage] = StageResult(
                status: .passed(detail),
                duration: started.duration(to: .now).seconds
            )
        } catch let skip as ValidationSkip {
            results[stage] = StageResult(
                status: .skipped(skip.message),
                duration: started.duration(to: .now).seconds
            )
        } catch {
            results[stage] = StageResult(
                status: .failed(error.localizedDescription),
                duration: started.duration(to: .now).seconds
            )
        }
    }

    private func fail(_ stage: Stage, _ message: String) {
        results[stage] = StageResult(status: .failed(message), duration: 0)
    }

    private func finish() {
        // Restore the chat-path prompt cache (disabled for measurement).
        Edge0EnginePreferences.edge0_35BSessionReuse = true
        for stage in Stage.allCases where results[stage]?.status == .pending {
            results[stage] = StageResult(status: .skipped("Not reached."), duration: 0)
        }
        isRunning = false
    }

    // MARK: - Summary

    /// Aggregate, privacy-safe export: stages, statuses, timings, baseline
    /// counters, and device summary only. No prompt or generated text ever
    /// appears here.
    var summaryText: String {
        var lines = [
            "Edge0 Device Validation",
            deviceSummary,
            "",
        ]
        for stage in Stage.allCases {
            let result = results[stage]
            let status: String
            switch result?.status ?? .pending {
            case .pending: status = "pending"
            case .running: status = "running"
            case .passed(let detail): status = "PASS · \(detail)"
            case .failed(let detail): status = "FAIL · \(detail)"
            case .skipped(let detail): status = "SKIP · \(detail)"
            }
            lines.append(String(
                format: "%2d. %-28@ %@ (%.2fs)",
                stage.rawValue,
                stage.title as NSString,
                status as NSString,
                result?.duration ?? 0
            ))
        }

        if let sample = baseline {
            lines.append("")
            lines.append("EDGE0 BASELINE")
            lines.append("FAMILY: \(sample.family) · requested \(sample.mode) · effective \(sample.effectiveMode)"
                + (sample.routerK > 0 ? " · router K=\(sample.routerK)" : "")
                + (sample.loraModules > 0 ? " · LoRA modules \(sample.loraModules)" : ""))
            if let passed = sample.parityPassed {
                lines.append("PARITY")
                lines.append(
                    "  exact reference: \(passed ? "PASS" : "FAIL")"
                    + " · emitted \(sample.parityEmittedTokens)/9"
                    + " · first differing index "
                    + (sample.parityFirstDifferingIndex.map(String.init) ?? "none")
                )
            }
            lines.append(String(format: "load: %.2fs", sample.loadSeconds))
            lines.append("prompt tokens: \(sample.promptTokens) · output tokens: \(sample.generatedTokens)")
            let systemTokens = sample.metrics["prompt.systemTokens"] ?? "?"
            let historyTokens = sample.metrics["prompt.historyTokens"] ?? "?"
            let userTokens = sample.metrics["prompt.userTokens"] ?? "?"
            let overheadTokens = sample.metrics["prompt.templateOverheadTokens"] ?? "?"
            lines.append("PROMPT ACCOUNTING")
            lines.append(
                "  system: \(systemTokens) · history: \(historyTokens)"
                + " · user: \(userTokens) · template overhead: \(overheadTokens)"
            )
            if let decodeCalls = sample.metrics["generation.decodeCalls"] {
                lines.append("GENERATION")
                lines.append(
                    "  decode calls: \(decodeCalls)"
                    + " · generated: \(sample.metrics["generation.generatedTokens"] ?? "?")"
                    + " · visible answer: \(sample.metrics["generation.finalAnswerTokens"] ?? "?")"
                    + " · reasoning: \(sample.metrics["generation.reasoningTokens"] ?? "?")"
                    + " · control: \(sample.metrics["generation.controlTokens"] ?? "?")"
                )
                lines.append(
                    "  decode-only: \(sample.metrics["generation.decodeTokensPerSecond"] ?? "?") tok/s"
                    + " · end-to-end: \(sample.metrics["generation.endToEndTokensPerSecond"] ?? "?") tok/s"
                    + " · stop: \(sample.metrics["generation.stopReason"] ?? "?")"
                )
            }
            if let fallback = sample.metrics["mode.fallback"], !fallback.isEmpty {
                lines.append("  mode fallback: \(fallback)")
            }
            lines.append("PREFILL")
            lines.append(String(
                format: "  seconds: %.3f · hit rate: %.1f%% · loads/token: %.2f · bytes/token: %llu · aggregate expert wait: %.3fs",
                sample.prefillSeconds,
                sample.prefillHitRate * 100,
                sample.prefillLoadsPerPromptToken,
                sample.prefillBytesPerPromptToken,
                sample.prefillAcquireWaitSeconds
            ))
            lines.append("DECODE")
            lines.append(String(
                format: "  seconds: %.3f (TTFT %.2fs) · tok/s: %.2f · hit rate: %.1f%% · loads/token: %.2f · bytes/token: %llu · aggregate expert wait: %.3fs",
                sample.decodeSeconds,
                sample.ttftSeconds,
                sample.decodeTokensPerSecond,
                sample.decodeHitRate * 100,
                sample.decodeLoadsPerGeneratedToken,
                sample.decodeBytesPerGeneratedToken,
                sample.decodeAcquireWaitSeconds
            ))
            lines.append("PREFETCH")
            lines.append("  actual-router concurrent loads only; no speculative prediction in this phase")
            if let predictions = sample.metrics["prerouter.predictions"] {
                lines.append("PREROUTER")
                lines.append(
                    "  predictions: \(predictions)"
                    + " · predicted experts: \(sample.metrics["prerouter.predictedExperts"] ?? "?")"
                    + " · precision: \(sample.metrics["prerouter.precision"] ?? "?")"
                    + " · recall: \(sample.metrics["prerouter.recall"] ?? "?")"
                )
                lines.append(
                    "  prefetch requests/loads/completed: "
                    + "\(sample.metrics["prerouter.prefetchRequests"] ?? "?") / "
                    + "\(sample.metrics["prerouter.prefetchLoadsStarted"] ?? "?") / "
                    + "\(sample.metrics["prerouter.prefetchLoadsCompleted"] ?? "?")"
                    + " · bytes: \(sample.metrics["prerouter.prefetchBytes"] ?? "?")"
                )
                lines.append(
                    "  misses avoided: \(sample.metrics["prerouter.actualMissesAvoided"] ?? "?")"
                    + " · ready-from-prediction: \(sample.metrics["prerouter.readyFromPrediction"] ?? "?")"
                    + " · late-despite-prediction: \(sample.metrics["prerouter.lateDespitePrediction"] ?? "?")"
                    + " · fallbacks: \(sample.metrics["prerouter.fallbacks"] ?? "?")"
                )
                lines.append(
                    "  unused predicted experts: \(sample.metrics["prerouter.unusedPredictedExperts"] ?? "?")"
                    + " · unused speculatively-read bytes: \(sample.metrics["prerouter.unusedPrefetchedBytes"] ?? "?")"
                )
            }
            if let kdaPrefill = sample.metrics["profile.prefill.kdaSeconds"] {
                lines.append("COMPONENT PROFILE")
                lines.append(
                    "  prefill — kda: \(kdaPrefill)s · mla: \(sample.metrics["profile.prefill.mlaSeconds"] ?? "?")s"
                    + " · moe: \(sample.metrics["profile.prefill.moeSeconds"] ?? "?")s"
                    + " · router: \(sample.metrics["profile.prefill.routerSeconds"] ?? "?")s"
                    + " · embed: \(sample.metrics["profile.prefill.embeddingSeconds"] ?? "?")s"
                    + " · lm_head: \(sample.metrics["profile.prefill.lmHeadSeconds"] ?? "?")s"
                )
                lines.append(
                    "  decode — kda: \(sample.metrics["profile.decode.kdaSeconds"] ?? "?")s"
                    + " · mla: \(sample.metrics["profile.decode.mlaSeconds"] ?? "?")s"
                    + " · moe: \(sample.metrics["profile.decode.moeSeconds"] ?? "?")s"
                    + " · router: \(sample.metrics["profile.decode.routerSeconds"] ?? "?")s"
                    + " · lm_head: \(sample.metrics["profile.decode.lmHeadSeconds"] ?? "?")s"
                )
                lines.append(
                    "  read concurrency: \(sample.metrics["runtime.readConcurrency"] ?? "?")"
                    + " · pool capacity: \(sample.metrics["pool.capacityBytes"] ?? "?") B"
                )
            }
            if let banks = sample.metrics["staging.banksScheduled"] {
                lines.append("STAGING")
                lines.append(
                    "  banks scheduled/completed/switches: "
                    + "\(banks) / \(sample.metrics["staging.banksCompleted"] ?? "?") / "
                    + "\(sample.metrics["staging.bankSwitches"] ?? "?")"
                )
                lines.append(
                    "  ready-before-use: \(sample.metrics["staging.readyBeforeUse"] ?? "?")"
                    + " (rate \(sample.metrics["staging.readyBeforeUseRate"] ?? "?"))"
                    + " · late-at-use: \(sample.metrics["staging.lateAtUse"] ?? "?")"
                    + " · critical stage wait: \(sample.metrics["staging.criticalStageWaitSeconds"] ?? "?") s"
                )
                lines.append(
                    "  staged loads/bytes: \(sample.metrics["staging.loadsCompleted"] ?? "?") / "
                    + "\(sample.metrics["staging.bytes"] ?? "?") B"
                    + " · cancellations: \(sample.metrics["staging.cancellations"] ?? "?")"
                )
            }
            lines.append(
                "footprint before/after load/peak: "
                + "\(Self.bytes(sample.footprintBeforeLoad)) / "
                + "\(Self.bytes(sample.footprintAfterLoad)) / "
                + "\(Self.bytes(sample.peakFootprint))"
            )
            lines.append(
                "thermal before load / after load / end: "
                + "\(sample.thermalBeforeLoad) / \(sample.thermalAfterLoad) / \(sample.thermalEnd)"
            )
            if !sample.metrics.isEmpty {
                lines.append("runtime counters:")
                for key in sample.metrics.keys.sorted() {
                    lines.append("  \(key) = \(sample.metrics[key] ?? "")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private static func edge0Preset(family: Edge0ModelFamily) -> AssistantModel? {
        AssistantModelCatalog.presets.first {
            $0.runtime == .edge0MLX && $0.repoID == family.repoID
        }
    }

    private static func firstReadyMLXPreset() -> AssistantModel? {
        AssistantModelCatalog.presets.first { preset in
            preset.runtime == .mlx && ModelDownloadCenter.shared.models.contains {
                ($0.id == preset.id || $0.sourceRepoID == preset.repoID) && $0.isReady
            }
        }
    }

    private func describeDevice() -> String {
        let process = ProcessInfo.processInfo
        let ram = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: process.physicalMemory),
            countStyle: .memory
        )
        // The Metal line mirrors MLX's NAX gate (read-only); the kernel that
        // actually runs must be confirmed in a Metal System Trace.
        return "\(Self.machineIdentifier()) · iOS \(process.operatingSystemVersionString) · RAM \(ram) · thermal \(process.thermalState.label) · \(Edge0MetalEnvironment.current().summary)"
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown-device" : identifier
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
        case .nominal: return "thermal nominal"
        case .fair: return "thermal fair"
        case .serious: return "thermal serious"
        case .critical: return "thermal critical"
        @unknown default: return "thermal unknown"
        }
    }
}
