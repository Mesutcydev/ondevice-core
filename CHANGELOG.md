# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [Unreleased]

### Build history

- **47 (2026-09-21):** Switched FastVLM's default to a reachable repository,
  repaired stale download settings and retry behavior, added a destination
  writability check, and kept model download actions on one line. Reduced the
  oversized API server and storage cleanup buttons. See
  `Docs/DESIGN_FIX_2026-09-20.md` (Round 2).
- **48 (2026-09-21):** Made Discover card Download actions start a transfer,
  gave Installed and Discover model rows card layouts, and aligned Lens model
  readiness with the vision model picker's full installation check. See the
  same document (Round 3).
- **49 (2026-09-21):** Added repair and clearer errors for unwritable model
  folders, looked for FastVLM's downloaded Core ML encoder inside its model
  directory, corrected accent-button contrast, and cleared overlapping or
  duplicate chat controls. See the same document (Round 4).
- **50 (2026-09-22):** Centered the boot splash across the full screen,
  matched its light background to the system launch screen, and added a
  minimum display time. See the same document (Round 5).
- **51 (2026-09-22):** Refined the chat empty state and consolidated the voice
  session accessory and workspace action into one bottom bar. These changes
  are inferred from source modification times before the build 51 archive;
  no separate release note was recorded.
- **52 (2026-09-22):** Refined composer and keyboard placement with measured
  clearance below the composer and a leading keyboard-dismiss key. These
  changes are inferred from source modification times before the build 52
  archive; no separate release note was recorded.

Builds 47–49 received device reports that drove the next round of fixes. The
full release hardware gate, including real inference, camera and microphone
checks, remains open. Builds 51–52 have no recorded device verification.
Build 52's source-only IPA omits the bundled VLM and FastVLM Core ML package;
Lens may download approximately 520 MB on first use, and the FastVLM path is
unavailable without its encoder package.

### Security

- Local API / Mac bridge: an oversized `Content-Length` no longer overflows the
  HTTP parser. Any LAN host could previously crash the app with one
  unauthenticated request while the API server was on. See
  `Docs/RELEASE_AUDIT_BUILD52_2026-09-23.md`.
- Local API and Mac pairing failures are throttled per remote host, so one
  failing peer cannot lock out all clients. The Local API now permits at most
  8 simultaneous connections per host and 32 overall.

### Fixed

- Image studio → Share → Save Image no longer terminates the app (added
  `NSPhotoLibraryAddUsageDescription`).
- The status bar follows the appearance instead of forcing dark text, which was
  invisible in dark mode.
- A paired Mac bridge can advertise over Bonjour again (`NSBonjourServices`).
- Updated audio taps, playback, session interruption handling and share
  extension item loading for the iOS 27 APIs. Corrected misleading weak
  captures in service callbacks.
- Removed 16 unreferenced view files from the app target, with restorable
  copies under the ignored `build/removed-dead-views-2026-09-23/` directory.

### Changed

- **API server page** rebuilt after the OnDevice LAS operator homepage, in this
  app's native language: live runtime activity with tokens per second, device
  health, per-protocol connection URLs, confirmed key rotation, Share
  connection, inline quick start, the served-endpoint catalog, model Unload,
  and the previously hidden Nearby devices (AWDL) setting. A revealed API key
  hides when the app leaves the foreground.

### Added

- One-page first-run onboarding (`Views/OnboardingOnePager.swift`), shown
  after the legal gate: a README-style capability table (MLX, GGUF, Core AI,
  Core ML, Stable Diffusion plus the product surface), a plain-language
  privacy note, and a single primary action. Replaces the retired multi-page
  tour; compiles into the DesignReview harness verbatim.
- `Docs/UI_CONSISTENCY_AUDIT_2026-09-19.md`: the state of every layout conflict,
  control-proportion and dead-affordance finding from the app-wide audit, what
  was fixed and what is deliberately left.
- **API server workspace** in the leading sidebar: the local HTTP server is a
  retained primary workspace rather than the former Mac pairing sheet. Mac
  pairing is hidden (its implementation and stored credentials are preserved),
  and legacy bridge navigation requests redirect to the API workspace.
  Enable/stop, port validation, key rotation and model selection remain wired
  to the existing services. See `Docs/API_SERVER_WORKSPACE_2026-09-20.md`.
  Ships in sideload build 44 (`OnDeviceMax-sideload-entitled-1.0.0-44.ipa`).

### Changed

- App-wide design unification to the Studio language: Home rebuilt (Lens /
  Voice / Mac tiles and the hero mic action removed; editorial rows and
  hairlines), Models tab chrome restyled (mono eyebrows, neutral storage bar,
  flat search field, ink-underline role picker, square-cut chips and badges),
  Mac bridge hero and Voice library flattened off gradient styling, and 108
  legacy capsule controls swept to the 9 pt square-cut grammar. Vendor
  gradient monogram tiles render neutral with ink glyphs.

- **Navigation shell**: the bottom navigator is gone. The shell is a
  conversation home page (pinned/recent list, native search, Voice and New
  chat) with every feature in a leading sidebar — Library, Current chat, Lens,
  Voice, Image studio, Models, Device, API server, search and history, with
  Chat and Settings anchored at the foot. Visited workspaces stay mounted so
  chat drafts, attachments and scroll state survive navigation. See
  `Docs/SIDEBAR_NAVIGATION_2026-09-19.md`. This supersedes the earlier
  `TabView` direction and is also the structural fix for the composer/tab-bar
  conflict: two bottom `safeAreaInset`s used to stack, putting the bar between
  the field and the keys.
- **Round 2 refinement**: camera and voice ownership serialized (late
  callbacks rejected by operation IDs, background transitions preserve
  explicit demand), one persistent voice accessory across all workspaces,
  Lens capture-then-review flow with per-operation pixel/prompt capture,
  conflict confirmation when chat/model/image work would take the runtime
  from an active voice session, chat list snippets, and compact voices /
  image / models / device surfaces. See `Docs/ROUND2_IMPLEMENTATION.md`.
  Ships in sideload build 45 (`OnDeviceMax-sideload-entitled-1.0.0-45.ipa`).
- **Design polish pass**: the Downloads sheet leaves the retired lowercase-mono
  dialect — sentence-case labels, sans card copy, and a blue accent capsule
  for Download/Retry replacing the inverted white slab. Image studio gains a
  designed empty state (a placeholder canvas in the result slot) and its
  prompt suggestions are one grouped card. API server and model statuses are
  color-coded. See `Docs/UI_DESIGN_AUDIT_2026-09-20.md`. Ships in sideload
  build 46 (`OnDeviceMax-sideload-entitled-1.0.0-46.ipa`).
- **September 20 native UI pass**: chat composer (one continuous surface,
  measured multiline input, model pill, Voice/Send/Stop), explicit Dictate
  text destination, reply actions with disclosed model/timing details,
  conversation drawer with create/manage groups, compact voice library and
  session, image studio with real result canvas, native Installed/Discover
  models control, and a scrollable Device surface — all rebuilt on native
  controls, system typography and the 4/8/12/16/24/32-point spacing scale.
  Legacy route requests redirect; the old generator sheets were removed. See
  `Docs/UI_UX_BRIEF_2026-09-20.md`. Ships in sideload build 43
  (`OnDeviceMax-sideload-entitled-1.0.0-43.ipa`).
- **Chat composer** rebuilt as one contained panel — Liquid Glass on iOS 26 (the
  same material as the tab bar), a single accent run key, icon-only `Attach` and
  `Reason` controls, and the runtime status in its own strip above it. The field
  and controls share one row, so an empty composer is a bar rather than an
  expanded text area, and a long prompt grows to five lines before scrolling.
- **Keyboard**: one hide key, on the leading edge of the keyboard's own
  accessory row, so nothing competes with the composer's send button.
- **Typography**: `KoduTheme.sans`/`display`/`mono` no longer address SF faces by
  name. `Font.custom(".SFUI-Regular", …)` cannot be resolved by CoreText, so
  every label in the app had been rendering CoreText's last-resort face, Times
  New Roman. The app is SF Pro again, and Dynamic Type still scales.
- **Models screen** now reaches real destinations: discovery, Core AI packs,
  storage cleanup, and per-model details / configure / export / delete. Each of
  those previously did nothing but switch to the Models tab it was already on.
- **Proportions**: 16 controls that drew below 44pt (down to a bare 13pt glyph)
  now carry full tap targets, and four corner radii moved onto the radius
  ladders. `StudioSpacing.tabBarClearance` is 24, not 140 — a native `TabView`
  already reserves the bar.

### Fixed

- Deleting a model now deletes it (the confirmation dialog was inert); export
  writes a file; configure opens the per-model settings sheet.
- The conversation picker no longer presents a share sheet from inside itself.
- Duplicate affordances removed: history as both a toolbar glyph and a menu
  item, `Details` both on the row and in its menu, and two "choose a model"
  buttons on an empty thread.
- Capturing is no longer possible with no vision model selected — the shutter is
  disabled instead of failing later from the inference path.
- Removed the dead old Lens tab stack from `ContentView` (`CameraRootView` and
  eight helpers, nothing instantiated any of them): 2434 → 748 lines.
- FastVLM's verified-unreachable text-model trap now logs a diagnostics fault
  before trapping, so CrashReporter's post-crash trail records the state that
  led there instead of a bare, context-free SIGABRT.
- The Settings Whisper STT block now fails with a descriptive precondition
  message if the `whisper-base-en` catalog entry ever goes missing, instead of
  force-unwrapping an arbitrary first catalog model.
- Removed LensFramePreparer's duplicated `modelMinimumSide` switch (and its
  stale TODO); the tile-fit path already reads the single source of truth,
  `VLMCapabilities.minimumProcessorSide`.

## [1.0.0] - 2026-09-17

### Changed

- Forked OnDevice Core as **OnDevice Max**: the app, share extension, unit-test
  and UI-test bundle identifiers, App Group, CloudKit container, URL scheme and
  every internal identifier namespace now use `com.mesutcydev.ondevicemax`. The
  two products install side by side and share no container, keychain service or
  Spotlight domain.
- Aligned the open-source release metadata (CITATION.cff, SBOM) to the 1.0.0
  marketing version already declared by `project.yml`.

### Fixed

- `scripts/validate_open_source.sh` compared the two committed SwiftPM lockfiles
  through the retired `IOSLocalLLM.xcodeproj` / `IOSLocalLLM.xcworkspace` paths,
  so the hygiene check failed on a missing file before it ever reached the
  version, secret and action-pinning checks. It now reads the generated
  `OnDeviceMax.*` paths.
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
