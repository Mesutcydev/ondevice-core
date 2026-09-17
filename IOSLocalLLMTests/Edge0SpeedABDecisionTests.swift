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
//   6. the expert-reads A/B kind and its frozen acceptance rule;
//   7. the sustained-thermal kind, its stability rule, and thermal ranks;
//   8. the session-reuse prefix decision (prompt cache).

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
        // Prefill/TTFT are TIME deltas: slower than +5% is a fail, faster
        // is fine.
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: 5.1, ttftDeltaPercent: 0, decodeDeltaPercent: 10
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: 0, ttftDeltaPercent: 5.1, decodeDeltaPercent: 10
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.readaheadAcceptance(
            prefillDeltaPercent: -10, ttftDeltaPercent: -10, decodeDeltaPercent: 10
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
        // Prefill is a TIME delta: -3% (faster) meets the bar.
        XCTAssertTrue(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: -3, decodeDeltaPercent: 0
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: -10, decodeDeltaPercent: -3
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: -2.9, decodeDeltaPercent: 10
        ))
        // A SLOWER prefill can never pass, however good decode is.
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: 5, decodeDeltaPercent: 10
        ))
        // Decode must not degrade beyond -3%.
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: -10, decodeDeltaPercent: -3.1
        ))
        // The device result (2026-09-17: prefill -1.5%, decode -3.5%)
        // is rejected on both terms.
        XCTAssertFalse(Edge0DiagnosticPlan.readsAcceptance(
            prefillDeltaPercent: -1.5, decodeDeltaPercent: -3.5
        ))
    }

    // MARK: 7. Sustained (thermal) kind

    func testSustainedPlanIsBackToBackStaged() {
        XCTAssertEqual(
            Edge0DiagnosticKind.sustained35B.scoredPlan,
            Array(repeating: .staged, count: 6)
        )
        XCTAssertTrue(Edge0DiagnosticPlan.populationGate(
            kind: .sustained35B, exactCount: 0, boundedCount: 0, stagedCount: 6
        ))
    }

    func testSustainedStableRule() {
        // Stable: no serious transition, drift within -5%.
        XCTAssertTrue(Edge0DiagnosticPlan.sustainedStable(
            decodeDriftPercent: 0, maxThermalRank: 0
        ))
        XCTAssertTrue(Edge0DiagnosticPlan.sustainedStable(
            decodeDriftPercent: -5, maxThermalRank: 1
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.sustainedStable(
            decodeDriftPercent: -5.1, maxThermalRank: 0
        ))
        XCTAssertFalse(Edge0DiagnosticPlan.sustainedStable(
            decodeDriftPercent: 0, maxThermalRank: 2
        ))
    }

    func testThermalRankMapping() {
        XCTAssertEqual(Edge0DiagnosticPlan.thermalRank("thermal nominal"), 0)
        XCTAssertEqual(Edge0DiagnosticPlan.thermalRank("thermal fair"), 1)
        XCTAssertEqual(Edge0DiagnosticPlan.thermalRank("thermal serious"), 2)
        XCTAssertEqual(Edge0DiagnosticPlan.thermalRank("thermal critical"), 3)
    }
}

// MARK: - Session-reuse prefix decision (prompt cache)

/// Pure prefix-reuse decision for the 35B prompt cache (no MLX needed).
@MainActor
final class Edge0SessionReuseTests: XCTestCase {
    func testExactExtensionReusesTheWholeSnapshot() {
        XCTAssertEqual(
            Edge0_35BEngine.sessionReuseCount(
                enabled: true, snapshotTokens: [1, 2, 3],
                keyMatches: true, promptTokens: [1, 2, 3, 4, 5]
            ),
            3
        )
    }

    func testIdenticalPromptIsARegenerationReuse() {
        XCTAssertEqual(
            Edge0_35BEngine.sessionReuseCount(
                enabled: true, snapshotTokens: [1, 2, 3],
                keyMatches: true, promptTokens: [1, 2, 3]
            ),
            3
        )
    }

    func testDivergenceFallsBackToFreshPrefill() {
        XCTAssertNil(Edge0_35BEngine.sessionReuseCount(
            enabled: true, snapshotTokens: [1, 2, 3],
            keyMatches: true, promptTokens: [1, 2, 9, 4]
        ))
    }

    func testTruncatedPromptFallsBackToFreshPrefill() {
        XCTAssertNil(Edge0_35BEngine.sessionReuseCount(
            enabled: true, snapshotTokens: [1, 2, 3],
            keyMatches: true, promptTokens: [1, 2]
        ))
    }

    func testKeyMismatchDisabledAndMissingSnapshotFallBack() {
        XCTAssertNil(Edge0_35BEngine.sessionReuseCount(
            enabled: true, snapshotTokens: [1, 2, 3],
            keyMatches: false, promptTokens: [1, 2, 3, 4]
        ))
        XCTAssertNil(Edge0_35BEngine.sessionReuseCount(
            enabled: false, snapshotTokens: [1, 2, 3],
            keyMatches: true, promptTokens: [1, 2, 3, 4]
        ))
        XCTAssertNil(Edge0_35BEngine.sessionReuseCount(
            enabled: true, snapshotTokens: nil,
            keyMatches: true, promptTokens: [1, 2, 3, 4]
        ))
    }

    /// The device validation once found the probe returning nil instantly.
    /// This pins the dispatch chain: a managed wrapper must reach the
    /// backend's guard (which throws noActiveModel when no model is loaded)
    /// instead of falling through to the protocol-extension nil default.
    func testSessionReuseProbeDispatchReachesTheBackend() async {
        let backend = Edge0RuntimeBackend()
        let managed = ManagedRuntimeEngine(
            id: "dispatch-test",
            runtime: .edge0MLX,
            capabilities: RuntimeCapabilities(),
            backend: backend
        )
        do {
            let result = try await managed.runSessionReuseProbe()
            XCTFail(
                "expected the backend's noActiveModel guard to throw; got "
                    + String(describing: result)
            )
        } catch {
            // Reached the backend (its family guard threw) — chain wired.
        }
    }

    func testBackendSessionReuseProbeGuardThrowsWithoutFamily() async {
        let backend = Edge0RuntimeBackend()
        do {
            let result = try await backend.runSessionReuseProbe()
            XCTFail("expected noActiveModel; got \(String(describing: result))")
        } catch {
            // Expected: loadedFamily is nil before any load.
        }
    }
}
