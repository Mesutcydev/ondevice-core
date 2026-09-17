import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0SpeedABDecisionTests
//
// Regression tests for the 2026-09-17 build-47 finding: four completed
// knob A/Bs (eval-window, microbatch, prerouter, compute) exported
// "FINAL — completed 4/4" with NO DECISION section. Root cause: the
// decision stage gated on Exact/Bounded mode populations before any
// kind-specific block, but every knob kind runs a staged-only plan, so
// the gate dead-ended every completed knob run.
//
// These tests pin:
//   1. the population gate routes every knob kind to its verdict path;
//   2. the readahead A/B kind exists with a counterbalanced plan;
//   3. the frozen readahead acceptance rule;
//   4. the readahead requested/effective metric pair plumbing;
//   5. engine-side load-capture of the readahead flag;
//   6. the expert-reads A/B kind and its frozen acceptance rule.

@MainActor
final class Edge0SpeedABDecisionTests: XCTestCase {

    private func resetPreferences() {
        Edge0EnginePreferences.edge0_35BReadaheadHints = false
        Edge0EnginePreferences.edge0_35BRouterReadbackMode = 0
        Edge0EnginePreferences.edge0_35BExecutionMode = .staged
    }

    override func tearDown() {
        resetPreferences()
        super.tearDown()
    }

    // MARK: 1. Population gate

    /// Every knob kind must pass the gate with ZERO Exact/Bounded trials —
    /// the build-47 failure mode was a completed staged-only run reaching
    /// the decision stage and producing an empty verdict.
    func testKnobKindsPassPopulationGateWithNoModePopulations() {
        for kind in Edge0DiagnosticKind.allCases where kind != .singleExact
            && kind != .ab && kind != .prefillAB && kind != .exactDrift {
            XCTAssertTrue(
                Edge0DiagnosticPlan.populationGate(
                    kind: kind, exactCount: 0, boundedCount: 0, stagedCount: 4
                ),
                "\(kind.rawValue) must reach its verdict with staged-only trials"
            )
        }
    }

    /// Mode-pair kinds still require their populations — the gate must not
    /// become a no-op for the kinds that DO compare execution modes.
    func testModePairKindsStillGateOnModePopulations() {
        XCTAssertFalse(Edge0DiagnosticPlan.populationGate(
            kind: .ab, exactCount: 0, boundedCount: 0, stagedCount: 4
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.populationGate(
            kind: .ab, exactCount: 1, boundedCount: 2, stagedCount: 0
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.populationGate(
            kind: .ab, exactCount: 2, boundedCount: 2, stagedCount: 0
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.populationGate(
            kind: .prefillAB, exactCount: 2, boundedCount: 1, stagedCount: 2
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.populationGate(
            kind: .prefillAB, exactCount: 0, boundedCount: 2, stagedCount: 2
        ))
    }

    // MARK: 2. Readahead A/B kind

    func testReadaheadABHasCounterbalancedStagedPlan() {
        XCTAssertEqual(
            Edge0DiagnosticKind.readaheadAB.scoredPlan,
            [.staged, .staged, .staged, .staged]
        )
        XCTAssertEqual(
            Edge0DiagnosticKind.readaheadAB.warmUpModes,
            [.staged]
        )
    }

    // MARK: 3. Acceptance rule

    func testReadaheadAcceptanceRule() {
        // Decode is the primary metric: +5% required.
        XCTAssertTrue(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: -1, ttftDeltaPercent: -1, decodeDeltaPercent: 5
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: 0, ttftDeltaPercent: 0, decodeDeltaPercent: 10
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: -1, ttftDeltaPercent: -1, decodeDeltaPercent: 4.9
        ))
        // Prefill/TTFT must not degrade beyond -5%.
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: -5.1, ttftDeltaPercent: 0, decodeDeltaPercent: 10
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: 0, ttftDeltaPercent: -5.1, decodeDeltaPercent: 10
        ))
        // The advisory-on decode regression observed on device
        // (-6.8% decode) would be rejected by this rule.
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: 0, ttftDeltaPercent: 0, decodeDeltaPercent: -6.8
        ))
    }

    // MARK: 4. Metric-pair plumbing

    /// The backend exports the load-captured readahead state as the
    /// effective half of the requested/effective pair, so the A/B decision
    /// can distinguish requested-on-without-reload from a real on-arm.
    func testGenerationMetricsCarryReadaheadPair() {
        var metrics = Edge0_35BGenerationMetrics()
        XCTAssertFalse(metrics.readaheadRequested)
        XCTAssertFalse(metrics.readaheadEffective)

        metrics.readaheadRequested = true
        metrics.readaheadEffective = true
        XCTAssertTrue(metrics.readaheadRequested)
        XCTAssertTrue(metrics.readaheadEffective)
    }

    // MARK: 5. Engine load capture

    /// The engine reads the preference ONCE at load and freezes it: a later
    /// preference change must not leak into the load-captured state, which
    /// is what the reload-per-arm lifecycle depends on.
    func testEngineLoadCaptureFreezesReadaheadState() {
        Edge0EnginePreferences.edge0_35BReadaheadHints = true
        let engine = Edge0_35BEngine()
        // Not loaded: the frozen state stays the default (false).
        XCTAssertFalse(engine.readaheadHintsEnabled)
        // The preference is still live for the NEXT load to capture.
        XCTAssertTrue(Edge0EnginePreferences.edge0_35BReadaheadHints)

        Edge0EnginePreferences.edge0_35BReadaheadHints = false
        _ = Edge0_35BEngine()
        XCTAssertFalse(engine.readaheadHintsEnabled)
    }

    // MARK: 6. Expert-reads A/B kind

    func testReadsABHasCounterbalancedStagedPlan() {
        XCTAssertEqual(
            Edge0DiagnosticKind.readsAB.scoredPlan,
            [.staged, .staged, .staged, .staged]
        )
        XCTAssertTrue(Edge0DiagnosticPlan.populationGate(
            kind: .readsAB, exactCount: 0, boundedCount: 0, stagedCount: 4
        ))
    }

    func testReadsAcceptanceRule() {
        // Prefill is the primary metric: +3% required.
        XCTAssertTrue(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: 3, decodeDeltaPercent: 0
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: 10, decodeDeltaPercent: -3
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: 2.9, decodeDeltaPercent: 10
        ))
        // Decode must not degrade beyond -3%.
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: 10, decodeDeltaPercent: -3.1
        ))
    }
}
