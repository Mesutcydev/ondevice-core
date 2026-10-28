# MiniCPM 35B Assistant performance update

October 14, 2026 · OnDevice: Max 1.0.1 (10)

The three recommended adjustments have been implemented and measured separately
on an Apple M4 Mac. The largest measured improvement is the wait before the
first token. A 234-token prompt decreased from a repeated build-9 baseline of
14.57 seconds to 4.73 seconds with the final profile. This is host evidence;
new iPhone throughput and sustained thermal behavior require TestFlight testing.

Build **1.0.1 (10)** is accepted by Apple (**VALID**) and available for internal
TestFlight testing (**IN_BETA_TESTING**). Apple records the upload at
**October 14, 2026, 01:59:36 Europe/Istanbul**. Build ID is
`8b1f1c51-22de-43be-9a25-c4d2c5c6fd05` for app `6818199563`, bundle
`com.mesutcydev.ondevicemax`. The existing **Me** group has access to all builds.
English What to Test notes and the IPA checksum were verified after processing.
The external state is `READY_FOR_BETA_SUBMISSION`.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).

## Changes

1. **Text-only Assistant runtime.** Assistant passes no projector and uses direct
   text tokenization and evaluation. It no longer initializes the unused vision
   encoder. Lens retains its image-capable runtime and existing profile. The
   prepared download, receipt validation and model revision are unchanged.
2. **Larger prompt batches with matching expert capacity.** Assistant uses a
   256-slot shared expert bank and a 128-token physical batch. The full bank fits
   the complete routed expert union. Lens keeps bank 40 and batch 4. The logical
   batch remains 512, context 4,096 and output ceiling 256. All eight routed
   experts are preserved.
3. **Memory-aware decode cache.** Assistant uses cache 24 only with at least
   5.5 GB of live, platform-bounded model memory, nominal thermals, Low Power Mode
   off and no pressure cooldown. Other supported conditions use cache 16 with
   the existing 4.8 GB admission floor. Native construction can retry cache 16
   once after releasing a failed larger-cache candidate; a cancelled load is
   never retried. The profile is selected at load time. Existing coordinated
   residency, pressure and thermal cleanup remain active.

Numeric Assistant diagnostics now record load, prefill, first-token and decode
durations; input/output counts; bank, batch and cache sizes; and whether a vision
encoder was loaded. No prompt, response text or image is recorded. Thread counts,
prefetch depth, expert parking, sampler controls and instruct formatting retain
their existing behavior.

## Staged measurements

All runs use the same official, checksum-verified prepared weights and synthetic
fixtures, deterministic greedy sampling and 64 generated tokens. Only numeric
results are saved. The sequence was build-9 baseline, text-only, repeated
build-9 baseline, larger bank/batch, then cache 24. There were **29 completed
benchmark generations**. Short and medium prompts have two baseline/text-only
repetitions and three final-profile repetitions; the longer prompt has one run
per profile. These are small host samples, not a phone benchmark or a broad
quality evaluation.

| Profile | Bank / batch / cache | First token, 54 input tokens | First token, 234 input tokens | First token, 854 input tokens | Decode at 234 tokens | Peak process footprint |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Build 9, repeated baseline | 40 / 4 / 16, vision loaded | 5.16 s | 14.57 s | 47.53 s | 12.49 tokens/s | 2.80 GB |
| Step 1: text-only | 40 / 4 / 16 | 4.25 s | 11.87 s | 40.17 s | 13.62 tokens/s | 1.69 GB |
| Step 2: larger bank/batch | 256 / 128 / 16 | 2.20 s | 4.72 s | 13.52 s | 13.34 tokens/s | 1.88 GB |
| Step 3: expanded cache | 256 / 128 / 24 | 2.28 s | 4.73 s | 13.50 s | 14.01 tokens/s | 2.31 GB |

First-token timing starts at generation entry after model initialization and
ends at the first streamed text. It includes prompt work and excludes model
loading and Swift artifact validation.

Times and decode rates are medians where repeated. Footprints are maximum
observed process `phys_footprint` sampled every 10 ms and use decimal GB. The
initial baseline was 5.23 / 15.08 / 48.91 seconds with a 2.80 GB peak; its later
repeat supports the direction of the latency change.

The final medium-prompt first-token wait is approximately **68% shorter** than
the repeated baseline. Cache 24 adds about **5%** to medium-prompt decode speed
compared with cache 16, and costs approximately 0.43 GB of observed host footprint.
Its benefit is smaller than the prompt-batch benefit, so it requires extra live
memory and favorable device conditions. Cold and warm file-cache states differed
during model loading; these runs do not establish a trustworthy load-speed ratio.

The displayed tokens/s measures the decode loop after prompt preparation. Faster
prefill can therefore improve responsiveness more than the displayed rate. The
user's earlier approximately ten-second wait and six tokens/s were observed in
Assistant on iPhone 17 Pro Max. Neither figure can be replaced with these Mac
results.

## Verification

| Check | Result |
| --- | --- |
| MiniCPM catalog, artifact integrity and adaptive-cache policy | 21 host tests passed |
| Download journal, scope and recovery | 18 host tests passed |
| App Store framework metadata and distribution rules | 32 tests passed |
| Real text-only cache 16 and 24 | Exact arithmetic output, instruct formatting, output cap, decode cancellation/retry, context refusal, unload/reload passed |
| Cancellation during larger-batch prompt preparation | Cancelled before output; nonblocking metrics getter and retry passed for both caches |
| Real Lens path and shared native runtime | Input-dependent image colors, actual stage order, image cancellation/retry, text/image transitions, unload/reload and top-eight routing passed |
| MiniCPM download links | All six pinned file links returned readable bytes with matching source sizes |
| Generic iPhone Release compile | App and test bundle compiled successfully with shipping Xcode |
| Archive and signed export | Passed: profiles, entitlements, code signatures, framework metadata, native UUIDs and all seven runtime imports |
| Apple TestFlight processing | VALID; internal IN_BETA_TESTING; test notes and checksum verified |

The temporary official validation weights were removed after real-model checks;
weights and generated native frameworks remain outside Git. The production model
preparation format is unchanged, so an existing completed download can be reused.
The 35B model remains experimental and requires a 12 GB class device.

No production UI code changed in this update. Build 9's waiting-state, sidebar,
background-download and Live Activity UI checks are documented in
[the previous release report](TESTFLIGHT_BUILD_9_DOWNLOADS_AND_LENS.md). The full
app uses device-only CoreAI; its simulator UI harness does not measure inference.

## Release packaging

Shipping Xcode **27A266a** produced the archive and manual distribution export
using the existing owner-team certificate and explicit profiles for the app,
share extension and download activity extension. All three bundles are
**1.0.1 (10)**. Native runtime UUIDs match the reviewed device slices, all seven
MiniCPM functions are imported, and framework version/minimum-OS metadata passed
verification. Required model/runtime notices match the signed IPA.

All **1,082** fingerprinted source files remained unchanged during packaging and
upload; all **18** package checkouts match their locked revisions. The exported
IPA is **91,309,697 bytes**, with SHA-256
`0b5b0f441c46f4bdad35bd71e80dc4fa198b421288e2516d249e02b75957816e`.

Signed artifacts and verification logs are retained in ignored
`build/appstore/1.0.1-10/`. The upload completed successfully and Apple accepted
the binary. Final source hashes still match after upload.

## Test on iPhone

Compare a new Assistant chat and repeated follow-ups using the same prompts and
output lengths as build 9. Record first-token wait, displayed tokens/s and whether
the phone is warm, charging or in Low Power Mode. Repeat for several minutes to
check sustained behavior. Cache selection happens when the model loads; after
enabling Low Power Mode, switch to another model and back before comparing.
Test Stop during preparation and output, retry, another
model, and Assistant → Lens → Assistant. Check the existing download cancellation,
background transfer and Dynamic Island activity as regression flows.

Local numeric evidence is retained in ignored
`build/minicpm-performance-release-2026-10-14/`: staged JSONL measurements, summary,
real-model regression logs, unit-test logs and download-link probes.
