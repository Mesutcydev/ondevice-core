# Edge0 audit round — 2026-09-17

Scope: the complete Edge0 runtime (`IOSLocalLLM/Services/Runtime/Edge0/`),
its tests, and the Edge0 documents, in the working-tree state after the
Phase 5M readahead work and the 2026-09-17 pass (per-layer read-plan hoist,
NAX gate mirror, NAX A/B script, doc errata).

Provenance: source inspection, call-site audit, and static checks on this
machine; `xcodebuild build-for-testing` compile gate for **device** (full
test target, `-derivedDataPath build/5A-DD`, `CODE_SIGNING_ALLOWED=NO`);
`scripts/validate_open_source.sh`; and — added the same day — focused unit
execution on the iPhone 17 simulator through the isolated sim-compat project
(`project-simcompat.yml` → `OnDeviceSimCompat.xcworkspace`, the device-only
`coreai-models` package excluded). Real-checkpoint regressions still require
the device session — see §4 for the honest matrix.

## 1. What this pass changed (verified in source)

| Item | Implementation | Evidence |
| --- | --- | --- |
| 35B per-layer read plan (Edge0-AI/Edge0#7 port) | `Edge0_35BExpertReadPlan` / `Edge0_35BExpertGeometry`; `Edge0_35BExpertLoader` resolves locations, row geometry and MLX shapes once per layer at model load | `index.location(` occurs exactly **3×** in `Edge0_35BRealWeights.swift`, all inside the plan builder; the per-expert `matrix(_:expert:)` path contains none |
| 8B per-layer plan | `Edge0ExpertLayerLocations` + `Edge0ExpertLayout.layerLocations(for:in:)`; `Edge0ExpertLoader.init` resolves and validates every expert layer once | `index.location(` count in `Edge0ExpertLoader.swift` = **0**; per-load path is dict lookup → `bundle(for:)` assembly → row slices |
| Fail-fast validation | Both loaders now raise missing-tensor / shape / dtype / quantization errors at model load (engine construction) instead of first expert load | Covered by `testLoaderFailsFastWhenLayerTensorIsMissing`, `testProductionInitFailsFastOnIncompleteCheckpoint`, `testReadPlanFailsFastWhenTensorIsMissing` |
| NAX gate mirror | `Edge0MetalEnvironment` (read-only) appended to the device-validation summary | `Edge0DeviceValidation.describeDevice()`; `Edge0MetalEnvironmentTests` pin parse + threshold math against MLX's condition |
| NAX A/B build arm | `scripts/patch-mlx-disable-nax.sh` (disable/enable/status, idempotent) | Exercised end-to-end on a scratch checkout: status→disable→status→disable(no-op)→enable→status all correct; live `build/5A-DD` checkout left **enabled** |
| Doc errata | A18→A19 corrected in the rebase audit (E5 row, §15.3 erratum, compat-matrix row, compile note), benchmark notes §5, 35B doc candidate cell; scan doc §7/§8 added | `Docs/EDGE0_UPSTREAM_REBASE_AUDIT.md`, `scripts/edge0_upstream_benchmark_notes.md`, `Docs/EDGE0_35B_MODEL_ARCHITECTURE.md`, `Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md` |

## 2. Invariant checks

- **Byte ranges unchanged.** The plan only hoists resolution; per-expert
  reads still address `rowByteCount × expert` inside the same tensors, and
  the 8B path still uses `Edge0TensorLocation.row(_:)` slices. New tests
  assert byte-identity against direct store range reads.
- **Routing authority untouched.** No change to router, staging, prerouter,
  or pool code. `Edge0_35BModel.swift` diff is limited to the loader
  construction site.
- **Production defaults intact** (`Edge0EnginePreferences`):
  `edge0_35BStagedEvalWindow = 1`, `edge0_35BMicrobatchGroupSize = 4`,
  `edge0_35BAdvisoryPrerouter = false`, `edge0_35BRouterReadbackMode = 0`,
  `edge0_35BReadaheadHints = false`.
- **Readahead remains advisory-only** and default-OFF; hints ride on the
  same plan descriptors, failure-tolerant, never in the read path.
- **No dependency change.** Pin unchanged (`PrismML-Eng/mlx-swift @ e40e0a57`,
  MLX C++ 0.31.1, mlx-c v0.6.0, mlx-swift-lm 3.31.4). No new third-party
  material, so no notice/license updates were required.
- **API compatibility.** `Edge0ExpertLayout.bundleLocation(for:in:)` keeps
  its signature, error order (layer → expert → resolve) and validation
  behavior; `Edge0ModelArtifacts.validateWeightGeometry` and the layout
  tests are unaffected. `Edge0_35BExpertLoader(index:stores:layer:
  readaheadHints:)` keeps its shape, now `throws` — all 13 call sites
  (engine, model, 11 parity sites) updated; no other callers exist.

## 3. Static evidence

- **Compile gate:** `** TEST BUILD SUCCEEDED **`, 0 errors, full
  `IOSLocalLLMTests` target built for `generic/platform=iOS`
  (`build/edge0-hoist-buildfortesting.log`).
- **Warnings:** all Edge0 warnings cleared in the follow-up cleanup —
  `Edge0_35BPrerouter` Sendable conformances (`@unchecked Sendable`),
  `Edge0SpeedAB` (`nonisolated` constant; sampler lock moved into a sync
  helper), `Edge0Engine`/`Edge0RealWeights` (`var`→`let`),
  `Edge0PrerouterRuntime` (`withLock` result), `Edge0_35BRealWeights` (dead
  locals), and the deprecated `asData(noCopy:)` calls in four test files
  (→ `asData().data`). Rebuild: **0 Edge0 warnings**; remaining app-wide
  warnings are pre-existing and untouched.
- **Stale references:** none (`Self.byteSize`, `expertLoader.index`,
  old loader member access all absent; no TODOs/FIXMEs in touched files).
- **Test inventory:** 33 `Edge0*` test files, including the two new suites
  (`Edge0_35BExpertLoaderTests`, `Edge0MetalEnvironmentTests`) and additions
  to `Edge0ExpertLoaderTests` / `Edge0ExpertLayoutTests`.
- **Project file:** regenerated from `project.yml` with XcodeGen; the new
  sources/tests are present in `project.pbxproj` (+429/−86, regeneration
  noise included).

## 4. Execution status (honest matrix)

| Check | Result |
| --- | --- |
| Device compile gate (build-for-testing, full test target) | **Passed**, 0 errors |
| Open-source validator (`validate_open_source.sh`) | **Passed** — "Repository hygiene checks passed" (the previously recorded CITATION.cff version failure is resolved by the 1.0.0 metadata refresh) |
| Focused Edge0 unit tests, simulator | **Executed clean** through the isolated sim-compat project: **21 passed, 29 skipped, 0 failures, 0 aborts** (`Test Suite 'Selected tests' passed`, exit 0; `build/simcompat-tests5.log`). Skips are environment gates (no real checkpoints, no oracle fixtures) plus the MLX-allocating cases, which skip via `Edge0TestDevice.requireSimulatorMLXSupport()`: the simulated Metal device cannot back mlx at all (no architecture name — mlx aborts in `metal::Device::Device()`; private-mode heaps rejected — `MTLSimDevice` assertion), and mlx's scheduler initializes the GPU stream unconditionally, so even CPU-only use is impossible there |
| Focused Edge0 unit tests, device | **Blocked in this environment:** Xcode has no signed-in account, so automatic provisioning fails for all bundle IDs ("No Accounts … No profiles"). This is consistent with the profile-less release scheme. The 7 MLX-eval cases above and the real-checkpoint suites belong here |
| Real-checkpoint 35B regressions (parity/oracle suite) | **Not run** — no checkpoint staged on this machine; `EDGE0_35B_MODEL` gated |
| Device A/Bs (5M readahead, NAX engagement) | **Not run** — require the test device with a signed build |

Consequence: on the simulator, all non-gated cases pass and the
MLX-allocating cases skip cleanly (the simulated GPU cannot back mlx); those
cases must be exercised in the next signed device session before being
described as passing. The real-checkpoint regressions likewise wait for the
device session.

## 5. Findings and open items

All five release-process findings were fixed on 2026-09-17 (same day):

1. **Release notes — FIXED.** `CHANGELOG.md` `[Unreleased]` now covers the
   5M + hoist + NAX work, the warning cleanup, and the sim-compat test path.
2. **Build number — FIXED.** `CURRENT_PROJECT_VERSION` is `47` in
   `project.yml` (app + share extension) and the regenerated project.
3. **Stray root file `-` — FIXED.** Moved out of the tree to
   `build/stray-dash-file.plist.bak` (build/ is gitignored); not committed.
4. **Uncommitted state — FIXED.** The full set (sources, tests, docs,
   `project.pbxproj`, `project-simcompat.yml`, `OnDeviceSimCompat.xcworkspace`)
   is committed as the follow-up to the baseline snapshot. Reminder for
   release builds: `xcodegen generate` **then** `pod install` — the
   CocoaPods phases and library links are re-added by pod install.
5. **Swift-6 warnings — FIXED.** All Edge0 warnings cleared (Sendable
   conformances, NSLock in async contexts, `nonisolated` constant,
   `var`→`let`, deprecated `asData(noCopy:)` → `asData().data`); the rebuild
   shows zero Edge0 warnings.
6. **NAX engagement is still unverified on device.** The gate mirror says
   "eligible" on the A19 Pro; the trace recipe + A/B arm are ready
   (scan doc §8, `scripts/patch-mlx-disable-nax.sh`). Until traced, treat
   all MLX-side performance claims as unconfirmed.
7. **5M readahead A/B remains the scheduled device experiment** (toggle in
   Diagnostics; engine captures it once per load). The prerouter,
   eval-window, and microbatch A/Bs have since run on device — see
   "Build-47 device A/B session" below.
8. **A19-specific hazards on record** (mlx#3702 fp32 wrongness for certain
   shapes; TF32 default on NAX devices; Xcode 26.5 metalfe context) — see
   the scan doc §3. The frozen nine-ID oracle passing on device is the
   current mitigation evidence.

### Build-47/49 device A/B session (iPhone18,2 · 2026-09-17, Diagnostics runner)

Six counterbalanced runs on the production pool (512 MiB · reads 4 ·
greedy · 118-token prompt · 64 output tokens · 60 s idle recovery ·
thermal nominal throughout; identical router hash and expert counts in
every trial):

| Experiment | Result | Verdict |
| --- | --- | --- |
| Exact vs Bounded decode | decode 4.83 → 6.97 tok/s (+44%) | Bounded decode confirmed (the staged default's decode path) |
| Staged vs bounded/exact prefill | 6.9–7.1 s vs 10.3–11.8 s | Staged prefill confirmed as the production default |
| Staged microbatch g1 vs g4 | prefill 8.24 s → 6.95 s (−16%) | g4 promotion reconfirmed |
| Staged eval window w1 vs w4 | 6.91/7.07 s vs 6.91/7.70 s | No win — w1 stays |
| Advisory prerouter off vs on | decode 6.85–7.27 vs 6.51–6.65 tok/s; expert loads 9.6k → 12.3k (+28%, ~4.8 GB wasted reads per run) | **Rejected** — stays OFF |
| Advisory readahead (5M) off vs hints | decode 7.29 → 5.69 tok/s median (−22.1%); prefill/TTFT −0.7% (noise) | **Rejected** — stays OFF |
| Expert reads 4 vs 6 (build 49) | prefill 7.00 → 6.90 s (1.5% faster, below the 3% bar); decode 7.05 → 6.80 tok/s (−3.5%, beyond the −3% floor) | **Rejected** — reads 4 stays |

Sequence parity held in every trial (`sequence match: identical`), so no
candidate ever touched routing or outputs. The 5M readahead and
expert-reads A/Bs are now closed (both rejected with evidence, build 48/49
reload-per-arm runners); the NAX engagement trace remains the one open
device item. The hoist itself is
invisible in these numbers, as expected: >50% of prefill MoE time is
expert-load acquire wait (I/O), not metadata resolution.

### Build-49 in-app device validation (Edge0-35B · 2026-09-17)

The in-app device validation runner (`Edge0DeviceValidationRunner` — the
production Assistant path, never a test-only model instance) completed all
15 stages on the sideloaded build 49 (iPhone18,2 · iOS 27.2 · `applegpu_g18p`,
NAX-eligible; production configuration: staged prefill, bounded decode,
reads 4):

| Stage | Result |
| --- | --- |
| Artifacts / admission | resident 1397 tensors/1.39 GB · experts 360/18.12 GB · 310 LoRA modules; pool auto → 1213 slots/2 GiB · safe input 4096 tok (experimental cap) |
| Load | 1.94 s · footprint 103.3 MB → 1.89 GB |
| Prefill / first token | 7.58 s · TTFT 7.65 s · hit 78% · aggregate expert wait 46.4 s |
| Decode | 45 tok · 8.33 tok/s · hit 78% · stop eos |
| **Exact reference parity (9 IDs)** | **PASS · 9/9 exact ids · first differing index none** · position 13 |
| Cancellation / after-cancel | stop→end 0.02 s · generation resumes without restart |
| Unload / MLX switch / switch back | 0.18 s · Bonsai 27B 2.71 s · Edge0-35B 2.14 s |

The frozen nine-ID oracle passing **on device through the production
staged path** (`mode.effective = staged`, `prefill staged·microbatch4`,
`decode boundedPrefetch`, `reads.configured 4`) is the real-hardware
correctness evidence for the exactness contract; peak footprint 4.42 GB,
thermal nominal throughout, NAX eligibility confirmed device-side
(engagement still pending a Metal trace).

### Build-54 device validation (prompt-cache proof · 2026-09-17)

The 16-stage in-app validation on the sideloaded build 54 is fully green —
the first complete pass — including the new **Session reuse parity** stage:

| Stage | Result |
| --- | --- |
| 1–10, 12–16 | PASS (oracle 9/9 again; load 1.90 s; prefill 7.40 s; TTFT 7.46 s; decode 8.30 tok/s; cancel stop→end 0.03 s; unload 0.19 s; MLX switch 2.69 s; switch back 2.16 s) |
| **11. Session reuse parity** | **PASS · reuse applied · reused 22 tok · prefilled 30 tok · prompts 29→52 · answers byte-identical** |

The reuse numbers are the design working exactly: turn 2 restored the
prompt-boundary snapshot (system + first user turn = 22 tokens) and
prefilled only the 30 new tokens (assistant answer + second user turn +
generation tail). In a long chat the reused fraction grows with the
history, which is where the per-turn prefill cost collapses.

## 6. Verdict

The pass is **source-complete, compile-clean, and test-executed on the
simulator**: byte-range semantics unchanged by construction, routing
authority and production defaults untouched, call sites fully updated, and
every new failure mode covered. Findings 1–5 are fixed and committed. What
remains: the **device session** (signed build) for the MLX-evaluation cases,
the real-checkpoint suites, and the 5M/NAX A/Bs; then IPA packaging.
Nothing found in this round blocks packaging.
