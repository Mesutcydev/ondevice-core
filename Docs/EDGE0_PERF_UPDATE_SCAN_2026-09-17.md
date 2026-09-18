# Edge0 performance-update scan (2026-09-17)

Research pass across the upstream Edge0 repository, the MLX C++ / mlx-swift /
mlx-c stack our runtime is pinned to, and public device benchmarks — looking
for performance work that could improve the two measured pain points on
iPhone 17 Pro Max (iPhone18,2):

- **first answer** (prefill + TTFT, accepted production ≈ 6.5–7.0 s on the
  118-token frozen profile, decode ≈ 7.5 tok/s);
- **decode rate** (≈ 7.4–7.6 tok/s, boundedPrefetch path).

Provenance: GitHub REST/API reads at the SHAs named below, plus published
measurements quoted from the linked PRs/issues. Nothing here is a device
measurement we performed. Snapshot: 2026-09-17 ~11:00 UTC.

---

## 0. The finding that changes the premise

Our audit (`EDGE0_UPSTREAM_REBASE_AUDIT.md` §15) describes the target as
"iPhone18,2 (A18 Pro)". That is wrong: **iPhone18,2 is the iPhone 17 Pro Max
with the A19 Pro GPU**, and per MLX's own gate (`device.h`, `#3083` — verified
in our pin at `Source/Cmlx/mlx/mlx/backend/metal/device.h:268-287`), the NAX
(neural-accelerator) matmul path is enabled for **phone-class ('p') GPUs at
gen ≥ 18**. `device.cpp` documents `'p'` as "phone" class. A18 = g17p is
excluded (that is the #3083 fix); **A19/A19 Pro = g18p is included**
(confirmed by mlx#3702: "the NAX matmul path, which #3083 enables for
`gen >= 18` phone architectures (i.e. A19)").

Our app builds with `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, so the runtime
availability half of the gate (`iOS 26.2+`) is satisfied unconditionally.
**Consequence: on this device the MLX stack is expected to take NAX kernels,
and every NAX-kernel performance improvement in MLX 0.32.x is hardware-relevant
to us — while simultaneously the A19-specific NAX hazards below apply.**

Two follow-ups the audit inherited from the "A18" assumption must be revised:
E4/E5 (NAX gating by OS version) is not about A18 mis-gating; it is about
whether our *current* build actually executes NAX kernels on A19, and which
ones. See §3.

---

## 1. Upstream Edge0 — what moved, what is pending

Frozen revision `f8c4cb2c` (2026-09-16) is still effectively current:

- `main` HEAD = `5b65e6fcc66c` (2026-09-17T04:29Z) — **docs only** ("add the
  arXiv badge"). Last code-affecting commit remains `62dcab2`
  (WILLNEED readahead + in-place staged stack, 2026-09-14).
- HF checkpoint: no weight changes. `Edge0-35B-A3B-preview` recent commits
  (`e21098e7faa9`, `0534b75900d2`, `15dc6959b64f`, our pin `1ff9f447`) are
  all README-only.
- New paper (docs commit `ca40e7d`): **arXiv 2609.18063, "The Other Half of
  the Memory Wall: Serving 35B MoEs from SSD with Trained Routing
  Prediction"** (submitted 2026-09-16). Claims 20 tok/s on a 24 GB machine
  inside ~3 GiB. It re-confirms the architecture we already audited —
  "the prediction is consumed as the routing itself" — i.e. the zero-drop
  staged decode is still bought with routing authority. Nothing in it
  relaxes our exactness contract.

### Open PRs with performance content (unmerged)

| PR | What | Measured | Source |
| --- | --- | --- | --- |
| **#7** `perf: prepare typed mmap expert reads once per layer` | Prepare per-layer typed, immutable row readers once; `_build` reads selected experts with shard/offset/stride/count/dtype already resolved — removes repeated tensor-name lookup + metadata arithmetic + intermediate byte views from the warm-file cache-miss path | 5.25–11.74% median paired reduction of expert-build time (328 paired blocks, 65,600 timed builds; Linux i5, MLX CPU) | lmtlssss, open since 2026-09-10 |
| **#6** `perf(streaming): page-granular mmap warming` | Touch exactly one byte per OS page instead of chunk-sized copies; exact page coverage tests | Warming *work*: 68.38% median paired reduction (real-weight prep). **Cold page-cache controls: no clear speed advantage** (128 MiB interval [−2.65%, +0.37%]) | lmtlssss, open since 2026-09-10 |
| #23 (draft) | GGUF + packed Metal kernels — direction feedback; author reports 0.311 tok/s / TTFT 36.9 s on an M5 with an IQ1_S 3-shard checkpoint. Not a candidate; context only | — | owenqwenstarsky |
| #3 | Independent Swift/MLX iPhone 8B M0/M1 port — confirms the porting boundary, no perf content | — | Aventurine-git |

### Issue signals

- **#17** (open): "Decode speed ~30x below documented benchmarks on Apple M1
  (8 GB)" — 0.66–0.81 tok/s. Maintainer: decode on memory-constrained hosts
  is page-fault bound, not compute bound; recommends `EDGE0_PREWARM=1` and a
  larger expert cache. Counter-datapoint in-thread: M1 Max / 64 GiB = 17.3
  tok/s overall, 19.0 steady. Confirms the I/O-bound regime for streaming
  decode and that capacity (not I/O bandwidth) collapses it.
- **#106** (open, filed 2026-09-17): README's "peak active memory" is the MLX
  allocator peak, not process memory; hot-expert backing is anonymous memory.
  Informative for our memory-budget documentation, not a perf item.

---

## 2. MLX upstream — the NAX kernel wave (0.32.0 → main)

Our pin is MLX C++ **0.31.1** (fork submodule `d90771c8`). Upstream MLX is at
**v0.32.2** (2026-08-25) plus main commits through 2026-09-16. The delta since
0.31.1 is dominated by NAX (Metal 4 TensorOps) kernel work that targets
*exactly* our model family. Items that map onto our ops:

### 2.1 Quantized MoE / gather_qmm — our routed experts

| Upstream change | Effect | Our exposure |
| --- | --- | --- |
| `#4352` Skip unnecessary simdgroup computations for quantised MOE matmuls on NAX (v0.32.2) | **+4.25% … +6.68% prefill** on Qwen3-30B-A3B-4bit (M5 Pro/Max) | `gather_qmm_rhs_nax` = the kernel our routed MoE uses (`Edge0ExpertMath` → `MLX.gatherQuantizedMM`, 4-bit affine, group 64, transpose) |
| `#4023` Pick BM from rows per expert in `gather_qmm_rhs_nax` (v0.32.1) | tuning for few-rows-per-expert dispatch | our decode routes ≤4 experts with 1 row each; microbatch-4 prefill = 1…4 rows/expert |
| `#4171` Use a 32-row block in `qmm_t_nax` when one block covers all of M (v0.32.2) | small-M tuning | per-token QMM stays M=1 (eval window 1) |
| `#4051` Fix and enable non-transposed NAX qmm (v0.32.1); `#3631`/`#3632` NAX qmm edge-tile / kernel-name fixes (v0.32.0) | correctness/unlock of NAX qmm variants | needed for stable NAX execution |
| `#3941` Skip empty NAX GEMM output groups (v0.32.1) | small win on ragged groups | our union stacks are ragged (U ∈ 1…4) |

### 2.2 Full attention (head_dim 256) — our 10 full-attention layers

| Upstream change | Effect | Our exposure |
| --- | --- | --- |
| `#3842` **Fused full-attention path for head_dim == 256 on NAX devices** (v0.32.2) | Motivated verbatim by "Full-attention layers in the **Qwen3.5/3.6 family** use head_dim == 256"; replaces the unfused graph that materializes `[heads, qL, kL]`; ~2× the unfused graph at long context | our full attention is 16 Q × 256 / 2 KV × 256. Dispatch needs causal, no array mask, **qL ≥ 1024** — i.e. long prompts, not the 118-token frozen profile |
| `#4416` Make head-dim-256 prefill with array mask run fused NAX kernel (main, 2026-09-02) | extends coverage to masked prefill | relevant for any masked/batched prefill path |
| `#3843` unroll_count(4) for the NAX attention Q@K.T loop (v0.32.1); `#4455` NAX attention for long unmasked D72/D80; `#4459` D512 vector attention; `#4431` gqa decode batch-offset fix | NAX attention tuning/fixes | head_dim 256 limits direct reuse of the small-head kernels; `#3842`/`#4416` are the ones that reach us |

### 2.3 GQA decode attention

`#4077` "Read each K/V byte once in gqa-8 decode attention" (v0.32.2) — our
full-attention layers are GQA-8 (16 Q / 2 KV heads), which matches the
kernel's `gqa_factor == 8` condition, **but the dispatch also requires
head_dim 64 or 128 and N ≥ 8192**. Our head_dim is 256 and our context is
clamped to 4096, so this kernel does **not** fire for us today. Worth
re-checking if/when head_dim-256 decode variants land or context grows.

### 2.4 Linear attention (GatedDeltaNet) — our 30 linear layers

`#4020` "Adding metal kernels for the gated delta nets" — **merged to main
2026-09-15** (post-0.32.2, in no release yet). Adds sequential / simdgroup /
NAX kernels for the gated delta rule (ICLR 2024 formulation), exposed as
`mlx::core::fast::gated_delta_update(queries, keys, values, gates, beta,
initial_state, mask)` (`mlx/fast.h:63`). Validated by the author on
`Qwen3.5-35B-A3B` (word perplexity identical across all three backends).

This is the single most on-target new primitive for our 35B: 30 of 40 layers
run the gated-delta recurrence, currently on our reference-ops path. Cost to
adopt: MLX C++ from main + an mlx-c binding + an mlx-swift binding (none
exist yet) + parity fixtures. Our Mac profile puts GatedDeltaNet+GQA at ~5%
of prefill wall; the decode-step share is unprofiled. Treat as a future
candidate, not a next-phase item.

### 2.5 Small-batch (decode-shaped) kernels

`#3764` small-batch quantized matvec (`qmv_wide`, v0.32.0), `#3888` `gemv_wide`
for fp16/bf16 matmuls of a few rows (v0.32.1) — decode is exactly small-M
matmuls for the resident projections, LoRA, router gate and lm_head. Direct
relevance to tok/s.

### 2.6 Other possibly-relevant

- `#4185` `force_fused` option for SDPA (v0.32.2) — an explicit control we
  do not have in 0.31.1.
- `#3622` "NAX requires setting MACOSX_DEPLOYMENT_TARGET=26.2" + `#3586`
  "Xcode 26.5 / metalfe-32023.883 mis-compiles NAX GEMM kernel" — applies to
  builds that compile the metallib locally. We build mlx-swift from source
  with Xcode 26.5 (our own `scripts/patch-mlx-metal-warning.sh` exists for a
  different Xcode 26.5 metal warning). This is a build-path risk to verify,
  not a perf update.
- `#3894` / `#3534` — fp32 matmul on NAX devices silently uses TF32-class
  precision (`MLX_ENABLE_TF32` default 1). Closed as expected behavior.
  Matters anywhere we do fp32 *matmuls* on device (we mostly do fp32
  elementwise + explicit rounding, so exposure is narrow — worth a grep).
- `MLX_METAL_FAST_SYNCH` exists as a documented env knob
  (`docs/src/usage/environment_variables.rst`, `mlx/fence.h`) — given our
  barrier-heavy decode (~82 host syncs/token per the audit), cheap to
  evaluate as a diagnostic, not a product lever.

---

## 3. A19-specific NAX hazards (new, must verify)

1. **mlx#3702** (open): on iPhone 17 Pro Max / A19 Pro, MLX returns
   *deterministically wrong* GPU results in a float32 pipeline (Demucs),
   matching an independently documented A19 dot-product hardware issue for
   certain matrix dimensions ("masking out unused lanes"). `MLX_ENABLE_TF32=0`
   did not fix it; forcing `can_use_nax = false` changed but did not fully
   fix the output. So on A19 there are correctness hazards beyond the
   documented TF32 precision trade — for *some* op/dtype/shape combinations.
   Their pipeline is fp32; our 35B path is bf16 + 4/8-bit quantized. **Our
   frozen nine-ID oracle passing on device is evidence our op mix is not
   affected, and that evidence should be recorded as the mitigation.**
2. **OS-version gate**: NAX engages only at iOS ≥ 26.2. Our app targets
   iOS 27.0, so the regime in the field is "NAX eligible". Any A/B we run on
   device compares against a NAX-on baseline, not a NAX-off baseline.
3. **Verification recipe (do first)**: capture a prefill and a decode with
   Instruments → Metal System Trace on the test device and check which
   kernels execute (`*_nax*` names such as `qmm_t_nax`,
   `gather_qmm_rhs_nax`, `steel_gemm_*_nax*`, `steel_attention_nax*`). If no
   `_nax` kernels appear, NAX is not engaged in our build and the §2 items
   stop being "tuning" and become "capability" — the largest single
   first-answer lever on the table. If they do appear, §2 is worth a
   measured 5–10% + attention-path improvements at long prompts.

---

## 4. mlx-swift delivery status and bump logistics

- Our pin `PrismML-Eng/mlx-swift @ e40e0a57` (2026-06-11) is the **tip of
  the fork's `prism` branch** — compare vs itself: identical, no upstream
  movement since. Fork delta over upstream = 1-bit affine quantization +
  1-bit `qmv`/`qmv_fast` decode kernels (PrismML work, "large mobile decode
  win") on top of an upstream 0.31.4-era main. Nothing 4-bit-relevant.
- Upstream mlx-swift: latest **tag 0.31.6** (2026-07-02). `main` moved to
  MLX C++ **0.32.2** via `ab924c82` ("update for mlx v0.32.2", 2026-09-01),
  plus Swift-side fixes after it: `#471` wired-memory ticket lifecycle
  during cancellation (2026-09-11), `#461` CompiledFunction/evalLock deadlock
  + compiler-cache race (2026-08-24), `#463` `StreamOrDevice.stream(_:)` arg
  fix (2026-08-27).
- **No tagged release carries any of that yet.** Maintainer in mlx-swift#470
  (2026-09-10): release is gated behind a CUDA build fix + mlx-c pickup,
  "best guess ~3 weeks"; the workaround offered is to pin `main` by commit
  hash or fork both mlx and mlx-swift.
- **mlx-swift#470 is the bump-warning we must internalize**: bumping 0.31.6
  → main (0.32.2) "changes generation output substantially" on *non-NAX*
  hardware — measured ~28% relative shift in a bf16 video pipeline output
  (identical weights/seed/code), not bisectable in reasonable time. The
  earliest ref carrying the NAX split-K dtype fix (mlx#3810) is that same
  main. For our exactness gates this means: **any bump past 0.31.1 requires
  re-baselining the frozen oracle and the full parity suite, and the
  bf16-logit router ties our parity fixtures depend on must be re-checked.**
- Other open mlx-swift issues relevant if we rebase the fork:
  `#446` (Package.swift `exclude:` list breaks for pins past v0.31.2 — jaccl
  restructure; fixed on main, but our fork must not carry the stale list),
  `#441` (batched single-token RoPE fix in mlx 0.32.0 — B>1 only, not our
  path), `#313` (MetalCompilerPlugin).
- Our audit's E6 remains the load-bearing constraint: C++ ≥ 0.31.2 makes
  default streams thread-local; `Edge0ExpertLoader` builds `MLXArray`s on
  task-group threads. 0.32.0 added `new_thread_unsafe_stream` (`#3578`) and
  main has `#4462` (don't restore a thread-affine stream across threads) —
  the escape hatches exist, but our bump checklist must include an explicit
  off-main-thread array-construction smoke test.

---

## 5. What we can do without any dependency change

**Port upstream PR #7's pattern into our loaders** (landed in this pass —
see §7). Our
`Edge0_35BExpertLoader.matrix(...)` re-derives, per expert per projection:
tensor names via `Edge0_35BExpertSpec.name(...)` (string building), three
`index.location(...)` lookups, row-byte-count geometry validation — 9 name
constructions + 9 index lookups + validations **per expert**; at ~160 expert
loads per decoded token that is ~1,440 resolutions/token plus the same again
during prefill. Upstream measured 5.25–11.74% median paired reduction of
expert-build time by pre-resolving exactly this once per layer. In Swift,
precompute per (layer × projection) a small immutable descriptor struct
(location, rowByteCount, dtype, shape) once at load; the per-expert path
becomes 9 × (advise → pread → wrap). Byte ranges are unchanged, so it is
exactness-inert by construction (the `Edge0Readahead` hint path can ride on
the same descriptors).

Also note: our Phase 5M `F_RDADVISE` readahead is already implemented and
default-OFF (`Edge0EnginePreferences.edge0_35BReadaheadHints`, wire-in at
`Edge0_35BExpertLoader.matrix`, diagnostics toggle "Readahead hints (5M)",
applied at next model load). Upstream PR #6's honest cold-cache caveat
("no clear speed advantage" on Linux) does not contradict our case — ours
issues hints against lookahead the pipeline already computes — but the
device A/B is the only way it becomes a default.

---

## 6. Ranked recommendations

1. **Verify NAX engagement on device** (Metal System Trace, §3.3). This
   decides everything else: capability (large) vs tuning (5–10%-class).
   Cost: one profiling session. No code change.
2. **If NAX is not engaged / only partially engaged**: treat enabling it as
   the top prefill/TTFT project, following Apple's own M5 numbers (NAX
   TTFT speedups 3.33–4.06×; decode 1.19–1.27× — decode stays
   bandwidth/IO-bound, which matches our 133 ms/token with ~270 MiB read).
   Requires the mlx-swift/C++ move (§4) *and* re-baselined exactness gates.
3. **If NAX is engaged**: plan the mlx-swift bump as a Phase-5 style
   project (main-pin or post-release) to collect the §2.1/§2.2/§2.5 kernel
   set; hard acceptance = frozen oracle + full parity re-baseline, per
   #470's warning. Keep the PrismML fork alive only if Bonsai 1-bit models
   stay in the product.
4. **Land the §5 loader-descriptor hoist now** (no dependency change,
   exactness-inert, measurable on the same device A/B harness).
5. **Phase 5M readahead A/B stands** as scheduled; upstream PR #6/#7 and
   issue #17 all corroborate the read-path focus for decode on flash-backed
   phones, with PR #6 warning not to over-claim cold-cache gains.
6. **Watch** (not now): `mlx#4020` gated-delta Metal kernels + Swift
   binding (their validation target is literally Qwen3.5-35B-A3B);
   `#4077` if head_dim-256 decode dispatch appears; `MLX_METAL_FAST_SYNCH`
   as a diagnostic; `#106` for memory-metric wording.

Do **not** expect the tok/s number to move much from any MLX change alone:
Apple's own NAX data shows decode gains of ~1.2× while our decode is I/O
and synchronization-bound by design. The first-answer number is where the
compute-side updates pay.

---

## 7. Implementation status (2026-09-17 pass)

Landed in this working tree:

| Item | Where |
| --- | --- |
| Per-layer read plan for the 35B routed experts (Edge0-AI/Edge0#7 pattern): locations, row geometry and MLX shapes resolved once at model load; per-expert path is advise → pread → wrap | `Edge0_35BExpertReadPlan` / `Edge0_35BExpertGeometry` in `IOSLocalLLM/Services/Runtime/Edge0/Edge0_35BRealWeights.swift`; loader rewritten; engine/model construction resolves the plan at load |
| Same treatment for the 8B loader: `Edge0ExpertLayerLocations` + `Edge0ExpertLayout.layerLocations(for:in:)`; `Edge0ExpertLoader` resolves every expert layer once at construction and fails fast on an incomplete checkpoint | `IOSLocalLLM/Services/Runtime/Edge0/Edge0ExpertLayout.swift`, `Edge0ExpertLoader.swift` |
| NAX gate mirror (read-only, no runtime effect) surfaced in Diagnostics | `Edge0MetalEnvironment` (`IOSLocalLLM/Services/Runtime/Edge0/Edge0MetalEnvironment.swift`), appended to the device-validation summary |
| NAX-off A/B build arm | `scripts/patch-mlx-disable-nax.sh` (`disable` / `enable` / `status`) |
| Tests | `Edge0_35BExpertLoaderTests`, `Edge0MetalEnvironmentTests`, plus fail-fast tests in `Edge0ExpertLoaderTests` / `Edge0ExpertLayoutTests` |

Byte ranges and array shapes are unchanged by construction (the plans only
hoist resolution), so the hoist is exactness-inert; the Phase 5M readahead
hint path rides on the same descriptors.

### 7.1 Follow-up pass (same day, after the first device A/B exports)

The four build-47 device A/B exports (eval-window, microbatch, prerouter,
compute; each "FINAL — completed 4/4") contained **no DECISION section**.
Root cause: `Edge0SpeedABRunner.computeDecision()` gated on
Exact/Bounded mode populations *before* the kind-specific blocks, but every
knob kind runs a staged-only plan, so the gate dead-ended every completed
knob run with an empty verdict (and drift was never labeled for them).
Landed fixes:

| Item | Where |
| --- | --- |
| Per-kind population gate (mode-pair kinds still require their mode populations; knob kinds route to their own verdicts) | `Edge0DiagnosticPlan.populationGate(kind:exactCount:boundedCount:stagedCount:)` |
| Per-arm drift labeling for knob kinds (first→last prefill change *within* an arm group) | `Edge0SpeedABRunner.knobArmGroups(_:)` + the drift rule in `computeDecision()` |
| The missing counterbalanced readahead A/B runner (the §5N open gap): reload-per-arm lifecycle, `readaheadRequested`/`readaheadEffective` proof pair (SETUP-BLOCKED when requested-on runs without a reload), frozen acceptance rule (decode ≥ +5%, prefill/TTFT ≥ −5%) | `Edge0DiagnosticKind.readaheadAB`, the reload block in `performRun()`, the decision block in `computeDecision()`, `Edge0DiagnosticPlan.readaheadAcceptance` |
| Engine exports the load-captured readahead state (`mode.readaheadEffective`, available at load time before any generation) | `Edge0_35BEngine.readaheadHintsEnabled`, `Edge0RuntimeBackend.metrics35B()` |
| Tests | `Edge0SpeedABDecisionTests` (6 cases: gate routing, mode-pair gates still bind, readahead plan, acceptance rule, metric pair, load-capture freeze) — executed 6/6 on the simulator |

Recomputed verdicts from the four build-47 exports (the runs were valid;
only the printing was broken): w4 prefill +4.5% / decode +0.9% → keep w1
(matches the Phase 5G closeout); g4 prefill −15.6% → reconfirms the promoted
g4 default; advisory-on decode −6.8% → keep advisory OFF (matches the Phase
5J expectation); batched readback −3.6% → below the frozen ≥5% bar, matches
the recorded Phase 5K rejection.

## 8. NAX verification procedure (device)

1. **Gate expectation.** Run the Edge0 Device Validation runner on the
   iPhone 17 Pro Max; the device summary now carries
   `metal applegpu_gXX · gen NN · NAX eligible|not eligible`. This is the
   read-only mirror of MLX's `is_nax_available()` — an expectation, not proof.
2. **Prove which kernels run.** Instruments → Metal System Trace on the
   device; capture a 35B generation with the prefill region emphasized and
   search kernel names for `_nax` (`qmm_t_nax`, `gather_qmm_rhs_nax`,
   `steel_gemm_*_nax*`, `steel_attention_nax*`). Present = NAX engaged.
3. **Attribute it (optional, decisive).** Build the NAX-off arm:
   `./scripts/patch-mlx-disable-nax.sh disable`, clean-build the Cmlx target,
   reinstall, re-measure the frozen profile; restore with `enable`. Any
   delta is the NAX contribution on this device. Numerics may differ between
   arms — re-run the frozen nine-ID oracle per arm before comparing outputs.
4. **Long-prompt attention check.** For prompts ≥ 1024 tokens the fused
   head_dim-256 NAX attention path (mlx#3842) is the one to watch; it does
   not engage on the 118-token frozen profile.

## 9. Pool-starved decode: audit findings 1+2+4 (build-55 candidates)

An external audit of the build-54 device numbers (load 1.90 s, prefill
7.40 s, decode 8.30 tok/s, pool auto → 2 GiB / 1213 slots, hit 78%, peak
4.42 GB) plus the build-47 expert-load counts (9.6k loads × 1,769,472 B per
182-token run ≈ 17 GB of flash reads per run) concluded the decode
bottleneck is the expert pool, and that the pool is capped by two accounting
mistakes rather than by the device:

1. **The state/KV reserve was a flat `ceiling / 8`** (~1.06 GB on the 12 GB
   phone) even though the admitted 4,096-token context can only materialize
   ~148 MB (KV + the fixed linear state). The difference was held out of
   pool headroom and reserved against nothing.
2. **The tier list stopped at 2 GiB**, so the binding constraint was the
   cap, not the headroom.

Landed in this working tree (both exactness-inert — caching changes no math):

| Item | Where |
| --- | --- |
| `Edge0_35BPoolAccounting` (legacy / reclaimed). Reclaimed allowance: `max(maxContextTokens × 20,480 B + linearStateBytes, 256 MiB)`, capped by `ceiling / 8`; tier list gains 3,072 MiB | `Edge0_35BMemoryBudget.stateKVAllowance`, `.poolTierBytes(for:)`, `.resolve(accounting:maxContextTokens:)`, `Edge0_35BContextBudget` |
| Load-captured knob + requested/effective proof pair; the budget resolves at load, so the runner reloads per arm transition | `Edge0EnginePreferences.edge0_35BPoolAccounting` (default `.legacy`), `Edge0_35BEngine.poolAccountingCaptured`, `Edge0RuntimeBackend.metrics35B()` (`pool.accounting*`, `budget.stateKVAllowanceBytes`, `budget.poolAllowanceBytes`) |
| `35B Pool budget A/B (legacy vs reclaimed)` kind — counterbalanced, auto pool (the fixed 512 MiB pin is dropped for this kind), decision block with per-arm pool/allowance/hit-rate/loads and a Jetsam-line check; frozen rule: decode ≥ +5%, prefill/TTFT ≥ −5%, tier must change, reclaimed peak ≤ 5.6 GB datapoint | `Edge0DiagnosticKind.poolBudgetAB`, `Edge0DiagnosticPlan.poolBudgetAcceptance`, `Edge0SpeedABRunner.*` |
| Finding 4: microbatch clamp 4 → 16 plus the `Staged wide-microbatch A/B (g4 vs g8)` kind; frozen rule prefill ≥ +5%, decode ≥ −5%; promoted default stays g4 | `Edge0EnginePreferences.edge0_35BMicrobatchGroupSize`, `Edge0DiagnosticKind.microbatchWideAB`, `Edge0DiagnosticPlan.wideMicrobatchAcceptance` |
| Tests | `Edge0SpeedABDecisionTests` (+8 cases: both plans, both frozen rules with boundary cases, clamp bound, metric pair, load-capture), `Edge0SpeedABRunnerCleanupTests` (snapshot capture/restore), `Edge0_35BIntegrationTests` (legacy behavior pinned exactly; reclaimed allowance/tier expectations) |

Pending device evidence: run **35B Pool budget A/B (legacy vs reclaimed)** and
**Staged wide-microbatch A/B (g4 vs g8)** on the iPhone 17 Pro Max (one kind
per session, 60 s idle recovery, cool device). Promote `.reclaimed` — flip
the default in `Edge0EnginePreferences` and record the verdict on the knob —
only if the decision block returns an acceptance; if the reclaimed arm does
not select a larger tier, the run reports that honestly (accounting-only
outcome). The 4096-MiB tier is deliberately NOT appended: the audit proposes
it as a separate device A/B once 3 GiB is validated.
