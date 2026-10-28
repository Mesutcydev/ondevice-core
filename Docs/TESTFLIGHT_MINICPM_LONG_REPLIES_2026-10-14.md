# MiniCPM 35B long-answer correction

October 14, 2026 · OnDevice: Max 1.0.1 (11)

The screenshot shows an HTML reply stopping during CSS with “cut off at token
limit.” The MiniCPM Assistant had a fixed **256-token ceiling** in the service,
Swift adapter and native generator. It overrode the normal **2,048-token**
response-length setting. The early ceiling has been removed from all three.
Build **1.0.1 (11)** is accepted by Apple (**VALID**) and available in internal
TestFlight (**IN_BETA_TESTING**). The existing **Me** group has access to all
builds. English test notes and the IPA checksum were verified after processing.
Build ID: `1f0b661a-7da7-4824-a352-0b3236eb6776`. Apple records the upload at
`2026-10-14T08:20:49+03:00` Europe/Istanbul for app `6818199563`, bundle
`com.mesutcydev.ondevicemax`.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).

## Behavior

Assistant now follows the user's global or per-model response-length setting,
the existing device thermal limit and the normal GGUF profile. The native
tokenizer gives the reply only the exact remaining space in its **4,096-token
context**, reserving one final position. A valid long prompt with a large reply
request is shortened to fit, rather than rejected just because the requested
reply is too long. An input that leaves no output position is still refused.

The context allocation, memory-admission gates, residency coordination, cache
profiles, top-eight expert routing and critical-thermal stop behavior remain
unchanged. Lens retains its 256-token image-response ceiling and existing
image-prompt admission. No new model files or preparation format are required;
the completed 35B download can be reused.

A reply that actually reaches its requested or context budget remains marked as
incomplete. **Continue** in the response menu appends through the existing open
assistant-turn path. The service now advertises native cache continuation only
when the bridge actually has a usable cache; MiniCPM's full-prefill continuation
remains supported. The fix does not hide genuine limit warnings or append
invented closing code.

The response-footer speed label now shows **one decimal place**. Previously,
6.1 and 6.4 could both display as “6 tok/s.” The change preserves localized number
formatting, accessibility text and the existing identifier.

## Verification

| Check | Result |
| --- | --- |
| Native token-budget boundary checks | Passed, including 4,200 prompt-length cases, large inputs, a one-position remainder and unchanged image admission |
| MiniCPM catalog, artifacts and text-profile policy | 22 host tests passed |
| Real model, cache 16 and cache 24 | Both completed a standalone **867-token HTML document**, including its script and closing HTML tag |
| Continuation | Both continued a reply deliberately stopped after 384 tokens and completed the same 867-token document |
| Stop and recovery | Cancellation after 300 streamed tokens and subsequent retry passed for both cache profiles |
| Exact native context boundary | A 512-token runtime with 383 prompt tokens returned 128 output tokens, with the limit flag set and one final position reserved |
| Lens regression | Actual image encoding → prompt evaluation → answer generation order and text arithmetic passed |
| Response footer | Production view's simulator UI flow passed; native screenshot visually verified at 18.4 tok/s |
| App Store verifier | 32 tests passed |
| Production iPhone compile | Release app and test bundle compiled with shipping Xcode |
| Signed release | Archive and distribution export verified |
| Apple processing | VALID and internal IN_BETA_TESTING; notes and checksum verified |

Real model checks ran on Apple silicon Mac with checksum-verified official
OpenBMB weights. Model output stayed in memory; logs retain numeric
counts and pass/fail results. Temporary weights were removed after verification.
The simulator tested the production presentation component through `QA/NativeUI`,
not device-only CoreAI or real iPhone inference.

## Speed

The user reports about **6 tokens/s on iPhone 17 Pro Max** after build 10. That is
a decode-rate observation, separate from prompt preparation. Build 10 primarily
improved prompt latency in the host benchmark and did not establish a new phone
decode rate. Its [report](TESTFLIGHT_MINICPM_PERFORMANCE_2026-10-14.md) records the
measurement scope.

The phone was visible to Xcode in this session, but Instruments could not attach
to the running app by PID or executable name; no usable phone trace was obtained.
Low Power Mode and thermal conditions were not confirmed. This release changes
reply budgeting and display precision; **it does not claim another decode-speed
improvement**. Further throughput tuning requires device measurements.

## Test on iPhone

Use the existing MiniCPM 35B download and a response length of 2,048 tokens. Ask
for a complete HTML page with CSS and JavaScript, check that it includes its
closing tags, and test Stop after the response has already passed its old length.
If a genuine budget is reached, use **More response actions → Continue**.

Compare the decimal tokens/s using similar prompts and output lengths, with the
phone cool and Low Power Mode off; record whether it is charging. Also switch
between Assistant and Lens. A long conversation can leave less context space
for a new reply even with a higher response-length setting.

Ignored local evidence is retained in
`build/minicpm-response-release-2026-10-14/`: native boundary checks, real-model
regression logs, `rate-footer-ui-corrected.xcresult`, the native screenshot,
compile logs and release verification records.

## Release packaging

Shipping Xcode **27A266a** produced the archive and manual distribution export
with the existing owner-team profiles for the app, share extension and download
activity extension. All three report **1.0.1 (11)**. Required framework version
and minimum-OS values, code signatures, provisioning, entitlements, native UUIDs
and all seven private MiniCPM imports passed verification.

All **1,084** source fingerprints stayed unchanged during packaging, and all
**18** package checkouts matched their locked revisions. IPA size is
**91,311,360 bytes**, SHA-256:
`e0606840e2c9c6dab08dc585a2c6746fe3e35312df624212740df60f87921ee8`.

Signed artifacts and verification logs are in ignored
`build/appstore/1.0.1-11/`. Upload succeeded and Apple accepted the binary. Final source hashes still match
after upload. External state is `READY_FOR_BETA_SUBMISSION`.
