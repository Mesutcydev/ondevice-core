import Foundation

// MARK: - Edge0 Speed Diagnostic plan
//
// Pure, testable state for the 35B speed diagnostic: the trial plan per
// kind, scored-trial admission rules, recovery bookkeeping, and terminal
// status classification. The runner owns live generation; this type owns
// the decisions so they can be tested without a model.

enum Edge0DiagnosticKind: String, CaseIterable, Identifiable, Sendable {
    case singleExact = "Single scored Exact"
    case ab = "A/B (counterbalanced)"
    case prefillAB = "Prefill A/B (bounded vs staged)"
    case evalWindowAB = "Staged eval-window A/B (w1 vs w4)"
    case microbatchAB = "Staged microbatch A/B (g1 vs g4)"
    case prerouterAB = "35B Prerouter A/B (off vs advisory)"
    case computeAB = "35B Compute A/B (production vs candidate)"
    case readaheadAB = "35B Readahead A/B (off vs hints)"
    case readsAB = "35B Expert reads A/B (4 vs 6)"
    case poolBudgetAB = "35B Pool budget A/B (legacy vs reclaimed)"
    case microbatchWideAB = "Staged wide-microbatch A/B (g4 vs g8)"
    case sustained35B = "35B Sustained Run (thermal)"
    case exactDrift = "Exact drift (early vs late)"

    var id: String { rawValue }

    /// Scored trials in order. Counterbalanced: the Bounded mode never
    /// always runs second.
    var scoredPlan: [Edge0ExecutionMode] {
        switch self {
        case .singleExact:
            return [.exact]
        case .ab:
            return [.exact, .boundedPrefetch, .boundedPrefetch, .exact]
        case .prefillAB:
            return [.boundedPrefetch, .staged, .staged, .boundedPrefetch]
        case .evalWindowAB:
            return [.staged, .staged, .staged, .staged]
        case .microbatchAB:
            return [.staged, .staged, .staged, .staged]
        case .prerouterAB:
            return [.staged, .staged, .staged, .staged]
        case .computeAB:
            return [.staged, .staged, .staged, .staged]
        case .readaheadAB:
            return [.staged, .staged, .staged, .staged]
        case .readsAB:
            return [.staged, .staged, .staged, .staged]
        case .poolBudgetAB:
            return [.staged, .staged, .staged, .staged]
        case .microbatchWideAB:
            return [.staged, .staged, .staged, .staged]
        case .sustained35B:
            // Back-to-back identical trials (no idle recovery): the point is
            // a continuous sustained-load window, not an A/B comparison.
            return Array(repeating: .staged, count: 6)
        case .exactDrift:
            return [.exact, .exact, .exact]
        }
    }

    /// One unscored warm-up per distinct mode in the plan.
    var warmUpModes: [Edge0ExecutionMode] {
        var seen = Set<Edge0ExecutionMode>()
        return scoredPlan.filter { seen.insert($0).inserted }
    }

    var isComparison: Bool { self == .ab || self == .prefillAB }

    static func modeLabel(_ mode: Edge0ExecutionMode) -> String {
        switch mode {
        case .exact: return "Exact"
        case .boundedPrefetch: return "Bounded"
        case .staged: return "Staged"
        case .stagedPrerouter: return "StagedPrerouter"
        }
    }
}

enum Edge0DiagnosticPhase: String, Sendable {
    case preparing
    case warmUp
    case recovery
    case scoredTrial
    case finished
}

enum Edge0DiagnosticTerminal: String, Sendable {
    case completed
    case cancelled
    case blocked
    case failed
    case timedOut
}

struct Edge0DiagnosticPlan: Sendable {
    let kind: Edge0DiagnosticKind
    var modes: [Edge0ExecutionMode] { kind.scoredPlan }
    var plannedScoredTrials: Int { modes.count }

    enum Admission: Equatable {
        case allowed
        case blocked(reason: String)
    }

    /// Scored-trial admission. Every check is explicit so a blocked run can
    /// report exactly which condition stopped it.
    static func admission(
        snapshotAvailable: Bool,
        snapshotComplete: Bool,
        hasLiveWork: Bool,
        thermalSeriousOrCritical: Bool,
        recoveryTimedOut: Bool
    ) -> Admission {
        if !snapshotAvailable {
            return .blocked(reason: "resource snapshot unavailable")
        }
        if !snapshotComplete {
            return .blocked(reason: "resource snapshot incomplete")
        }
        if hasLiveWork {
            return .blocked(reason: "live generation, leases, loads, or reads")
        }
        if recoveryTimedOut {
            return .blocked(reason: "recovery timeout")
        }
        if thermalSeriousOrCritical {
            return .blocked(reason: "thermal serious/critical")
        }
        return .allowed
    }

    /// Terminal classification. A run with zero scored trials is still
    /// terminated for a specific reason; "insufficient scored trials" is a
    /// result limitation, never the termination reason.
    static func terminalStatus(
        completedScoredTrials: Int,
        plannedScoredTrials: Int,
        cancelled: Bool,
        blockedReason: String?,
        failedReason: String?,
        timedOut: Bool
    ) -> (terminal: Edge0DiagnosticTerminal, reason: String) {
        if let blockedReason {
            return (.blocked, blockedReason)
        }
        if let failedReason {
            return (.failed, failedReason)
        }
        if timedOut {
            return (.timedOut, "a scored trial exceeded its timeout")
        }
        if cancelled {
            return (.cancelled, "cancelled by the user")
        }
        if completedScoredTrials >= plannedScoredTrials {
            return (.completed, "\(completedScoredTrials)/\(plannedScoredTrials) scored trials")
        }
        return (
            .blocked,
            "stopped after \(completedScoredTrials)/\(plannedScoredTrials) scored trials"
        )
    }

    /// Export labeling: in-progress exports never carry a final decision.
    static func exportLabel(
        terminal: Edge0DiagnosticTerminal?,
        completedScoredTrials: Int
    ) -> String {
        guard let terminal, completedScoredTrials > 0 else {
            return "IN PROGRESS — NO FINAL PERFORMANCE DECISION"
        }
        return "FINAL — \(terminal.rawValue)"
    }

    /// Population gate for the runner's decision stage: which kinds require
    /// which execution-mode populations before a verdict can be assembled.
    ///
    /// The preference-only knob kinds (staged-only plans) never gate on the
    /// Exact/Bounded mode pairs: their verdicts come from their own arm
    /// labels, and a gate on mode populations would dead-end every completed
    /// run with an empty decision — exactly what build 47's device exports
    /// showed (four "FINAL — completed 4/4" sessions on 2026-09-17, none
    /// with a DECISION section). They gate themselves per arm inside their
    /// decision blocks. `exactDrift` has no mode decision at all (its output
    /// is the drift diagnosis), so it intentionally fails this gate and
    /// leaves the decision empty.
    static func populationGate(
        kind: Edge0DiagnosticKind,
        exactCount: Int,
        boundedCount: Int,
        stagedCount: Int
    ) -> Bool {
        switch kind {
        case .ab:
            return exactCount >= 2 && boundedCount >= 2
        case .prefillAB:
            return boundedCount >= 2 && stagedCount >= 2
        case .exactDrift:
            return false
        default:
            return true
        }
    }

    /// Frozen acceptance rule for the Phase 5M readahead A/B. Readahead
    /// (`F_RDADVISE` over expert slices just before their preads) targets
    /// the read-bound decode path — 270 MiB of expert bytes per decoded
    /// token at the flash wall — so the primary metric is decode throughput:
    /// at least +5%, with prefill and TTFT not degrading by more than 5%.
    /// Sequence parity and arm effectiveness are separate gates in the
    /// runner.
    ///
    /// Conventions: `decodeDeltaPercent` is a THROUGHPUT delta (positive =
    /// faster); `prefillDeltaPercent`/`ttftDeltaPercent` are TIME deltas
    /// (negative = faster, so "not slower than +5%" is `<= 5`).
    static func readaheadAcceptance(
        prefillDeltaPercent: Double,
        ttftDeltaPercent: Double,
        decodeDeltaPercent: Double
    ) -> Bool {
        decodeDeltaPercent >= 5
            && prefillDeltaPercent <= 5
            && ttftDeltaPercent <= 5
    }

    /// Frozen acceptance rule for the expert-read concurrency A/B (4 vs 6).
    /// Read concurrency widens the pread fan-out on the I/O-bound expert
    /// path, so the primary metric is prefill: at least 3% faster, with
    /// decode not degrading by more than 3%. Sequence parity and arm
    /// effectiveness are separate gates in the runner.
    ///
    /// Conventions: `prefillDeltaPercent` is a TIME delta (negative =
    /// faster, so "at least 3% faster" is `<= -3`); `decodeDeltaPercent`
    /// is a THROUGHPUT delta (positive = faster).
    static func readsAcceptance(
        prefillDeltaPercent: Double,
        decodeDeltaPercent: Double
    ) -> Bool {
        prefillDeltaPercent <= -3 && decodeDeltaPercent >= -3
    }

    /// Build-45 device datapoint: a 12 GB iPhone reported ~9.2 GB of
    /// apparent headroom and was still Jetsam-killed around this footprint,
    /// so it is the operative upper bound for any pool-growth experiment.
    static let recordedJetsamFootprintBytes: UInt64 = 5_600_000_000

    /// Frozen acceptance rule for the pool-budget A/B (audit findings 1+2:
    /// context-based state-KV allowance + the 3 GiB tier). The lever is the
    /// pool: more resident experts cut miss reads, so the primary metric is
    /// decode THROUGHPUT — at least +5%. Prefill/TTFT are TIME deltas
    /// (negative = faster) and may not degrade by more than 5%. The larger
    /// tier must actually have been selected (an accounting-only change
    /// with no tier shift cannot demonstrate the win), and the reclaimed
    /// peak footprint must stay at or under the recorded Jetsam datapoint —
    /// an unsampled peak (0) fails closed. Sequence parity and arm
    /// effectiveness are separate gates in the runner.
    static func poolBudgetAcceptance(
        decodeDeltaPercent: Double,
        prefillDeltaPercent: Double,
        ttftDeltaPercent: Double,
        effectivePoolsDiffer: Bool,
        reclaimedPeakFootprintBytes: UInt64
    ) -> Bool {
        decodeDeltaPercent >= 5
            && prefillDeltaPercent <= 5
            && ttftDeltaPercent <= 5
            && effectivePoolsDiffer
            && reclaimedPeakFootprintBytes > 0
            && reclaimedPeakFootprintBytes <= recordedJetsamFootprintBytes
    }

    /// Frozen acceptance rule for the wide-microbatch A/B (g4 → g8). Same
    /// construction as the g1 → g4 promotion: prefill is a TIME delta
    /// (negative = faster) and must improve by at least 5%; decode is a
    /// THROUGHPUT delta (positive = faster) and may not degrade by more
    /// than 5%. Sequence parity is a separate gate in the runner.
    static func wideMicrobatchAcceptance(
        prefillDeltaPercent: Double,
        decodeDeltaPercent: Double
    ) -> Bool {
        prefillDeltaPercent <= -5 && decodeDeltaPercent >= -5
    }

    /// Frozen stability rule for the sustained-thermal run (no A/B arms).
    /// "Sustained-stable" means the device held its decode rate within 5%
    /// from the first to the last back-to-back trial and never entered a
    /// Serious/Critical thermal state. Fair is tolerated (it is a normal
    /// sustained-load plateau, not throttling evidence); Serious/Critical is
    /// the transition the device matrix asks us to record.
    static func sustainedStable(
        decodeDriftPercent: Double,
        maxThermalRank: Int
    ) -> Bool {
        decodeDriftPercent >= -5 && maxThermalRank <= 1
    }

    /// Ranks a thermal label from the runner's `label` extension.
    static func thermalRank(_ label: String) -> Int {
        if label.contains("critical") { return 3 }
        if label.contains("serious") { return 2 }
        if label.contains("fair") { return 1 }
        return 0
    }

    /// Recovery status text with remaining time and the next trial.
    static func recoveryText(
        elapsedSeconds: Double,
        minimumSeconds: Double,
        nextMode: Edge0ExecutionMode,
        nextIndex: Int,
        planned: Int
    ) -> String {
        let remaining = max(0, minimumSeconds - elapsedSeconds)
        let modeName = Edge0DiagnosticKind.modeLabel(nextMode)
        return String(
            format: "Recovery: %.0f s remaining. Next: scored %@ trial %d of %d.",
            remaining, modeName, nextIndex, planned
        )
    }
}
