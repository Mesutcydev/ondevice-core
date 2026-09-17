# Upstream Edge0 docs + repo audit — 2026-09-17

Target: `Edge0-AI/Edge0` @ `main` (`5b65e6f`, 2026-09-17) — the full `docs/`
set (`architecture.md`, `moe.md`, `prerouter.md`, `streaming.md`,
`attention.md`, `adding-a-model.md`) and the repository state (CI, tests,
open issues/PRs).

Method: every doc and every file a claim was checked against was fetched
through the GitHub API at `5b65e6f`; claims were spot-checked against the
repo (`tests/`, `.github/workflows/ci.yml`, `src/edge0/…`) and cross-
referenced with our own audits (`Docs/EDGE0_UPSTREAM_REBASE_AUDIT.md`,
`Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md`). Not audited here: the paper
(`paper/main.pdf`), `docs/models/*` cards, and the HF checkpoints.

Base-state note: upstream has **no code commits past our pinned `f8c4cb2`**
— only `5b65e6f` (a README badge). Nothing to re-pin; the mechanisms we
track (`warm_willneed`, `incr_stack`, hidden clip, `use_compile`) are all
already inside the pin and analyzed in the rebase audit (§G list).

## 1. Overall verdict

The doc set is unusually strong: it documents mechanisms at implementation
depth (bit-identical contracts, option tables with defaults, real measured
numbers) and is honest about what is not wired yet (`attention.md` says so
explicitly). The findings below are completeness/consistency issues, plus
one class that matters for us: **published-metric precision** — the same
problem issue #106 raises.

## 2. Findings (doc by doc)

| # | Doc | Finding | Severity | Suggested fix |
| --- | --- | --- | --- | --- |
| 1 | architecture.md | The layered-structure tree omits two real modules: `engine/hooks.py` (per-layer callbacks; the `load_hot_layer` path per #106) and `streaming/install.py` (`install_streaming_experts` — how streaming gets wired into a model) | medium | Add both; they are load-bearing |
| 2 | architecture.md | Testing Strategy lists 4 of 7 test files — `test_server.py`, `test_e2e_slow.py`, and `test_repo_hygiene.py` (which *is* the CI boundary enforcement) are missing | low | Complete the list |
| 3 | architecture.md | "CI enforces this with grep" — the actual enforcement is a regex check (`_MLX_IMPORT`) inside `tests/test_repo_hygiene.py` running in the Linux CI job | nitpick | Reword to name the hygiene test |
| 4 | architecture.md | "Acceptance metrics … peak active memory" is never defined; per #106 it is the **MLX allocator peak** (excludes page cache, MLX buffer cache, numpy, interpreter). README vs paper numbers diverge (1.0 vs 1.5 GiB; 14.9–17.7 vs 20.4 tok/s) | high | Define the metric precisely, add a process-RSS column, reconcile README with the paper (#106 §3) |
| 5 | prerouter.md | Tier table row `hidden \| 512 (fp16)` mislabels the **head width** as "hidden": 512 is fc1's output / fc2's input; the model hidden the feature concat actually uses is 2048 (35B) / 1536 (8B) | medium | Rename the row ("head width"), or state both values |
| 6 | streaming.md | `staged_replace` row says "paired with the prerouter; zero drops", while prerouter.md documents that production presets use explicit-index routing with `staged_replace=False` — zero-drop holds via slot mapping, not via replace | low | Cross-reference the nuance |
| 7 | streaming.md | Presets (`staged_k4` / `prod_k8` / `staged_k8`) are named but their actual option overrides are undocumented — the 35B preset's full flip set (`incr_stack`, `incr_writeback`, `warm_willneed`, `staged_n=4`, `prefill_hot=32`, `use_compile`) and its measured deltas live only in the `options.py` docstring | high | Add a presets table (overrides + measured numbers) to streaming.md — these are the project's headline perf numbers |
| 8 | attention.md | `summarize()` is described as "used for the CLI banner" while the same doc notes the module is not referenced anywhere yet | low | State "define-first, not yet wired" once, up front |
| 9 | moe.md | No findings — the strongest doc in the set; bundle order / layout / path semantics verified consistent with our Swift port and its parity tests | — | — |
| 10 | adding-a-model.md | No findings — line-numbered and contract-complete | — | — |

Measured numbers the docs currently bury (from `options.py` `staged_k4`
docstring, 16 GiB M2, 60-step replay, same-run pairing): `staged_sync` +
`incr_stack` + `incr_writeback` → peak MLX 2.92 → 2.60 GiB, minor
faults/step 5162 → 1925, CPU 143 → 109 ms/step; `warm_willneed` → staging
wall 162 → 27 ms/step; together step 244.25 → 187.58 ms, 4.09 → 5.33 tok/s
(+31.0%).

## 3. Repo state (2026-09-17 snapshot)

- **CI**: two jobs — macOS unit tests (`pytest -m 'not slow'`) and a Linux
  pure-Python hygiene job (MLX-import boundary). No docs lint/build, so doc
  drift (findings 1–3, 5–8) is unguarded.
- **Open issues that matter to us**
  - **#106** — metric precision (finding 4). Already recorded in our scan
    doc; our own docs should state footprint-vs-allocator semantics
    explicitly (we measure `phys_footprint`).
  - **#17** — M1 decode speed; the maintainer confirms the design is
    page-fault bound (LRU-capped, mmap-backed), which is exactly the class
    our readahead + NAX work targets. Still open.
  - **#5** — "how do I run it on a phone" plus a 2026-09-16 contribution
    offer: community demand for what this fork does. Worth a courteous
    pointer when we publish.
- **Open PRs relevant to us**
  - **#3** Swift/MLX iPhone port (unchanged since 09-10) — closest upstream
    artifact to this fork; keep watching.
  - **#7** per-layer typed reads — we ported the pattern this week; our
    commit stands on its own (upstream hasn't merged).
  - **#13** stop layer discovery on IndexError — robustness fix; worth
    checking our `Edge0SafetensorsIndex` for the same failure mode.
  - **#4** serve hardening (loopback bind warning + chat request limits) —
    port candidate for `LocalAPIServer.swift`.
  - **#105** SSE cumulative-id decode fix — check our `LocalAPIServer` SSE
    path for the same bug class before shipping.
  - **#6** page-granular warming — still deferred (no cold-cache gain in
    upstream's own numbers).

## 4. Improvements for this fork (ranked)

1. **LocalAPIServer hardening pass** — #4 analog (bind warning, request
   limits) + #105 analog (SSE decode). Small, testable.
2. **§G3 `MLX.compile`** — the docs re-confirm `use_compile=True` is the
   upstream default on the staged/exact MoE math; our runtime still has zero
   compiled closures. Top unported perf lever (already ranked in the rebase
   audit).
3. **§G2 hidden-state NaN/Inf detection** — upstream runs a clip by default;
   our plan (detect first, don't clip) stands.
4. **Doc alignment** — cross-link the upstream docs set from our EDGE0 docs
   as canonical mechanism descriptions; adopt explicit metric definitions in
   our benchmark prose.
5. **Loader robustness check** — #13 analog in the safetensors index.

## 5. Suggested upstream contributions (optional, small)

- One docs PR with findings 1–3, 5, 6, 8 (mechanical), plus a presets table
  (7) and the metric definition (4) if the maintainers want them from
  outside. Nothing code-level from us is blocked on upstream.
