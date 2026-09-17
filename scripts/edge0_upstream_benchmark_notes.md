# Edge0 upstream benchmark methodology (reference only)

Phase 5L forensic note. This file records **how upstream measures** the
numbers quoted in its README and tier docs, so those numbers are never
compared against our iPhone acceptance benchmark without an explicit
methodology bridge.

Nothing here changes our benchmark. The accepted iPhone18,2 profile
(118 prompt tokens, 64 output max, Thinking Off, greedy, 512 MiB /
303-slot pool, reads 4) is unchanged.

Upstream identity for every statement below:

| Item | Value |
| --- | --- |
| Repository | <https://github.com/Edge0-AI/Edge0> |
| Frozen revision | `f8c4cb2c1871735502d958bc63d2f31b88ca7123` |
| Commit date | 2026-09-16T19:42:10+08:00 |
| Subject | `docs(readme): add the ModelScope mirrors next to the Hugging Face links` |
| Historical pin | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0` (2026-09-10) |
| Reference checkout | `/tmp/edge0-upstream-current` (read-only, clean) |

## 1. The benchmark is `examples/bench.py`

README claims (current revision, `README.md` Benchmark table):

| Tier | Decode speed | Prefill throughput (cold / warm) | Peak active memory | Test machine |
|---|---|---|---|---|
| `edge0-35b` | 14.9–17.7 tok/s | 113 / 140 tok/s | 2.9 GiB | Mac mini M4 Pro, 24 GB |
| `edge0-8b` | 23.9–25.3 tok/s | 500 / 1428 tok/s | 1.0 GiB | Mac mini M4 Pro, 24 GB |

`docs/models/edge0-35b.md` repeats `14.9–17.7 tok/s (M4 Pro)` and
`≈ 2.9 GiB`. `Qwen35Config._defaults()` still pins the **acceptance**
figures at `target_tok_s=13.0`, `peak_active_mem_mb=3400.0`
(`src/edge0/models/edge0_35b/__init__.py`). Note the doc string in that
same file still says "acceptance ≈13 tok/s, peak active ≈3.3 GB" — so
upstream's own acceptance target (13.0 tok/s / 3400 MB) and its
advertised measurement (14.9–17.7 tok/s / 2.9 GiB) are different numbers
serving different purposes. The 3.3 GB → 2.9 GiB change between
`0700e65` and current is a **documentation-only** edit
(`docs/models/edge0-35b.md`), not a code change.

## 2. Exact measurement conditions, read from source

From `examples/bench.py::run_bench` (lines 72–134) and `main` (137–160):

| Condition | Value | Source |
|---|---|---|
| Hardware | Mac mini M4 Pro, 24 GB (`applegpu_g16s`) | README table; corroborated by commit `2e168c5` ("Verified on the M4 Pro bench machine (applegpu_g16s, which never takes the NAX path)") |
| Runs per tier | 2, in one process, sequentially | `for run in range(2)` |
| Model tier | auto-detected from the checkpoint, or forced by name | `AutoEngine.from_pretrained` |
| Prompt | default: one short Chinese question per tier (`PROMPTS`); `BENCH_LONG=1`: ~3k-token synthetic 40-paragraph prompt | `_prompt_for` / `_long_prompt` |
| Prompt length (README numbers) | ~3.3k tokens (`BENCH_LONG=1`); README says the 3.3k figure applies to prefill only | README footnote: "Prefill numbers are throughput over a ~3.3k-token prompt (`BENCH_LONG=1`)" |
| Warm-up decode steps | 10, **sampled** (argmax-selected token ids but untimed steps) | `--warmup` default 10 |
| Timed decode tokens | 200 | `--ntok` default 200 (`BENCH_NTOK`) |
| Sampling in the timed window | `sample(...)` with tier `GenerationConfig`: temperature 0.7, top_k 64, top_p 0.95, repetition_penalty 1.0 (35B) / 1.1 (8B); `seed=None` → **non-deterministic** | `bench.py` 85–89, 113–115; `src/edge0/config.py` |
| Warm-up token selection | `argmax` (greedy) | `bench.py` 107 |
| Cache state | `engine.reset()` before each run; shared LRU + prefetch buffer **survive** `reset()` by design (`StreamingSwitchGLU.reset` docstring) | `bench.py` 94; `streaming/layer.py` 1429–1441 |
| Prerouter state | ON (tier default, `prerouter` not overridden); 33 heads, start_layer 7 | `Qwen35Config._defaults` |
| Streaming options | `LayerOptions.staged_k4()` incl. `staged_sync=True`, `incr_stack=True`, `incr_writeback=True`, `warm_willneed=True`, `cache_slots=64`, `prefill_hot=32`, `full_layer_prefill=False` | `streaming/options.py` 126–134 |
| Compile | `use_compile=True` (MoE math wrapped in `mx.compile`) | `LayerOptions.staged_k4` |
| Peak-memory definition | `core.get_peak_memory()` after `core.reset_peak_memory()`, i.e. the **MLX allocator peak**, per run; the reported figure is `max` over the 2 runs | `bench.py` 95, 120, 131 |
| Model load | **EXCLUDED** from all timings (engine built in `main` before `run_bench`) | `bench.py` 155–158 |
| Tokenizer | **EXCLUDED** (loaded at engine build) | same |
| First token | **EXCLUDED** from the decode timer; `t_decode` starts after the 10 warm-up steps | `bench.py` 110–119 |
| Prefill timing | `t_prefill` wraps `engine.prefill(ids)` only, so TTFT-equivalent is *not* reported; throughput = `len(ids) / t_prefill` | `bench.py` 96–98, 124 |
| cold vs warm prefill | cold = first request after process start (page cache empty); warm = subsequent requests (page cache resident) | README footnote |
| Thermal / repetition policy | **NONE** — no thermal gating, no backoff, no cooldown between the 2 runs | absent from `bench.py` |
| Output | prints per-run `prefill_s`, `tok_s`, `peak_active` then `mean tok/s` and `peak<=` | `bench.py` 125–133 |

Two important consequences:

1. **The 14.9–17.7 tok/s range is not a determinism range.** Sampling uses
   `seed=None`, so the two runs draw different tokens; the spread
   combines machine variance with sampling-path variance. Our greedy
   acceptance number is a different quantity and must not be compared to
   it directly.
2. **Peak active memory excludes mmap'd checkpoint pages.** Expert weights
   are mmapped and streamed, so 2.9 GiB is the MLX allocator peak, not
   the process RSS or the file-backed page cache. The current revision's
   own `staged_k4` docstring reports the companion figure on a different
   machine: "Peak MLX 2.92 → 2.60 GiB, file-backed page cache 4.25 → 4.72
   GiB" on a 16 GiB M2. Both numbers describe the same workload.

## 3. The separate, more rigorous upstream measurement

Commit `62dcab2` (the WILLNEED + incremental-stack performance change)
documents a **different and stricter** protocol than `bench.py`. It is the
only upstream measurement that is paired, round-rotated and bit-identical:

- Machine: 16 GiB M2 (deliberately memory-starved; 19.7 GB checkpoint).
- Workload: 60-step **sampled REPLAY** with 20 untimed warm-up steps.
  Replay feeds both arms the *same* token sequence, so the work is
  identical.
- 5 rounds, **rotated arm order**, paired per round.
- `cache_slots=64`.

Reported result (35B):

| Arm | step | tok/s |
|---|---|---|
| new (`incr_stack` + `incr_writeback` + `warm_willneed`) | 187.58 ms | 5.33 |
| shipped default | 244.25 ms | 4.09 |
| `prerouter=None` | 264.06 ms | 3.79 |

- new vs shipped: −56.8 ms median, paired 4/5 → +31.0 %
- prerouter's own gain: +8.0 % → +37.8 % (paired 5/5)
- Output unchanged: 60/60 identical tokens in the replay A/B
- Supporting counters: CPU 143 → 109 ms/step, peak MLX 2.92 → 2.60 GiB,
  minor faults 5162 → 1925, staging wall 162 → 27 ms/step, critical-path
  expert load 105 → 84 ms/step.
- Upstream's own caveats: single 16 GiB M2; `incr_writeback` is free only
  because LRU hits are ~0 at 64 slots and "needs revalidation on a
  larger-memory host where the LRU actually hits"; `incr_stack` is gated
  on `staged_sync`; and `scripts/e2e_smoke.py`'s staged-vs-exact gate
  **already failed on this checkpoint with the OLD default too** (old vs
  exact MISMATCH; new vs old identical).

That last caveat matters for us: upstream's own staged path does not
currently pass its staged-vs-exact equality gate on the released 35B
checkpoint, on either the old or the new default. This is exactly the
property our frozen-oracle / full-model-parity suite exists to protect.

## 4. Mapping upstream metrics onto ours

| Upstream metric | Definition | Our nearest metric | Comparable? |
|---|---|---|---|
| decode `tok_s` | 200 sampled tokens after 10 warm-up steps, model load and first token excluded | `decodeRate = (generated − 1) / decodeSeconds`, measured from first token (`Edge0_35BEngine.swift` 603–607) | Only after aligning sampling (upstream samples T=0.7/top_k 64; ours is greedy), token count (200 vs 64) and machine (M4 Pro 24 GB vs iPhone18,2) |
| `prefill_s` / prefill tok/s | wall time of `engine.prefill(ids)` over a ~3.3k-token prompt | `prefillSeconds` (`Edge0_35BEngine.swift` 400, 615) over a 118-token prompt | Not directly — prompt lengths differ by ~28×, and upstream's cold/warm split depends on macOS page cache |
| peak active memory | `mx.get_peak_memory()`, MLX allocator only | `peak high-water` from the device memory advisor (~2.71 GB at g4) | Different definitions: MLX allocator peak vs app high-water. Not a like-for-like number |
| TTFT | **not measured** | `timeToFirstTokenSeconds` (597–602) | Ours is strictly more informative; upstream has no TTFT figure |
| cold/warm prefill | first vs subsequent request in a process | our cold-start vs cached-decode runs | Conceptually similar; our ≥32 cached-decode-step invariant has no upstream analogue |

## 5. What upstream's numbers do and do not tell us about iPhone

Do **not** treat the M4 Pro figures as an iPhone prediction:

- Upstream measures on a 24 GB desktop-class machine with an
  `applegpu_g16s` GPU that **never takes the NAX path**
  (commit `2e168c5`). Our target, iPhone18,2, is an **A19 Pro** (phone
  class g18) — the fixed mlx#3083 gate *enables* NAX for it, so the device
  sits in a regime upstream's bench machine cannot see and upstream never
  measured. (Erratum 2026-09-17, replacing an earlier "A18 Pro" label here;
  see `Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md` §3.)
- Upstream's headline gain comes from a memory-starved 16 GiB host where
  the workload degrades into page-fault latency (217 ms / 3079 major
  faults). iPhone storage and VM behaviour differ; the same mechanism
  may pay off differently, and it must be measured, not inferred.
- Upstream's decode loop carries no thermal or memory refusal path.
  Ours does, by design (see `ARCHITECTURE.md`); thermal/memory refusals
  are product behaviour here and any port must preserve them.

## 6. Reproduction status

**UPSTREAM MAC REPRO BLOCKED — CHECKPOINT NOT PRESENT.**

Searched the local machine for an installed Edge0 checkpoint (model
directories, `*.safetensors`, Hugging Face cache, simulator containers,
mounted volumes). No 35B or 8B checkpoint is present locally. Per the
Phase 5L instruction, the ~19.5 GB base model was **not** downloaded, so
no upstream runtime measurement was taken on this Mac.

Everything in this note is derived from source inspection at the frozen
revision plus upstream's own published measurement notes — not from a run
we performed. Metadata-only identity verification *was* possible and is
reported in `Docs/EDGE0_UPSTREAM_REBASE_AUDIT.md` §3 (HF API commit
history, file sizes, LFS blob OIDs, and header-only safetensors range
reads — no weight download).

If reproduction is wanted later, the minimal recipe is:

```bash
# separate venv, honour the pins EXACTLY, do not touch system Python
python3.12 -m venv /tmp/edge0-venv
/tmp/edge0-venv/bin/pip install 'mlx==0.30.6' 'mlx-metal==0.30.6' 'mlx-lm==0.31.0'
cd /tmp/edge0-upstream-current && /tmp/edge0-venv/bin/pip install -e '.[dev,fetch]'
export EDGE0_35B_MODEL=/path/to/checkpoint          # ~19.5 GB download required
BENCH_LONG=1 /tmp/edge0-venv/bin/python examples/bench.py edge0-35b
```

`mlx-lm` must stay at 0.31.0 because `streaming/layer.py:49` imports
`_gather_sort` / `_scatter_unsort` from
`mlx_lm.models.switch_layers`, and `pyproject.toml` warns newer `mlx-lm`
crashes in decode on a `tolist()` of lazily-evaluated arrays.
