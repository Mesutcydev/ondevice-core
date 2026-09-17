# Edge0 native foundation (Phase 2)

Developer note for the native Edge0 storage / quantized-MoE foundation that
lives under `IOSLocalLLM/Services/Runtime/Edge0/`. Phase 2 deliberately does
**not** run the model: `RuntimeEngineFactory` still refuses `.edge0MLX`.

## Upstream reference

| Item | Value |
| --- | --- |
| Repository | <https://github.com/Edge0-AI/edge0> |
| Commit inspected | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0` |
| License | Apache-2.0 (`LICENSE`), see also upstream `NOTICE` |

Modules studied (read-only; no Python copied):

- `src/edge0/models/edge0_8b/__init__.py` — `Ling8BConfig`
- `src/edge0/moe/spec.py` — `MoESpec`, `QuantSpec`, `WeightLayout`
- `src/edge0/streaming/mmap.py` — `SafetensorsMmap` byte-range access
- `src/edge0/streaming/cache.py` — `SharedExpertCache` LRU
- `src/edge0/streaming/layer.py` — `StreamingSwitchGLU._build` /
  `_get_bundles` / `gather_qmm` usage
- `src/edge0/backends/mlx/quant.py` — `gather_qmm` wrapper, `_swiglu`
- `docs/models/edge0-8b.md`, `docs/streaming.md` — tier profile and math
  contract

Model artifact layout was verified directly against the published
checkpoint (`Edge0/Edge0-8B-A1B-preview`, `model.safetensors`) by fetching
only its 141,224-byte JSON header — no weights were downloaded.

## Edge0-8B artifact facts (measured)

| Item | Value |
| --- | --- |
| Layout | single `model.safetensors` (4,508,556,096 bytes) |
| Layers | 24 total; layer 0 dense; layers 1…23 routed MoE |
| Routed experts | 128 per layer + 1 resident shared expert |
| Routing width | K = 8 (`SIGMOID_GROUP`, n_group 8, topk_group 4, scaling 2.5, norm_topk_prob) |
| Expert bytes | 1,327,104 per expert; 169,869,312 per layer; 3,906,994,176 total |
| Resident/common | 601,561,920 bytes |
| Quantization | 4-bit affine, group size 64, `transpose=true` |
| Weight layout | `SEPARATE` — gate/up/down stacked as separate tensors |

### Routed-expert tensor naming

```text
model.layers.{L}.mlp.experts.{proj}.{part}
```

- `L` in `1…23`
- `proj` in `gate_proj`, `up_proj`, `down_proj`
- `part` in `weight`, `scales`, `biases`

Stacked tensor shapes (axis 0 is the expert axis, contiguous per expert):

| Projection | `weight` (U32) | `scales` (BF16) | `biases` (BF16) |
| --- | --- | --- | --- |
| `gate_proj` | `[128, 512, 192]` | `[128, 512, 24]` | `[128, 512, 24]` |
| `up_proj` | `[128, 512, 192]` | `[128, 512, 24]` | `[128, 512, 24]` |
| `down_proj` | `[128, 1536, 64]` | `[128, 1536, 8]` | `[128, 1536, 8]` |

Packed U32 words hold `32 / bits = 8` four-bit values; `scales`/`biases`
carry one entry per group of 64 input features (`in / 64`).

### Expert projection layout (math order)

Upstream bundle order is `("up_proj", "gate_proj", "down_proj")` so the
positional math signature is `_swiglu(up, gate) = silu(gate) * up`. The
resident shared expert uses `model.layers.{L}.mlp.shared_experts.*` with the
same 9 tensors unstacked; it is not streamed.

## MLX primitive

| Item | Value |
| --- | --- |
| Dependency | `https://github.com/PrismML-Eng/mlx-swift` |
| Revision (project.yml pin) | `e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230` |
| Swift API | `MLX.gatherQuantizedMM(_:_:scales:biases:lhsIndices:rhsIndices:transpose:groupSize:bits:mode:sortedIndices:stream:)` |
| C kernel | `mlx_gather_qmm` (also surfaced by `QuantizedSwitchLinear` in `mlx-swift-lm`) |
| Wrapper needed | No — the exact primitive is exposed by the pinned fork |

`Edge0ExpertMath` calls the API with `transpose: true, groupSize: 64,
bits: 4, mode: .affine`, matching upstream `gather_qmm` defaults.

### mmap vs pread decision

Phase 2 ships the explicit `pread` backend (`Edge0PreadTensorStore`). An
mmap backend was evaluated and deliberately deferred: a virtual mapping does
not reduce the physical footprint of the pages actually touched, the expert
read pattern (one contiguous ~1.3 MB slice per expert) is already
page-cache-friendly, and mmap adds unmap/lifetime hazards on model unload.
If Phase 3 profiling shows page-fault cost dominating after the page cache
warms, a `madvise(WILLNEED)`/mmap read path can be added behind the same
`Edge0TensorStore` protocol without touching the index, layout, loader, or
pool.

## Swift implementation map

| Upstream concept | Swift type |
| --- | --- |
| `SafetensorsMmap` metadata | `Edge0SafetensorsIndex`, `Edge0TensorLocation`, `Edge0SafetensorsHeaderParser` |
| mmap byte-range read | `Edge0PreadFile`, `Edge0PreadTensorStore`, `Edge0TensorStoreSet` |
| `MoESpec` / layout | `Edge0ExpertSpec.edge0_8B`, `Edge0ExpertLayout`, `Edge0ExpertBundleLocation` |
| `_build` per-expert load | `Edge0ExpertLoader`, `Edge0ExpertWeights` |
| `gather_qmm` + `_swiglu` | `Edge0ExpertMath` |
| `BailingKDA` + gated delta rule | `Edge0KDAAttention`, `Edge0KDAState` |
| `gated_delta_ops` reference path | `Edge0KDAAttention.gatedDeltaOps` (Metal kernel deferred) |
| `SharedExpertCache` | `Edge0ExpertPool` (hard-bounded, dedup, ABA-safe) |
| memory policy | `Edge0MemoryBudget` (derived from `MemoryAdvisor` / `DeviceSafetyMonitor`) |

## Deliberate Phase 2 non-goals

No Ling/Edge0 transformer, no generation, no HTTP client, no Python
embedding, no prerouter, no LoRA, no speculative expert prediction, no
double buffering/staging. `.edge0MLX` remains refused by
`RuntimeEngineFactory` until Phase 3 has real inference.


## Final execution configuration (Phase 4B-4)

Production chain: `RuntimeEngineFactory → ManagedRuntimeEngine →
Edge0RuntimeBackend → Edge0Engine → Edge0Model`.

- **Prefill**: `Edge0ExecutionMode.stagedPrerouter` — two-bank staged
  pipeline over true-router-selected experts, plus advisory prerouter
  prefetch (width 8, owners 7…22). Default since Phase 4B-3 device
  acceptance (iPhone18,2 medians: prefill 1.801 s, TTFT 1.843 s, decode
  14.07 tok/s, peak ~1.49 GB, thermal fair).
- **Decode**: bounded-prefetch path (single token has no staging pipeline).
- **Expert pool**: admission-driven tier (404 slots / 512 MiB on the
  baseline device); `Edge0EnginePreferences.poolCapacityBytesOverride`
  may only shrink it for A/B, never overcommit.
- **Read concurrency**: tensor-store semaphore, default 4; experiment set
  2/4/6 via `Edge0EnginePreferences.expertLoadConcurrency` (clamped ≤ 6).
- **KDA**: reference ops path (fused KDA skipped — Mac component profile
  shows KDA ≈1% of prefill MoE wall time, far below the 15% threshold;
  device profile pending).
- **Component profiling**: opt-in
  (`Edge0EnginePreferences.componentProfilingEnabled`) coarse attribution
  for KDA/MLA/MoE/router/embedding/lm_head, split prefill/decode; no cost
  when disabled.

Fallbacks:
- missing/failing prerouter → `staged` (fallbacks counter), base model
  remains valid;
- wrong predictions → true router corrects, never executed;
- admission failure → load refused safely;
- cancel → generation state discarded, prerouter quiesced before unload;
- runtime switch → previous runtime drained, no speculative work survives.

Model storage: canonical root `Documents/LLMModels`; persisted registry
records are re-anchored to the current container on load and stale
absolute container URLs are never used as write destinations.

Artifacts: base checkpoint files + optional `prerouter_edge0_8b.safetensors`
(38,802,304 B, fp16, owners 7…22). No model weights in source control.
