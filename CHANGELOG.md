# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [Unreleased]

### Added

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

- Cleared the remaining Swift 6 readiness warnings in the Edge0 runtime and
  its tests (Sendable conformances, NSLock use in async contexts, deprecated
  `asData(noCopy:)` calls).

### Notes

- Phase 5M bounded expert readahead is implemented but off by default
  pending the device A/B; the per-token router readback path is unchanged.
- Focused Edge0 suites now execute on the simulator through an isolated
  sim-compat project (`project-simcompat.yml` + `OnDeviceSimCompat.xcworkspace`);
  see `Docs/VALIDATION.md`. Checkpoint- and fixture-gated cases skip cleanly.
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
