# Validation and evidence policy

This document separates implemented safeguards from verified behavior. A code
path or a user report is not automatically a benchmark.

## Current evidence

The maintainer has confirmed manual debugging and user testing of model
management, RAM admission, memory-warning handling, and thermal-management
behavior. The repository contains the corresponding policy and lifecycle code,
but does not yet include enough shareable raw logs to claim a comprehensive
device benchmark.

Automated, repeatable checks currently include:

| Scope | Command | Environment |
| --- | --- | --- |
| Repository hygiene | `./scripts/validate_open_source.sh` | Linux or macOS |
| VoiceAgentOrb package | `swift test --package-path Packages/VoiceAgentOrb` | macOS CI |
| XcodeGen consistency | `xcodegen generate` followed by a clean diff | macOS |
| App workspace build | `xcodebuild build -workspace OnDeviceCoreAIStudio.xcworkspace -scheme OnDeviceCoreAIStudio -destination 'platform=iOS Simulator,name=iPhone 17'` | iPhone 17 simulator, iOS 27 |
| App unit and UI tests | `xcodebuild test -workspace OnDeviceCoreAIStudio.xcworkspace -scheme OnDeviceCoreAIStudio -destination 'platform=iOS Simulator,name=iPhone 17'` | iPhone 17 simulator, iOS 27 |

On 29 July 2026, the open-source workspace built successfully and the
first-launch legal flow, onboarding, Home, Assistant, and Models screens were
manually exercised on the simulator. Assistant model preparation is
intentionally skipped on simulator builds because the simulated GPU cannot
provide valid MLX inference evidence; the real inference path remains a
physical-device validation requirement.

Do not pass `CODE_SIGNING_ALLOWED=NO` to the test command. Simulator tests are
ad-hoc signed without a paid developer account, and the Keychain-backed
pairing and credential-wipe tests require the resulting Keychain entitlement.

On 17 September 2026 the focused Edge0 suites (expert read plans, loaders,
layout, metal environment, resident plans) executed on the iPhone 17
simulator through the isolated sim-compat project described below: all
non-gated cases passed; cases gated on real checkpoints (`EDGE0_35B_MODEL`,
`EDGE0_8B_MODEL`) or oracle fixtures (`EDGE0_35B_FIXTURES`) skip cleanly when
those are absent.

On 17 September 2026 the **in-app device validation runner** completed all
15 stages on the sideloaded build 49 (iPhone 17 Pro Max, iOS 27.2) through
the production Assistant path: artifacts validated, admission accepted
(auto pool → 1213 slots/2 GiB), load 1.94 s, prefill 7.58 s, TTFT 7.65 s,
decode 8.33 tok/s, **exact reference parity PASS — 9/9 ids, first differing
index none**, cancellation (stop→end 0.02 s), generation after cancel,
unload, MLX switch, and switch back. This is the first real-hardware run of
the frozen nine-ID oracle through the production staged configuration
(`mode.effective = staged`, `prefill staged·microbatch4`, `decode
boundedPrefetch`, `reads 4`); peak footprint 4.42 GB, thermal nominal
throughout.

Edge0 unit suites execute on the simulator through an isolated sim-compat
project, because the simulator SDK ships no `CoreAI.framework` and the app's
`coreai-models` package is device-only. Recipe:
`xcodegen generate --spec project-simcompat.yml` creates
`OnDeviceSimCompat.xcodeproj`; build/test it through
`OnDeviceSimCompat.xcworkspace` (which also references `Pods/Pods.xcodeproj`,
so the CocoaPods targets build by implicit dependency), e.g.:

    xcodebuild test -workspace OnDeviceSimCompat.xcworkspace \
      -scheme OnDeviceCoreAIStudio \
      -destination 'platform=iOS Simulator,id=<simulator-udid>' \
      -derivedDataPath build/SimCompat-DD \
      -only-testing:IOSLocalLLMTests/Edge0_35BExpertLoaderTests

The production project is untouched by this path; regenerate it with the
normal `xcodegen generate` + `pod install` flow (SETUP_INSTRUCTIONS.md).
Note that `pod install` is required after every `xcodegen generate` — the
CocoaPods script phases and library links are re-added by it.

Tests that allocate MLX arrays skip on the simulator: the simulated Metal
device reports no architecture name and rejects the private-mode heaps mlx's
allocator requires, and mlx's scheduler initializes the GPU stream
unconditionally, so MLX cannot run on the simulator at all. Those cases guard
themselves with `Edge0TestDevice.requireSimulatorMLXSupport()` and belong in a
signed device session. With that gate the focused Edge0 suites run clean on
the simulator: **21 passed, 29 skipped, 0 failures, 0 aborts**.

## Required physical-device matrix

Before making a quantified reliability or performance claim, record:

| Field | Required evidence |
| --- | --- |
| Hardware | exact device model and RAM tier |
| Software | iOS, Xcode, app commit, model ID and quantization |
| Model lifecycle | load, generate, cancel, switch, unload |
| Memory pressure | admission decision, warning handling, recovery |
| Thermal | nominal/fair/serious/critical transition behavior |
| Backgrounding | generation stop and resource release |
| Duration | warm-up, run length, prompt/context/output sizes |
| Result | logs, MetricKit/signpost evidence, failures and limitations |

Simulator tests are useful for UI and deterministic logic, but are not evidence
for Jetsam limits, Metal residency, sustained thermals, or battery behavior.
Use synthetic prompts and redact tokens, device names, addresses, and user data.

## Claim language

Use “implemented” for a code path, “manually observed” for a recorded manual
test, and “validated” only when the device, commit, procedure, and outcome are
documented. Never generalize one device result to all supported hardware.
