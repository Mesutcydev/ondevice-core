# Edge0 upstream rebase audit (Phase 5L)

Forensic delta audit of the public Edge0 repository against our native Swift
runtime, with a ranked port plan. **No production behaviour is changed by this
phase.** No Swift source was modified.

Three subjects are distinguished throughout:

| Label | Meaning |
| --- | --- |
| **OLD UPSTREAM @ `0700e65`** | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0`, 2026-09-10 — the revision our port was studied from (recorded in `Docs/EDGE0_NATIVE_FOUNDATION.md`) |
| **CURRENT UPSTREAM @ `f8c4cb2`** | `f8c4cb2c1871735502d958bc63d2f31b88ca7123`, 2026-09-16 — frozen in §A. "Current upstream" always means this SHA |
| **OUR SWIFT RUNTIME** | `IOSLocalLLM/Services/Runtime/Edge0/` at the working-tree state during this audit |

## Executive summary — read this first

**The premise of this phase is factually incorrect, and correcting it is the
main result.** Fixed-slot staged decode, GPU-resident slot mapping, `asm_cache`,
incremental stack, prerouter-integrated staging, `mx.compile` support,
hot/prefetch-history mechanisms, and the `Qwen35Config` 35B profile **all
already existed at OLD UPSTREAM @ `0700e65`**. Verified by symbol presence at
both revisions (§C.1): every one of the 24 mechanism names listed in the phase
brief resolves to source files at `0700e65`. There is no "materially different
35B profile" to rebase onto.

What actually changed between `0700e65` and `f8c4cb2` is **21 non-merge commits
touching 35 files (+749/−161)**, and it is dominated by *correctness fixes and
default flips*, not new architecture:

1. **ONE genuinely new mechanism**: `warm_willneed` — `madvise(MADV_WILLNEED)`
   readahead hints over expert byte ranges (`62dcab2`).
2. **Three default flips** in `LayerOptions.staged_k4()`: `incr_stack`,
   `incr_writeback`, `warm_willneed` turned ON. The mechanisms pre-existed.
3. **A routing-authority correction**: "zero-drop layer scoping" — staging is
   now switched OFF for every layer whose route is not a prerouter prediction
   (`b57d83a`). This *narrows* the staged path.
4. **Two silent-corruption fixes**: hot-stack zero overflow row (`1e6f8c6`,
   an out-of-bounds gather) and cross-request staged-state leakage
   (`b57d83a`).
5. **One robustness fix**: `QWEN_HIDDEN_CLIP=1000` per-layer NaN scrub
   (`51b8697`), on by default in the 35B engine.
6. **One dependency pin**: `mlx` 0.30.4 → 0.30.6 for A18/A18 Pro NAX
   mis-gating (`2e168c5`).
7. **Documentation-only**: the "Qwen3.6-35B-A3B" rename, 3.3 GB → 2.9 GiB,
   ModelScope mirrors, `pregate` → `prerouter` naming.

**The checkpoint did not change at all.** Our pinned HF revision `1ff9f447` and
current HF HEAD `15dc6959` have **identical LFS blob OIDs for every weight,
adapter and config file**; only `README.md` differs (5997 → 5985 bytes). The
"Qwen3.6" rename is naming, not weights (§3).

**Our MLX stack is inside upstream's safe window, and better validated than
upstream's.** We are on MLX C++ **0.31.1**, which contains the NAX fix
upstream pinned 0.30.6 to obtain, and is below 0.31.2 where upstream documents
thread-local default streams breaking pool-thread builds. Upstream states "the
A18-side effect still needs confirmation from the reporter"; we have physical
validation on iPhone18,2 with a frozen nine-ID oracle (§15).

**The decisive architectural finding** (§10): current production 35B **does not
execute the true router** for consumer layers L7–L38 at decode. The patched
MoE block routes from the prerouter's cached `pred_inds`/`pred_scores`; the
gate is evaluated only at pos-0 fallback and for L0–L6/L39. Upstream's
fixed-slot zero-host-sync decode is therefore *bought with routing authority*.
Our release contract requires exact true-router semantics, so that trade is not
available to us (§H).

**ONE ranked candidate for the next phase** (§G, §I): advisory
`F_RDADVISE`/`F_RDADVISEV` readahead over expert byte ranges in
`Edge0TensorStore`, issued from the lookahead we *already* compute in staged
prefill. It is the only upstream change that is new, portable with no
dependency change, numerically inert by construction, and compatible with
true-router exactness — because it consumes a lookahead of *actual* router
selections rather than requiring a prediction to replace the router.

---

## A. Frozen upstream identity

Cloned read-only to `/tmp/edge0-upstream-current`. Our working tree was not
modified while studying upstream.

| Item | Value |
| --- | --- |
| Repository URL | `https://github.com/Edge0-AI/Edge0.git` |
| **Frozen current HEAD SHA** | **`f8c4cb2c1871735502d958bc63d2f31b88ca7123`** |
| Commit date (ISO) | `2026-09-16T19:42:10+08:00` |
| Commit subject | `docs(readme): add the ModelScope mirrors next to the Hugging Face links` |
| Author | linyubupa |
| Dirty/clean status | **clean** (`git status --porcelain` empty) |
| Tags at HEAD | none (repository has no tags) |
| Historical reference preserved | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0`, `2026-09-10T11:16:26+08:00`, `README: remove demo video` — present and resolvable in the same clone |
| Commits `0700e65..f8c4cb2` | 33 including merges; **21 non-merge** |
| Diffstat | 35 files, +749 / −161 |
| License | Apache-2.0 (`LICENSE`, `NOTICE`); vendored mlx-lm model code |

`f8c4cb2` is a documentation commit. The last code-affecting commit is
`62dcab2` (`perf(streaming): WILLNEED readahead + in-place staged stack for
edge0-35b`, 2026-09-14). **`main` is not assumed stable**; every statement
below is pinned to `f8c4cb2`.

Non-merge commits in the window, newest first:

```
f8c4cb2 docs(readme): add the ModelScope mirrors next to the Hugging Face links
ca40e7d docs(paper): add Edge0 technical report (The Other Half of the Memory Wall)
62dcab2 perf(streaming): WILLNEED readahead + in-place staged stack for edge0-35b
e4cd73c / dd633cd / 2982774 docs: drop the peak-memory footnote boilerplate
56c8b79 / b909856 / 48bd224 docs: drop the long-context KV-cache figure for edge0-8b
b413a22 / 63d6efb docs: rename the 35b base model to Qwen3.6-35B-A3B
6cc13ef docs: drop the local prerouter notes from the tree
b57d83a fix(prerouter): zero-drop layer scoping, working --no-prerouter, 8b sync
1e6f8c6 fix(streaming): give the hot stack its zero overflow row
a8392a8 fix(server): keep the rendered chat template in ChatSession.prompt_ids
51b8697 fix(35b): clip per-layer hidden states so one fp16 overflow cannot NaN-poison the net
2e168c5 / 0d52bf8 fix(deps): pin mlx 0.30.6 and document the A18 NAX mis-gating
a38d3da docs: point the GitHub badge at the renamed repo
1d32a55 chore: unify the legacy pregate naming on prerouter
c6b6d59 docs: sync the Chinese README and fix stale docs claims
bc353dc fix(fetch): use tuple element for MODEL env var in done hint
```

## B. Current 35B release contract @ `f8c4cb2`

Read from source, not documentation. Primary sources:
`src/edge0/models/edge0_35b/__init__.py` (`Qwen35Config._defaults`),
`src/edge0/streaming/options.py` (`LayerOptions.staged_k4`),
`src/edge0/models/base.py` (`ModelConfig`), `src/edge0/config.py`
(`GenerationConfig`), `src/edge0/moe/spec.py`, `src/edge0/prerouter/spec.py`.

### B.1 `Qwen35Config._defaults()` — exact values

| Field | Value | Source |
| --- | --- | --- |
| `name` | `edge0-35b` | `edge0_35b/__init__.py:33` |
| `moe_spec.num_experts` | 256 | `:37` |
| `moe_spec.top_k` | **4** | `:37` |
| `moe_spec.intermediate_size` | 512 | `:37` |
| `moe_spec.router` | `RouterKind.SOFTMAX_TOPK` | `:38` |
| `moe_spec.norm_topk_prob` | `True` | `:38` |
| `moe_spec.shared_experts` | 1 | `:39` |
| `moe_spec.quant` | bits 4, group_size 64, mode `"affine"` | `:40` |
| `moe_spec.layout` | `WeightLayout.SEPARATE` | `:41` |
| `moe_spec.key_template` | `language_model.model.layers.{layer}.mlp.switch_mlp` | `:42` |
| `moe_spec.block_path` | `language_model.model.layers.{layer}.mlp` | `:43` |
| `moe_spec.layer_path` | `language_model.model.layers.{layer}` | `:44` |
| `options` | `LayerOptions.staged_k4()` | `:45` |
| `prerouter.kind` | `SOFTMAX_TOPK` | `:47` |
| `prerouter.start_layer` | 7 | `:48` |
| `prerouter.hidden` | 512 | `:48` |
| `prerouter.dtype` | `"fp16"` | `:48` |
| `prerouter.feature_topk` | `"executed"` | `:49` |
| `prerouter.weights_file` | `prerouter_edge0_35b.safetensors` | `:50` |
| `prerouter.patch_call` | **`True`** | `:52` |
| `prerouter.owners` | `None` → derived `range(6, 39)` = 33 heads | `spec.py:62-65` |
| `prerouter_top_k` | 4 | `:54` |
| `lora` | `lora_edge0_35b.safetensors` | `:55` |
| `lora_r` / `lora_alpha` | 16 / 32.0 (scale 2.0) | `:56` |
| `gen.temperature` | 0.7 | `:58` |
| `gen.top_p` | 0.95 | `:58` |
| `gen.top_k` | 64 | `:58` |
| `gen.repetition_penalty` | 1.0 | `:59` |
| `gen.max_new_tokens` | 2048 | `:59` |
| `gen.eos_ids` | `(248046, 248044)` | `:60` |
| `gen.first_token_greedy` | `True` (dataclass default; not overridden) | `config.py:34` |
| `prefill_chunk` | 2048 | `:61` |
| `hot_window` | 4 | `:62` |
| `intra_staging` | `False` | `:63` |
| `prefetch_history` | `True` | `:64` |
| `port` | 8085 | `:65` |
| `target_tok_s` | 13.0 | `:66` |
| `peak_active_mem_mb` | 3400.0 | `:67` |
| `history_slots` | **`False`** — NEW field in this window | `models/base.py:53` |

### B.2 `LayerOptions.staged_k4()` — exact values

From `streaming/options.py:126-134`, with dataclass defaults (`:64-93`) filled
in where the preset omits a field:

| Field | Value | Note |
| --- | --- | --- |
| `staged` | `True` | |
| `staged_replace` | **`False`** | routing supplied by the patched block, not by replacing it |
| `staged_n` | 4 | 4 slots + 1 zero overflow row = 5 rows |
| `staged_trigger` | 4 | staged path fires only when `indices.size == 4` |
| `staged_sync` | `True` | fills run synchronously at the step boundary |
| `asm_cache` | `True` | **not in the preset** — takes the dataclass default (`:69`) |
| `incr_stack` | **`True`** | flipped ON in this window (`62dcab2`) |
| `incr_writeback` | **`True`** | flipped ON in this window |
| `warm_willneed` | **`True`** | NEW field, flipped ON in the same commit |
| `history_prefetch` | `True` | inert at decode with the prerouter on — see §14 |
| `hot_per_layer` | **0** | hot PINS disabled → `pin_bonus`, `hot_update_interval`, `hot_decay` are inert for 35B decode |
| `hot_update_interval` | 4 | inert (`hot_per_layer == 0`) |
| `hot_decay` | 0.75 | still feeds `_hot_counts`, which selects the prefill hot stack |
| `pin_bonus` | 2.0 | **not in the preset** — dataclass default (`:76`); inert |
| `cache_slots` | **64** | shared LRU across ALL 40 layers = 1.6 slots/layer |
| `prefetch_cap` | 48 | |
| `load_threads` | 8 | |
| `prefetch_threads` | 4 | |
| `use_compile` | `True` | |
| `top_k` | 4 | overrides the resident block's `num_experts_per_tok` (8) |
| `full_layer_prefill` | **`False`** | 35B does NOT use whole-layer prefill |
| `prefill_full_layers` | 0 | |
| `prefill_hot` | **32** | 35B prefill uses the hot-stack path with n_hot=32 |

Note the docstring/`docs` drift fixed in this window: `docs/streaming.md` now
correctly says `staged_k4()` is "staged decode with 4 slots, prefill hot stack
32, on-demand prefill", replacing the older "whole-layer prefill over 12
layers" claim. Source always agreed with the new text.

### B.3 Effective runtime path for 35B decode @ `f8c4cb2`

Derived from `engine/qwen.py::load_installed` (`:63-88`) +
`prerouter/install.py::_patch_qwen_consume` (`:157-195`) +
`streaming/layer.py::__call__` (`:1263-1425`):

- **L7…L38 (32 consumer layers)**: route from `pred_inds`/`pred_scores`
  (prerouter). `indices.size == 4 == staged_trigger` → **incremental-stack
  staged path** (`layer.py:1327-1341`): `core.take(_incr_slot_table, indices)`
  on GPU, `_moe_math` over the persistent `[5, ...]` tensors. **No host sync,
  no `core.stack`, no `asm_cache` lookup.**
- **L0…L6 and L39 (8 layers)**: `_staged_mode = False` (zero-drop scoping,
  `qwen.py:83-87`) → **exact decode path** (`layer.py:1360-1373`): two
  `tolist()` calls, `_get_bundles`, `core.stack` of 9 tensors, unsorted
  `gather_qmm` (`do_sort` needs `local2d.size >= 64`; here it is 4).
- **Prefill (multi-token)**: `prefill_hot=32` → **hot-stack path**
  (`layer.py:1121-1224`): indices remapped to the resident 32-expert stack
  (+1 zero overflow row), sorted gather, misses scatter-added exactly.
  `full_layer_prefill=False`, so `load_full_layer` is never called for 35B.
- **Step boundary**: one batched head einsum (`stager.py:_logits`) → one
  `core.eval` + one `tolist` for all 33 heads → per-consumer
  `stage_experts`.

## C. OLD → CURRENT upstream semantic diff

### C.1 Mechanism presence check (the premise test)

`git grep -c` for each symbol at both revisions, restricted to `src/`:

| Symbol | Files @ `0700e65` | Files @ `f8c4cb2` | Verdict |
| --- | --- | --- | --- |
| `asm_cache` | 2 | 2 | pre-existing |
| `cache_slots` | 3 | 3 | pre-existing |
| `incr_stack` | 2 | 2 | pre-existing (**default flipped**) |
| `incr_writeback` | 2 | 2 | pre-existing (**default flipped**) |
| `use_compile` | 2 | 2 | pre-existing |
| `staged_n` | 3 | 3 | pre-existing |
| `staged_trigger` | 2 | 2 | pre-existing |
| `staged_sync` | 2 | 2 | pre-existing |
| `staged_replace` | 3 | 3 | pre-existing |
| `hot_per_layer` | 3 | **4** | pre-existing; gained a reference in `engine/qwen.py` |
| `hot_update_interval` | 2 | 2 | pre-existing |
| `hot_decay` | 2 | 2 | pre-existing |
| `pin_bonus` | 2 | 2 | pre-existing |
| `prefill_chunk` | 4 | 4 | pre-existing |
| `full_layer_prefill` | 3 | 3 | pre-existing |
| `prefill_full_layers` | 4 | 4 | pre-existing |
| `hot_window` | 6 | 6 | pre-existing |
| `intra_staging` | 4 | 4 | pre-existing |
| `prefetch_history` | 5 | 5 | pre-existing |
| `feature_topk` | 4 | 4 | pre-existing |
| `patch_call` | 4 | 4 | pre-existing |
| `target_tok_s` | 4 | 4 | pre-existing |
| `peak_active_mem_mb` | 4 | 4 | pre-existing |
| `warm_willneed` | **0** | **3** | **NEW in this window** |

Fixed-slot staged decode, GPU-resident slot mapping (`core.take` on
`_incr_slot_table`), `asm_cache`, incremental stack, prerouter-integrated
staging, `mx.compile`, hot/prefetch-history: **all present at `0700e65`**. The
only new mechanism is `warm_willneed`.

### C.2 Semantic diff by category

Raw `git diff` is deliberately not reproduced; this is the semantic delta.

| # | Category | File / function | OLD @ `0700e65` | CURRENT @ `f8c4cb2` | Why (documented/inferred) | 35B? | Prefill? | Decode? | Numerical semantics? | Swift already has it? | Missing? | Feasibility | Upside | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | I/O | `streaming/mmap.py::advise_willneed_range`; `layer.py::warm_experts_willneed` | absent (only whole-shard `advise_willneed`) | page-aligned `madvise(MADV_WILLNEED)` over one (expert, tensor) byte range, issued before builds in `prefetch()` and `stage_experts()` | memory-starved host degrades into "cold pages × per-fault latency"; demand faults serialize on the VM map lock | yes | yes | yes | **no** — advisory only | **no** (we use `pread`, zero madvise/`F_RDADVISE`) | **YES** | upstream: staging wall 162 → 27 ms/step | **very low** |
| 2 | CACHE / MEMORY | `options.py::staged_k4` | `incr_stack=False`, `incr_writeback=False` | both `True` | replaces per-step `core.stack` with persistent in-place tensors; keeps staged bundles out of the shared LRU | yes | no | **yes** | no (claimed bit-identical, 60/60 replay tokens) | no | no — needs in-place array row writes, absent in MLX Swift | peak MLX 2.92 → 2.60 GiB, CPU 143 → 109 ms/step | **high** (in-place mutation lifetime) |
| 3 | ROUTING | `engine/qwen.py::load_installed`, `engine/ling.py::load_installed`, `models/base.py::history_slots` | every streaming layer kept `_staged_mode=True`; non-consumer layers staged from history (previous actuals) | non-consumer layers (`li < start_layer` or `li > n-2`) get `_staged_mode=False`; `--no-prerouter` disables staging entirely; legacy behaviour is opt-in via `history_slots=True` | history-filled slots "silently zero every routed expert outside that set" — measured 3.0–3.75 of 4 dropped per step for L0-6/L39; 17–26 % drop on 8b | yes | no | **yes** | **YES — fixes an output-quality defect** | n/a (we never stage from history) | no | quality | low |
| 4 | CORRECTNESS FIX | `layer.py::load_hot_layer` / `materialize_hot` / `_build` | hot stack had `len(_hot_key)` rows; per-expert slice divisor `len(_hot_key)` | `len(_hot_key) + 1` rows, last row all zeros; divisor updated | prefill sends misses to row `n_hot`; without the row the gather **reads past the end of the stack** | yes | **yes** | no | yes (OOB read) | n/a (no hot stack in Swift) | no | — | low |
| 5 | CORRECTNESS FIX | `backends/mlx/_impl/qwen3_5.py::Qwen3_5TextModel.__call__`; `engine/qwen.py::__init__` | absent | `QWEN_HIDDEN_CLIP` (default 1000) clamps each layer output to ±v and zeroes NaN entries | one fp16 overflow at layer 10 → all-NaN from L11 → all-NaN logits → argmax falls back to token 0 (`!`) collapse, unrecoverable until restart (issue #11) | yes | yes | yes | **YES when it fires** (no-op otherwise; upstream verified greedy ids unchanged) | **no** — no NaN/clip guard anywhere in `Services/Runtime/Edge0/` | partially | robustness | **medium** (could mask a real divergence) |
| 6 | CORRECTNESS FIX | `engine/qwen.py::_reset_state`, `engine/ling.py::_reset_state` | reset KV + prerouter state only | also clears `block.prerouter_m_in` / `prerouter_oh` (ling: `last_topk`, `prev_topk_oh`, `m_in_cache`) and calls `exp.reset()` on every streaming layer | leftover features made the next request's first `stage_all` run heads on the previous request's last hidden state; leftover `_staged_state` defeated the "fill not ready → exact path" fallback and served the previous request's bundles | yes | yes | yes | yes (cross-request contamination) | n/a — we build a fresh `model.makeState()` per generation (`Edge0_35BEngine.swift:380,756`) and hold no staged slot state | no | — | low |
| 7 | PREROUTER | `prerouter/stager.py::_stacked_weights` / `_logits` | per-head loop: 3 small ops × 33 heads | weights stacked once (cached by owner tuple), 3 `einsum`s for all heads; falls back to the loop on any shape/dtype mismatch | "the owner heads share one shape" — measured on 8b | yes | no | **yes** | "mathematically identical up to fp16 rounding" — **not bit-identical** | no (our advisory prerouter runs per-head) | yes, but only if the advisory prerouter is enabled | head cost | **medium** (fp16 rounding ≠ our exactness bar) |
| 8 | PREROUTER | `prerouter/stager.py::stage_all` | always `core.eval` + `tolist` | skipped entirely when `stream_layers` is empty (no consumer needs host IDs) | "the sync produces nothing usable" | yes | no | yes | no | n/a | no | — | low |
| 9 | PREFILL | `layer.py::prefetch_from_prefill` (new); `engine/qwen.py::_prefill_end` | after prefill, `stage_from_prefill()` filled slots from the last prefill token's actual top-k | with a prerouter, `prefetch_from_prefill()` warms the cache instead; the first decode step runs the exact path | "staging the last prefill token's actual top-k there zeroes every routed expert outside that set (measured 4/4 for L7)" | yes | boundary | first token | yes | partial — our staged prefill stages *actual* next-token router selections, so the defect does not apply | no | — | low |
| 10 | DECODE | `engine/qwen.py::_step_pre` / `_step_post` | non-consumer layers re-staged from `last_used` every step; `sync_actuals()` called for them | guarded by `exp._staged_mode`; `sync_actuals` also skipped unless `hot_per_layer > 0` | "the bookkeeping (and its per-layer host sync) is dead weight"; "the previous token's set overlaps the next route by only ~6 %, so the reads are wasted (measured 11.7 → 16.7 tok/s when removed)" | yes | no | **yes** | no | n/a | no | — | low |
| 11 | DEPENDENCIES | `pyproject.toml` | `mlx==0.30.4`, `mlx-metal==0.30.4` | `mlx==0.30.6`, `mlx-metal==0.30.6`; `mlx-lm` stays 0.31.0 | ≤0.30.4 mis-gates NAX matmul on A18/A18 Pro → silently wrong numbers (issue #8), fixed in 0.30.5 by mlx#3083/#3092; ≥0.31.2 makes default streams thread-local and breaks pool-thread builds | yes | yes | yes | **YES on A18/A18 Pro** | our MLX C++ is **0.31.1** — already past the fix, before the stream regression | no | n/a | n/a | see §15 |
| 12 | I/O (server) | `server/chat.py::ChatSession.prompt_ids` | template render fell back to hardcoded ChatML on `TypeError`; `text` could be left **unbound** → `NameError` when the tokenizer had no chat template | rendered template is always kept; nested fallbacks; explicit `_chat_text()` only as last resort | hardcoded ChatML drops the template's empty `<think></think>` closer → the model opens its own `<think>` and the turn derails (issue #11) | yes | **yes** | yes | **YES** (different prompt ids) | we call `tokenizer.applyChatTemplate` (`Edge0_35BEngine.swift:349`) — must be confirmed to render the template rather than substitute ChatML | verify | — | medium |
| 13 | GRAPH CONSTRUCTION | `prerouter/stager.py` `_store` signature | `experts: list[int]` | `experts: list[int] \| None`; `_store` skips `stage_experts` when falsy | supports #8 | yes | no | yes | no | n/a | no | — | low |
| 14 | STACK CONSTRUCTION | (none) | — | — | `incr_stack` pre-existed; only its **default** changed (see #2) | — | — | — | — | — | — | — | — | — |
| 15 | COMPILATION | (none) | `use_compile=True` | `use_compile=True` | unchanged | — | — | — | — | — | — | — | — | — |
| 16 | ATTENTION | (none) | — | — | no attention change in the window; vendored `qwen3_5.py` gained only the hidden clip (#5) | — | — | — | — | — | — | — | — | — |
| 17 | LORA | (none in code) | `adapters/lora.py` unchanged | unchanged | docs reworded ("parallel LoRA" → "Recover-LoRA", `architecture.md`) | — | — | — | no | yes, equivalent (`Edge0LoRA`, `Edge0_35BRealWeights.swift:9-30`) | no | — | — |
| 18 | QUANTIZATION | (none) | `backends/mlx/quant.py::gather_qmm` | unchanged | — | — | — | — | — | yes (`Edge0ExpertMath.gatheredProjection`) | no | — | — |
| 19 | SAMPLING | (none) | `sampling.py` | unchanged | — | — | — | — | — | yes (`Edge0Sampler`) | no | — | — |
| 20 | MODEL MATH | `moe/routing.py`, `moe/spec.py`, `backends/mlx/_impl/qwen3_5_moe.py` | — | **docstring/comment text only** ("Qwen3.5-MoE" → "Qwen3.6-35B-A3B") | naming | no | no | no | **no** | yes | no | — | — |
| 21 | BENCHMARKING | `examples/bench.py` | — | **unchanged in this window** | README table edited only | — | — | — | — | — | — | — | — |
| 22 | REGISTRY / CLI | `registry.py::demo_kwargs`, `cli.py --history-slots`, `models/edge0_8b::demo_no_prerouter` | absent | `edge0 demo` runs 8b on the gate-routed exact path; `--history-slots` restores legacy staging | expose the #3 correction | 8b mostly | no | no | no | n/a | no | — | — |
| 23 | CORRECTNESS FIX (tests) | `tests/test_streaming_math.py` | — | +2 tests pinning the zero overflow row and hot-path-with-misses == exact | regression guard for #4 | yes | yes | no | — | n/a | no | — | — |
| 24 | DOCS | `README*.md`, `docs/*`, `paper/main.pdf` | 3.3 GB peak; "Qwen3.5-MoE"; GitHub badge `Edge0-AI/edge0` | 2.9 GiB; "Qwen3.6-35B-A3B"; badge `Edge0-AI/Edge0`; ModelScope mirrors; technical report added | marketing/naming | — | — | — | **no** | — | — | — | — |

### C.3 8B-tier changes in the same window (for completeness)

`LayerOptions.prod_k8()` was **inverted**: `staged` `False → True`,
`staged_sync` `False → True`, and the docstring rewritten from "staged decode
is OFF — the deployment verified staged decode on ling degrades output" to
"staged decode ON for the prerouter consumers". `docs/prerouter.md` updated 8b
`start_layer` 1 → 7 and heads 22 → 16 (owners 7..22). Our 8B behaviour must be
re-checked against this only if we ever track upstream 8B defaults; our 8B path
is separately validated and is **not** changed by this audit.

## D. Current upstream → Swift gaps

| Mechanism (CURRENT UPSTREAM @ `f8c4cb2`) | Upstream implementation | OUR SWIFT RUNTIME | Gap |
| --- | --- | --- | --- |
| Fixed-slot staged decode | `_incr_tensors` `[5,...]` × 9, `_incr_slot_table` `[256]` int32, `core.take` (`layer.py:1327-1341`) | **NOT PRESENT** — no slot table, no staged buffers, no double buffer | Structural. Requires constant-shape stacks |
| Double-buffered staging | `_staged_state` / `_staged_state_next`, `wait_staged` / `swap_staged` (`layer.py:252-256, 742-776`) | **NOT PRESENT** | — |
| GPU-resident routing indices | router/prerouter `inds` never leave the GPU on the staged path | **NOT PRESENT** — `indices.asType(.int32).asArray(Int32.self)` forces a readback per token per layer (`Edge0_35BModel.swift:239-240, 287-289`) | **~40 host readbacks/token** |
| Per-layer output eval | not needed (bundles stay resident) | `MLX.eval(output)` per layer per token (`Edge0_35BModel.swift:512`) to release leases | **~40 extra barriers/token**, coupled to lease/eviction design |
| `asm_cache` (slot table + stacked wargs, cap 2) | `_staged_asm_cache`, `_slot_table_cache` (`layer.py:262-272, 1268-1311`) | **NOT PRESENT**; and bypassed upstream in `incr_mode` | — |
| `incr_stack` in-place row writes | `self._incr_tensors[(proj,part)][slot] = b[...]` (`layer.py:684-687`) | **NOT POSSIBLE** — MLX Swift has no writable subscript; `mlx_array_set` is whole-array replacement | Blocking, see §8 |
| `warm_willneed` readahead | `madvise(MADV_WILLNEED)` per (expert, tensor) range (`mmap.py:52-77`, `layer.py:392-414`) | **NOT PRESENT** — `pread` only, zero `madvise`/`F_RDADVISE`/`posix_madvise` in the whole app | **Portable** (Darwin `F_RDADVISE` on the existing fd) |
| `use_compile` MoE math | 4 `@core.compile` closures per layer (`layer.py:152-238`) | **NOT PRESENT** — zero `MLX.compile` calls in `Services/Runtime/Edge0/` | API exists in our pin (`Transforms+Compile.swift:153`) |
| Shared LRU | `SharedExpertCache`, `cache_slots=64` keyed `(layer, expert)`, global budget (`cache.py:17-46`) | `Edge0ExpertPool`, **303 slots / 512 MiB**, same `(layer, expert)` key, LRU eviction, lease pinning (`Edge0ExpertPool.swift`) | Ours is **4.8×** larger and adds lease ownership upstream lacks |
| Prefetch buffer | `PrefetchBuffer` cap 48, separate from the LRU (`cache.py:50-81`) | advisory unpinned `prefetch(key:)` + `beginPrefetch(keys:)` (`Edge0ExpertPool.swift:417-457`) | Equivalent intent |
| Hot-stack prefill (`prefill_hot=32`, `hot_window=4`) | numpy backing + GPU window, exact miss scatter-add (`layer.py:990-1224`) | **NOT PRESENT** — staged prefill with microbatch-4 over on-demand union stacks (`Edge0_35BModel.swift:112-121`) | Different strategy; both on-demand |
| Whole-layer prefill (E3b) | `load_full_layer` / `clear_full_layer` (`layer.py:932-982`) | **NOT PRESENT** | Upstream also has it **OFF** for 35B |
| Sorted gather | `_gather_sort` / `_scatter_unsort` from `mlx_lm.models.switch_layers`, `do_sort = size >= 64` | **NOT PRESENT** | Irrelevant at our group sizes (§12) |
| Prerouter heads | 33 heads, `start_layer` 7, `patch_call=True`, **authoritative at decode** | `Edge0_35BPrerouter` (owners 6…38, fc1 `[512,2560]`) + `Edge0PrerouterRuntime` — **advisory only, default OFF**, "the true router remains the sole authority" (`Edge0PrerouterRuntime.swift:7`) | Deliberate divergence |
| Hidden clip / NaN scrub | `QWEN_HIDDEN_CLIP=1000` (`qwen3_5.py`) | **NOT PRESENT** | Robustness gap, see §G candidate 4 |
| LoRA (unmerged delta) | `LoraLinear`: `base(x) + scale·((x@Aᵀ)@Bᵀ)`, fp16, scale 2.0 (`adapters/lora.py:34-51`) | `Edge0LoRA.delta/apply` — same formula, same dtype discipline (`Edge0_35BRealWeights.swift:9-30`) | **Parity** |
| Router math | precise softmax → `argpartition(kth=-k)[..., -k:]` → take → renormalize (`moe/routing.py:13-24`) | `Edge0_35BMoE.select` — same formulation, with an explicit comment on tie behaviour (`Edge0_35BModel.swift:49-67`) | **Parity** |
| Gather QMM | `mx.gather_qmm(..., rhs_indices, transpose=True, group_size=64, bits=4, mode="affine")` | `MLX.gatherQuantizedMM` with identical arguments (`Edge0ExpertMath.swift:36-47`) | **Parity** |
| Cancellation | **NOT PRESENT** — no cancellation check in `engine/base.py::generate` | `Task.isCancelled \|\| generationID != generation` per step, `advisoryRuntime?.cancel()`, `pool.cancelAdvisoryLoads()` (`Edge0_35BEngine.swift:284-307, 403-415, 512-517, 765`) | **We are strictly ahead** |
| Thermal / memory refusal | **NOT PRESENT** | `ModelResidency` / `MemoryAdvisor` / `DeviceSafetyMonitor` coordinated residency | **We are strictly ahead** |
| Per-request state reset | `exp.reset()` + feature-capture clearing (NEW) | fresh `model.makeState()` per generation; pool survives as a cache | Parity in effect |

### D.1 Host-sync barrier count, per decode token

| | CURRENT UPSTREAM @ `f8c4cb2` | OUR SWIFT RUNTIME |
| --- | --- | --- |
| Consumer layers L7–L38 (32) | 0 (GPU `core.take`) | 1 readback + 1 eval each = **64** |
| Non-consumer layers L0–L6, L39 (8) | 1 eval + 2 `tolist` each = **~24** | 0 extra (same path as above) |
| Stager / step boundary | 1 eval + 1 `tolist` for all 33 heads = **2** | n/a (advisory prerouter off) |
| `sync_actuals` | **0** (skipped: `_staged_mode=False` and `hot_per_layer=0`) | n/a |
| Logits + sampler | 1 eval + 1 `item` = **2** | 1 eval + 1 argmax `item` = **2** |
| **Total ≈** | **~28** | **~82** |

So upstream's fixed-slot architecture does genuinely eliminate most of the host
synchronization we still pay — roughly a **3× reduction in barrier count**. The
mechanism is exactly as advertised: `local2d = core.take(self._incr_slot_table,
indices)` (`layer.py:1338`) maps a GPU-resident `[1,1,4]` index array through a
GPU-resident `[256]` int32 table, so no routing datum is ever read to the host.

**But the reduction is not free.** It holds only because the consumer layers
route from `pred_inds` — i.e. because the staged set *is* the routing set by
construction (§10). Upstream measured what happens when that alignment is
absent: 3.0–3.75 of 4 experts dropped per step, and its own
`scripts/e2e_smoke.py` staged-vs-exact gate **still fails on the released 35B
checkpoint with the OLD default too** (`62dcab2` commit message). Our exactness
invariant is precisely the property that gate is testing.

## E. Compatibility risks

| # | Risk | Severity | Evidence | Mitigation |
| --- | --- | --- | --- | --- |
| E1 | Adopting staged slots against a **true** router silently zeroes every routed expert outside the slot set | **Critical** | `qwen.py:63-77`; measured 3.0–3.75/4 drops for L0-6/L39; 4/4 for L7 at the prefill boundary | Do not adopt. Upstream's own answer was to turn staging off for those layers |
| E2 | Upstream's staged-vs-exact equality gate fails on the released 35B checkpoint, on both old and new defaults | **High** | `62dcab2` commit message, "Caveats" | Treat upstream staged decode as *not* exactness-proven; our frozen oracle is the stronger instrument |
| E3 | `head_batch` batched einsum is "identical up to fp16 rounding", i.e. **not bit-identical** | Medium | `stager.py:60-66` | Only relevant if the advisory prerouter is enabled; would need its own parity fixture |
| E4 | NAX kernel gating differs by OS version: `is_nax_available()` requires `iOS ≥ 26.2` **and** `gen >= (arch == 'p' ? 18 : 17)` | **High (unmeasured)** | our MLX C++ 0.31.1, `Source/Cmlx/mlx/mlx/backend/metal/device.h:268-285` | Same device can take different matmul kernels on iOS 26.1 vs 26.2+. Run the frozen oracle on both |
| E5 | Upstream never confirmed the A18 fix empirically ("still needs confirmation from the reporter") | Medium | `2e168c5` commit message | **Erratum (2026-09-17):** our target iPhone18,2 is an **A19 Pro** (phone class g18), which the fixed gate *enables* for NAX — the A18 exclusion is not the switch this device exercises. Our physical validation covers the NAX-eligible regime; verify kernel engagement per `EDGE0_PERF_UPDATE_SCAN_2026-09-17.md` §3, and treat the A18-assumption follow-ups in E4 as revised there |
| E6 | Bumping MLX C++ past **0.31.2** makes default streams thread-local; we construct `MLXArray` off the main thread in `Edge0ExpertLoader` inside `pool.acquire` task groups | **High if we bump** | `pyproject.toml` comment; `Edge0_35BModel.swift:322-338` | Freeze the pin; add a pool-thread array-construction smoke test to the bump checklist |
| E7 | `incr_stack` in-place mutation while an async graph may still reference the buffer | **High** | `layer.py:283-289` gates `_incr_mode` on `staged_sync`; our earlier 8B investigation rejected unsafe in-place mutation | Not portable anyway (§8) |
| E8 | Chat-template substitution changes prompt ids (`<think>` closer lost) | Medium | `a8392a8`, `server/chat.py:88-118` | Verify `tokenizer.applyChatTemplate` (`Edge0_35BEngine.swift:349`) renders the shipped `chat_template.jinja`; our tokenizer parity test covers this |
| E9 | Upstream `cache_slots=64` yields ~0 LRU hits; its own note says enlarging the LRU is the speed lever | Low | `options.py:44-50, 168-181` | Our 303-slot pool is already in the "enlarged" regime. Do not shrink it to match upstream |
| E10 | `docs/streaming.md` claims "each layer's MoE weights around 310MB"; the checkpoint says **432 MiB** (256 × 1 769 472 B) | Low (doc error) | `model.safetensors.index.json`; `Edge0_35BModelConfiguration.swift:107` | Trust the index, not the prose |

## F. Benchmark methodology

Full detail in **`scripts/edge0_upstream_benchmark_notes.md`**. Summary:

- Harness: `examples/bench.py`, unchanged in this window.
- Machine: Mac mini M4 Pro, 24 GB (`applegpu_g16s`, which never takes the NAX path).
- Shape: ~3.3k-token prefill (`BENCH_LONG=1`) → 10 **sampled** warm-up steps →
  200 **timed sampled** decode tokens → 2 runs per tier.
- Excluded: model load, tokenizer, first token. Not excluded: nothing else.
- No thermal policy, no repetition policy, no cooldown between runs.
- Sampling: temperature 0.7, top_k 64, top_p 0.95, `seed=None` →
  **non-deterministic**; 14.9–17.7 tok/s is not a determinism range.
- Peak memory: `mx.get_peak_memory()` = **MLX allocator peak only**, excluding
  mmap'd checkpoint pages. The same workload on a 16 GiB M2 shows "file-backed
  page cache 4.25 → 4.72 GiB" alongside "peak MLX 2.92 → 2.60 GiB".
- The stricter measurement is in commit `62dcab2`, not in `bench.py`: 16 GiB M2,
  60-step sampled **replay** (both arms fed the same token sequence), 20 untimed
  warm-up steps, 5 rounds, rotated arm order, paired per round, 60/60 identical
  tokens.

Our existing iPhone acceptance benchmark is **not** altered by this phase.

## G. Ranked port candidates

### G1 — RECOMMENDED: advisory readahead over expert byte ranges (`F_RDADVISE`)

**What it is.** Port of `warm_willneed` / `advise_willneed_range` (delta #1).
Before issuing the `pread`s for a set of experts, tell the kernel to start
async readahead over exactly those byte ranges.

**Why this and not something bigger.** It is the only change in the entire
`0700e65..f8c4cb2` window that is simultaneously new, portable, numerically
inert, and compatible with true-router exactness.

**Semantics.** Purely advisory: no data is returned, no ordering guarantee,
failure is ignored. Upstream wraps it in `try/except: pass` and labels it
"advisory only" (`mmap.py:43-77`, `layer.py:392-414`). It cannot change a
single output token.

**Dependencies.** None. No MLX change, no package change, no dependency update.
Our `Edge0TensorStore` reads through a plain fd (`Edge0PreadFile`,
`Edge0TensorStore.swift:59-141`), and Darwin provides the fd-based equivalent
of `madvise(MADV_WILLNEED)`:

- `F_RDADVISE` (= 44), "Issue an advisory read async with no copy to user"
- `F_RDADVISEV` (= 116) with `struct radvisoryv { rav_flags; rav_count;
  radvisory *rav_ranges; }`, up to `READ_ADVISE_RANGES_MAX` = 64 ranges per call
- `F_RDADVISEV_NOAGE` (= 0x1), "keep read pages in the active queue"

All three are present in the iOS 27 simulator SDK
(`usr/include/sys/fcntl.h:252, 357, 426-442`), so this is not a
Mac-only capability. `F_RDADVISEV` is the better fit: one syscall can cover
up to 64 ranges, and one token's worth of experts across a layer is
4 experts × 9 tensors = 36 ranges.

**Why we can use it where it matters.** Readahead only helps if the byte ranges
are known *before* the read. Upstream gets that knowledge from the prerouter.
**We already have it without the prerouter**: staged prefill computes the next
group's *true-router* selections ahead of time and carries them in
`lookahead`/`lookaheadLazy` (`Edge0_35BModel.swift:575-641`), and
`Edge0ExpertPool.beginPrefetch(keys:)` already exists as the advisory-load
entry point (`Edge0ExpertPool.swift:430-457`). Those are actual router
selections on real token input — "a wrong guess is impossible", as that call
site's own comment says. So readahead can be wired to a lookahead we already
pay for, with routing authority untouched.

**Expected upside.** Upstream measured staging wall **162 → 27 ms/step** and
step time 244.25 → 187.58 ms (+31.0 %, paired 4/5) on a memory-starved 16 GiB
M2. Our accepted first-token region is ~7 s on a 118-token prompt at g4
(prefill median 6.973 s), i.e. **prefill-dominated and I/O-bound** — the regime
where readahead pays. Honest caveat: the M2 number is not an iPhone
prediction. iPhone NAND, VM and page-cache behaviour differ, and the upside
must be measured with our existing counterbalanced A/B harness
(`Edge0BenchmarkPlan`, `.prefillAB`).

**Risk.** Very low. Advisory-only; worst case it does nothing. Two things to
guard: (a) never let it block or throw into the read path — mirror upstream's
swallow-all behaviour; (b) avoid hinting ranges we will not read, since
`F_RDADVISEV_NOAGE` would keep them in the active queue and could displace
pages we do need. Start without `NOAGE`.

**Scope.** `Edge0TensorStore.swift` (add an advise method on
`Edge0PreadFile`/`Edge0PreadTensorStore`), one call site in the staged-prefill
lookahead, one in `Edge0ExpertPool.beginPrefetch`. New default-OFF preference
in `Edge0EnginePreferences` following the Phase 5H/5J/5K pattern, plus a device
A/B arm. No production default changes without an accepted A/B.

### G2 — Deferred: hidden-state NaN/Inf **detection** (not clipping)

Delta #5. Upstream's clip is a real fix for a real, unrecoverable failure. But
a silent clip can mask a genuine divergence, which conflicts with our
exactness invariant, and we have **not** demonstrated the defect on our
pipeline — our dtype discipline differs (we compute rope, softplus/decay and
the gated delta rule in fp32 and round back:
`Edge0_35BAttention.swift:140, 166-167, 308-317`).

Recommended shape: a default-off **sentinel** that checks the per-layer hidden
state for non-finite values and *reports* (diagnostics counter + typed refusal)
rather than rewriting. That closes the observability gap and answers "are we
exposed at all?" without touching numerics. Only if exposure is demonstrated
should a clip be considered, and then as an explicit product decision.

### G3 — Deferred, coupled: `MLX.compile` around the routed MoE math

Delta: `use_compile=True` upstream; **zero** `MLX.compile` calls in our Edge0
runtime. The API exists in our pin — `MLX.compile(inputs:outputs:shapeless:_:)`
with an unbounded-arity `[MLXArray] -> [MLXArray]` form
(`Transforms+Compile.swift:153`), over `mlx_compile` (mlx-c `compile.h:37`).

Blocked by a shape problem: `mx.compile` specializes on shapes, and our stack
is rebuilt per layer per token with a **variable** union size `U ∈ 1…4`
(`Edge0_35BModel.swift:434-448`), so each distinct `U` triggers a recompile.
Upstream avoids this *because* fixed slots give constant `[5, ...]` shapes — the
two mechanisms are coupled. A Swift-only fix would pad the stack to a constant
row count and prove padding numerically inert. Worth investigating, but it is a
larger change than G1 with a real correctness surface. Not the next phase.

### G4 — Not now: batched prerouter heads (`head_batch`)

Delta #7. Only pays off if the advisory prerouter (Phase 5J, default OFF) is
enabled, and upstream states it is "identical up to fp16 rounding" — below our
exactness bar without a dedicated parity fixture. Revisit together with any
decision on the advisory prerouter.

## H. Explicit non-candidates

| Mechanism | Verdict | Reason |
| --- | --- | --- |
| **Fixed-slot staged decode against the true router** | **NON-CANDIDATE** | Requires the staged set to equal the routed set. With a true router that set is unknowable before the readback we are trying to remove. Upstream's own measurements: 3.0–3.75 of 4 experts dropped per step when the alignment is absent (`qwen.py:63-77`), and its staged-vs-exact gate fails on the released checkpoint (`62dcab2`) |
| **Prerouter as routing authority** (`patch_call=True` consumption of `pred_inds`) | **NON-CANDIDATE** | Directly violates "exact router semantics", the frozen nine-ID oracle, full-model parity and the 412-token stress invariant. See §10 |
| **`incr_stack` / `incr_writeback`** | **NON-CANDIDATE (not portable)** | MLX Swift has no in-place row write: no writable subscript on `MLXArray`, `mlx_array_set` is whole-array replacement, `mlx_array_set_data` is whole-array. The only route is `asMTLBuffer(device:noCopy:)` + manual blit synchronization — exactly the unsafe in-place mutation our earlier 8B investigation rejected. See §8 |
| **`asm_cache`** | **NON-CANDIDATE** | Upstream bypasses it entirely in `incr_mode` (`layer.py:1327-1331`, "no `core.stack`, no asm cache"). It caches `core.stack` graph nodes we do not build. Even at its best it holds **2** entries |
| **Sorted gather (`_gather_sort` / `_scatter_unsort`)** | **NOT A CURRENT CANDIDATE** | Upstream's threshold is `local2d.size >= 64` (`layer.py:1384`) on the exact path. Our routed microbatch-4 group produces `size = 16`; single-token decode produces `size = 4`. Never reached. Our group has ≤16 unique experts, and the 35B default prefill uses the hot-stack path, not the exact path. Also depends on `mlx_lm.models.switch_layers`, which we do not vendor |
| **Whole-layer prefill (E3b) / `load_full_layer`** | **REFERENCE INFRASTRUCTURE, NOT A RECOMMENDED PORT** | `full_layer_prefill=False` and `prefill_full_layers=0` for the current 35B. One 35B layer is 256 × 1 769 472 B = **432 MiB**; the old doc's "12 leading layers" would be ~5.2 GiB of page cache. Upstream does not enable it; we should not either |
| **Hot pins / `pin_bonus` / `hot_update_interval`** | **NON-CANDIDATE** | `hot_per_layer=0` for 35B, so all of it is inert upstream. Nothing to port |
| **History prefetch at decode** | **NON-CANDIDATE** | Dead in current 35B production (`_step_pre` takes the prerouter branch, and non-consumer layers are `_staged_mode=False`). Upstream measured removing it as a win: "11.7 → 16.7 tok/s" |
| **`cache_slots=64` (shrinking our pool)** | **NON-CANDIDATE — regression** | Upstream's 64 slots cannot hold one token's 160-key working set and measures ~0 hits; it is described as "the price of the small footprint". Our 303 slots / 512 MiB is deliberately in the regime upstream identifies as the speed lever |
| **`staged_replace=True`** | **NON-CANDIDATE** | Not used by either tier at current revision |
| **`demo_kwargs` / registry aliasing / `--history-slots` CLI** | **NON-CANDIDATE** | Python CLI surface with no iOS analogue |
| **MLX version change in either direction** | **NON-CANDIDATE this phase** | We are on MLX C++ 0.31.1 — already past the NAX fix (≥0.30.5) and before the thread-local-stream regression (≥0.31.2). Moving either way is a net loss. See §15 |
| **Model migration / re-download** | **NON-CANDIDATE** | Checkpoint is byte-identical (§3). Nothing to migrate |

### H.1 Developer-only experiments: remain default-OFF

Confirmed unchanged by this audit, and **not** reactivated:

| Experiment | Flag | Default | Location |
| --- | --- | --- | --- |
| Staged eval window 4 | `edge0_35BStagedEvalWindow` | `1` | `Edge0EnginePreferences.swift:63` |
| Batched router readback | `edge0_35BRouterReadbackMode` | `0` | `Edge0EnginePreferences.swift:117` |
| Shared-expert batching | — | off | — |
| Advisory learned prerouter | `edge0_35BAdvisoryPrerouter` | `false` | `Edge0EnginePreferences.swift:98` |

Accepted production configuration, confirmed in source:
`defaultExecutionMode = .staged` (`Edge0_35BEngine.swift:142`) which resolves to
prefill `staged` / decode `boundedPrefetch` (`:720-728`), microbatch group size
4 (`Edge0EnginePreferences.swift:82`), eval window 1, per-token router readback
mode 0, expert load concurrency 4 (`:30`), pool tier 512 MiB →
`512 MiB / 1 769 472 B = 303` slots (`Edge0_35BMemoryBudget.swift:41,83-87`).

## I. Next-phase recommendation

**Implement G1 only: advisory `F_RDADVISEV` readahead over expert byte ranges,
default-OFF, measured with the existing counterbalanced prefill A/B.**

Rationale:

1. It is the single genuinely new mechanism in the window, and the one upstream
   attached its largest measured gain to (staging wall 162 → 27 ms/step).
2. It is numerically inert by construction, so it cannot threaten the frozen
   nine-ID oracle, full-model parity, the 412-token stress, ≥32 cached decode
   steps, exact router semantics, the 310 LoRA adapters, quantization, RoPE,
   GatedDeltaNet state, the GQA cache, tokenizer/template, Thinking/history,
   EOS/sampler behaviour, cancellation/regeneration, unload/reload, or 8B
   behaviour.
3. It needs no dependency change. Our MLX pin stays exactly where it is, which
   is the one place upstream's own analysis says is safe.
4. It fits our existing machinery rather than replacing it: `beginPrefetch`
   already exists, the staged-prefill lookahead already computes the required
   byte ranges, and `Edge0EnginePreferences` already carries the default-OFF
   experiment pattern with a device A/B harness behind it.
5. It targets our actual pain point. The accepted ~7 s first-token region is
   prefill-dominated (prefill median 6.973 s at g4), and prefill is where our
   lookahead is already available — so the upside does not depend on enabling
   the advisory prerouter.

Acceptance gate for the next phase, in order:

1. Unit-test the range computation (page alignment outward, clamping to file
   size, ≤64 ranges per `F_RDADVISEV` call, empty/zero-length no-op) — no device
   needed.
2. Confirm advisory failure is swallowed and never propagates into the read
   path.
3. Run the frozen nine-ID oracle and full-model parity with the flag ON: output
   must be **bit-identical** to flag OFF. This is the primary gate, because the
   mechanism is supposed to be invisible.
4. Device A/B on iPhone18,2 with the accepted profile (118 prompt tokens,
   64 output max, Thinking Off, greedy, 512 MiB / 303 slots, reads 4), using
   `.prefillAB`-style counterbalancing and paired rounds, reporting prefill
   median, TTFT, first-visible, decode rate, peak high-water, and pool read
   latency p95.
5. Only after an accepted A/B does the default flip. Until then it stays a
   developer arm.

Explicitly **not** in the next phase: any routing-authority change, any
in-place tensor mutation, any MLX version move, any cache-size reduction, any
model migration, and any change to the accepted iPhone benchmark.

---

## 3. Model identity / Qwen version verification

**No model download was performed.** Verification used the HF API (commit
history, tree listings with LFS OIDs), byte-range fetches of small JSON/Jinja
files, and header-only range reads of the two safetensors adapter files.

### 3.1 Revision comparison

| Item | Value |
| --- | --- |
| HF repo | `Edge0/Edge0-35B-A3B-preview` |
| Our pinned revision | `1ff9f4478890faec0368c5463b621d1036d5b518` (2026-09-10) — `Edge0ModelFamily.qwen35MoEPinnedRevision` |
| Current HF HEAD | `15dc6959b64fb579550f2b9b3bfd3e6b3a3b1173` (2026-09-14) |
| Repo created | 2026-09-08 |
| Commits between | 4, all titled "Upload README.md" plus one `.mp4` upload |

Tree diff (path + size) between the two revisions:

```
4c4
< README.md      5997
---
> README.md      5985
```

**`README.md` is the only difference.** All 19 other entries match, and every
LFS-backed file has an **identical blob OID** at both revisions:
`lora_edge0_35b.safetensors` (42 413 928 B),
`prerouter_edge0_35b.safetensors` (138 422 000 B),
`model-00001..00004-of-00004.safetensors`
(4 395 019 264 / 5 368 472 749 / 5 368 324 139 / 4 377 211 365 B),
`tokenizer.json`, `vocab.json`, `model.safetensors.index.json`.

Byte-level confirmation by SHA-256 of the small text files fetched at both
revisions:

| File | Result |
| --- | --- |
| `config.json` | **IDENTICAL** (`a822a9e48b0aafbe3144ec37…`) |
| `model.safetensors.index.json` | **IDENTICAL** (`e359cd95565275b923fed8df…`) |
| `chat_template.jinja` | **IDENTICAL** (`e84f32a23fdda27689f868aa…`) |

### 3.2 Where "Qwen3.6" comes from

`config.json` at current HEAD says, unchanged from our pinned revision:

```json
"architectures": ["Qwen3_5MoeForConditionalGeneration"],
"model_type": "qwen3_5_moe",
"text_config": { "model_type": "qwen3_5_moe_text", ... }
```

"Qwen3.6-35B-A3B" appears **only** as:

- an HF repo tag: `base_model:Qwen/Qwen3.6-35B-A3B`,
  `base_model:adapter:Qwen/Qwen3.6-35B-A3B`;
- upstream prose, introduced by `b413a22` / `63d6efb` ("docs: rename the 35b
  base model to Qwen3.6-35B-A3B"), which touched only `README.md`,
  `README_zh.md`, `docs/architecture.md`, `docs/models/edge0-35b.md`,
  `docs/moe.md`, `docs/prerouter.md`, `docs/streaming.md` and **comments** in
  `moe/routing.py`, `moe/spec.py`, `engine/qwen.py`,
  `backends/mlx/_impl/__init__.py`, `models/edge0_35b/__init__.py`.

`registry.py::TYPE_ALIASES` is unchanged: `qwen3_5_moe_text → edge0-35b`,
`qwen3_5_moe → edge0-35b`. The class is still `Qwen35Config`; the vendored
backbone is still mlx-lm 0.31.0's `qwen3_5_moe` / `qwen3_next`.

### 3.3 Explicit answers

1. **Is the underlying checkpoint revision actually different?**
   No. Between our pinned `1ff9f447` and current HEAD `15dc6959` the only
   changed file is `README.md`. Every weight shard and both adapters have
   identical LFS blob OIDs. The 19.5 GB we have is current.
2. **Did only upstream naming/documentation change?**
   Yes. "Qwen3.5-MoE" → "Qwen3.6-35B-A3B" is a documentation and HF-tag
   rename, plus code comments. No identifier, alias, `model_type` or class name
   changed.
3. **Did model architecture / config semantics change?**
   No. `config.json` is byte-identical (SHA-256 match). Verified against our
   `Edge0_35BModelConfiguration.Expectation`: `architectures`
   `Qwen3_5MoeForConditionalGeneration`, wrapper `qwen3_5_moe`, text
   `qwen3_5_moe_text`, hidden 2048, 40 layers, 16 heads, 2 KV heads, head_dim
   256, vocab 248 320, max_pos 262 144, 256 experts, `num_experts_per_tok` **8
   declared / 4 released**, moe_intermediate 512, shared_expert_intermediate
   512, linear_conv_kernel_dim 4, linear_key_head_dim 128, linear_num_key_heads
   16, linear_num_value_heads 32, linear_value_head_dim 128, bits 4 / group 64 /
   affine, **80** 8-bit module overrides (40 × `mlp.gate` +
   `mlp.shared_expert_gate`), bos 248 044, eos 248 044, 30 linear + 10 full
   attention layers with `full_attention_interval` 4 and first full-attention
   layer 3. All match the live file. `layer_types`, `rope_parameters`
   (theta 10 000 000, `mrope_section` [11,11,10], partial_rotary_factor 0.25,
   `mrope_interleaved` true), `rms_norm_eps` 1e-6 — all as our decoder expects.
4. **Did tensor layout change?**
   No. `model.safetensors.index.json` is byte-identical: 1 757 tensors,
   `total_size` 20 401 929 952, 4 shards (383/498/504/372 tensors). Layer-0
   routed-expert keys are exactly
   `language_model.model.layers.0.mlp.switch_mlp.{gate_proj,up_proj,down_proj}.{weight,scales,biases}`
   — 9 tensors, `WeightLayout.SEPARATE`, matching
   `Edge0_35BExpertLayout.keyTemplate`. Our recorded byte accounting checks out
   against the live shard sizes: 40 × 256 × 1 769 472 = 18 119 393 280 routed
   bytes; + 1 389 394 176 resident = 19 508 787 456 payload; shard files total
   19 509 027 517, i.e. 240 061 bytes of safetensors headers (~60 KB/shard).
5. **Did the LoRA artifact change?**
   No. Header range-read at current HEAD: 620 tensors, all `F16`, **310 distinct
   modules** (`.lora_A` / `.lora_B` pairs), `lora_A` `[16, in]`, `lora_B`
   `[32, 16]`, metadata `{"model":"edge0-35b","kind":"lora","K":"4","r":"16",
   "alpha":"32","source":"…/lora_qwen35_v7_round9.npz",
   "source_md5":"dbdef1af692986ad1937562c0d2aab7f",
   "converted":"2026-09-08T09:59:20+00:00","format_version":"1"}`. Targets
   include `linear_attn.in_proj_{a,b,qkv,z}`, `linear_attn.out_proj`,
   `mlp.shared_expert.{gate,up,down}_proj`. This confirms the 310-module count
   in our production configuration and our `Edge0LoRA` scale of 2.0 (= 32/16).
6. **Did the prerouter artifact change?**
   No. 99 tensors, all `F16` = **33 heads × 3**; owners `6…38` (metadata lists
   all 33 explicitly); `fc1.weight` `[512, 2560]`, `fc2.weight` `[256, 512]`,
   `linear_init.weight` `[256, 2560]`, where `2560 = hidden 2048 + 2 × 256
   experts` — exactly what `Edge0_35BPrerouter` validates
   (`fc1.dim(1) == hidden + 2 * numExperts`). Metadata
   `{"kind":"prerouter","source":"…/pregate_qwen35_v7_round9.npz",
   "source_md5":"df15dff55499f6dc0343d54379b03e32"}`. The `pregate` →
   `prerouter` rename (`1d32a55`) touched only `scripts/verify_alignment.py`
   env-var names and the conversion script's key normalization; the released
   file name was already `prerouter_edge0_35b.safetensors`.
7. **Are our existing weights compatible with current upstream code?**
   Yes, without qualification. Current upstream resolves the same two file names
   from the model directory (`artifact("prerouter_edge0_35b.safetensors", …)`,
   `artifact("lora_edge0_35b.safetensors", …)`), reads the same key templates,
   and `TYPE_ALIASES` still maps the same `model_type`. **No model migration is
   needed or warranted in Phase 5L.**

Do **not** rename our local architecture identifiers because a README changed.
`Edge0_35BModelConfiguration.Expectation` should keep
`Qwen3_5MoeForConditionalGeneration` / `qwen3_5_moe` / `qwen3_5_moe_text`,
because those are what the checkpoint actually contains.

## 5. Qwen35Config settings table — CURRENT UPSTREAM vs OUR SWIFT

`CURRENT UPSTREAM` = values read from source at `f8c4cb2` (§B).
`OUR SWIFT` = values read from source in the working tree.

| SETTING | CURRENT UPSTREAM @ `f8c4cb2` | OUR SWIFT | MATCH / DIFFER | IMPACT |
| --- | --- | --- | --- | --- |
| `top_k` | 4 (`options.top_k=4`, `moe_spec.top_k=4`, `prerouter_top_k=4`) | 4 (`Edge0_35BExpertLayout.topK`, `releasedExpertsPerToken=4`) | **MATCH** | routing width; drives stack size and slot count |
| routing kind | `SOFTMAX_TOPK`, `norm_topk_prob=True` | precise softmax → `argPartition(kth: V−k)[…, −k...]` → renormalize with `+1e-20` | **MATCH** | exact router semantics preserved |
| `staged` | `True` | `.staged` execution mode = staged **prefill**, decode resolves to `boundedPrefetch` | **DIFFER (semantics)** | upstream "staged" = fixed-slot decode; ours = staged prefill. Same word, different mechanism |
| `staged_n` | 4 (+1 zero row) | n/a — no slots | **DIFFER** | ours stacks the exact union `U ≤ 4` instead |
| `staged_trigger` | 4 | n/a | DIFFER | — |
| `staged_sync` | `True` | n/a (our decode evals per layer) | DIFFER | ours has a stronger completion boundary |
| `staged_replace` | `False` | n/a | n/a | unused upstream |
| `asm_cache` | `True` (but bypassed in `incr_mode`) | absent | DIFFER | no impact — dead in upstream's own default |
| `incr_stack` | **`True`** | absent, **not portable** | **DIFFER** | upstream: removes 9 `core.stack` nodes/layer/step |
| `incr_writeback` | **`True`** | absent | DIFFER | upstream: dedups staged set from the LRU |
| `use_compile` | `True` | **absent — zero `MLX.compile` calls** | **DIFFER** | real, unexploited opportunity (§G3) |
| `cache_slots` | 64 (shared, all layers) — ~0 hits measured | **303 slots / 512 MiB** with lease pinning | **DIFFER (ours larger, deliberately)** | ours can hold ~1.9 tokens' working set; upstream cannot hold one |
| `hot_per_layer` | 0 | n/a | MATCH (both off) | hot pins inert upstream |
| `hot_update_interval` | 4 (inert) | n/a | n/a | — |
| `hot_decay` | 0.75 | n/a | DIFFER | feeds upstream's prefill hot-stack selection only |
| `pin_bonus` | 2.0 (inert) | n/a | n/a | — |
| `prefill_chunk` | 2048 | full prompt (118 accepted); chunking via microbatch groups | DIFFER | our accepted profile is far below 2048 |
| `full_layer_prefill` | **`False`** | absent | **MATCH** | E3b is off upstream too |
| `prefill_full_layers` | 0 | absent | MATCH | — |
| `hot_window` | 4 | absent | DIFFER | governs upstream's prefill GPU window |
| `intra_staging` | `False` | absent | MATCH (both off) | — |
| `prefetch_history` / `history_prefetch` | `True` / `True` — but **dead at decode** with the prerouter on | advisory `beginPrefetch` from actual router lookahead | **DIFFER (ours stronger)** | upstream's is unused; ours drives real prefill overlap |
| prerouter `start_layer` | 7 | advisory runtime, owners 6…38 | MATCH (identity) | — |
| prerouter `owners` | derived 6…38, 33 heads | 6…38, "absent owners are never failures" | **MATCH** | — |
| `feature_topk` | `"executed"` | executed top-k features | **MATCH** | head input contract |
| `patch_call` | `True` → block `__call__` patched, prediction becomes the route | absent by design (advisory only) | **DIFFER (deliberate)** | **the routing-authority divergence — see §10** |
| LoRA `r` / `alpha` | 16 / 32.0, scale 2.0, unmerged fp16 delta | 16 / 32.0, scale 2.0, unmerged fp16 delta, 310 modules | **MATCH** | verified against the live artifact header |
| `target_tok_s` | 13.0 (M4 Pro acceptance) | n/a — device A/B acceptance instead | DIFFER (not comparable) | different hardware class |
| `peak_active_mem_mb` | 3400.0 (MLX allocator peak) | 512 MiB pool tier + memory-advisor high-water (~2.71 GB at g4) | DIFFER (different definitions) | do not compare directly |
| `temperature` / `top_p` / `top_k` / `rep_penalty` | 0.7 / 0.95 / 64 / 1.0 | app-driven; accepted profile is **greedy** | DIFFER | our acceptance is deterministic, upstream's is not |
| `eos_ids` | `(248046, 248044)` | from `config.json` text_config + generation_config | **MATCH** | — |
| `first_token_greedy` | `True` | greedy throughout the accepted profile | MATCH in effect | — |
| `max_new_tokens` | 2048 | 64 in the accepted profile | DIFFER | benchmark shape |
| hidden clip / NaN scrub | `QWEN_HIDDEN_CLIP=1000`, on by default | **absent** | **DIFFER** | robustness gap (§G2) |
| readahead hint | `warm_willneed=True` | **absent** | **DIFFER** | **the G1 candidate** |
| cancellation | **absent** | per-step `Task.isCancelled` + generation-id invalidation + advisory cancel | **DIFFER (ours ahead)** | must be preserved |
| thermal / memory refusal | **absent** | `ModelResidency` / `MemoryAdvisor` / `DeviceSafetyMonitor` | **DIFFER (ours ahead)** | product behaviour; must be preserved |
| expert load concurrency | `load_threads=8`, `prefetch_threads=4` | `expertLoadConcurrency = 4`, bounded read semaphore | DIFFER | ours tuned for iPhone NAND/thermals |

## 6. Deep audit — fixed-slot staged execution

Source: `streaming/layer.py:240-315` (init), `:538-585`
(`_build_staged_bundles`), `:587-706` (`_stage_incr`), `:708-741`
(`stage_experts`), `:742-776` (`wait_staged`/`swap_staged`), `:820-861`
(`sync_actuals`), `:1263-1358` (consume), `:1429-1441` (`reset`).

1. **How are slots allocated?** `n = staged_n = 4` usable slots plus slot
   index `n` as the all-zero overflow row → persistent tensors of shape
   `[5, ...]`. In `_stage_incr` allocation is **sticky**: survivors keep their
   slot (zero work), slots of evicted experts are freed, and
   `free = [i for i in range(n) if occ[i] is None]`; newly arriving experts
   take freed slots in order (`:619-637`).
2. **How are expert IDs associated with slots?** Two CPU-side structures:
   `_incr_occupancy: list[slot] -> expert id | None` (authoritative,
   `:302, 618-631`) and `slot_of_list: [num_experts] -> slot` rebuilt each step
   for compatibility consumers and stats (`:627-631`).
3. **What tensor contains the slot mapping?**
   `self._incr_slot_table = core.full((num_experts,), n, dtype=core.int32)` —
   a GPU `[256]` int32 array initialized to all-`n` (the overflow row),
   `core.eval`-ed once at allocation (`:613-616`). In the non-incremental path
   the equivalent is `core.array(slot_of_list, dtype=core.int32)`, cached in
   `_slot_table_cache` (cap 8) inside `_build_asm` (`:1268-1276`).
4. **What stays CPU-side?** `_incr_occupancy`, `slot_of_list`, the expert id
   lists (`sorted({int(e) for e in experts})[:n]`), the bundle resolution
   cascade, `_hot_counts`, all `_stats`, and both locks (`_lock`,
   `_staging_lock`).
5. **What stays GPU-side?** `_incr_tensors` — 9 persistent arrays for the
   SEPARATE layout (`up/gate/down` × `weight/scales/biases`), each `[5, ...]`
   (`:606-612`); `_incr_slot_table` `[256]` int32; `_zero_slot` per
   (proj, part); and the router/prerouter `indices` array.
6. **Where are indices materialized?** Never on the staged path.
   `local2d = core.take(self._incr_slot_table, indices)` (`:1338`) is a GPU
   gather producing `[1,1,4]`. `indices` arrives from the patched MoE block as
   `pred_inds` (GPU) or from the router's `argpartition` (GPU).
7. **Does routing index data ever call `tolist`/`item` or otherwise synchronize
   to the host in the staged hot path?** **No.** The staged consume branch
   (`:1320-1358`) contains no host read. Host reads elsewhere in a 35B decode
   step: (a) the stager's single `tolist` for all 33 heads at the step boundary
   (`stager.py:194`) — and current upstream *skips even that* when
   `stream_layers` is empty; (b) `sync_actuals`'s `idx.reshape(-1).tolist()`
   (`:830`) — **not called at all** in current 35B production, because
   `_step_post` guards it on `exp._staged_mode or hot_per_layer > 0` and
   non-consumer layers have `_staged_mode=False` with `hot_per_layer=0`
   (`qwen.py:209-221`); (c) the exact-path fallback's two `tolist` calls
   (`:1364, 1372`) for L0–L6 and L39.
8. **What happens when a required slot is unavailable?**
   `if slot is None: continue` — the expert is dropped rather than corrupting a
   slot (`:648-652`). The code comments this unreachable because `|exp| ≤ n`
   guarantees a free slot for every changed expert. A dropped expert's
   contribution maps to the zero row, i.e. **it is silently discarded** — which
   is exactly the failure mode the zero-drop scoping exists to prevent.
9. **What is the overflow / zero slot?** Index `n` (= 4).
   `_incr_slot_table` is initialized to all-`n`, evicted experts are reset to
   `n` (`:688-690`), and row `n` of every `_incr_tensors` entry is allocated
   zero and **never written after init** (`:604-612`). The non-incremental path
   pads the stack with `self._zero_slot[(proj, part)]` to `staged_n + 1` rows
   (`:1284-1287`).
10. **How does exact fallback work?** `st = self._staged_state; if st is None:`
    → `staged_fallback += 1`, `_staged_at_use = None`, and control falls
    through to the exact decode path (`:1321-1326`). The branch also requires
    `self._staged_mode and indices is not None and indices.size ==
    self._staged_trigger`, so multi-token input (prefill) never takes it.
    Upstream's `reset()` fix (#6 in §C.2) exists because a leftover
    `_staged_state` would make `st` non-`None` and defeat this fallback.
11. **What is `staged_sync` actually synchronizing?** Not the GPU. It selects
    *where the fill runs*: with `staged_sync=True`, `stage_experts` builds
    synchronously on the calling thread at the step boundary
    (`:729-738`); with `False` it submits to the thread pool and double-buffers
    asynchronously (`_submit_stage_locked`, `:778-793`). This matters because
    `_incr_mode` is gated on it — `o.incr_stack and self._staged_mode and
    self._staged_sync and not self._staged_replace` (`:289-291`) — with the
    comment "Safe only when the previous forward's eval has finished … the async
    double-buffered fill would race the writes."
12. **What is double-buffered?** `_staged_state` (ACTIVE, read by the current
    step's `__call__`, "never disturbed mid-step") and `_staged_state_next`
    (the fill target) (`:249-256`).
13. **When are staged buffers swapped?** At the step boundary:
    `_forward` runs `stage_all()` then `state.swap()` (`qwen.py:185-187`);
    `swap_staged()` → `wait_staged()` promotes `_staged_state_next` to
    `_staged_state` and clears `_staged_pending` (`:742-776`). In sync mode the
    fill lands directly in `_staged_state_next`, so promotion is trivial.
14. **What owns staged storage?** The per-layer `StreamingSwitchGLU` instance
    owns `_incr_tensors`, `_incr_slot_table`, `_incr_occupancy` and
    `_incr_bundles`. In `incr_writeback` mode the canonical bundle for a staged
    expert lives **only** in `_incr_bundles`; it is written back to the shared
    LRU on eviction from the stack (`:670-680`).
15. **What prevents stale-token use?** Three mechanisms: (a)
    `core.eval(self._incr_slot_table)` after in-place mutation, labelled
    `FIX(2026-09-02)` — "without this, near-100 % slot churn reads stale slot
    tables and the output collapses" (`:692-699`); (b) exact occupancy
    mirroring, so a returning expert cannot be hidden from `changed` and
    silently mapped to the zero row (`:640-644`); (c) `reset()` clearing
    `_pending_indices`, `_staged_at_use`, `_last_prefill_topk`,
    `_staged_state`, `_staged_state_next`, `_staged_pending` and `last_used`
    per request (`:1429-1441`).
16. **How does cancellation interact with it?** **It does not — cancellation is
    absent upstream.** There is no cancellation token or interrupt check in
    `StreamingSwitchGLU`, in the staged path, or in `Edge0Engine.generate`
    (`engine/base.py:101-151`). `close()` shuts the pools down with
    `cancel_futures=True` (`:1443-1449`) and `reset()` clears staged state, but
    a mid-generation abort has no representation. **Our runtime is strictly
    ahead here** (`Edge0_35BEngine.swift:284-307, 403-415, 512-517, 765`), and
    any port must not regress it.

### 6.1 Direct comparison with our runtime

| Aspect | CURRENT UPSTREAM @ `f8c4cb2` | OUR SWIFT RUNTIME |
| --- | --- | --- |
| Router readback | none on consumer layers | `indices.asType(.int32).asArray(Int32.self)` per token per layer (`Edge0_35BModel.swift:239-240`, `287-289`) |
| Staging source | prerouter prediction (authoritative) | **actual** true-router selections, computed ahead (`lookahead` / `beginPrefetch`) |
| Stack shape | constant `[5, ...]` persistent | variable union `[U, ...]`, `U ∈ 1…4`, rebuilt per layer per token (`:434-448`) |
| Stack traffic | 0 at steady state (in-place delta writes) | 4 × 1 769 472 B = 6.75 MiB per layer per token → **270 MiB per token** across 40 layers |
| Microbatch | n/a at decode (single token) | routed MoE microbatch-4 at prefill (accepted) |
| Pool | 64 shared LRU slots (~0 hits measured) | 303 slots / 512 MiB with lease pinning |
| Advisory loading | prerouter `stage_experts` (authoritative) | `prefetch(key:)` unpinned, `beginPrefetch(keys:)` — "a wrong prediction can never exhaust pin capacity" |
| Lease ownership | none | `Edge0ExpertLease` with generation checks, pinned entries never evicted, `release` idempotent |
| Cancellation | none | full |

**Does upstream's fixed-slot architecture genuinely eliminate the host
synchronization we still have?** Yes — that is real and correctly described.
`core.take` over a `[256]` int32 slot table keeps routing indices GPU-resident,
and the constant `[5, ...]` shape additionally removes the per-step
`core.stack`. Our ~82 barriers per decode token (§D.1) against upstream's ~28
is a genuine structural gap, and the 270 MiB/token of stack traffic is a
genuine cost we pay that upstream does not.

**But the elimination is purchased with routing authority.** The slot set equals
the routed set only because the consuming block routes *from* the prediction.
With a true router, the set is unknowable before the readback that we are trying
to remove — which is why upstream's own correction (`b57d83a`) was to *switch
staging off* for every layer that still routes with its gate. Porting the slot
machinery to our true-router production path would reproduce exactly the
zeroing defect upstream just fixed. Not implemented, per instruction.

## 7. Deep audit — `asm_cache`

Source: `layer.py:262-272` (construction), `:1266-1288` (`_build_asm`),
`:1302-1311` and `:1344-1356` (the two consume sites).

- **Cache key**: `exp_key = tuple(staged_exp)` — the staged expert id tuple, in
  sorted order. Per layer instance.
- **Cached objects**: the pair `(slot_of, wargs)` where `slot_of` is the
  materialized GPU `[num_experts]` int32 slot table and `wargs` is the tuple of
  9 (SEPARATE) or 6 (fused) `core.stack`-ed weight/scale/bias arrays.
- **Does it include**: the slot table — **yes** (via `_slot_table_cache`, a
  separate cap-8 dict keyed the same way, `:1268-1276`); stacked graph nodes —
  **yes**, that is the primary content; expert-set mapping — yes, implicitly as
  the key; a compiled graph — **no** (`mx.compile` caching is internal to MLX
  and keyed separately); tensor views — the stacked arrays are new tensors, not
  views of the bundles.
- **Lifetime**: the `StreamingSwitchGLU` instance. Not cleared by `reset()`
  (`:1429-1441` does not touch `_staged_asm_cache` or `_slot_table_cache`), so
  both survive across requests.
- **Invalidation**: capacity only. `if len(self._staged_asm_cache) > 1: pop(next(iter(...)))`
  → effective capacity **2 entries** (evict-when-over-1). `_slot_table_cache`
  evicts at **> 8**. No content-based invalidation, and none is needed: the key
  is the expert set, and the stacked arrays are immutable once built.
- **Generation scope**: none — it is process/instance scoped and survives
  `reset()`.
- **Layer scope**: per layer (each `StreamingSwitchGLU` has its own dicts).
- **Memory cost**: one entry holds 9 stacked arrays of `[5, ...]` rows ≈
  5 × 1 769 472 B ≈ 8.4 MiB per layer, ×2 entries ×40 layers ≈ **675 MiB**
  worst case if every layer cached two distinct sets. `_slot_table_cache` adds
  8 × 1 KiB per layer (negligible). In practice the expert set changes almost
  every step, so the cache rarely holds two useful entries.
- **Interaction with changing expert sets**: this is its weakness. A new set is
  a new key → full rebuild of 9 `core.stack` nodes. With near-100 % slot churn
  (upstream's own words at `:694`) the hit rate is structurally low.
- **Interaction with staged buffers**: mutually exclusive. In `_incr_mode` the
  consume branch returns before reaching `_staged_asm_cache` —
  `wargs = tuple(self._incr_tensors[...])` with the comment "no `core.stack`,
  no asm cache" (`:1327-1336`).
- **Interaction with LRU**: none directly; the cached arrays are independent of
  `SharedExpertCache`. In non-incr mode `_build_staged_bundles` still puts fresh
  builds into the LRU (`:576-582`).
- **Interaction with cancellation**: none (no cancellation upstream).

**Cache hit conditions / likely hit rate on current 35B decode**: `asm_cache`
is **unreachable** in the current 35B default, because `staged_k4()` sets
`incr_stack=True` and `_incr_mode` is therefore true, and the incremental
branch precedes and bypasses it. Its hit rate in the current default is
**exactly 0**. Even in a hypothetical non-incremental configuration, a hit
requires the *same* sorted 4-expert tuple to recur within the last 2 sets on
the same layer — upstream's own measurements (44 % of staged uses change per
step on 8b; ~6 % adjacent-token overlap for gate-routed layers) make that rare.

**Useful for prefill?** No. Prefill takes the hot-stack or whole-layer branch
(`indices.size > 8`), neither of which consults `_staged_asm_cache`.

**Primarily decode-oriented?** Yes, and specifically *non-incremental* staged
decode — a configuration neither shipped tier uses at `f8c4cb2`.

**Comparison with Swift.** Our runtime rebuilds the equivalent objects every
step: `MLX.stacked(...)` of 9 arrays per layer per token
(`Edge0_35BModel.swift:434-448`), plus a fresh `localIndices` `MLXArray`
(`:425-431`). So yes — **we rebuild what `asm_cache` would cache, every step,
and upstream has also stopped caching it.** The right response is not to add an
equivalent cache (upstream's own data says it would miss) but either to make the
stack shape constant (§G3) or to stop rebuilding it at all (§8, blocked).

No implementation in this section.

## 8. Deep audit — incremental stack (`incr_stack`, `incr_writeback`)

Source: `layer.py:281-315` (init/gating), `:587-706` (`_stage_incr`),
`:1327-1341` (consume), `:820-861` (`sync_actuals` write-back interaction),
`:1429-1441` (`reset`).

- **Exact tensor shapes**: `_incr_tensors[(proj, part)]` is
  `[staged_n + 1, *bundle_shape[1:]]` = `[5, ...]`. For SEPARATE layout with
  hidden 2048, moe_intermediate 512, bits 4, group 64: `up/gate weight`
  `[5, 512, 64]` uint32, `up/gate scales` and `biases` `[5, 512, 8]` bf16,
  `down weight` `[5, 2048, 16]` uint32, `down scales`/`biases` `[5, 2048, 32]`
  bf16. Nine tensors, `5 × 1 769 472 B` = 8.4375 MiB per layer, **337.5 MiB
  across 40 layers**. `_incr_slot_table` is `[256]` int32 = 1 KiB per layer
  (40 KiB total).
- **Allocation ownership**: the per-layer `StreamingSwitchGLU`. Lazily allocated
  on the first `_stage_incr` call, then `core.eval`-ed once (`:604-616`).
  Slot `n` is zero-filled and never written again.
- **Update operation**: in-place row assignment on the main thread —
  `self._incr_tensors[(proj, part)][slot] = b[(proj, part)]` for each changed
  slot (`:683-687`) — plus scalar slot-table writes `tbl[e] = n` for evicted
  and `tbl[e] = slot` for new (`:688-691`), then
  `core.eval(self._incr_slot_table)` (`:699`).
- **Deduplication behaviour**: sticky slots. `changed = [e for e in exp if e
  not in self._incr_bundles]`; survivors are **not** rewritten. Counters:
  `stage_delta_hits += len(exp) - len(writes)`, `incr_writes += len(writes)`
  (`:700-703`). `bundles` is rebuilt to mirror occupancy exactly, with the
  explicit comment that "a stale entry would hide a returning expert from
  `changed` (no slot assigned, no row write → its contribution silently maps to
  the zero row)" (`:640-644`).
- **Synchronization assumptions**: `_incr_mode` requires `staged_sync`. The
  comment is explicit — "Safe only when the previous forward's eval has
  finished (`staged_sync`, the production default) — the async double-buffered
  fill would race the writes" (`:283-288`). And: "in-place delta writes (main
  thread, previous graph already evaluated: stage runs at the step boundary in
  sync mode)" (`:681-682`).
- **Writeback behaviour**: with `incr_writeback`, a staged expert's canonical
  bundle lives only in `_incr_bundles` (the stack rows are the math copy), so
  there is no LRU duplication; on eviction from the stack the bundle is
  `shared_cache.put` back so returning experts still hit the LRU (`:670-680`).
  `sync_actuals` also skips its LRU promotion in write-back mode (`:846-851`).
- **Relationship to staged slots**: it *is* the staged-slot implementation. The
  consume branch reads `_incr_tensors` directly as `wargs` and computes
  `local2d = core.take(self._incr_slot_table, indices)` (`:1327-1341`).
- **Is backing storage mutated?** Yes — the persistent `[5, ...]` MLX arrays
  are mutated in place, row by row.
- **When is mutation safe?** Only at the step boundary, on the main thread,
  after the previous forward has been fully evaluated. That is the entire
  content of the `staged_sync` gate.
- **How is previous graph completion guaranteed?** By `staged_sync` placing the
  fill after `core.eval(logits)` in `_forward` (`qwen.py:174-187`), plus the
  explicit `core.eval(self._incr_slot_table)` (`:692-699`) whose absence caused
  a documented output collapse. There is **no** fence, event or reference-count
  mechanism — completion is guaranteed by program order, not by a lifetime
  proof.
- **Cancellation safety**: none. No cancellation exists upstream; an abort
  between the row writes and the consuming eval would leave a partially updated
  stack.
- **Numerical parity tests**: upstream's own claim is "Output is unchanged: new
  == old token-for-token on the consistency control, and 60/60 identical tokens
  in the replay A/B" (`62dcab2`). But the same commit records that
  `scripts/e2e_smoke.py`'s staged-vs-exact gate **already fails on this
  checkpoint with the OLD default too**. So incremental stacking is proven
  *equivalent to the previous staged path*, not proven *equivalent to exact*.

**Did current upstream introduce a safe lifetime mechanism that changes our
earlier conclusion?** **No.** The safety argument is unchanged in kind:
`_incr_mode` is gated on `staged_sync`, i.e. on the fill being sequenced after
the previous forward's evaluation by program order. There is no ownership token,
no event/fence, no copy-on-write, no reference counting on the mutated buffer.
Our earlier 8B investigation rejected in-place mutation while asynchronous
graphs might still reference the buffer; that conclusion stands.

**Portability: blocked, independently of the lifetime question.** MLX Swift in
our pin (`PrismML-Eng/mlx-swift` @ `e40e0a57`, MLX C++ 0.31.1, mlx-c v0.6.0)
exposes **no in-place row write**:

- `MLXArray` subscripts are get-only — no `set:` accessor and no `_modify`
  anywhere in `Source/MLX/MLXArray+Indexing.swift`;
- `mlx_array_set(mlx_array* arr, const mlx_array src)` replaces the **whole**
  array (`mlx-c/mlx/c/array.cpp:46-54`), as do `mlx_array_set_bool/int/float/…`;
- `mlx_array_set_data(arr, data, shape, dim, dtype)` sets the **whole** array to
  a copied buffer (`mlx-c/mlx/c/array.h:190-201`).

The only conceivable route is `MLXArray.asMTLBuffer(device:noCopy:)`
(`Source/MLX/MLXArray+Metal.swift:21`) or `asData(access: .noCopyIfContiguous)`
(`MLXArray+Bytes.swift:210`) followed by a manual Metal write plus explicit
blit/eval synchronization — i.e. hand-rolled aliasing of an MLX-owned buffer.
That is precisely the unsafe in-place mutation our 8B work rejected, now with
the added hazard of bypassing MLX's allocator.

**Not ported. Mutation is not ported without a lifetime proof, and no lifetime
proof exists upstream.**

## 9. Deep audit — zero-host-sync routing

### 9.1 CURRENT UPSTREAM 35B DECODE @ `f8c4cb2`

Per decode step. `⟂` marks a CPU↔GPU boundary.

```
Engine.step(tid)                                     engine/base.py:94-100
├─ _step_pre(tid)                                    qwen.py:190-206
│    └─ pg_stager is not None → for li<7 or li>38:
│         if exp._staged_mode and exp.last_used: …   ← FALSE for all 8 layers
│                                                    (scoping set _staged_mode=False)
│       ⇒ NO-OP. No sync. No prefetch.
├─ _forward([tid])                                   qwen.py:154-188
│  ├─ inputs = core.array(ids)[None,:]                    (host→GPU, 1 int)
│  ├─ prefill_multi=False, full_layer=False
│  ├─ self._lm.model(inputs, cache, before_layer_cb=None,
│  │                 after_layer_cb=None, async_eval_per_layer=False)
│  │   for li in 0..39:                                  qwen3_5.py:277-296
│  │     hidden = layer(hidden, mask, cache)
│  │     if QWEN_HIDDEN_CLIP>0: mx.where(isnan…)/mx.clip   ← GPU, lazy
│  │     MoE block __call__ (PATCHED)                     install.py:157-195
│  │       li in 7..38 (CONSUMER):
│  │         pred = st.pred_inds[li]           ← GPU array, cached from last step
│  │         inds, scores = pred, st.pred_scores[li]      ← NO GATE EVAL
│  │         oh = topk_onehot(inds, 256)                  ← GPU
│  │         st.oh[li] = oh; block.prerouter_m_in = x; block.prerouter_oh = oh
│  │         switch_mlp(x, inds) → StreamingSwitchGLU.__call__   layer.py:1108
│  │           _pending_indices = indices                 (stores the GPU array)
│  │           _staged_mode ∧ indices.size==4==staged_trigger → STAGED  :1320
│  │             wait_staged()                            (no-op in sync mode)
│  │             _incr_mode ∧ _incr_tensors → 
│  │               wargs = tuple(_incr_tensors[...])      ← persistent, no stack
│  │               local2d = core.take(_incr_slot_table, indices)   ← GPU
│  │               return self._moe_math(x, *wargs, local2d)        ← @mx.compile
│  │             ⇒ NO tolist, NO item, NO eval.  ⟂ none
│  │       li in 0..6, 39 (NON-CONSUMER, _staged_mode=False):
│  │         pred = None → gates = softmax(self.gate(x))   ← TRUE ROUTER
│  │           argpartition → inds; take_along_axis → scores; renormalize
│  │         switch_mlp(x, inds) → __call__ → EXACT PATH   layer.py:1360
│  │           flat = indices.reshape(-1)
│  │           unique = sorted(set(int(v) for v in flat.tolist()))   ⟂ SYNC+READ
│  │           bundles = self._get_bundles(unique)          (pool builds, may ⟂)
│  │           local2d = core.array([remap[e] for e in flat.tolist()])  ⟂ READ (cached)
│  │           wargs = core.stack(...) × 9                  ← rebuilt every step
│  │           do_sort = local2d.size >= 64 → False (size 4)
│  │           _moe_math(orig_x, *wargs, local2d)           ← @mx.compile
│  │         ⇒ 8 layers × (1 eval + 2 tolist)
│  ├─ logits = self._lm.lm_head(h[0,-1])
│  ├─ core.eval(logits)                                            ⟂ SYNC
│  ├─ _pg_stager.stage_all()                          stager.py:161-207
│  │    for owner in 6..38: read block.prerouter_m_in / prerouter_oh / oh_prev
│  │    _logits(...) → stacked einsum over 33 heads (head_batch)     ← GPU
│  │    _select(logits) → select_from_logits(...,4)                  ← GPU
│  │    stream_layers non-empty (32 consumers) ⇒
│  │      core.eval(inds_all, scores_all)                            ⟂ SYNC
│  │      flat = inds_all.reshape(33,-1).tolist()   ← ONE tolist     ⟂ READ
│  │    per owner: _store → st.pred_inds[consumer]=inds_i (GPU),
│  │                        exp.stage_experts(experts)
│  │      └─ warm_experts_willneed(unique)  ← madvise, no ⟂
│  │      └─ _staged_sync ∧ _incr_mode → _stage_incr(unique)
│  │           bundle cascade: _incr_bundles → _pinned → shared_cache → _build
│  │           in-place row writes; tbl updates; core.eval(_incr_slot_table) ⟂
│  └─ _pg_state.swap()                                              (CPU only)
├─ _step_post(tid)                                   qwen.py:208-227
│    for li<7 or li>38: if exp._staged_mode or hot_per_layer>0: sync_actuals()
│      ⇒ FALSE for all 8 ⇒ NO-OP. sync_actuals' tolist never runs.
└─ return logits
Sampler: argmax(...).item() or random.categorical(...).item()        ⟂ SYNC+READ
```

Boundary count per decode token: **8 exact-path layer evals + ~16 `tolist`
reads + 1 stager eval + 1 stager `tolist` + 1 logits eval + 1 sampler read ≈
28**. Of these, **zero** come from the 32 consumer layers.

**The exact mechanism by which routing indices remain GPU-resident**: the
consumer layer never computes routing at all. It reads a *cached GPU array*
(`st.pred_inds[li]`) produced at the previous step boundary, and maps it through
a *cached GPU int32 table* (`_incr_slot_table`) with `core.take`. Both operands
are device arrays; the result `local2d` feeds `gather_qmm`'s `rhs_indices`
directly. Nothing in that chain has a host representation.

`mx.take` alone does **not** prove the path is host-sync-free — and the audit
does not rest on it. The proof is the absence of any `tolist`/`item`/numpy
conversion in `layer.py:1320-1358`, combined with the `_step_pre`/`_step_post`
guards that stop `sync_actuals` from running. Note also that
`streaming/install.py:100-106` ships a `route_indices()` assertion guard whose
docstring states the design intent: "indices must stay on GPU … the whole staged
design assumes no per-layer host syncs". That guard is defined but **not called
anywhere** in the current tree.

Search results for host-sync primitives in `src/edge0/` at `f8c4cb2`
(excluding tests): `.tolist()` at `stager.py:194`, `layer.py:830, 1124, 1140,
1237, 1364, 1372`; `.item()` at `sampling.py:61`, `engine/base.py:126`. Python
`sorted(...)`/`set(...)` appear at `layer.py:720, 833, 869, 1364` and
`stager.py:198` — all on already-materialized host lists, or on the prefill
paths (`:1124, 1140, 1237` are guarded by `indices.size > 8`, i.e. multi-token).
Blocking `core.eval` in the decode path: `qwen.py:175` (logits),
`stager.py:192` (one for all heads), `layer.py:699` (slot table).

### 9.2 OUR SWIFT 35B DECODE

```
Edge0_35BEngine generation loop                       Edge0_35BEngine.swift
├─ Task.isCancelled || generationID != generation                ⟂ (CPU check)
├─ MLX.argMax(logits).item(Int.self)                             ⟂ SYNC+READ
├─ model.decode(tokenID:state:mode:)                Edge0_35BModel.swift:1227
│  ├─ ids = MLXArray([Int32(tokenID)],[1,1])                      (host→GPU)
│  ├─ hidden = weights.embedTokens(ids)
│  ├─ for index in 0..39: layer(hidden, state:, mode:)
│  │   ├─ attention (KDA / MLA)                                  GPU, lazy
│  │   └─ Edge0_35BMoE.callAsFunction(x)          Edge0_35BModel.swift:94
│  │       tokens == 1 ⇒ falls through to the per-token loop :213
│  │       └─ routedToken(tokenInput, deferred:false)          :264
│  │          ├─ logits = weights.routerGate.base(x)              ← TRUE ROUTER
│  │          ├─ Self.select(logits:topK:4)                    :49-67
│  │          │    softmax(precise) → argPartition → takeAlong → renorm
│  │          ├─ indices.asType(.int32).asArray(Int32.self)    :287-289
│  │          │    ⇒ map { Int($0) }                            ⟂ SYNC + READ  (1/40)
│  │          ├─ prerouterTap?(layerIndex, x, selected)  ← advisory only, off
│  │          ├─ uniqueExperts (order-preserving dedupe)          (CPU)
│  │          ├─ capacity guard: pool.configuredCapacitySlots     (CPU constant)
│  │          ├─ concurrent acquire for U experts
│  │          │    withThrowingTaskGroup → pool.acquire(key)   :322-338
│  │          │      └─ Edge0TensorStore pread (bounded queue, ≤4) ⟂ I/O
│  │          │      └─ MLXArray(bytes, shape, dtype:)             (host→GPU ×9)
│  │          ├─ MLX.stacked(...) × 9  (weight/scales/biases × up/gate/down)
│  │          │                                              :434-448  6.75 MiB
│  │          ├─ localIndices = MLXArray(selected.map{position[...]}, shape)
│  │          │                                              :425-431  (host→GPU)
│  │          ├─ Edge0ExpertMath.switchGLUExpertForward(...)  :450
│  │          │    gatherQuantizedMM × 3 + swiglu               GPU, lazy
│  │          ├─ (expertDown * scores).sum(axis:-2)              GPU, lazy
│  │          ├─ shared expert + sigmoid gate                    GPU, lazy
│  │          ├─ MLX.eval(output)                            :512 ⟂ SYNC  (2/40)
│  │          └─ for lease in leases: await pool.release(lease)   (CPU)
│  ├─ state.position += 1
│  ├─ rmsNorm + lmHead                                            GPU, lazy
│  └─ return logits[0,-1]
└─ onEvent(.token(delta))
```

Boundary count per decode token: **40 router readbacks + 40 `MLX.eval(output)`
+ 1 argmax `item` ≈ 81**.

### 9.3 Boundary comparison

| Boundary class | UPSTREAM @ `f8c4cb2` | OUR SWIFT | Notes |
| --- | --- | --- | --- |
| Router index read to host | 0 (consumers) / 16 (8 non-consumer layers) | **40** | our readback exists to choose which experts to load |
| Per-layer output eval | 0 (consumers) / 8 | **40** | ours exists to release leases so slots can be evicted — a *memory* constraint, not a math one |
| Step-boundary eval | 2 (logits + one stager eval for 33 heads) | 1 (logits) | upstream amortizes all heads into one |
| Sampler read | 1 | 1 | parity |
| Weight stack rebuild | 0 at steady state | **9 arrays × 40 layers** | 270 MiB/token of stack traffic |
| Async readahead hint | yes (`warm_willneed`) | **no** | §G1 |
| Total ≈ | **28** | **81** | ~2.9× |

Two of our three gaps are *self-imposed by design choices we should keep*:
the readback is the price of exact true-router execution, and the per-layer
eval is the price of a bounded pool with lease ownership. The third — no
readahead hint — is a pure omission with no correctness content, which is why
§G1 targets it.

## 10. Deep audit — current prerouter + stager

Sources: `prerouter/spec.py`, `prerouter/heads.py`, `prerouter/stager.py`,
`prerouter/state.py`, `prerouter/install.py`, `engine/qwen.py`,
`streaming/layer.py`.

### 10.1 One complete decode transition

Token `t−1` → prediction by owner `N` → consumption by layer `N+1` at token `t`.

```
TOKEN t-1, LAYER N (owner, N in 6..38), inside _forward:
  patched Qwen3NextSparseMoeBlock.__call__(x)          install.py:157-195
    guard: prerouter_enabled ∧ st is not None ∧ x.ndim==3 ∧ x.shape[1]==1
           ∧ sm._staged_replace is False                → else orig_call (router)
    li = N
    pred = st.pred_inds[N] if N >= st.start(7) else None
    if pred is not None:  inds, scores = pred, st.pred_scores[N]     ← PREDICTION
    else:                 gates = softmax(self.gate(x), precise=True)
                          inds = argpartition(gates,-k)[-k:]; scores = take_along; renorm
    oh = topk_onehot(inds, 256)                                     ← GPU
    st.oh[N] = oh
    self.prerouter_m_in = x            ← FEATURE CAPTURE (single-token forwards only)
    self.prerouter_oh   = oh           ← FEATURE CAPTURE
    y = self.switch_mlp(x, inds)                                    ← STAGED PATH
    y = (y * scores[...,None]).sum(axis=-2)
    shared_y = sigmoid(shared_expert_gate(x)) * shared_expert(x)
    return y + shared_y

STEP BOUNDARY (after core.eval(logits)):
  CrossTokenStager.stage_all()                          stager.py:161-207
    for owner N in state.owners (6..38):
      m_in   = block.prerouter_m_in          (layer N's MoE input at token t-1)
      cur_oh = st.oh[N]                      (executed one-hot at token t-1)
      prev_oh= st.oh_prev[N]                 (executed one-hot at token t-2)
      if any is None: skip
      metas.append(N); inputs/cur_ohs/prev_ohs.append(...)
    logits = _logits(metas, inputs, cur_ohs, prev_ohs)   [33,1,1,256]
      _stacked_weights(metas): cache key = tuple(metas); stacks fc1/fc2/linear_init
        across all 33 heads once → w1,w2,wl; core.eval'd; reused across steps
      feats = concatenate([stack(inputs), stack(cur_ohs), stack(prev_ohs)], -1)
      f2 = feats.reshape(33,-1)                       [33, 2560]
      h1 = einsum("ni,nij->nj", f2, w1)               [33, 512]
      act= gelu_erf(h1)
      out= einsum(f2,wl) + einsum(act,w2)             [33, 256]
      → reshape [33,1,1,256]
    inds_all, scores_all = _select(logits) = select_from_logits(logits, 4)
    if stream_layers:  core.eval(inds_all, scores_all); flat = ONE tolist
    for i, owner N in enumerate(metas):
      consumer = N + 1
      experts = sorted({int(v) for v in flat[i]})
      _store(consumer, logits[i], inds_all[i], scores_all[i], experts)
        st.pred_inds[consumer]   = inds_i        ← GPU ARRAY, keyed by CONSUMER
        st.pred_scores[consumer] = scores_i      ← GPU ARRAY
        st.logits[consumer-1]    = logits_i
        stream_layers[consumer].stage_experts(experts)
          warm_experts_willneed(unique) → _stage_incr(unique) → in-place rows
      _note(N, cur_oh) → rolls st.oh_prev
  st.swap():  logits_prev ← logits; oh_prev ← oh; logits/oh ← [None]*n

TOKEN t, LAYER N+1 (consumer):
  pred = st.pred_inds[N+1]  → the SAME GPU array the stager just stored
  ⇒ slots (staged from `experts`) == routing (pred_inds) BY CONSTRUCTION
```

### 10.2 Semantics clarified

- **`staged_replace`**: when `True`, `switch_mlp` is called with `indices=None`
  and routes through the *whole* staged set (`layer.py:1291-1318`) — the staged
  set replaces the router outright. **Both shipped tiers set it `False`.**
- **explicit-index routing**: the production mode. `staged_replace=False`, so the
  block still passes an index array — but that array *is* the prerouter's
  `pred_inds`. The slot table then maps it without drops.
- **"routing supplied by prerouter"**: literal. `pred_inds` and `pred_scores`
  are the routing indices **and** the expert weights.
- **slot mapping**: `_incr_slot_table[expert] → slot`, GPU-resident `[256]`
  int32, consumed by `core.take`.
- **zero drop**: not an emergent property but a construction guarantee — the
  stager stages `sorted(set(flat[i]))` and the block consumes `inds_all[i]`,
  which are the same selection.
- **true router execution, if any**: only in the `pred is None` fallback.
- **prediction mismatch behaviour**: **there is none.** No comparison against
  the gate is made, because the gate is not evaluated. `staged_dropped` can only
  be non-zero on the exact path (via `sync_actuals`), which the scoping now
  prevents from running for 35B.
- **fallback behaviour**: (a) `pred is None` → the real router runs for that
  layer/step (pos-0 fallback, "as in training"); (b) `_staged_state is None` →
  `staged_fallback += 1` and the exact path runs; (c) `head_batch` shape/dtype
  mismatch → per-head loop; (d) missing prerouter weights → `ValueError` at
  install time with an actionable message.

### 10.3 The authoritative question

> **DOES CURRENT PRODUCTION 35B STILL EXECUTE THE ORIGINAL TRUE ROUTER FOR
> EVERY CONSUMER LAYER DURING DECODE?**

**NO.**

For layers **7…38** (32 of 40) at steady-state decode, the patched
`Qwen3NextSparseMoeBlock.__call__` takes `inds = st.pred_inds[li]` and
`scores = st.pred_scores[li]` and **never evaluates `self.gate`**
(`install.py:168-181`). The true router runs only:

- at layers **0…6** and **39**, where `pred is None` (`li < st.start`) or no
  owner predicts (`li = n−1`), and which are additionally `_staged_mode=False`
  after zero-drop scoping;
- at a consumer layer on the **first decode step**, where `pred_inds` is still
  `None` — the pos-0 fallback used in training;
- whenever `prerouter=None` / `--no-prerouter`, in which case *no* layer keeps
  slots and every layer runs the gate on the exact path.

**What becomes authoritative:** the prerouter head's cached `pred_inds` **and**
`pred_scores`. Both the expert *set* and the expert *weights* come from the
prediction. Alignment between the staged set and the routed set is not verified
or reconciled — it is guaranteed by both being the same array
(`stager.py:_store` writes `inds_i` into `st.pred_inds[consumer]` and
`sorted(set(flat[i]))` into `stage_experts`, from one `_select` call).

Consequences for our exact-output requirement:

1. Upstream's 35B decode output is a function of the prerouter weights. It is
   **not** the true-router output. Any comparison of our greedy tokens against
   upstream's decode tokens is a comparison against a *different model
   trajectory*, not a parity check.
2. The property our frozen nine-ID oracle, full-model parity, 412-token stress
   and ≥32-cached-decode-step invariants protect — exact true-router semantics —
   is precisely the property upstream trades away for its host-sync-free decode.
3. Upstream's own `scripts/e2e_smoke.py` staged-vs-exact gate fails on the
   released 35B checkpoint (both old and new defaults). We should read that as
   corroboration that staged/predicted decode is not exact on this checkpoint,
   not as an upstream bug to be ported around.
4. Therefore the ~3× barrier reduction in §D.1 is **not available to us** at
   our current release contract. Obtaining it would be a product decision to
   ship predicted routing, with a new oracle, new parity fixtures and a new
   quality story — not a performance port.

**Routing replacement is not ported in Phase 5L.**

## 11. Deep audit — `mx.compile`

### 11.1 Current upstream

- **What is compiled**: four closures created per `StreamingSwitchGLU` instance
  in `__init__` (`layer.py:152-238`) — `_make_moe_math`,
  `_make_moe_math_sorted`, `_make_moe_math_fused`,
  `_make_moe_math_sorted_fused` — each decorated `@core.compile`
  (`core` is `mlx.core`, so this is plain `mx.compile`, **not** `shapeless`).
  Two are kept per instance (`_moe_math`, `_moe_math_sorted`), fused variants
  replacing them when `fuse_gu`. With 40 layers that is **80 compiled
  functions** per engine. Separately, `backends/mlx/_impl/qwen3_next.py:58` uses
  `@partial(mx.compile, shapeless=True)` in the vendored mlx-lm model code.
- **Compiled body**: the whole routed FFN — `gather_qmm(up)`,
  `gather_qmm(gate)`, `_swiglu`, `gather_qmm(down)`, plus
  `expand_dims`/`squeeze` (and `_scatter_unsort` in the sorted variants). One
  closure = one fused kernel group.
- **Dynamic inputs**: the *contents* of `x` and of the weight/scale/bias arrays.
- **Static**: every shape and dtype. At decode, `x` is `[1,1,2048]` and
  `local2d` is `[1,1,4]`; the stacked weights are `[5, ...]` under `incr_stack`
  (or `[U+1, ...]` otherwise). `mx.compile` without `shapeless` specializes on
  shapes, so a shape change forces recompilation.
- **Do expert-set changes cause recompilation?** **No — and this is the key
  synergy.** Under `incr_stack` the tensors are persistent `[5, ...]` arrays
  whose *contents* are mutated in place; shapes never change, so one compiled
  graph serves every expert set. Without `incr_stack`, `core.stack` produces
  `[U+1, ...]` with `U` varying 1…4 → up to 4 distinct specializations per
  layer. Fixed slots are what make compilation cheap.
- **Compile cache behaviour**: MLX's internal cache, keyed by the compiled
  function identity plus input signatures. `_staged_asm_cache` is a *separate*,
  unrelated graph-node cache (§7) and is bypassed in `incr_mode`.
- **Warm-up cost**: one compile per math function per layer on first use. Not
  measured upstream. Bounded by `MLX_CACHE_LIMIT_MB` (default **256**,
  `engine/base.py:170-177`).
- **Memory cost**: the compiled kernel cache, capped at 256 MiB by default;
  not included in `get_peak_memory()` accounting in any documented way.
- **Prefill applicability**: **limited.** The exact path uses `_moe_math` /
  `_moe_math_sorted` and so is compiled — but 35B prefill takes the *hot-stack*
  path (`prefill_hot=32`, `indices.size > 8`), which calls `_gather_gate_up`
  and `quant.gather_qmm` **directly**, not through a compiled closure
  (`layer.py:1150-1223`). The whole-layer path is likewise uncompiled
  (`:1244-1260`). Only the hot path's per-expert miss correction reuses raw
  `gather_qmm`. So in the current 35B default, **prefill is essentially not
  compiled**; compilation benefits decode.
- **Decode applicability**: full — consumers via `_moe_math` on the incremental
  stack, non-consumers via `_moe_math` on the exact path.
- **Interaction with staged slots**: enabling (see above).
- **Interaction with LoRA**: none. LoRA wraps `nn.Linear` modules outside the
  MoE math (`adapters/lora.py:34-51`), so compiled closures never see it.
- **Interaction with quantized gather QMM**: `gather_qmm` is *inside* the
  compiled closure, so the dequantize-matmul kernels for up/gate/down and the
  SiLU gate fuse into one compiled graph. This is where most of the win is.

### 11.2 Our pinned Swift MLX

| Item | Value |
| --- | --- |
| Swift package | `PrismML-Eng/mlx-swift` @ `e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230` (2026-06-11) — `project.yml:32-34` |
| MLX C++ submodule | `PrismML-Eng/mlx` @ `d90771c8b59bcaee356560cd4e37498719d91cf4` |
| **MLX C++ version** | **0.31.1** (`Source/Cmlx/mlx/mlx/version.h`) |
| mlx-c | `ml-explore/mlx-c` @ `v0.6.0` |
| mlx-swift-lm | 3.31.4 |
| swift-transformers-mlx | 0.2.0 |
| Current usage in `Services/Runtime/Edge0/` | **zero `MLX.compile` calls** |

**Does Swift MLX expose a compatible compilation facility?** **Yes.**

```swift
// Source/MLX/Transforms+Compile.swift:153
public func compile(
    inputs: [any Updatable] = [], outputs: [any Updatable] = [],
    shapeless: Bool = false,
    _ f: @escaping ([MLXArray]) -> [MLXArray]
) -> @Sendable ([MLXArray]) -> [MLXArray]
```

- The array form has **unbounded arity**, so our 11-argument MoE math
  (`x` + 9 weight arrays + `localIndices`) fits. The convenience overloads in
  `Transforms+CompileOverloads.swift` cap input arity at **6**, so the array
  form is required.
- `shapeless:` matches Python's `mx.compile(shapeless=True)`.
- `inputs:`/`outputs:` take `any Updatable`; `MLXArray` conforms
  (`MLXArray.swift:610`), giving the equivalent of Python's compile-with-state.
- Backed by `mlx_compile(mlx_closure*, mlx_closure, bool shapeless)`
  (mlx-c `compile.h:37`), with `CompiledFunction` managing the MLX-side cache
  id and `mlx_detail_compile_erase` on deinit.
- `MLX.compile(enable:)` (`Transforms+Compile.swift:234`) maps to
  `mlx_set_compile_mode`, giving a global off-switch — useful for an A/B arm.

**Compatibility risks** (why this is §G3 deferred, not §G1):

1. **Shape variability.** Our stack is `[U, ...]` with `U ∈ 1…4` per layer per
   token, so a naïve port recompiles per distinct `U` — up to 4 specializations
   × 40 layers × (fused/unfused) and unpredictable warm-up stalls. Upstream
   avoids this only via constant-shape fixed slots, which we cannot adopt
   (§10). A Swift-only alternative is padding the stack to a constant row count
   and proving the padding numerically inert (duplicate/zero rows never
   selected by `localIndices`); that is a real correctness surface requiring
   its own parity fixture.
2. **`gather_qmm` inside a compiled closure on the NAX path.** NAX availability
   depends on OS version and GPU generation (§15, E4). A compiled kernel graph
   captured under one gating decision must not be replayed under another. Any
   compile work must be validated across the iOS 26.2 boundary on the A19 Pro
   target (iPhone18,2 — see the 2026-09-17 erratum in §15.3).
3. **Thread affinity.** Compiled closures are `@Sendable`, but MLX 0.31.1's
   default stream is not yet thread-local (that lands ≥0.31.2). Our MoE math is
   built on Swift-concurrency tasks; if the pin ever crosses 0.31.2, both
   compile and pool-thread array construction break the same way upstream
   documents.
4. **No measured benefit on our hardware.** Upstream reports no compile A/B
   number at all. Claiming upside here would be speculation.

**Do not assume Python `mx.compile` has a direct Swift equivalent** — it does
have one, but with arity, shape-specialization and stream-affinity differences
that must be handled explicitly. **No dependency update in this phase.**

## 12. Deep audit — sorted gather

Sources: `layer.py:176-230` (`_moe_math_sorted`, `_moe_math_sorted_fused`),
`:1082-1106` (`_gather_gate_up`), `:1360-1425` (exact path), `:49`
(`from mlx_lm.models.switch_layers import _gather_sort, _scatter_unsort`).

- **Input shapes**: exact path — `x` `[B,T,H]` → `expand_dims(x,(-2,-3))`
  `[B,T,1,1,H]`; `local2d` `[B,T,k]`; stacked weights `[E_stack, out, in]`.
  Sorted path — `_gather_sort(x, local2d)` returns
  `(x_sorted [B*T*k, 1, 1, H], local [B*T*k], inv_order)`, then
  `_scatter_unsort(z, inv_order, indices.shape)` restores `[B,T,k,H]` before
  `.squeeze(-2)`.
- **Threshold**: `do_sort = local2d.size >= 64` (`layer.py:1384`), on the
  **exact path only**.
- **Sorting key**: `local2d` — the per-(token, slot) *local* expert index into
  the stacked weight tensor. Grouping tokens by expert.
- **Expert grouping**: after sorting, all rows targeting expert `j` are
  contiguous, so `gather_qmm(..., sorted_indices=True)` can use the grouped
  kernel and skip per-row index indirection.
- **How token order is restored**: `_scatter_unsort(z, inv_order, out_shape)`.
- **Why it improves execution**: larger contiguous per-expert batches → better
  GPU occupancy and fewer gather instructions per output row. The benefit grows
  with `M`.
- **Numerical equivalence**: same `gather_qmm` kernel family with
  `sorted_indices=True`; reduction order within a row is unchanged, so results
  are expected identical. Upstream pins this with
  `tests/test_streaming_math.py` (`test_hot_stack_matches_exact`,
  `test_hot_stack_with_misses_matches_exact`). We did not verify bit-identity
  ourselves.
- **Prefill relevance**: **high upstream** — a 3.3k-token prompt gives
  `local2d.size ≈ 13 000 ≥ 64`, and the hot-stack / whole-layer prefill paths
  use `_gather_sort` **unconditionally** (`:1154, 1247`), independent of the 64
  threshold.
- **Decode relevance**: **zero.** Single token, `k=4` → `local2d.size == 4`.

**Comparison with our routed microbatch-4.** Our staged prefill processes a
group of ≤4 prompt tokens with one batched `gatherQuantizedMM` over the union
stack, `localIndices` of shape `[1, g, topK]` with `g ≤ 4`, `topK = 4` →
**`local2d.size ≤ 16`**. Single-token decode gives `size == 4`. Our group has
at most 16 unique experts.

**Does upstream's ≥64 threshold mean this is irrelevant to our current g4
workload?** **Yes.** We never reach 64 at g4, in prefill or in decode. Even the
full 118-token accepted prompt would only reach it if we batched ≥16 tokens per
group, which our pool-capacity bound (`capacityGroup = capacitySlots / topK`,
`Edge0_35BModel.swift:108-112`) and the clamped `1…4` group size
(`Edge0EnginePreferences.swift:82-91`) explicitly prevent. It also depends on
`mlx_lm.models.switch_layers`, which we do not vendor.

**NOT A CURRENT CANDIDATE.**

## 13. Deep audit — full-layer prefill (E3b)

Sources: `layer.py:932-982` (`load_full_layer` / `clear_full_layer`),
`engine/hooks.py:12-51` (`make_prefill_before_layer`), `engine/qwen.py:154-188`
(`_forward` gating), `engine/qwen.py:230-247` (`_prefill_end`),
`options.py:82-84, 132-133`.

- **`load_full_layer()`**: idempotent (`if self._full_weights is not None:
  return`). The checkpoint stores experts **already stacked per layer**, so this
  is **9 direct whole-tensor loads** (`up/gate/down` × `weight/scales/biases`),
  *not* 256×9 per-expert builds. Conversion is a bitcast: `u32_view(raw, shape)`
  for weights, `raw.view("<u2")` → `.view(core.bfloat16)` → `.reshape` for
  scales/biases. Upstream documents ≈9 ms/layer. For `fuse_gu` layouts it must
  interleave gate/up rows **per expert** — a flat concatenate would misalign
  rows (`:951-967`). 35B is `SEPARATE`, so this branch is not taken.
- **`clear_full_layer()`**: `self._full_weights = None` (`:981-982`). Called by
  the before-layer hook for layer `li−1`, and for every layer in
  `_prefill_end`.
- **9-tensor loading**: yes — see above.
- **Stacked checkpoint layout**: confirmed against the live index —
  `language_model.model.layers.N.mlp.switch_mlp.{proj}.{part}`, one tensor per
  (proj, part) with the expert axis leading.
- **Overlap with previous-layer execution**: `before_layer_cb` runs
  `load_full_layer` for layer `li` while layer `li−1`'s GPU work is still
  queued; `async_eval_per_layer=True` is passed only when `full_layer` is true
  (`qwen.py:158-171`). The hook drops `li−1` first, "its async_eval was already
  submitted, so the GPU queue keeps the arrays alive until evaluated"
  (`hooks.py:17-22`).
- **Page-cache assumptions**: explicit. "After use, `clear_full_layer()` frees
  the GPU copy, and the page cache carries the hot data" (`docs/streaming.md`).
  `load_full_layer` reads whole tensors through the mmap, so a full 35B layer
  pulls 432 MiB through the page cache.
- **Sorted gather path**: yes — the whole-layer branch uses
  `_gather_sort(x, indices)` and `sorted_indices=True` unconditionally
  (`:1244-1260`), with the comment "same ops as the exact path
  (bit-identical), no tolist / no bundles / no remap". Note it still does one
  `tolist` for `_hot_counts` bookkeeping and `_last_prefill_topk` (`:1237`).
- **Memory peak**: one layer's full stack = 256 × 1 769 472 B =
  **452 984 832 B = 432 MiB** GPU-resident while that layer runs, plus the page
  cache footprint of every layer touched. `prefill_full_layers=N` limits this to
  the leading N layers; the older doc claim of "12 for Qwen" would be ~5.2 GiB.
- **`prefill_full_layers`**: 0 for 35B (0 = every layer, per
  `options.py:58-59`).
- **`full_layer_prefill`**: **`False` for 35B** (`options.py:132`).
- **`prefill_chunk`**: 2048 (`edge0_35b/__init__.py:61`).

**Does current 35B enable it?** **No.** Verified in
`LayerOptions.staged_k4()` at `f8c4cb2`: `full_layer_prefill=False`,
`prefill_full_layers=0`, `prefill_hot=32`. In `_forward`,
`full_layer = prefill_multi and self._all_stream_layers and
opts.full_layer_prefill` → `False`, so `before_cb` still runs (driving the
**hot-stack** window) but `load_full_layer` is never reached: the hook returns
early at `if hot_n: … if not full_n: return` (`hooks.py:33-46`).

**Physical I/O for one 35B layer**: 432 MiB
(256 experts × 1 769 472 B). Note `docs/streaming.md`'s "around 310MB" does not
match the checkpoint (risk E10).

**Full-layer strategy vs our staged g4 on-demand strategy.** Upstream's 35B
uses neither: it uses the **hot-stack** path (32 resident experts per layer in
numpy page-cache backing, a sliding GPU window of ~5 layers via
`hot_window=4`/`ahead=2`, misses scatter-added exactly). Our staged g4 computes
the next group's *actual* router selections ahead and acquires only that
token's ≤4 experts per layer, releasing leases immediately. Ours has a strictly
smaller working set per step (4 × 1.6875 MiB = 6.75 MiB/layer vs 33 ×
1.6875 MiB = 55.7 MiB/layer for the hot stack) and needs no numpy backing
store, at the cost of the per-layer eval and the stack rebuild.

**Verdict: reference infrastructure, not a recommended port.** Current 35B
defaults do not use it. Do not enable full-layer prefill without evidence; on a
phone, a 432 MiB single-layer resident spike is not survivable alongside our
memory-advisor budget.

## 14. Deep audit — hot window / prefetch history

Sources: `options.py:38-50, 71-76, 85-93, 126-134`;
`models/base.py:67-70`; `layer.py:893-928` (`_refresh_hot_pins`),
`:990-1078` (`load_hot_layer`/`materialize_hot`/`dematerialize_hot`),
`:484-514` (`prefetch`), `engine/hooks.py:72-87`
(`make_history_prefetch`), `engine/qwen.py:190-206, 229-247`.

- **What history is retained**: per layer — `last_used` (the previous step's
  unique actual expert ids), `_hot_counts` (decayed usage frequency),
  `_last_prefill_topk`, `predicted_experts` (prerouter-predicted set, for pin
  bonus). Plus `PrerouterState.oh` / `oh_prev` per layer and the stager's
  `cur_step`.
- **Per-layer?** Yes — all of the above live on the per-layer
  `StreamingSwitchGLU`. The `SharedExpertCache` and `PrefetchBuffer` are the
  only cross-layer structures.
- **Per-generation?** Partially. `reset()` (`:1429-1441`) clears
  `_pending_indices`, `_staged_at_use`, `_last_prefill_topk`,
  `_staged_state(_next)`, `_staged_pending`, `last_used`, `_full_weights`.
  **`_hot_counts`, `_pinned`, `_incr_*` and the shared LRU survive across
  requests** — the docstring calls this "the cross-request memory".
- **Does it change physical reads?** `prefetch()` / `beginPrefetch`-equivalents:
  **yes**, they submit real `_build` work (real `pread`s). `_hot_counts`: no —
  it only influences selection.
- **Does it change only eviction priority?** `_hot_counts` feeds
  `_refresh_hot_pins` (pinned bundles are removed from the LRU and never
  evicted) and `load_hot_layer` (prefill hot-stack membership, rebuilt only
  when membership changes by >12.5 %, `:1013-1017`).
- **How do prerouter predictions affect pinning?**
  `_refresh_hot_pins` scores `candidates = set(_hot_counts) |
  set(predicted_experts)`, adds `pin_bonus` (2.0) to every predicted expert,
  sorts descending and takes `hot_per_layer` (`:893-911`). **For 35B
  `hot_per_layer = 0`, so `_refresh_hot_pins` returns immediately and this
  entire mechanism is inert.**
- **Memory cost**: `_hot_counts`/`predicted_experts` are dicts of ≤256 ints per
  layer (negligible). The prefill hot stack is the real cost:
  `n_hot=32` experts + 1 zero row = 33 × 1 769 472 B ≈ **55.7 MiB numpy
  backing per layer** (page cache, explicitly "counts ZERO toward MLX active",
  `:996-999`), materialized to GPU only inside the sliding window:
  `hot_window=4`, `ahead = max(1, 4//2) = 2` → materialize `li…li+2`,
  dematerialize `lj < li−2`, i.e. ~5 layers × 55.7 MiB ≈ **278 MiB GPU**.
- **Reset behaviour**: `clear_hot_layer()` drops backing + window + key + set;
  `dematerialize_hot()` drops only the GPU copy; `load_hot_layer` is a no-op if
  the key is unchanged or membership churn is ≤ `max(1, n_hot//8)`.
- **`hot_window`** (4) governs the *prefill* GPU materialization window only.
  It has no decode role.
- **`prefetch_history` / `history_prefetch`**: `make_history_prefetch` submits
  each layer's `last_used` so SSD loads overlap this step's compute, exploiting
  "~0.4 overlap measured" adjacent-token locality (`hooks.py:72-87`). **But
  `_step_pre` calls it only in the `elif` branch, i.e. when
  `self._pg_stager is None`** (`qwen.py:190-206`). With the 35B prerouter on,
  the `if` branch runs instead, and its only action is guarded by
  `exp._staged_mode` — which zero-drop scoping set `False` for L0–L6/L39.
  **Net effect: history prefetch does nothing at 35B decode in current
  production.** Upstream's own note explains the deliberate removal: "the
  previous token's set overlaps the next route by only ~6 %, so the reads are
  wasted (measured 11.7 → 16.7 tok/s when removed)".

### 14.1 Comparison with our LRU / pool

| | CURRENT UPSTREAM @ `f8c4cb2` | OUR SWIFT |
| --- | --- | --- |
| Cache capacity | `cache_slots=64`, one global budget, keyed `(layer_idx, expert)` | 512 MiB tier → **303 slots**, keyed `Edge0ExpertKey(layer, expert)` |
| Slots per layer | 64 / 40 = **1.6** | 303 / 40 = **7.6** |
| Working set per decode step | 40 layers × 4 = **160 keys** | 40 × ≤4 = **≤160 keys** |
| Can it hold one token's working set? | **No** (160 > 64) | **Yes, ~1.9 tokens** (160 < 303) |
| Measured hit rate | ~0 — upstream's own docstring: "the released 64 slots = 2.8 slots/layer measured exactly 0 hits, rebuilding 184 bundles/step" (8b figures) | ~45 % at the 512 MiB tier, per `Edge0_35BMemoryBudget.swift:39-40` |
| Eviction | `OrderedDict` LRU, `popitem(last=False)`; pinned entries popped out of the LRU | LRU with **lease pinning**: pinned entries never evicted, acquirers wait for a slot |
| Ownership / leases | none | `Edge0ExpertLease` with generation checks; `release` idempotent; `peakActiveLeases` tracked |
| Cross-request persistence | LRU + `_hot_counts` + `_incr_*` survive `reset()` | pool survives as a cache; model state is rebuilt per generation |
| Hot pins | `hot_per_layer=0` → inert | none |
| Readahead | `warm_willneed=True` | **none** |

**Does current upstream obtain its benefit through a smaller cache plus smarter
residency rather than simply more memory?** **No.** Its 64-slot LRU is measured
at ~0 hits and is explicitly described as "the price of the small footprint",
with the note that enlarging it "buys speed with RAM (1024 = +1.3 GiB, peak
1.4 → 2.6 GiB → 40.02 → 31.44 ms/step, paired 3/3 rounds, output identical) —
do it only when the memory budget allows". Its measured 35B gain comes from two
things that are *not* residency policy: (1) `warm_willneed` kernel readahead
(staging wall 162 → 27 ms/step), and (2) `incr_stack` + `incr_writeback`
removing per-step `core.stack` work and de-duplicating the staged set from the
LRU (peak MLX 2.92 → 2.60 GiB, CPU 143 → 109 ms/step). Our 303-slot pool is
already in the regime upstream identifies as the speed lever, and our ~45 % hit
rate is real where upstream's is not.

**No cache-policy port.** Do not shrink the pool to match upstream; that would
be a regression. The transferable idea is (1), which is §G1.

## 15. Dependency / MLX semantics audit

### 15.1 Exact current pins

`pyproject.toml` @ `f8c4cb2`:

```
mlx==0.30.6
mlx-metal==0.30.6; platform_system == 'Darwin'
mlx-lm==0.31.0
numpy>=1.24
safetensors>=0.4
```

At `0700e65` the first two were `0.30.4`. `mlx-lm` did not move.

Upstream's stated reasons, verbatim from the `pyproject.toml` comment and commit
`2e168c5`:

- **Why ≥ 0.30.5**: "0.30.4 and older mis-gate the NAX matmul kernels on Apple
  A18/A18 Pro (silently wrong numbers → garbled output, issue #8); fixed
  upstream in 0.30.5 (ml-explore/mlx#3083, #3092)." The bug: `can_use_nax &=
  get_architecture_gen() >= 17`, and A18/A18 Pro report gen 17 while that path
  "returns silently wrong numbers: checkpoints load, LoRA/prerouter install,
  generation runs to completion, and the text comes out as incoherent
  mixed-language noise."
- **Why < 0.31.2**: "default streams become thread-local and the pool-thread
  builds in `edge0/streaming/layer.py` fail with `no Stream(gpu, N) in current
  thread`."
- **Why `mlx-lm` stays 0.31.0**: "newer releases crash in decode" — specifically
  a `tolist()` on lazily-evaluated arrays. Also load-bearing:
  `layer.py:49` imports `_gather_sort` / `_scatter_unsort` from
  `mlx_lm.models.switch_layers`.
- **Verification status**: "Verified on the M4 Pro bench machine
  (`applegpu_g16s`, which never takes the NAX path): greedy token ids for both
  tiers are identical between 0.30.4 and 0.30.6 (16/16 per tier), `pytest` 60
  passed / 1 skipped, `pytest -m slow` 2 passed. **The A18-side effect still
  needs confirmation from the reporter.**"

### 15.2 Our Swift stack

| Component | Version / revision | Source |
| --- | --- | --- |
| `mlx-swift` | `PrismML-Eng/mlx-swift` @ `e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230`, 2026-06-11 | `project.yml:32-34`; `Package.resolved` |
| **MLX C++** | **0.31.1** | `Source/Cmlx/mlx/mlx/version.h` (`MAJOR 0 / MINOR 31 / PATCH 1`), submodule @ `d90771c8` |
| `mlx-c` | v0.6.0 (`ml-explore/mlx-c`) | `CMakeLists.txt:30-34`, `.gitmodules` |
| `mlx-swift-lm` | 3.31.4 (`ml-explore`) | `project.yml:35-37` |
| `swift-transformers-mlx` | 0.2.0 (`DePasqualeOrg` fork) | `project.yml:38-40` |
| `swift-transformers` / `swift-huggingface` | 1.3.3 / 0.9.0 | `Package.resolved` |

Two conclusions follow directly:

1. **We are already past the NAX fix.** 0.31.1 > 0.30.5, and our tree carries
   the *post-fix* gating expression
   `can_use_nax &= gen >= (arch == 'p' ? 18 : 17)`
   (`device.h:268-285`) rather than the buggy flat `>= 17`. The defect upstream
   pinned around is not present in our stack.
2. **We are below the thread-local-stream regression.** 0.31.1 < 0.31.2, so
   off-main-thread `MLXArray` construction — which we do in
   `Edge0ExpertLoader` inside `pool.acquire` task groups
   (`Edge0_35BModel.swift:322-338`) — remains valid. **We sit inside the exact
   window upstream considers safe, by one patch version on the upper side.**

### 15.3 NAX gating detail — a risk we have not previously recorded

Our MLX 0.31.1 gates NAX on **both** OS version and GPU generation:

```cpp
if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *))
  can_use_nax = true;
auto arch = d.get_architecture().back();
auto gen  = d.get_architecture_gen();
can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
```

`is_nax_available()` gates `gather_qmm_rhs` — the kernel our routed MoE uses —
at `quantized.cpp:1138`, plus `matmul.cpp:366, 962, 2402`,
`quantized.cpp:697, 793`, and `scaled_dot_product_attention.cpp:177`.

Consequence: **the same iPhone18,2 can execute different matmul kernels
depending on the iOS version** (NAX off below iOS 26.2, potentially on at or
above). Our app targets iOS 18+, so both regimes are in the field. Upstream
cannot see this because its bench machine (`applegpu_g16s`) "never takes the
NAX path". This is an argument for re-running the frozen nine-ID oracle across
the iOS 26.2 boundary, and it is independent of anything in this upstream
window.

**Erratum (2026-09-17).** This section was written under the assumption that
iPhone18,2 carries an A18 Pro. It does not: iPhone18,2 is the iPhone 17 Pro
Max with an **A19 Pro**, whose GPU reports phone class at **gen 18** — i.e.
the fixed condition *enables* NAX for it (the A18 exclusion is what mlx#3083
added). In this copy the deployment target is iOS 27.0, so the availability
half of the gate is statically true and the gate reduces to `gen >= 18` on the
target device: **expect NAX kernels to be selected**. The open question is
therefore not A18 mis-gating but whether NAX kernels are actually engaged in
our build — verified by trace, not inference. See
`EDGE0_PERF_UPDATE_SCAN_2026-09-17.md` §3 for the Metal System Trace recipe
and `scripts/patch-mlx-disable-nax.sh` for a NAX-off A/B build arm.

### 15.4 Compatibility matrix

| FEATURE | UPSTREAM MLX REQUIREMENT | OUR SWIFT MLX SUPPORT | RISK | TEST REQUIRED |
| --- | --- | --- | --- | --- |
| `gather_qmm` 4-bit affine, group 64, `rhs_indices`, `transpose=True` | `mx.gather_qmm`, mlx 0.30.6 | `MLX.gatherQuantizedMM(...)` with identical parameters — `Ops.swift:1468`; used at `Edge0ExpertMath.swift:36-47` | Kernel-path divergence (NAX vs steel) could change numerics | `Edge0GatheredQMMTests`, `Edge0MoEParityTests` (exist); add an iOS-26.2-boundary run |
| NAX kernel gating on the A19 Pro target (iPhone18,2) | pin ≥0.30.5 fixed the A18 mis-gate; upstream **unconfirmed** on A18 and never measured A19 | 0.31.1 has the fixed condition `gen >= (arch=='p' ? 18 : 17)` **plus** an `iOS ≥ 26.2` availability gate; phone class at gen 18 (A19/A19 Pro) is *enabled* | **High, unmeasured**: NAX engagement in our build is unverified; same device can take different kernels by OS version | Trace which kernels run (Metal System Trace, `*_nax*`); frozen nine-ID oracle + full-model parity on iOS 26.1 **and** 26.2+; NAX-off A/B via `scripts/patch-mlx-disable-nax.sh` |
| `mx.compile` on the MoE math | `mx.compile` (non-shapeless), mlx 0.30.6 | `MLX.compile(inputs:outputs:shapeless:_:)`, unbounded-arity array form — `Transforms+Compile.swift:153`; `mlx_compile` in mlx-c `compile.h:37`. **Unused by our Edge0 code** | Shape specialization vs our variable `U ∈ 1…4` stack → recompiles; captured kernels vs NAX gating | Parity fixture + recompile-count instrumentation before any adoption (§G3) |
| Thread-local default streams | **avoid ≥0.31.2** (pool-thread builds break) | 0.31.1 → not thread-local → safe. We do build `MLXArray` on task-group threads | **High if we ever bump** past 0.31.2 | Add a pool-thread array-construction smoke test to the dependency-bump checklist |
| In-place array row write (`arr[slot] = b`) | Python mlx `__setitem__` | **NOT SUPPORTED** — get-only subscripts; `mlx_array_set` / `mlx_array_set_data` are whole-array | Blocks `incr_stack` outright | none (not portable) |
| `madvise(MADV_WILLNEED)` readahead | `mmap.madvise`, Darwin | we use `pread`, no mmap — but Darwin **`F_RDADVISE` (44)** / **`F_RDADVISEV` (116)** with `struct radvisoryv` (≤64 ranges) are in the iOS SDK (`sys/fcntl.h:252, 357, 426-442`); `MADV_WILLNEED` also present (`sys/mman.h:206-213`) if we ever mmap | **Low** — advisory, failure-tolerant | Read-latency p95 A/B on device (§G1 step 4) |
| `_gather_sort` / `_scatter_unsort` | `mlx-lm==0.31.0` `mlx_lm.models.switch_layers` | absent; we do not vendor mlx-lm Python | none — threshold never reached (§12) | none |
| `argpartition` tie behaviour | `mx.argpartition(gates, kth=-k)[..., -k:]` | `MLX.argPartition(gates, kth: V−k)[…, start…]`, with an explicit comment that negating the array would change tie resolution (`Edge0_35BModel.swift:52-63`) | Low — already reasoned about and pinned | `Edge0RouterParityTests` (exists) |
| `softmax(precise=True)` | mlx 0.30.6 | `MLX.softmax(..., precise: true)` | Low | `Edge0RouterParityTests` |
| `mx.eval` / `async_eval_per_layer` | mlx 0.30.6 | `MLX.eval(...)` explicit at lease boundaries | Low | existing lifecycle tests |
| bf16 bitcast views of quantized scales/biases | `np.view("<u2")` → `.view(bfloat16)` | `MLXArray(bytes, shape, dtype: .bfloat16)` (`Edge0_35BRealWeights.swift:442-448`) | Low | `Edge0SafetensorsTests`, `Edge0ExpertLoaderTests` |
| Categorical sampling / argmax | `mx.random.categorical`, `mx.argmax` | `Edge0Sampler` | Low | `Edge0SamplerTests` |
| `MLX_CACHE_LIMIT_MB` (256 default) | `core.set_cache_limit` | available via `MLX.setCacheLimit` — **not currently set by our Edge0 runtime** | Low; worth recording | none this phase |

**Do NOT downgrade or upgrade Swift MLX in this phase.** No dependency change
was made. "Newer ≠ better" is concretely true here: upgrading past 0.31.2 would
break off-main-thread array construction, and downgrading below 0.30.5 would
reintroduce the exact A18 NAX defect upstream pinned away.

## 17. Upstream Mac reproduction

**UPSTREAM MAC REPRO BLOCKED — CHECKPOINT NOT PRESENT.**

Searched for an installed Edge0 checkpoint on this machine: directories named
`*edge0*`, any `*.safetensors`, the Hugging Face cache
(`~/.cache/huggingface/hub`), iOS Simulator app containers, and mounted
volumes. The only hit was our own source directory
`IOSLocalLLM/Services/Runtime/Edge0`. **No 35B or 8B checkpoint is present
locally**, so reproduction would require the full ~19.5 GB download. Per the
phase instruction, it was **not** downloaded, and no upstream runtime
measurement was taken.

No separate Python environment was created, no system Python was modified, and
no Swift dependency was touched. `mlx_lm` is not importable in the ambient
interpreter, which would have blocked `streaming/layer.py:49` regardless.

Consequences for this audit: every upstream figure quoted here is taken from
source inspection at `f8c4cb2` or from upstream's own published measurement
notes (`62dcab2`, README, `docs/models/*.md`) — **not** from a run we
performed. Mac results would not have predicted iPhone results in any case
(§16.5 of the benchmark notes).

What *was* possible without downloading weights, and was done:

- HF API commit history and tree listings at both our pinned revision and
  current HEAD, including LFS blob OIDs (§3.1).
- Byte-range fetch + SHA-256 of `config.json`,
  `model.safetensors.index.json`, `chat_template.jinja`,
  `generation_config.json` at both revisions (§3.1).
- Header-only range reads (first 1 MiB) of `lora_edge0_35b.safetensors` and
  `prerouter_edge0_35b.safetensors`, yielding tensor counts, dtypes, shapes,
  key patterns and `__metadata__` provenance including source `npz` paths and
  MD5s (§3.3 items 5–6).

## 18. Feature parity matrix

Legend: **PARITY** = semantically equivalent and independently verified;
**OURS AHEAD** = we have a capability upstream lacks; **UPSTREAM AHEAD** =
upstream has a capability we lack; **DIVERGENT (deliberate)** = we differ by
design; **N/A** = not applicable to one side.

| # | Feature | CURRENT UPSTREAM @ `f8c4cb2` | OUR SWIFT RUNTIME | Status |
| --- | --- | --- | --- | --- |
| 1 | True-router exact path | exact decode path, L0–L6 + L39 only; **not** the consumer-layer route | the **only** route, all 40 layers; `.exact` is the correctness oracle | **DIVERGENT (deliberate)** |
| 2 | Staged actual-router prefill | n/a — prefill uses the hot-stack path (`prefill_hot=32`) | staged prefill: next group's *actual* router selections computed ahead, experts loaded during the current group | **OURS AHEAD** (different mechanism, same overlap goal) |
| 3 | Routed MoE microbatch | none at decode; prefill batched by chunk | microbatch-4 accepted production default (prefill 8.649 → 6.973 s median, −19.4 %) | **OURS AHEAD** |
| 4 | Fixed-slot staged decode | yes — `_incr_tensors` `[5,…]`, `_incr_slot_table` `[256]`, `core.take` | absent | **UPSTREAM AHEAD** (unusable for us — §10) |
| 5 | GPU-resident routing indices | yes on consumer layers | no — `asArray(Int32.self)` per token per layer | **UPSTREAM AHEAD** (unusable for us) |
| 6 | `asm_cache` | present, cap 2, **bypassed in `incr_mode`** → 0 hits in the default | absent | **N/A** (dead upstream) |
| 7 | `incr_stack` / `incr_writeback` | on by default | absent; **not portable** (no in-place write API) | **UPSTREAM AHEAD / blocked** |
| 8 | Readahead hint | `warm_willneed=True`, `madvise(MADV_WILLNEED)` per range | absent (`pread`, no advise) | **UPSTREAM AHEAD — §G1 candidate** |
| 9 | `mx.compile` MoE math | `use_compile=True`, 80 compiled closures | absent (API available, unused) | **UPSTREAM AHEAD — §G3 deferred** |
| 10 | Sorted gather | `_gather_sort`/`_scatter_unsort`, exact-path threshold ≥64; unconditional in prefill paths | absent | **N/A** (threshold unreachable at g4 — §12) |
| 11 | Whole-layer prefill (E3b) | implemented, **OFF** for 35B | absent | **N/A** (reference infrastructure — §13) |
| 12 | Hot-stack prefill (`prefill_hot`, `hot_window`) | 32 experts + zero overflow row, sliding GPU window ~5 layers, exact miss scatter-add | absent | **UPSTREAM AHEAD** (not needed at our prompt lengths) |
| 13 | Hot pins / `pin_bonus` / decay | implemented, **inert** (`hot_per_layer=0`) | absent | **N/A** |
| 14 | History prefetch at decode | implemented, **dead** in 35B production | advisory `beginPrefetch` from actual router lookahead | **OURS AHEAD** |
| 15 | Shared expert cache / LRU | 64 slots global, ~0 hits measured | 303 slots / 512 MiB, ~45 % hit at that tier | **OURS AHEAD** |
| 16 | Prefetch buffer | `PrefetchBuffer` cap 48 | advisory unpinned `prefetch(key:)`, capacity-guarded, never queues behind pinned work | **PARITY** |
| 17 | Lease / pin ownership | none | `Edge0ExpertLease`, generation-checked, pinned entries never evicted, `release` idempotent | **OURS AHEAD** |
| 18 | Learned prerouter | **authoritative** at decode, 33 heads, `patch_call=True` | advisory only, default OFF, "the true router remains the sole authority" | **DIVERGENT (deliberate)** |
| 19 | Batched prerouter heads | `head_batch` stacked einsum, "identical up to fp16 rounding" | per-head | **UPSTREAM AHEAD** (below our exactness bar — §G4) |
| 20 | Zero-drop layer scoping | yes — `_staged_mode=False` off-consumer; `history_slots=False` default | n/a — we stage from *actual* selections, so set == routing by construction | **PARITY in guarantee** |
| 21 | `prefetch_from_prefill` (vs stage) | yes — avoids zeroing at the prefill boundary | n/a — our staged prefill stages actual next-token selections | **N/A** |
| 22 | Recover-LoRA (unmerged delta) | `LoraLinear`, fp16, scale 2.0, 310 modules | `Edge0LoRA`, fp16, scale 2.0, 310 modules verified against the artifact header | **PARITY** |
| 23 | Quantization 4-bit affine / group 64 | `QuantSpec(4, 64, "affine")`; 8-bit gate overrides from `config.json` | `Edge0ExpertMath` bits 4 / group 64 / `.affine`; `eightBitModules` (80 modules) validated | **PARITY** |
| 24 | Router math (precise softmax → top-k → renorm) | `moe/routing.py::select_from_logits` | `Edge0_35BMoE.select`, same `argPartition(kth:-k)[…, -k:]` formulation, tie behaviour documented | **PARITY** |
| 25 | RoPE (partial rotary, mRoPE sections) | vendored mlx-lm `qwen3_next` | `Edge0_35BAttention` — fp32 rotation, rounded once to the input dtype, `mrope_section` [11,11,10], theta 1e7, partial 0.25 | **PARITY** |
| 26 | GatedDeltaNet state | vendored `Qwen3NextGatedDeltaNet` | `Edge0KDAAttention` — ops-based delta-rule step, fp32 state `[B, vHeads, vDim, kDim]`, bit-exact with the fused reference | **PARITY** |
| 27 | GQA cache | vendored `Qwen3NextAttention`, 16 heads / 2 KV heads / head_dim 256, `full_attention_interval` 4 | `Edge0_35BAttention` full-attention path, same geometry | **PARITY** |
| 28 | MLA (8B tier) | vendored bailing hybrid | `Edge0MLAAttention` + `Edge0MLAStateParityTests` | **PARITY** |
| 29 | Tokenizer / chat template | `apply_chat_template(..., enable_thinking=False)`; **fix** to always keep the rendered template (issue #11) | `tokenizer.applyChatTemplate(...)` (`Edge0_35BEngine.swift:349`) + `Edge0TokenizerParityTests`; `chat_template.jinja` byte-identical across revisions | **PARITY** (verify E8) |
| 30 | Thinking / history channel | `enable_thinking` template flag; server-side | `Edge0ThinkingChannel` — normalizes both literal-marker and structural paths to `<think>reasoning</think>answer` | **OURS AHEAD** |
| 31 | EOS / sampler behaviour | `eos_ids (248046, 248044)`, `first_token_greedy=True`, HF-style repetition penalty, one host-sync categorical draw | `Edge0Sampler` — temperature ≤0 or NaN → argmax greedy; EOS from config | **PARITY** |
| 32 | Hidden clip / NaN scrub | `QWEN_HIDDEN_CLIP=1000`, on by default | **absent** | **UPSTREAM AHEAD — §G2 (detection first)** |
| 33 | Per-request state reset | `reset()` + feature-capture clearing (NEW) | fresh `makeState()` per generation; pool survives as a cache | **PARITY** |
| 34 | Cancellation | **absent** | per-step `Task.isCancelled` + generation-id invalidation + advisory-load cancellation | **OURS AHEAD** |
| 35 | Regeneration safety | partial (reset fixes) | generation-id fencing; stale loads rejected (`staleLoadsRejected`) | **OURS AHEAD** |
| 36 | Unload / reload | `close()` shuts pools; no coordinated residency | coordinated `ModelResidency` / `MemoryAdvisor` / `DeviceSafetyMonitor`; lease counters must return to zero | **OURS AHEAD** |
| 37 | Thermal / memory refusal | **absent** | product behaviour, preserved by invariant | **OURS AHEAD** |
| 38 | 8B behaviour | `prod_k8` **inverted** to `staged=True`; `start_layer` 7, 16 heads | separately validated 8B path; unchanged by this phase | **DIVERGENT — re-check only if we track 8B defaults** |
| 39 | Frozen oracle / full-model parity / 412-token stress / ≥32 cached decode steps | `e2e_smoke.py` staged-vs-exact gate — **currently failing on the released 35B checkpoint** | `Edge0FullModelParityTests`, `Edge0_35BModelParityTests`, frozen nine-ID reference probe (`Edge0_35BEngine.swift:735-780`) | **OURS AHEAD** |
| 40 | Model identity pinning | repo id only; no revision pin | `qwen35MoEPinnedRevision = 1ff9f447…`, exact byte-size manifest for truncation refusal, curated repo-id match (refuses unknown checkpoints) | **OURS AHEAD** |
| 41 | Dependency safety window | mlx 0.30.6 (≥0.30.5 for NAX, <0.31.2 for streams) | MLX C++ 0.31.1 — inside the same window | **PARITY** |

**Score**: 15 PARITY, 14 OURS AHEAD, 8 UPSTREAM AHEAD (of which 3 are unusable
under our contract, 2 are inert upstream, 1 is not portable, 1 is deferred and 1
is §G1), 4 DIVERGENT/N-A.

## Invariants preserved by this phase

This audit modified **no Swift source, no build setting, no dependency and no
model artifact**. Two documentation files were added:
`Docs/EDGE0_UPSTREAM_REBASE_AUDIT.md` (this file) and
`scripts/edge0_upstream_benchmark_notes.md`. Our working tree was not touched
while studying upstream; the reference checkout lives at
`/tmp/edge0-upstream-current`.

All of the following remain exactly as they were: frozen nine-ID oracle,
full-model parity, 412-token stress, ≥32 cached decode steps, exact router
semantics, 310 LoRA adapters, quantization, RoPE, GatedDeltaNet state, GQA
cache, tokenizer/template, Thinking/history, EOS/sampler behaviour,
cancellation/regeneration, unload/reload, and 8B behaviour. The accepted
production configuration (true-router execution, Recover-LoRA 310 modules, K=4,
staged actual-router prefill, routed MoE microbatch-4, eval window 1, per-token
router readback, boundedPrefetch single-token decode, learned prerouter OFF) is
unchanged, and the four developer-only experiments remain default-OFF (§H.1).
No model migration was performed and no base model was downloaded.
