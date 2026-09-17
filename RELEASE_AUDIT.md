# OnDevice Core AI Studio — Release Audit 1.0.0

## Build 49 — 2026-09-17 (expert-reads A/B runner)

Follow-up to build 48, adding the last untested device lever as a first-class
diagnostic:

- **`35B Expert reads A/B (4 vs 6)`** kind: read concurrency is load-captured
  (the store's read semaphore is fixed at engine load), so the runner
  reloads the engine on every arm transition (4→6→6→4) and exports a
  requested/effective reads pair; a requested-6 trial whose store says
  otherwise is labeled SETUP-BLOCKED. Frozen acceptance rule: prefill
  ≥ +3% with decode ≥ −3%.
- Rows and the summary export carry reads requested/effective; the
  Diagnostics row shows the arm; two new decision tests pin the plan, the
  population gate, and the acceptance rule.

| Check | Result |
| --- | --- |
| Version metadata | Consistent: 1.0.0 (**49**) in `project.yml` (app + extension) |
| Focused Edge0 tests (simulator) | **Executed**: 11 passed / 0 failures (8 decision + 3 advise), exit 0 (`build/simcompat-reads.log`) |
| IPA packaging | **Packaged** — 52 independent artifact checks passed; ZIP member paths identical to build 48 |

Artifact: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-49.ipa`
(`...-latest.ipa` identical)

- Version **1.0.0 (49)**; the share extension also uses build **49**.
- Size: **53,209,144 bytes**.
- SHA-256: `436b3e5d78c18826cdbb4cb136b3ac5d61f0319159ce2bfdd60ad5d19ee677d3`.
- **52 independent artifact checks passed** (`verification-1.0.0-49/`). ZIP
  member paths exactly match build 48; the llama and whisper framework
  binaries are byte-identical; entitlements match builds 43–48 exactly
  (PCC, increased memory, extended virtual addressing, CloudKit/iCloud,
  shared App Group). Bundle IDs and minimum iOS 27.0 unchanged.

## Build 48 — 2026-09-17 (readahead fix + A/B diagnostic)

Follow-up to build 47 after the first device A/B session surfaced the 5M
readahead crash and the decision-stage gap:

- **Crash fix**: the `F_RDADVISE` `radvisory` struct fill wrote 4 bytes past
  the 16-byte struct (`ra_count` treated as an `off_t` plus a phantom third
  field); the imported `ra_offset`/`ra_count` fields are now set directly.
  The path had zero execution coverage before; new
  `Edge0TensorStoreAdviseTests` (3 cases) pin it.
- **Readahead A/B diagnostic**: the `35B Readahead A/B (off vs hints)` kind
  with a reload-per-arm lifecycle, the engine-exported requested/effective
  proof pair (SETUP-BLOCKED on a missed reload), a frozen acceptance rule
  (decode ≥ +5%, prefill/TTFT ≥ −5%), and a per-kind population gate that
  fixes the empty-DECISION exports from the build-47 session. New
  `Edge0SpeedABDecisionTests` (6 cases) pin the gate, plan, acceptance rule,
  metric pair, and load-capture.

| Check | Result |
| --- | --- |
| Version metadata | Consistent: 1.0.0 (**48**) in `project.yml` (app + extension) |
| Open-source validator | **Passed** — "Repository hygiene checks passed" |
| Focused Edge0 unit tests (simulator) | **Executed**: 30 passed / 29 skipped / 0 failures / 0 aborts, exit 0 (`build/simcompat-tests48.log`; includes the 6 decision tests and 3 advise tests; MLX-allocating cases skip by design) |
| UI polish (splash, onboarding, agreement) | Unchanged from build 47 (still verified on the simulator) |
| Real-checkpoint 35B regressions | **Not run** (no checkpoint staged on this machine) |
| IPA packaging | **Packaged** — 51 independent artifact checks passed; ZIP member paths identical to build 47 |

Artifact: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-48.ipa`
(`...-latest.ipa` identical)

- Version **1.0.0 (48)**; the share extension also uses build **48**.
- Size: **53,210,799 bytes**.
- SHA-256: `2f170235bdb4d2ea22073e9310e4322e69b243be6b9b3c6877b2ab061e01e037`.
- **51 independent artifact checks passed** (`verification-1.0.0-48/`). ZIP
  member paths exactly match build 47; the llama and whisper framework
  binaries are byte-identical; entitlements match builds 43–47 exactly
  (PCC, increased memory, extended virtual addressing, CloudKit/iCloud,
  shared App Group). Bundle IDs and minimum iOS 27.0 unchanged.
- Unlocks the device follow-up: the readahead A/B runs safely now — the
  fix makes the hints-ON arm viable, and the new kind prints a DECISION
  section. (Outcome, same day: the A/B ran on device and **rejected**
  readahead — decode 7.29 → 5.69 tok/s median (−22.1%), prefill/TTFT
  within noise; hints stay OFF. The performance campaign is closed with
  every candidate device-measured.)

## Build 47 — 2026-09-17

Sideload build covering the uncommitted work since build 46: the Phase 5M
readahead candidate and the 2026-09-17 pass (per-layer expert read plans in
both Edge0 loaders, NAX gate mirror in Diagnostics, NAX-off A/B script,
A18→A19 documentation errata), the Swift 6 warning cleanup, and the UI
redesign (splash, two-step onboarding, agreement screen). Full detail:
`Docs/EDGE0_AUDIT_ROUND_2026-09-17.md` and
`Docs/EDGE0_PERF_UPDATE_SCAN_2026-09-17.md`.

| Check | Result |
| --- | --- |
| Version metadata | Consistent: 1.0.0 (**47**) in `project.yml` (app + extension) and the regenerated project; `Info.plist`, `CITATION.cff`, and `CHANGELOG.md` (`[1.0.0] - 2026-09-17` + populated `[Unreleased]`) |
| Open-source validator | **Passed** — "Repository hygiene checks passed" (the previously recorded CITATION.cff version failure is resolved) |
| Device compile gate (build-for-testing, full test target) | **Passed** — 0 errors, 0 Edge0 warnings; re-verified after `pod install` re-integration |
| Focused Edge0 unit tests | **Executed on the iPhone 17 simulator** via the sim-compat project: **21 passed / 29 skipped / 0 failures / 0 aborts** (exit 0; `build/simcompat-tests5.log`). The 7 MLX-allocating cases skip via `Edge0TestDevice.requireSimulatorMLXSupport()` — the simulated Metal device cannot back mlx (no architecture name; private-mode heaps rejected) — and run in the device session |
| UI polish (splash, onboarding, agreement) | **Verified on the iPhone 17 simulator** — frames captured and inspected: splash sequence renders (tile → aperture ring → wordmark), onboarding shows "1 of 2" with the "Choose your models" CTA, agreement screen cards aligned with readable contrast |
| Real-checkpoint 35B regressions | **Not run** (no checkpoint staged on this machine) |
| IPA packaging | **Packaged** — `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-47.ipa`; 50 independent artifact checks passed; ZIP member paths identical to build 46 |

Resolved before packaging: build number bumped to 47; `[Unreleased]` changelog
entries written; stray root file `-` moved to `build/`; the full working set
committed together with the regenerated `project.pbxproj` and the sim-compat
project files. Remaining: device-session runs (MLX-eval cases, real
checkpoints, 5M/NAX A/Bs) on a signed build. Production Edge0
defaults are unchanged (staged g4 prefill, per-token router readback `0`,
boundedPrefetch decode, readahead and advisory prerouter OFF). Reminder:
`xcodegen generate` **then** `pod install` for release builds.

Artifact: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-47.ipa`
(`...-latest.ipa` identical)

- Version **1.0.0 (47)**; the share extension also uses build **47**.
- Size: **53,194,355 bytes**.
- SHA-256: `736cf53c629f0738512ecdb84ba0b0df1cfde98b35f2dae4d051e6b09849ed3c`.
- Built by the complete Xcode 27 Release sideload script; catalog invariants,
  direct-download preflight, archive, Foundation Models symbol preflight,
  license collection, and packaging verification all passed
  (`build/sideload-47-run.log`).
- **50 independent artifact checks passed** (`verification-1.0.0-47/`). ZIP
  member paths exactly match build 46 (no added or removed paths); the llama
  and whisper framework binaries are byte-identical to build 46. Entitlements
  match builds 43–46 exactly: PCC, increased memory, extended virtual
  addressing, CloudKit/iCloud, and the shared App Group remain intact. Bundle
  IDs and minimum iOS **27.0** are unchanged.
- Ships the redesigned splash / two-step onboarding / agreement screens (their
  copy strings verified in the shipped binary) and the Edge0
  read-plan/NAX/warning-cleanup work.

## Build 46 UI, voice orb, onboarding, and studio identity — 2026-09-16

This release packages the current workbench with the Aperture voice orb,
shared UI polish, three-step onboarding, broader Assistant copy, and the
website/source links in Settings. See `Docs/UI_POLISH_AUDIT.md` for the UI
validation and physical-device performance limitations.

Artifact: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-46.ipa`

- Version **1.0.0 (46)**; the share extension also uses build **46**.
- Size: **53,148,612 bytes**.
- SHA-256: `992da6461e509715f3e83a3b0c7a2f0dda9d6111dd6660a7f27b464faedd6756`.
- Built by the complete Xcode 27 Release sideload script. Catalog invariants,
  direct-download preflight, archive, Foundation Models symbol preflight,
  license collection, and packaging verification all passed.
- **47 independent artifact checks passed.** The ZIP member paths exactly
  match build 45. All nested code signatures verify; the app, share extension,
  and native frameworks are ARM64 device binaries. The llama and whisper
  framework binaries are byte-identical to build 45.
- Exact app and extension entitlements match builds **43, 44, and 45**:
  PCC, increased memory, extended virtual addressing, CloudKit/iCloud, and
  the matching shared App Group remain intact. Bundle IDs and minimum iOS
  **27.0** are unchanged. Privacy manifest, third-party notices, executable
  permissions, and file-sharing flags are present and valid.
- The packaged executable contains the updated Assistant welcome and app
  links; `default.metallib` contains both Aperture shader entry points.
- `latest.ipa` and the versioned IPA have the same checksum. Detailed evidence,
  exported entitlements, source fingerprints, and build logs are under
  `build/releases/verification-1.0.0-46/`.

This is the established profile-less, ad-hoc signed format and requires
installer-side re-signing with suitable profiles. Update the existing app
using the same bundle ID and Apple signing team to preserve its data; do not
uninstall first. This packaging pass does not establish physical-device model
performance or run another inference benchmark. The previously recorded
`CITATION.cff` version-metadata validator failure is unchanged.

## Build 45 Phase 5K packaging closeout — 2026-09-14

Build 45 is a packaging/cleanup closeout. The reported source change is the
diagnostic preference capture/restore path; it does not add or promote a new
inference optimization. Production 35B remains staged true-router prefill,
routed microbatch 4, eval window 1, per-token router readback (`0`), and
boundedPrefetch decode, with the learned prerouter off.

Validation record:

| Check | Result |
| --- | --- |
| Preference capture/restore helpers, including cancellation and errors | **5/5 executed and passed** |
| Actual app runner end-to-end cleanup and single-run guard | **Compiled only — not executed** |
| Full real-checkpoint model regressions for build 45 | **Not rerun** |
| IPA signing and application-identity verification | **Passed** (`1.0.0 (45)`, bundle `com.mesutcydev.ondevicecore`) |
| Open-source validator | Known, unchanged `CITATION.cff`/version failure |

The helper tests support the restoration logic; they do not establish that the
complete app runner restores preferences on a phone.

The profile-less IPA is
`build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-45.ipa` and must
be re-signed by the installer (SHA-256
`78fadc1a1f297e59f98428c85b65191ea14efa4f24dc2cfbea67777d08253705`). Install
it **as an update** over build 44,
without deleting the app or downloaded models. After installation, check the
developer router-readback setting in Diagnostics: ordinary use must be
**per-token / `0`**. Restoration deliberately writes back the captured value,
so an existing diagnostic value of `1` is preserved rather than reset.

After that check, return to ordinary 35B chat. Do not run another speed A/B for
this closeout. Future inference changes must restore the real-checkpoint
harness and fixtures in persistent development storage; there is no need to
redownload the checkpoint for this packaging-only change.

## Build 7 LFM answer-quality hotfix — 2026-08-22

- Fixed LFM2.5 2.6B returning raw
  `<|tool_call_start|>[knowledge_base(...)]<|tool_call_end|>` protocol text
  instead of answering ordinary questions. The Assistant now honors the
  curated Core AI pack's `supportsTools` capability before advertising or
  executing tools.
- Unsupported Core AI tool dialects receive a short direct-answer guardrail
  instead of the full tool catalog. This removes a large, irrelevant prompt
  from LFM's constrained on-device input budget and prevents unnecessary
  knowledge-base calls.
- Persisted conversations are sanitized when reopened with an unsupported
  Core AI tool dialect, so a tool catalog from a previously selected model
  cannot leak across model switches.
- MLX and GGUF retain their existing tolerant text-tool behavior. Tool-capable
  Core AI packs such as Nanbeige remain tool-enabled.
- Fixed Core AI tool follow-up planning so a trailing tool result is actually
  supplied to the synthesis pass.
- Xcode 27 Release archive and device `build-for-testing` succeeded.
  VoiceAgentOrb tests: 25 passed. Simulator execution remains unavailable
  because Apple's CoreAI module is device-only in this toolchain.

Build 7 IPA: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-7.ipa`

- Size: 51,598,481 bytes
- SHA-256: `5c1df91257b44972687040ebfae0dba2204d46a3488ec11ce2ecf482ea14480f`
- Final Payload/signatures, nested frameworks, share extension, privacy
  manifest, file-sharing flags, PCC, increased-memory, extended-addressing,
  iCloud and matching App Group entitlements all passed the release script.

## Build 6 performance and thermal hotfix — 2026-08-22

- Core AI EOS, user Stop, task cancellation, and abandoned stream consumers
  now cancel and drain the pipelined GPU producer instead of allowing hidden
  decoding to continue to the response-token limit.
- Cancellation waits for already-committed command buffers before returning
  the engine slot, preventing buffer reuse while GPU work is retiring.
- Core AI now uses the same thermal/memory admission cap as MLX/GGUF and stops
  an in-flight request if the device reaches critical thermal state.
- Fixed-S=1 Core AI pipelines are constrained to the verified-correct 1024 KV
  state range on iOS; the app advertises a 512-token Core AI output ceiling and
  compacts input to leave template/EOS headroom.
- Hybrid reasoning models receive `enable_thinking` through their tokenizer
  chat template. LFM2.5 2.6B remains correctly classified as reasoning-only.
- Core AI diagnostics now separate time-to-first-token from decode rate.
- Existing MLX behavior is unchanged. GGUF received only the missing
  critical-thermal in-flight cancellation guard.
- Xcode 27 device build and device test build succeeded. VoiceAgentOrb tests:
  25 passed. Simulator execution is unavailable because Apple's CoreAI module
  is device-SDK-only in this toolchain.

Build 6 IPA: `build/releases/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-6.ipa`

- Size: 51,597,548 bytes
- SHA-256: `209d488fe04256e6a7d272cb6bfbea7ae96f4d796fdaf7bb3032d87e1043c88c`
- Final Payload/signatures, nested frameworks, share extension, privacy
  manifest, file-sharing flags, PCC, increased-memory, extended-addressing,
  iCloud and matching App Group entitlements all passed the release script.

Audited and packaged with Xcode 27.0 / iPhoneOS 27.0 SDK.

## Product basis

This is a copy of the real CodeLens workbench (`CodeLens` HEAD `72a0c65`), not
the separate Core AI: LAS server product. It retains all five tabs and existing
runtimes:

- Home
- Assistant
- Lens
- Voice
- Models
- MLX / llama.cpp-GGUF / Whisper / Core ML
- Share extension, local API, Mac bridge and Apple Private Cloud

Apple Core AI is an additional local Assistant runtime selected alongside MLX
and GGUF. It does not replace those catalogs or features.

## Identity

- Project/workspace/scheme: `OnDeviceCoreAIStudio`
- Display name: `OnDevice Core`
- Bundle: `com.mesutcydev.ondevicecore`
- Share extension: `com.mesutcydev.ondevicecore.share`
- App Group: `group.com.mesutcydev.ondevicecore.shared`
- CloudKit: `iCloud.com.mesutcydev.ondevicecore`
- URL scheme: `ondevice-core`
- Minimum OS: iOS 27.0
- Version: 1.0.0 (7)

## Core AI runtime integration

- `ModelRuntime.coreAI` and `coreai:<catalog-id>` persisted selections.
- `CodingAssistantService` load / generate / stop / drain / unload / switch
  paths support Core AI without treating it as PCC.
- Lazy specialization on first Send.
- Same conversation history, context trimming, JSON mode, tool envelopes,
  token accounting and per-conversation model restoration as existing models.
- Unload-before-load policy drains Lens/MLX/GGUF before Core AI specialization.
- Core AI runs through the same memory/thermal/low-power admission gate.
- Background lifecycle cancels and unloads Core AI with the other heavy
  runtimes.
- Voice can continue using the selected Assistant runtime for reply generation;
  Lens remains on its existing MLX/GGUF vision pipelines.

## Model catalog and downloads

- 22 direct Hugging Face Core AI packs audited.
- Assistant UI offers the 16 official/chat packs; VLM/embedding/ASR packs are
  not falsely advertised as chat models.
- Exact repository subtrees — never the whole multi-platform repo.
- Measured download sizes and exact file links.
- Foreground sideload-safe downloads, pause/resume/retry/cancel.
- Wi-Fi-only policy, free-space preflight with partial-download credit and 1.5
  GB install headroom.
- Hugging Face LFS SHA-256 is checked incrementally for every LFS-backed file
  before installation; bad files are removed.
- One Core AI pack is installed at a time. Replacing it drains a live runtime,
  removes the previous multi-GB tree, and updates active/default identity
  safely. MLX/GGUF files are untouched.
- `Wipe all data` now includes Application Support/CoreAIModels and its setting.

Verification:

```text
verify_zoo_catalog.sh       All catalog invariants hold
verify_zoo_downloads.py     all 22 packs verified downloadable
build-for-testing           TEST BUILD SUCCEEDED
release archive             succeeded
FoundationModels preflight  no deprecated or missing imports
```

## UI/UX audit

- Existing CodeLens navigation and tab structure preserved.
- Core AI is embedded in Models → Assistant, not introduced as another product
  shell.
- Dedicated installed-pack card, download progress and exact-files/license UI.
- Installed Core AI pack appears in the normal Assistant picker with a CORE AI
  runtime badge.
- Missing-pack state links directly to Models.
- Replacing/removing packs resets selection safely and states explicitly that
  MLX/GGUF are unchanged.
- Ready status distinguishes `Ready via Apple Core AI` from PCC and other local
  runtimes.
- User-visible onboarding, splash, diagnostics, Shortcuts and review copy use
  `OnDevice Core`; the separate `iOS Local LLM Bridge` companion name and the
  upstream iOS Local LLM legal attribution remain intact.

### Download-start regression

The first sideload build made a Core AI download look inert after tapping
Download. Root cause had two layers:

1. `CoreAIHFDownloadManager.start()` scheduled a Task but left its published
   state at `.idle` until that Task later ran, so the same-frame button state
   did not acknowledge the tap.
2. The catalog card read a child manager from `CoreAIDownloadCenter`, but did
   not observe that manager. The center publishes manager insertion/removal,
   not every child's progress tick, so later enumerating/downloading/progress
   changes never redrew the controls.

Fixed by publishing `.enumerating` / `.downloading` synchronously in `start()`
and by rendering each manager through `CoreAIDownloadControlsView`, which owns
an `@ObservedObject` reference to that manager. Added immediate start/resume/
retry toasts, an indeterminate listing spinner, live bytes/total/speed, and
`CoreAIDownloadManagerTests.testStartPublishesVisibleStateSynchronously`.

The exact fixed tree again passed `build-for-testing` before IPA packaging.

A physical-device UI/inference run was not executed by the agent: the CoreAI
module is absent from the Simulator SDK, and the final IPA is intentionally
ad-hoc/re-signer-ready. Re-sign it with ForgeSign/AltStore or your provisioning
profile before installing on an iOS 27 device.

## IPA

`~/Desktop/OnDeviceCoreAIStudio-sideload-entitled-1.0.0-1.ipa`

- Size: 51,485,934 bytes
- SHA-256: `86190c64eb2923e7d9cf4d7afbbd7da12c084a81069b2bc98ff7d22dfa6060cd`
- Root structure: only `Payload/`
- App: `Payload/OnDeviceCoreAIStudio.app`
- App signature: verified ad-hoc; installer re-sign required
- Privacy manifest: present
- CoreAI, llama and whisper frameworks: all linked/present
- Share extension: present and signed
- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`: true

Embedded app entitlements verified from the final IPA:

- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`
- `com.apple.developer.private-cloud-compute`
- `com.apple.security.application-groups`
- `com.apple.developer.icloud-container-identifiers`
- `com.apple.developer.icloud-services`

The share extension carries the matching App Group entitlement.

## Isolation proof

- `/Users/m/Desktop/CodeLens`: clean at `72a0c65`.
- `/Users/m/Desktop/OnDeviceLAS`: no `OnDeviceCoreAIStudio`, bundle-id, or Core
  AI section artifacts from this work at `82fcdd59`.
- The earlier mistaken LAS-derived attempt is preserved separately at
  `/Users/m/Desktop/OnDeviceCoreAIStudio-LAS-WrongBackup` and is not used by
  this release.
