# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [Unreleased]

### Added

- 35B expert-read concurrency A/B runner: a counterbalanced
  "35B Expert reads A/B (4 vs 6)" kind. Read concurrency is load-captured
  (the store's read semaphore is fixed at engine load), so the runner
  reloads the engine on every arm transition (4→6→6→4) and exports a
  requested/effective reads pair; a requested-6 trial whose store says
  otherwise is labeled SETUP-BLOCKED instead of silently comparing
  off-vs-off. Acceptance rule (frozen): prefill ≥ +3% with decode ≥ −3%.
- 35B sustained-thermal diagnostic: a "35B Sustained Run (thermal)" kind —
  six back-to-back staged trials (256 tokens each, no idle recovery) with
  per-trial decode rates, first→last drift, thermal trajectory, and peak
  footprint, plus a frozen stability rule (decode drift ≥ −5% and no
  Serious/Critical thermal state). Fills the sustained/thermal row of the
  device evidence matrix.
- Session-state reuse (prompt cache) for the 35B chat path: the
  prompt-boundary generation state (MLA KV + linear state) is kept between
  turns, and a turn whose prompt is an exact token-level extension of the
  previous prompt prefills only the new suffix — the dominant latency cost
  in a long chat, where the whole conversation was re-prefilled on every
  turn. Numerics are unchanged by construction; a new in-app validation
  stage ("Session reuse parity") proves that a turn-2 answer from a reused
  state is byte-identical to the same turn from a fresh full prefill. The
  diagnostics runners disable reuse so every measured trial pays its own
  prefill.
- 35B readahead A/B runner (Phase 5M promotion path): a counterbalanced
  "35B Readahead A/B (off vs hints)" diagnostic kind with the correct
  lifecycle for a load-time knob — the engine is unloaded and reloaded on
  every arm transition (off→on→on→off), and the engine exports the
  load-captured `readaheadEffective` state so a requested-on trial without
  a reload is labeled SETUP-BLOCKED instead of silently comparing
  off-vs-off. Acceptance rule (frozen): decode ≥ +5% with prefill and TTFT
  ≥ −5%.
- Edge0 expert loaders resolve per-layer tensor locations and row geometry
  once at model load (upstream PR #7 pattern); per-expert loads are now pure
  advise → pread → wrap with byte-identical ranges.
- Edge0 diagnostics report NAX (Metal 4 tensor-core) eligibility, and
  `scripts/patch-mlx-disable-nax.sh` toggles the MLX NAX gate for A/B runs.

### Changed

- Edge0 loaders validate checkpoints fail-fast at load time; a missing or
  malformed expert tensor throws before the engine opens instead of on the
  first expert fetch.
- Corrected the iPhone 18,2 chip label from A18 Pro to A19 Pro across the
  Edge0 documentation.
- Redesigned the cold-start splash: one restrained sequence (mark settle,
  a single aperture ring sweep, wordmark rise) replacing the previous
  multi-layer animation. First-launch gates (legal, onboarding) now wait for
  the splash, so it is no longer covered on first run.
- Onboarding is now two steps (welcome → model setup); the middle
  "local by default" step was removed.
- Redesigned the first-launch agreement screen: review cards with
  per-document state, a live review-progress strip, and a self-explaining
  disabled primary action.

### Fixed

- 35B speed-diagnostic verdicts: completed knob A/Bs (eval-window,
  microbatch, prerouter, compute) exported "FINAL — completed 4/4" with no
  DECISION section — the decision stage gated on Exact/Bounded mode
  populations before the kind-specific blocks, but every knob kind runs a
  staged-only plan, so the gate dead-ended every completed run. The gate is
  now per-kind (mode-pair kinds still require their mode populations); knob
  kinds also label drift per arm group instead of never labeling it.
  Confirmed against the four build-47 device exports from 2026-09-17, whose
  medians (recomputed) were: w4 prefill +4.5% (keep w1), g4 −15.6%
  (confirms the promoted default), advisory-on decode −6.8% (keep OFF),
  batched readback −3.6% (below the frozen 5% bar, matches the recorded
  rejection). New `Edge0SpeedABDecisionTests` pin the gate routing, the
  readahead kind plan, the acceptance rule, and the requested/effective
  metric pair.
- Fixed an out-of-bounds stack write in the 5M readahead path: the
  `F_RDADVISE` `radvisory` struct fill wrote 4 bytes past the 16-byte
  struct (it treated `ra_count` as an `off_t` and filled a nonexistent
  third field), crashing on the first expert hint whenever readahead was
  enabled. The fields are name-accessible in Swift and are now set
  directly; new `Edge0TensorStoreAdviseTests` cover the path (runs on the
  simulator — no MLX involved).
- Cleared the remaining Swift 6 readiness warnings in the Edge0 runtime and
  its tests (Sendable conformances, NSLock use in async contexts, deprecated
  `asData(noCopy:)` calls).

### Changed

- Repository identity references updated to `Mesutcydev/ondevice-core`
  (README badges and clone commands, AGENTS.md identity block,
  codemeta.json, CITATION.cff, llms.txt, SETUP_INSTRUCTIONS, docs links,
  in-app source/support links, HTTP User-Agent strings, and the altstore
  subscription URL). Release-channel references (altstore asset/release
  URLs, the 3.2.6 SBOM, the source-release workflow) intentionally still
  point at `ios-local-llm`, where those releases and assets live.

### Fixed

- Prompt-cache snapshot boundary: the snapshot was taken at the very end
  of the prompt, but the template's generation tail (assistant header +
  thinking cue) is replaced by the answer on the next turn, so the end
  never prefix-matched again — the build-53 device validation showed
  "reuse NOT APPLIED · reused 0 tok · prefilled 52" (answers identical).
  The snapshot is now taken at the LAST `<|im_start|>` — the boundary that
  re-renders identically every turn — by splitting the prefill there (two
  prefill calls over one state are numerically identical to one call).
  New boundary tests.
- Session-reuse probe dispatch: the 35B engine's probe method returned a
  non-optional result while the `RuntimeParityProbing` requirement is
  optional, so existential calls could resolve to the protocol-extension
  nil default — the build-52 device validation reported "Session-reuse
  probe unavailable" (stage 11, 0.01s). The engine method now matches the
  requirement exactly, breadcrumbs name every nil site, and two new tests
  pin the managed-wrapper → backend dispatch chain.
- Edge0 A/B acceptance comparators compared the time-delta metrics
  (prefill/TTFT) as if positive meant faster — a latent sign inversion
  that would have accepted a slower prefill. Both rules are now
  time-delta correct (`readaheadAcceptance`: prefill/TTFT at most 5%
  slower; `readsAcceptance`: prefill at least 3% faster), with the
  conventions documented and pinned by tests. The device verdicts
  (readahead and reads rejected) are unchanged.
- The device-validation export labeled a 35B run "requested exact"
  whenever staged was selected; the label now reports the actual
  selection (the engine counters were always correct).

### Notes

- Phase 5M bounded expert readahead is implemented but off by default — the
  build-48 device A/B rejected it (decode 7.29 → 5.69 tok/s median, −22.1%;
  prefill/TTFT within noise); the per-token router readback path is unchanged.
- Expert-read concurrency stays at 4 — the build-49 device A/B rejected
  reads 6 (prefill 1.5% faster, below the 3% bar; decode −3.5%, beyond the
  −3% floor). Both acceptance comparators were fixed to time-delta form
  (`<= 5` / `<= -3`) after the verdict exposed inverted sign conventions.
- In-app device validation (build 49) passes all 15 stages on the iPhone 17
  Pro Max, including the frozen nine-ID exact-reference oracle on device
  (9/9 ids) through the production staged path — the first real-hardware
  oracle pass for the 35B.
- Build 54's device validation is the first **16/16** pass; the
  session-reuse parity stage proves the prompt cache on device (reused 22 /
  prefilled 30 tokens on a 29→52-token turn pair, answers byte-identical).
- Focused Edge0 suites now execute on the simulator through an isolated
  sim-compat project (`project-simcompat.yml` + `OnDeviceSimCompat.xcworkspace`);
  see `Docs/VALIDATION.md`. Checkpoint- and fixture-gated cases skip cleanly,
  and MLX-allocating cases skip on the simulator itself
  (`Edge0TestDevice.requireSimulatorMLXSupport()`): the simulated Metal device
  has no architecture name and rejects the private-mode heaps mlx's allocator
  requires, and mlx's scheduler initializes the GPU stream unconditionally, so
  MLX cannot run on the simulator at all — those cases belong in a signed
  device session.
- Added `Docs/EDGE0_AUDIT_ROUND_2026-09-17.md` (fork audit) and
  `Docs/EDGE0_UPSTREAM_DOCS_AUDIT_2026-09-17.md` (upstream docs/repo audit).

## [1.0.0] - 2026-09-17

### Changed

- Refreshed the open-source release metadata (CITATION.cff, SBOM) to the 1.0.0
  marketing version used by the sideload release track.

### Fixed

- Sideload build 110 restores the OnDevice LLM display name and preserves the
  share extension's application-group entitlement during ad-hoc packaging.
- Imported GGUF assistants now receive their chat template, sampler
  settings, and system/tool prompts. Recurrent Gemma 3n / Gemma 4 E-series
  keep the compact 512/128 workaround; dense Gemma 4 12B/31B do not.
- MLX seed, frequency penalty, and presence penalty settings are applied.
- Local API chat/responses/messages replies report real token usage.
- Truncated replies are labeled in the chat chrome; the compact GGUF
  128-token cap is visible on the token-cap chip.
- Release-styled app builds no longer embed the unit-test bundle.
- Chat prompts no longer invite invented tool results, citations, or live
  data. Gemma templates fold the system prompt into the first user turn
  once instead of duplicating it.
- Standard GGUF assistants no longer inherit the smaller MLX-family output
  cap; Ornith continuation resumes at the correct KV-cache position.
- Speculative model prefetch now runs only after model load while charging and
  thermally nominal, reducing idle disk work and phone heat.

### Added

- In-chat streaming, approval, running-tool, citation, and image-generation
  cards. Web/file tool consent stays in the transcript.
- True Continue: tap Continue or the cut-off chip to resume the same
  assistant turn. Standard GGUFs reuse the live KV when it is still
  resident; otherwise the open assistant turn is re-prefills. No fake
  "please continue" user message.
- Standard imported GGUFs reuse matching prompt-prefix KV across turns
  instead of clearing the cache every send. Compact Gemma 3n / E-series
  still recreate context.

## [3.2.6] - 2026-07-29

### Added

- OpenSSF Scorecard analysis with public results and code-scanning upload.
- Reproducible source-release archives with SHA-256 checksums and
  GitHub/Sigstore provenance attestations.
- Release verification instructions for contributors and downstream users.

## [3.2.5] - 2026-07-29

### Added

- Open-source governance, provenance, validation, security-model, citation,
  SBOM, and coding-agent documentation.
- Reproducible root-level llama.cpp and whisper.cpp framework build tooling.
- Standalone licensing and notices for VoiceAgentOrb.

### Changed

- Repository identity standardized as `ios-local-llm`.
- Dependency lockfiles synchronized.
- Qwen3 license metadata corrected to Apache-2.0.
- Privacy and network disclosures aligned across repository and in-app text.

### Security

- Added high-confidence Clang warnings and static analyzer checks.
- Expanded responsible disclosure and repository validation guidance.

[Unreleased]: https://github.com/Mesutcydev/ios-local-llm/compare/v3.2.6...HEAD
[3.2.6]: https://github.com/Mesutcydev/ios-local-llm/releases/tag/v3.2.6
[3.2.5]: https://github.com/Mesutcydev/ios-local-llm/releases/tag/v3.2.5
