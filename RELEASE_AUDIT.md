# OnDevice Core AI Studio — Release Audit 1.0.0

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
