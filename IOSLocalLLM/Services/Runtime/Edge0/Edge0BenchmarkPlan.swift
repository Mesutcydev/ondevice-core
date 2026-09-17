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
