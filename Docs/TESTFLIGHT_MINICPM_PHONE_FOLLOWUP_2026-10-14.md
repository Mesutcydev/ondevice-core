# MiniCPM 35B phone follow-up — 2026-10-14

OnDevice Max **1.0.1 (13)** is accepted by Apple and available to the existing
internal TestFlight group **Me**. Processing is `VALID`; internal state is
`IN_BETA_TESTING`. Upload time: **2026-10-14 16:01:10 Europe/Istanbul**.

## What build 12 actually measured

The user's iPhone 17 Pro Max diagnostics establish cache 48, shared bank 256,
full GPU offload, a text-only engine and a 128-token decode batch. A cache
fallback does not explain the observed speed.

| Request | Input / output tokens | First token | Decode | Prompt batch |
| --- | --- | --- | --- | --- |
| First supplied answer | 999 / 971 | 16.954 s | 6.29 tokens/s | 512 |
| Second supplied answer | 371 / 859 | 7.630 s | 6.95 tokens/s | 512 |
| Subsequent internal request | 199 / 5 | 9.220 s | 5.49 tokens/s | 128 |

Neither long answer hit its token limit. Loading took 2.2–2.4 seconds before the
requests; the first-token measurements are request time, not that loading time.
The export showed a 3.9 GB footprint, a 6.44 GB process limit, thermal state
`fair` and Low Power Mode off. Request-time thermal state was not logged, so the
export does not establish hardware throttling during either answer. The two
prompts differ and there is no controlled build 11 phone comparison.

The internal request started immediately after the second answer completed and
occupied the model for about 10.1 seconds. Its five-token output and timing match
`ConversationTitler` calling the same Assistant runtime for a title. This is an
inference from source and event ordering: build 12 did not label its purpose.

## Changes in build 13

The 35B streaming runtime retains the existing first-message conversation title
instead of generating a separate title after the answer. This removes an
expensive optional request and leaves the model available for the next user
message. Existing manual titles remain protected; other runtimes keep their
current title generation behavior.

Long text prompts may use a **1,024-token** prompt batch when thermal state is
nominal and both live headroom and process capacity admit the larger compute
allocation. The cache-48 envelope reserves 2.0 GB beyond expert capacity and
requires at least 1.8 GB remaining headroom. Smaller prompt batches and allocation
fallbacks remain available. Decode returns to 128 with complete recurrent/KV
state preservation and unchanged top-eight expert routing. The existing
4,096-token context and reply-length policy are preserved.

At thermal `fair`, foreground prompt batching can use **256** with sufficient
headroom. Serious/critical heat, Low Power Mode and pressure cooldown retain the
128 ceiling. Cache admission still requires nominal thermal state; this change
does not admit a larger cache at fair. Apple recommends reducing energy use
proactively at fair, so the optional title request is removed and the fair
batch ceiling remains below the nominal profile. See
[Apple's thermal guidance](https://developer.apple.com/videos/play/wwdc2019/422/).

Numeric-only diagnostics now record request-time batch policy and separate
prompt evaluation, context changes, sampling, token callbacks and parking.
Existing upstream atomic counters measure decode expert callbacks, GPU expert-ID
reads, expert installation, slot-ID writes, misses and logical read bytes.
Installation includes reads and GPU-visible copies; sampling can include GPU
waits. Counter spans overlap API spans and must not be added to them. Logical
read bytes are not a measurement of physical storage throughput. The counters
reuse existing synchronization and do not enable upstream stderr probes. No
prompts, answers, titles, captured media or credentials are logged.

## Validation

The 33 focused host policy/title tests pass. Native tests validate all admitted
prompt profiles, correct output after restoring the 128-token decode context,
full long HTML replies, continuation, Stop during prompt processing and decode,
retry, nonblocking metrics access, and a genuine context-bound token limit.
Both C and Swift agree on the 184-byte metrics ABI. The native adapter retains
eight private exports and no public llama/ggml/mtmd symbols.

The temporary validation model is byte-identical to the previous reviewed pack:
all 43 files match its independently retained SHA-256 receipt. It stayed outside
Git and was removed after testing; its manifest and verification receipt remain. Source weights and runtime revisions,
licenses, installed model layout and preparation format are unchanged.

An alternating-order comparison reused one cache-48 engine with decode batch
128, two samples per profile and prompt, and no concurrent compilation. All
eight requests returned the complete correct arithmetic/number sequence.

| Input tokens | Batch 512 first token | Batch 1024 first token | Change | Batch 512 decode | Batch 1024 decode |
| --- | --- | --- | --- | --- | --- |
| 854 | 11.462 s | 8.998 s | 21.5% faster | 5.975 tokens/s | 5.854 tokens/s |
| 1,154 | 16.638 s | 13.550 s | 18.6% faster | 5.373 tokens/s | 5.545 tokens/s |

The sampled peak footprint across this process was 3.80 GB. The watcher records
a process-wide high-water mark, so these are not independent per-request peaks.
Decode varied by −2.0% and +3.2%; this small sample establishes no decode gain
or consistent regression. A preceding three-sample comparison also reduced
first-response time, but ran all 512 cases before all 1024 cases and is retained
as secondary evidence rather than a controlled thermal comparison.

The shipping-Xcode Release app and test bundle passed the generic iPhone
`build-for-testing` compile gate. This is compile validation, not device test
execution. The focused host tests and real-model regressions ran on the Mac.
All six pinned MiniCPM download links passed fresh range-request checks for
HTTP status, expected file size and GGUF prefixes. The unchanged catalog's
existing same-day 36-pack release check is also retained. All three final native
slices have matching public headers, exactly eight private exports and the
required framework version/minimum-OS metadata. The App Store verifier's 32
tests and repository validation passed.

Signed archive, distribution export and Apple processing verification passed.
Release identity and integrity details are recorded below.
These host measurements cannot establish a new iPhone generation rate. The
publisher's advertised speed combines LES, mixed quantization and DSpark; this
build does not add speculative decoding. See the
[official model card](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B) and
[existing implementation audit](MINICPM_35B_BUILD11_WEB_OPTIMIZATION_AUDIT_2026-10-14.md).

## Test on iPhone

Reuse the installed MiniCPM 35B download. With the phone cool and Low Power Mode
off, test a longer prompt and answer, then a follow-up. Check Stop and Continue,
and confirm the model is available immediately after completion. Export
diagnostics without restarting, including `MiniCPM prompt policy`,
`MiniCPM text timings`, `MiniCPM call timings` and `MiniCPM decode expert counters`.
Compare first-response time separately from decode tokens/s using the same
prompt and comparable conditions. The extra counters will determine whether
further work should target expert installation, synchronization or model compute.

Ignored evidence: `build/minicpm-phone-followup-2026-10-14/`.
Signed release location: `build/appstore/1.0.1-13/`.

## Release verification

Shipping Xcode **27A266a** produced the Release archive and App Store export
using the same owner-team distribution setup as the accepted build 12. The app,
share extension and download activity extension all report **1.0.1 (13)**.
Framework version/minimum-OS metadata, nested signatures, provisioning,
entitlements, the two native runtime UUIDs and all eight private MiniCPM imports
passed both archive and exported-app verification. The isolated native builder
retains its prior toolchain; the iPhone native slice declares SDK/minimum OS
**27.0**.

All **1,088** release input hashes remained unchanged through packaging and
upload and passed a separate post-upload check. All **18** package checkouts
matched their locked revisions. Bundled model/runtime notices match the
reviewed source. The six MiniCPM URLs were freshly checked before packaging.
The download/preparation format remains compatible with the installed models;
there is no required model redownload.

IPA: **91,316,964 bytes**. SHA-256:
`79b77c0d2a947a74d0c2ab30fd2453178d7baf4ab5a61c28491d1d52d6c2ba69`.
This is local checksum verification before and after upload; Apple's upload API
did not supply a remote checksum. Upload/build ID:
`2d4b6c54-d245-43cd-8192-982020d57f42`.

Apple processing is **VALID** and internal TestFlight state is
**IN_BETA_TESTING**. The existing internal group **Me** has access to all builds.
English What to Test notes were published and read back successfully. External
state is `READY_FOR_BETA_SUBMISSION`; this release was uploaded for the user's
existing internal testing workflow.
