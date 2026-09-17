# Edge0-35B-A3B architecture (verified)

Discovery record for `Edge0/Edge0-35B-A3B-preview` (Phase 5A). Every value
was read from the real `config.json`, shard headers, LoRA/prerouter
safetensors, and the pinned upstream source — not from README estimates.

| Reference | Value |
| --- | --- |
| HF repo | `Edge0/Edge0-35B-A3B-preview` (sha `1ff9f4478890faec0368c5463b621d1036d5b518`, Apache-2.0) |
| Upstream reference | `Edge0-AI/edge0` @ `0700e6532f45e0d0d99e9c588d7d8cd240538ea0` |
| Upstream profile | `src/edge0/models/edge0_35b/__init__.py` (`Qwen35Config`, K=4 tier) |

## Artifact inventory (exact bytes)

| File | Bytes | Required |
| --- | ---: | --- |
| `model-00001-of-00004.safetensors` | 4,395,019,264 | yes |
| `model-00002-of-00004.safetensors` | 5,368,472,749 | yes |
| `model-00003-of-00004.safetensors` | 5,368,324,139 | yes |
| `model-00004-of-00004.safetensors` | 4,377,211,365 | yes |
| `model.safetensors.index.json` | 180,182 | yes |
| `config.json` | 23,591 | yes |
| `tokenizer.json` | 19,989,343 | yes |
| `tokenizer_config.json` | 1,139 | yes |
| `vocab.json` | 6,722,759 | yes |
| `chat_template.jinja` | 7,764 | yes |
| `generation_config.json` | 202 | yes |
| `lora_edge0_35b.safetensors` | 42,413,928 | **yes (release contract)** |
| `prerouter_edge0_35b.safetensors` | 138,422,000 | optional optimization |
| media / README / processor files | ~21.4 MB | no |

Totals: checkpoint 19,508,787,456 B; routed experts 18,119,393,280 B;
resident/common 1,389,394,176 B; 4 shards / 1,757 tensors.

## Text architecture

- Family `Qwen3_5MoeForConditionalGeneration` (wrapper `qwen3_5_moe`,
  text tower `qwen3_5_moe_text`); vision/MTP are config-only in this preview
  (no vision or `mtp` tensors in the index).
- 40 layers, hidden 2048, 16 Q heads × 256, 2 KV heads × 256 (GQA),
  `attn_output_gate` (q_proj outputs 2× heads), RMSNorm eps 1e-6,
  vocab 248,320, context 262,144, untied embeddings.
- **Layer schedule**: 30 `linear_attention` + 10 `full_attention` at
  3, 7, 11, … 39 (`full_attention_interval = 4`).
- Full attention: q/k/v/o with `q_norm`/`k_norm`; theta 1e7,
  partial_rotary_factor 0.25 (64 of 256 dims). The config advertises
  `mrope_section [11, 11, 10]` / `mrope_interleaved`, but `rope_type`
  resolves to `default`, so the runtime path is plain
  `nn.RoPE(dims=64, traditional=False)` — a **half-split** rotation
  (pairs stride `rotaryDim/2`), not interleaved pairs, and `mx.fast.rope`
  accumulates in float32 with a single round to the input dtype.
- Linear attention (`linear_attn`, GatedDeltaNet-style): conv kernel 4,
  key heads 16 × 128, value heads 32 × 128, `in_proj_qkv`/`in_proj_z`/
  `in_proj_a`/`in_proj_b`, `A_log`, `dt_bias`, `out_proj`, RMS norm;
  `mamba_ssm_dtype = float32`.
- Special tokens: BOS/EOS 248,044; generation EOS {248,046 `<|im_end|>`,
  248,044}; `<|im_start|>` 248,045.

## Production execution mode (promoted)

- **Staged prefill + routed MoE microbatch-4 + eval window 1 → bounded
  decode is the 35B production default** (Exact, Bounded Prefetch, and the
  legacy staged g1 remain selectable; an explicit preference always
  overrides the default). Phase 5H device A/B (iPhone18,2 · 118-token
  prompt · 64 output tokens · greedy · Thinking Off · 512 MiB / 303 slots
  · reads 4): prefill 8.649 → 6.973 s median (−19.4%), engine TTFT −19.5%,
  first visible −19.5%, decode +2.5%, engine completion 18.17 → 16.18 s
  (−10.9%), thermal nominal. Peak process high-water rose ~2.50 → ~2.71 GB
  (+~8.4%, below the frozen 10% review threshold); this is MLX
  allocator/cache residency plus bounded group temporaries, not a
  demonstrated leak — leases return to 0, group references are released,
  and no forced cache clearing was added. Build-34 confirmation: prefill 10.435 → 8.314 s
  median (−20.3%), first visible answer 10.500 → 8.373 s, engine completion
  19.917 → 17.902 s, decode 6.66 vs 6.58 tok/s with staged inside the
  bounded range, identical sequences, ~2.50 GB peak, thermal nominal. Staged/prerouter are not implemented for
  this family and are reported as resolved to Exact.
- Promotion evidence — two stable device sessions, four scored trials per
  mode: every bounded run beat every Exact run; ~8.3% lower median prefill
  and ~25.4% higher median decode throughput; identical generated
  sequences; no memory/thermal regression; clean generation/lease/load/
  queue/read boundaries.
- Measured configuration: iPhone18,2 · 118-token prompt · 64 output tokens
  · greedy · Thinking Off · 512 MiB / 303-slot pool · reads 4 · recovered,
  unprofiled scored trials. The benefit applies to this configuration and
  is not a guarantee for other prompts, pools, or devices.
- Underlying fix carried with this promotion: the per-token capacity guard
  no longer takes a pool statistics snapshot, and read-latency history is
  a bounded 2,048-sample ring (`Edge0LatencyRing`); that removed the
  +2.33 s-per-request MoE prefill drift.

## Staged eval-window experiment (closed — not promoted)

- Candidate: bounded eval window for staged prefill (evaluate up to k
  tokens' routed graphs together; per-token QMM stays M=1). Developer knob
  `Edge0EnginePreferences.edge0_35BStagedEvalWindow` (1...8, default 1).
- Device A/B (two sessions, four scored trials per window, iPhone18,2,
  118-token prompt, 64 output tokens, greedy, Thinking Off, 512 MiB /
  303-slot pool, reads 4):
  - Confirmation session: w4 prefill/TTFT ≈ 5.26% lower (8.274 → 7.839 s),
    decode unchanged (7.02 tok/s both), peak footprint unchanged.
  - Combined across both sessions: ≈ 4.70% lower prefill/TTFT
    (8.317 → 7.927 s), first visible 8.392 → 7.993 s, decode ≈ 1.46%
    higher. Below the frozen ≥5% promotion threshold.
- Decision: **w4 not promoted**; production remains staged prefill window 1
  + boundedPrefetch decode. w4 stays developer-only/default-off. Modest
  benefit observed; not a claim that w4 is slower or broken.
- Pending before any future promotion of this knob: a ~256-token prompt
  correctness/stress check, and explicit device reporting of sequence
  equality + peak active leases (counts/positions alone do not substitute).

## Shared-expert batching experiment (Phase 5I — rejected)

- Finding: the g4 microbatch path computed the shared-expert gate/up/down
  projections **per token** and concatenated them (with the separate
  sigmoid weighting gate also per token). Verified at the call site.
- Candidate: batch those three projections over the existing group input
  `[1, g, 2048]` (same ops, M = g), keeping the weighting gate per token.
  Isolated parity was perfect on synthetic MoE inputs (all layers
  0/12/39, lengths 1/3/4/5/8/9: relL2 = 0.0) and on an 8-step raw-prompt
  logits comparison (0.0).
- **Rejected**: on the real 33-token chat workload the batched branch
  deterministically changed late greedy tokens ("offline scenarios" →
  "offline areas"; reproduced twice per configuration). Batched M=g
  projection kernels therefore do not preserve exact-token identity on
  real activations with the pinned primitives, and the phase contract
  requires exact output identity. The execution path and its developer
  knob were removed; production stays per-token shared work inside g4.
- Mac provisional context (g1 staged profile): shared submission was
  ~0.155 s of a 4.23 s prefill (~3.7%), so the candidate was also unlikely
  to clear the 5% device bar on its own.

## App integration (Phase 5C)

- The runtime surface stays `.edge0MLX`; `Edge0ModelFamily` resolves the
  family from the curated repo id (`Edge0/Edge0-35B-A3B-preview`, pinned
  revision `1ff9f447…`) and the backend dispatches to `Edge0_35BEngine`.
  Architecture strings alone never classify a checkpoint as this release.
- The catalog entry is `edge0-35b-a3b-preview` (experimental, not the
  default). The download allowlist is exactly the eleven pinned artifacts
  (four shards + index + config + generation config + tokenizer +
  tokenizer config + chat template + `lora_edge0_35b.safetensors`);
  the prerouter is optional and not downloaded.
- Admission is family-specific (`Edge0_35BMemoryBudget` /
  `Edge0_35BContextBudget`): resident 1,389,394,176 B + LoRA 42,332,160 B,
  fixed linear state 64,389,120 B, KV 20,480 B per consumed token, and a
  policy-driven pool tier. Pools below top-4 are refused, never waited on.
- Bring-up context is clamped to a documented 4,096-token experimental
  limit; 262,144 is the architectural maximum, not a device-safe claim.
- Only exact true-router execution exists for this family: requested
  optimization modes resolve to exact and are reported as such.
- Diagnostics: the Edge0 device-validation runner gained a family picker
  and an "Exact reference parity (9 IDs)" stage that runs the frozen
  prompt through the loaded production engine.

## Thinking and identity (hotfix)

- The 35B template opens the thinking section IN THE PROMPT when
  `enable_thinking=true`; generated text therefore starts mid-thought with
  no opening marker, and `skipSpecialTokens` strips the delimiters. The
  engine synthesizes `<think>` / `</think>` around the decoded stream
  (`Edge0ThinkingChannel`), inserting the close at the exact decoded offset
  so post-close text is the final answer, not reasoning.
- `enable_thinking` is rendered through the real Jinja context via
  swift-transformers `additionalContext`. Swift token ids are pinned equal
  to the Python (transformers) renderer for both states.
- Ordinary chat defaults to direct answer; an explicit preference enables
  thinking. User sampler settings never change router K.
- Reasoning is stored inside `<think>…</think>` in assistant content, so
  the app's existing thinking presentation and history stripping apply, and
  prior-turn reasoning is not re-rendered into the next prompt.
- Identity: a short trusted block built from the active model (family,
  base family, local/on-device, native runtime) is appended to the existing
  system message — never duplicated — so the model answers identity
  questions factually without claiming a cloud service.
- Diagnostics separate reasoning tokens, final-answer tokens, time to
  first answer token, and `endedWhileThinking`; a generation that exhausts
  its budget while thinking is reported as incomplete, not as a successful
  empty answer.

## Verified parity notes (native port)

- **Rotary layout is half-split**: mirroring `mx.fast.rope(..., traditional=False)`
  means pairing `x[..<half]` with `x[half..<rotaryDim]` at stride `rotaryDim/2`;
  the 8B MLA `ropeInterleave` helper (consecutive pairs) is the wrong layout
  for this family. Cast the rotary span to float32, apply cos/sin there, and
  round the result once to bf16 — casting cos/sin to bf16 first leaves a
  ~1 ulp residual that accumulates into router flips.
- **Router ties must use the upstream formulation**: selection is
  `argpartition(gates, kth=-k)[..., -k:]` on the softmax gates (ascending
  partition, trailing k). Negating the gates and taking the leading k routes
  a different member of an equal-score tie; with bf16 logits such ties occur
  (observed 4th/5th margin 0.0 at layer 0 token 2).
- **MoE executes one token at a time**: the bounded expert pool must never
  pin the union of a whole prompt's selected experts. Per-token routing pins
  at most top-k (4) leases, releases them, and throws
  `insufficientPoolSlots` when capacity is below top-k instead of waiting.
- With these in place the native 35B is bit-exact end-to-end against the
  frozen oracle: all 40 layer outputs, top-20 logits, router selections
  (200/200), and the nine-token emission
  `[11751, 13, 271, 248068, 271, 248069, 271, 4639, 369]`.

## MoE

- 256 routed experts, `moe_intermediate_size` 512, one shared expert (512)
  with a sigmoid `shared_expert_gate`.
- Checkpoint config declares `num_experts_per_tok = 8`; **Edge0's released
  35B tier runs K=4** (upstream `staged_k4`, `prerouter_top_k = 4`).
- Router gate is a quantized projection `...mlp.gate` (256×2048), 8-bit
  group 64; selection is SOFTMAX_TOPK with `norm_topk_prob = true` as the
  release contract (the config omits the flag; the upstream profile sets it).
  No router expert bias tensor exists.
- Expert storage: `language_model.model.layers.{n}.mlp.switch_mlp.{gate,up,down}_proj.{weight,scales,biases}`.
  - `gate_proj`/`up_proj` weight `[256, 512, 256]` U32, scales/biases `[256, 512, 32]` BF16.
  - `down_proj` weight `[256, 2048, 64]` U32, scales/biases `[256, 2048, 8]` BF16.
  - Per expert bundle **1,769,472 B** (589,824 per projection).
  - Per-layer experts 452,984,832 B; all 40 layers 18,119,393,280 B.

## Quantization

- Global affine 4-bit, group 64 (U32 packs 8 values; scales/biases BF16).
- 80 per-module overrides at **8-bit group 64**: `...mlp.gate` and
  `...mlp.shared_expert_gate` for every layer.
- Resident embed/lm_head are also quantized (U32 + BF16 scales/biases;
  no bias part for these two, only `weight`/`scales`).

## LoRA (`lora_edge0_35b.safetensors`)

- 620 tensors (310 A/B pairs), rank 16, alpha 32, F16, unmerged.
- Targets per layer: linear layers `linear_attn.{in_proj_qkv,in_proj_z,in_proj_a,in_proj_b,out_proj}`;
  full-attention layers `self_attn.{q,k,v,o}_proj`; all layers
  `mlp.shared_expert.{gate,up,down}_proj`.
- **No LoRA on routed experts, router gate, embedding or lm_head.**
- Application contract: `y = quantizedMM(x) + (alpha/r) · B(A(x))`.

## Prerouter (`prerouter_edge0_35b.safetensors`)

- 99 tensors, F16, owners **6…38** (33 heads).
- Feature width **2560** = hidden 2048 + this-token K=4 one-hot (256) +
  previous-token K=4 one-hot (256); `fc1 [512, 2560]`, `fc2 [256, 512]`,
  `linear_init [256, 2560]`.
- Predicts layer N+1 from owner N; selection SOFTMAX_TOPK with K=4;
  advisory only in our runtime.

## Memory (logical)

| Component | Bytes |
| --- | ---: |
| Resident/common (index total − experts) | 1,389,394,176 |
| LoRA | 42,413,928 |
| Prerouter (optional) | 138,422,000 |
| Routed experts (streamed) | 18,119,393,280 |
| Checkpoint total | 19,508,787,456 |

No physical-memory claims: upstream's ~2.9–3.3 GiB active figure is a Mac
reference and must be re-measured on iPhone.

## Runtime integration plan

- Runtime stays `.edge0MLX`; add an internal family split
  `edge0_8B` / `edge0_35B` (runtime = backend, family = architecture).
- Architecture identity: `Edge0_35BModelConfiguration.isEdge0Architecture`
  accepts `BailingMoeV3ForCausalLM` and `Qwen3_5MoeForConditionalGeneration`.
- Reuse: safetensors index/pread store, expert pool, staging collector,
  prerouter scheduler concepts, storage/download/registry infrastructure.
- New in 5B: 35B configuration (done), GatedDeltaNet linear attention, GQA
  full attention with mrope/output gate, 35B MoE (softmax top-k + shared
  gate), LoRA application, 35B model/state.
- Catalog activation landed in Phase 5C (experimental entry
  `edge0-35b-a3b-preview`); generation was validated bit-exact on device in
  Phase 5B/5C, and the performance candidates (bounded prefetch, staged
  prefill, routed microbatch g4) were promoted through counterbalanced
  device A/Bs in Phases 5E–5H.

## Phase 5J — advisory prerouter (default OFF, device A/B pending)

The released 35B prerouter (`prerouter_edge0_35b.safetensors`,
~138,422,000 B, owners 6–38, K=4, F16) is implemented natively and wired as
purely advisory decode-side prefetching:

- `Edge0_35BPrerouter` mirrors the pinned upstream head exactly: features =
  `[MoE input (2048), executed top-k one-hot (256), previous-token one-hot
  (256)]`, `linear_init(feats) + fc2(gelu_erf(fc1(feats)))`, selection via
  precise softmax → trailing-k argpartition → renormalize.
- Parity gate (harness, real checkpoint, first decode boundary, owners
  6/12/20/30/38): selected expert IDs identical; F16 head-stage relative
  deltas ≤ 7.8e-4 (linear stage bit-exact).
- Scheduling reuses the generic `Edge0PrerouterRuntime` /
  `Edge0SpeculativeScheduler` (≤1 speculative read in flight, bounded queue,
  unpinned residents, cancellation + quiescence) now generic over the pool
  payload; predictions are scheduled after each decode step for the next
  token, reconciled at the true router with precision/recall/ready/unused
  metrics.
- The true router remains the sole authority: with a fixed and a throwing
  predictor the emitted sequences are byte-identical to advisory-off, and a
  post-cancel exact nine-ID probe stays bit-exact.
- Default OFF (`Edge0EnginePreferences.edge0_35BAdvisoryPrerouter = false`).
  A dedicated Diagnostics kind "35B Prerouter A/B (off vs advisory)" runs
  the counterbalanced plan (off→on→on→off) with the frozen acceptance rule
  (prefill/TTFT ≥5%, decode ≥−5%). Production remains staged g4 until the
  physical device A/B is accepted.

### Prediction horizon (explicit)

PREDICTOR DOES NOT TARGET INITIAL PREFILL. The decode tap captures owner
`(MoE input, executed top-k)` during a decode step and schedules heads
after that step's logits; predictions target the NEXT decode token, so they
can only overlap the next step's attention/compute. No head runs during
prefill (`advisory.prefillPredictions` is 0 by construction), and neither
the input features nor model routing were altered to fabricate overlap. The
existing prefill optimization remains staged true-router lookahead.

### Activation evidence (requested ≠ effective)

Effective state is exported per trial: artifact present/valid, head count
and loaded bytes, fallback reason, head invocations, prefill/decode
prediction split, precision/recall/ready/late, speculative requests and
completed reads, and a fixed fallback taxonomy (missing-head /
prediction-failed / runtime-closed). A requested-On trial whose predictor is
inactive is labeled SETUP-BLOCKED and excluded from the comparison.
Sequence parity is now checked for same-mode preference A/Bs too
(previously only mode-changing pairs were compared).

### Per-prediction horizon evidence (harness, real checkpoint)

A nil-by-default bounded event trace (`Edge0PrerouterEvent`, no payload or
content) lets the harness assert and print the exact horizon. Sample from a
real run:

```
owner 20 → target layer 21 · source token 17 → target token 18 [decode]
produced [0, 52, 65, 139] · ready [0, 65, 139] · late []
```

Every request is decode-phase, targets `owner + 1`, and targets the NEXT
token position (`targetToken == sourceToken + 1`); the first predicted
target is the second decode token, so the first decode step has no
prediction. Reconciliation of a target key always follows its request in
engine execution order, and reconcile also fires for layers with no head
(empty prediction) — those are not prediction failures.

### Activation defects found and fixed (build 42)

- `Edge0_35BPrerouter` declared `owns(_:)` while the protocol requires
  `owns(owner:)`; the wildcard default silently claimed every layer, so
  non-owner layers were scheduled and counted as `missing-head` fallbacks.
  Fixed with an explicit labeled `owns(owner:)`.
- The protocol default was changed to fail-closed (`false`); the 8B test
  predictors that relied on the wildcard now declare ownership explicitly.
- Extension: `late` (correct-but-not-yet-resident) is now emitted and
  reported separately from `ready`.

### Predictor download (optional, explicit)

`Edge0_35BModelArtifacts.prerouterFileName` (138,422,000 B pinned) is
fetched only through the Diagnostics "Download predictor (132 MB)" action,
using the existing downloader with a single-file allowlist into the
installed 35B directory. The base checkpoint and LoRA are never re-fetched,
nothing downloads during generation, and `.hf-expected.json` entries merge
instead of replacing so the base card keeps its size checks.


## Phase 5K — prefill compute/completion candidate (default OFF, device A/B pending)

Completion-aware Mac profile of the accepted production path (124-token
prompt, staged true-router + routed microbatch-4 + eval window 1) showed:

| Component | Seconds (Mac) | Share |
| --- | ---: | ---: |
| Router selection handling (per-token readback + lookahead) | 3.41–3.54 | ~33% |
| Group eval completion wall (routed experts, shared expert, attention) | 4.70–4.99 | ~45% |
| Expert acquire wait | 0.75–0.95 | ~8% |
| Shared-expert submission | 0.59–0.63 | ~6% |
| Stack build / routed QMM submission | 0.29 / 0.11 | ~4% |
| GatedDeltaNet / GQA | 0.58 / 0.004 | ~5% |

Attention candidates are below the noise floor and were not implemented.
An oversized-pool attribution probe (2 GiB vs 512 MiB class) changed
prefill by <1%, so expert I/O is not the lever (and reads/pool stay frozen).

Candidate (developer-only, `edge0_35BRouterReadbackMode`, default 0):
batch the router index readbacks. The per-token router projection and
`select` math are unchanged; production forces one CPU readback per token
per layer, the candidate materializes every pending index readback with ONE
eval per group. Nine-ID parity, 124-token stream, 404-token stress, and
position/KV state are identical; effective strategy is reported by the
engine (`mode.routerReadbackRequested/Effective`).

Mac smoke (like-for-like, both profiled): prefill 10.79 → 9.63 s (−10.7%),
selection component 3.48 → 2.62 s (−24.5%), all other components unchanged.
Mac is provisional and never promotes.

Device A/B kind: "35B Compute A/B (production vs candidate)" — counter
balanced 0→1→1→0 trials on the frozen profile with the acceptance rule
(prefill and TTFT ≥5%, first visible improves, decode ≥−5%, sequence
parity). Production remains staged g4 with the candidate OFF.

First physical session (118-token profile): prefill 7.070 → 6.627 s
(−6.27%), TTFT 7.097 → 6.639 s (−6.45%), first visible −0.46 s, decode
7.375 → 7.370 tok/s, peak footprint 2.70 GB in both modes, all scored
sequences identical, peak leases 16, clean boundaries. Because the control
drifted 4.3% within the session, one confirmation session is required
before promotion. Pre-confirmation corrections shipped: the scored-trial
thermal admission now also gates warm-ups (the export showed an unscored
warm-up starting at Serious), and the printed engine configuration and
trial rows now show `router readback requested/effective` from the engine
snapshot instead of relying on trial names.


### Phase 5K closeout — batched router readback REJECTED for production

Two valid physical sessions (118-token frozen profile, counterbalanced
0→1→1→0, four scored trials per mode, frozen combined-median rule):

| Metric (combined median) | Per-token (production) | Batched (candidate) | Change |
| --- | ---: | ---: | ---: |
| Prefill | 6.912 s | 6.574 s | −4.90% |
| TTFT | 6.924 s | 6.586 s | −4.88% |
| First visible | 6.978 s | 6.639 s | −4.86% |
| Decode | 7.545 tok/s | 7.560 tok/s | +0.20% |

The second session alone exceeded 5% (prefill −5.18%), but the
predetermined rule uses both sessions; 4.90% is below the frozen ≥5% bar
and was not rounded or cherry-picked. Decision: **rejected for production —
repeatable small benefit, frozen bar not met.** This is not a correctness
rejection: effective candidate execution was confirmed by the engine
snapshot (`router readback requested→effective` 0→0 / 1→1), all scored
sequences matched, peak leases stayed 16, memory ~2.7 GB, thermal Nominal,
decode unchanged.

Production remains staged true-router prefill + routed MoE microbatch-4 +
eval window 1 + **per-token router readback** → boundedPrefetch decode.
The candidate is retained only as a developer diagnostic
(`edge0_35BRouterReadbackMode`, default 0, plus the "35B Compute A/B"
runner); the runner now restores the preference so an interrupted trial can
never leave it enabled. No third session; no further changes to chase the
threshold. Closing note for future work: synchronization-boundary shaving
has reached diminishing returns (~0.35 s here); the next candidate must be
capable of substantially more.

## Phase 5N — decode-bandwidth audit and three shipped fixes

Audit of the production 35B path. The governing measurement is the decode
byte floor, derived from the pinned artifact geometry (not measured on
device here — see "Measurement status"):

- Per decoded token the true router selects 4 experts in each of 40 layers
  = 160 bundles × 1,769,472 B = **270 MiB of expert bytes per token**.
- The accepted profile runs 6.6–7.5 tok/s ⇒ 133 ms/token ⇒ **~2.03 GB/s
  sustained**. That is at the flash read wall, so decode time is
  essentially read time.
- Decode pool reuse is structurally near zero: per layer, two consecutive
  tokens overlap in `4×4/256 = 0.0625` experts, i.e. ~2.5 shared bundles of
  160 per token (**~1.6%**). A 512 MiB pool holds 1.9 tokens' experts; a
  2 GiB pool holds 7.6. Neither can make decode reuse matter, which is
  consistent with the Phase 5K probe finding that a 2 GiB vs 512 MiB pool
  changed prefill by <1%.

Consequence: **enlarging the pool is not a decode lever.** The remaining
levers are overlapping I/O with compute (readahead, advisory prerouter) and
removing redundant memory passes.

### Fix 1 — the 35B ignored the read-concurrency knob (bug)

`load35B` passed a hardcoded `maxConcurrentReads: 4` where `load8B` passes
`Edge0EnginePreferences.expertLoadConcurrency`. The Diagnostics "Expert
reads" picker (2/4/6) and `Edge0DeviceValidation` both write that
preference, so **every 35B A/B recorded in this document as "reads 4" ran
at 4 regardless of the picker**; the 2/4/6 experiment set was never
actually exercised on this family. Fixed to honor the preference, and the
load breadcrumb now reports `reads=` and `readahead=` so future sessions
record what was actually configured.

### Fix 2 — expert reads no longer zero-fill their destination

`Edge0PreadFile.read` allocated with `Data(count:)`, which guarantees zeroed
contents, then `pread` immediately overwrote every byte — one redundant pass
over all 270 MiB read per token. The destination is now allocated
uninitialized, 16-byte aligned, filled by `pread`, and transferred to `Data`
via a deallocating finalizer **only after the read fully succeeds**; every
early-throw branch deallocates explicitly.

Measured on an Apple Silicon Mac at 576 KiB (one projection slice):
`Data(count:)` 0.025 ms vs uninitialized 0.017 ms ⇒ ~0.008 ms/read ⇒
**~3.8 ms/token (≈2.9% of the 133 ms budget)**. Modest; shipped because it
is free and removes a whole memory pass.

### Fix 3 — generation ownership race (correctness)

`Edge0_35BEngine` / `Edge0Engine` are `@unchecked Sendable`; `cancel()` runs
on the MainActor while `generate()` runs on a non-isolated task, so
`generationID` and `lastGenerationMetrics` were genuinely shared and
unguarded. Both paths also used check-then-act
(`if generationID == generation { generationID = nil }`) and an unconditional
`generationID = nil` on the cancellation path, so a superseded generation
could **steal a newer generation's ownership and leave it uncancellable**.
Both engines now guard these two fields with a lock and clear through an
atomic compare-and-clear (`clearGeneration(if:)`).

### Phase 5M readahead is now reachable from Diagnostics

`edge0_35BReadaheadHints` (Phase 5M, the `warm_willneed` analogue) and
`edge0_35BAdvisoryPrerouter` (Phase 5J) were implemented and wired into the
engine but **not settable from any UI or A/B runner**, so neither could be
device-A/B'd toward promotion. Both now have Diagnostics toggles (35B family
only) that are applied before the model loads, are reported in the run
summary, and are captured/restored by `Edge0DiagnosticPreferences.Snapshot`
(readahead was previously absent from the snapshot, so a diagnostic run could
leak it into the next engine load).

Open gap — CLOSED (2026-09-17 follow-up pass): the counterbalanced
automated `readaheadAB` runner kind now exists ("35B Readahead A/B (off vs
hints)" in the Diagnostics picker). Unlike the eval-window/microbatch/
advisory/readback knobs, readahead is captured once per engine load, so the
runner reloads the model at every arm transition (plan off→on→on→off; both
trials of an arm share one reload). Arm effectiveness is proven by the
engine-exported `readaheadRequested`/`readaheadEffective` pair: a
requested-on trial whose engine state says OFF is labeled SETUP-BLOCKED
instead of silently comparing off-vs-off. Acceptance rule (frozen):
decode ≥ +5% with prefill and TTFT ≥ −5%. The same pass fixed the
build-47 decision-stage regression that dead-ended every completed knob
A/B export with an empty DECISION section (see the perf scan §7.1).

### Candidates examined and NOT implemented

Rejected on measured cost or reachability, with the numbers that decided it
(all on an Apple Silicon Mac; the *ratio* is what transfers, not the
absolute ms):

| Candidate | Measured / derived cost | Decision |
| --- | --- | --- |
| Zero-copy `MLXArray` construction (#3b) | removes ~4.3 ms/token of the `MLXArray(Data)` copy | Skipped: `MLXArray(rawPointer:finalizer:)` transfers ownership, and the fork's own docs warn the pointer must be "compatible with the computational backing" for a Metal stream. Weight buffers are read by GPU kernels, so correctness depends on MLX copying at first GPU touch. Cannot be settled without a device run, and ~3% does not justify the risk on a bit-exact path. |
| `incr_stack` / `incr_writeback` (#4) | stack rebuild ~4.3 ms/token at 66 GB/s (≈3.2%); ~8–14% if the target device's bandwidth were lower | Skipped for now: upstream's +31% came from mmap **page faults** (5162→1925 minor faults, staging wall 162→27 ms) on a memory-starved M2. This runtime `pread`s into heap buffers first, so those pages are already committed and the stack step is pure memcpy. Expected ~5–10% here, not ~55%, and it needs the frozen nine-ID oracle plus device A/B. Largest remaining candidate if decode is ever to move substantially. |
| KV preallocated stepped buffer (#5) | 0.04 ms/step at T=128; **1.27 ms/step (1.0%)** at the 4,096-token cap | Skipped: `KVCacheSimple` is available via the existing `MLXLMCommon` dependency and would help, but at ≤1% it does not clear any bar today. **Revisit before raising the 4,096 experimental context cap** — this is the O(T)-per-step term that grows. |
| Incremental decode text (#6) | `normalize` 0.014 ms/token at 64 tokens; 0.53 ms at 4,096 | Skipped: <0.4% of budget at realistic output lengths. Would touch the thinking-marker path that the phase contract protects for exact output identity. |
| Pool batch release + O(1) LRU (#9) | 0.0032 ms per 303-slot scan; ~61 ms across a ~7 s prefill (0.9%), and `wakeWaiters()` early-returns when no waiter is queued | Skipped: not on the critical path in practice. |
| Context admission floor (#8) | `viable = max(limited, 512)` | Skipped as a code change: the floor is **unreachable**, because `load35B` refuses admission when `isPoolEnabled` is false (`poolSlots >= 4`), and a headroom small enough to make the floor bind already fails that guard. Flagged as a latent policy smell only. |

### Newly found, unfixed (needs a product decision)

`generationAlreadyActive` is **declared in both engines and never thrown**,
and `RuntimeEngine.generate()` sets `activeGeneration = true` without ever
checking it. Nothing in the stack refuses a second concurrent generation;
the only protection is that `generationID` is overwritten (now at least
atomically). Whether to start refusing concurrent generation is a
behavioral decision, so it was left alone rather than changed silently.

### Measurement status

No Edge0 checkpoint is present on this machine, so **no device generation
measurement was taken** (same blocker as Phase 5L). What was measured here:
the allocation/zero-fill cost, `normalize` cost, LRU scan cost, and KV concat
cost, all as standalone microbenchmarks against the real production sources.
The 270 MiB/token and 1.6% reuse figures are derived from the pinned
artifact geometry recorded above, not profiled.

Memory-safety evidence for Fix 2 comes from a standalone harness that
compiles the real `Edge0TensorStore.swift` / `Edge0Safetensors.swift`
against a temporary checkpoint (the app's XCTest suite cannot execute in
this environment: the iOS Simulator SDK has no `CoreAI.framework`, and the
paired device's signing certificates are revoked). 17/17 checks pass,
including 600 × 576 KiB reads with 0.0 MiB footprint growth, and 600 failed
committed reads with 0.6 MiB growth. That harness was teeth-checked: with
the `deallocate()` deliberately removed, the failure-path assertion reports
339.0 MiB growth and fails. An earlier version of that assertion leaked only
untouched pages and passed even when broken; it was rewritten to commit the
buffer before failing, because `phys_footprint` counts only committed pages.

Equivalent coverage was added to `Edge0TensorStoreTests` (full-byte fill,
outliving a closed descriptor, unique storage per read, committed-leak
footprint bound) and to `Edge0RuntimeBackendTests` (ownership claim,
compare-and-clear semantics, superseded generation cannot steal ownership,
force-stop `cancel()`, concurrent claim/clear). These compile; they could not
be executed here for the signing/SDK reason above.
