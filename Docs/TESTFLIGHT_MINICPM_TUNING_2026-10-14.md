# MiniCPM 35B cache and prompt tuning

October 14, 2026 · OnDevice: Max 1.0.1 (12)

Build 12 tunes the MiniCPM 35B Assistant runtime after the user reported about
6 tokens/s and a similar initial wait in build 11, with a cool iPhone 17 Pro Max
and Low Power Mode off. It preserves build 11's long-response correction.
Build **1.0.1 (12)** is accepted by Apple (**VALID**) and available in internal
TestFlight (**IN_BETA_TESTING**). The existing **Me** group has access to all
builds. English test notes and the uploaded IPA checksum were verified. Apple
records the upload at `2026-10-14T12:05:35+03:00` Europe/Istanbul for app
`6818199563`, bundle `com.mesutcydev.ondevicemax`.
[TestFlight app record](https://appstoreconnect.apple.com/apps/6818199563/testflight/ios).

## Changes

The text engine can keep more frequently reused experts in memory. Selection
uses the existing live, platform-bounded `MemoryAdvisor` budget, with nominal
thermal state, Low Power Mode off and no memory-pressure cooldown required for
the larger profiles.

| Expert cache per layer | Minimum available memory at load |
| --- | --- |
| 16 | 4.8 GB |
| 24 | 5.5 GB |
| 32 | 5.9 GB |
| 48 | 6.2 GB |

If native allocation fails, the candidate is released before trying the next
smaller cache: 48 → 32 → 24 → 16. Cancellation stops this retry chain. The engine
retains all eight routed experts; the change does not reduce model routing.

Prompt processing now selects a microbatch of 128, 256 or 512 according to input
length and a separate admission check immediately before generation. That check
uses available memory and the process ceiling from one snapshot, plus the
existing thermal, power and pressure guards. It accounts for expert capacity
and incremental compute reserve without charging already resident pages twice.

After a larger prompt batch, the runtime returns to a 128-token compute context
for one-token generation. It preserves recurrent and KV state in a temporary,
bounded in-memory snapshot. Contexts never overlap. The first token is sampled
before the switch because the pinned runtime's state reader does not restore
sample-ready logits. If the snapshot cannot be obtained, generation keeps its
valid larger context. A failed restoration is retried in the previous admitted
profile; the engine never samples from partially restored state.

An original private shim rewraps parked, model-owned expert storage before a
context replacement. Ordinary unloading and request-end parking remain intact.
The runtime stays pinned to OpenBMB revision
`0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2`. All three native slices expose only
eight `od_mini47_*` functions, with no public llama, ggml or mtmd symbols.

Assistant diagnostics include both the actual prompt microbatch and decode
microbatch, along with selected cache, input/output counts and numeric timings.
No prompt, answer, captured media or credentials are logged.

## Functionality checks

| Check | Result |
| --- | --- |
| MiniCPM catalog, artifacts and memory policy | 26 host tests passed |
| Native token-budget boundaries | 4,200 prompt-length cases passed |
| Adaptive prompt batches | Real 35B arithmetic passed at 128, 256 and 512; decode returned to 128 |
| Cache 32 and cache 48 | Both completed the same 867-token standalone HTML document |
| Continue | Both completed a reply deliberately limited to 384 tokens |
| Stop | Cancellation during prompt processing and after 300 streamed tokens passed, followed by successful retry |
| Context limit | A 512-token context with 383 input tokens returned 128 output tokens and the genuine limit flag |
| Lens | Actual image encoding, prompt processing and decode stage order, followed by text arithmetic, passed |
| Production iPhone compilation | Release app and test bundle compiled with shipping Xcode |
| App Store verifier | 32 tests passed |
| Native metadata | All three slices have required version and minimum-OS values |
| Downloads | All six pinned 1B/35B links responded successfully |
| Repository hygiene | Passed |
| Signed release | Archive and distribution export verified |
| Apple processing | VALID and internal IN_BETA_TESTING; test notes verified |

The existing completed 35B download and preparation format can be reused. Lens
retains its image execution profile. The 4,096-token text context, normal
Assistant reply-length settings, thermal stop behavior, residency coordination,
background downloads, Live Activities and other model engines are preserved.
No production UI changes are included.

## Performance measurement

The comparison uses a preserved macOS framework whose checksum matches the
exact build 11 release fingerprint, against the candidate runtime. Synthetic
short, medium and longer-history prompts request the same arithmetic result and
number sequence. Answers are checked in memory; evidence contains numeric
timings and pass/fail results only. Compilation had finished before either
measurement run. All 26 fixtures returned the complete correct number sequence.
The table uses medians of five warm requests for short and medium prompts; the
longer-history fixture has one sample per profile.

| Fixture | Build 11 first token | Build 12 first token | Build 11 decode | Build 12 decode |
| --- | --- | --- | --- | --- |
| Short, 54 input tokens | 2.26 s | 2.30 s | 12.99 tokens/s | 14.66 tokens/s |
| Medium, 234 input tokens | 5.29 s | 3.63 s | 12.49 tokens/s | 14.25 tokens/s |
| Longer history, 854 input tokens | 13.99 s | 8.07 s | 13.76 tokens/s | 14.06 tokens/s |

Medium first-response time improved by **31%** and the longer-history fixture by
**42%**. Short first-response time stayed similar. Warm decode improved by
**13–14%** in the repeated short/medium fixtures. The sampled peak app footprint
increased from **2.31 GB** to **3.81 GB**; larger profiles therefore remain
conditional on healthy live memory. These host results are not iPhone
measurements and do not establish the publisher's advertised phone speed.

Post-release diagnostics from **1.0.1 (12)** now establish that cache **48** was
active on the iPhone, with bank 256, prompt batch 512 and decode batch 128. A
999-input/971-output request took **16.954 seconds** to its first token and
decoded at **6.29 tokens/s**. A 371-input/859-output request took **7.630 seconds**
and decoded at **6.95 tokens/s**. Neither reply hit its token limit. Model loading
took 2.2–2.4 seconds separately. These are different prompts without a controlled
build 11 phone comparison; they do not establish the host speed improvement on
the iPhone. The smaller-cache fallback is ruled out for these requests.

A subsequent internal request used 199 input tokens, produced five tokens and
spent another **9.220 seconds** reaching its first token. This matches the
conversation titler's use of the same runtime after the first answer; build 12
did not log the request's purpose. The export reported thermal state `fair`,
Low Power Mode off, a 3.9 GB app footprint and a 6.44 GB process limit. Thermal
state was not captured at each request, so this does not prove hardware
throttling. The follow-up implementation and measurements are recorded in the
[build 13 report](TESTFLIGHT_MINICPM_PHONE_FOLLOWUP_2026-10-14.md).

The connected iPhone was available, paired and in Developer Mode. A separate
probe app was built without replacing the user's TestFlight app or reading its
conversations. The device rejected both development and device-specific ad hoc
distribution signatures with `0xe8008018`, while the corresponding certificates
were present and unexpired in the owner team's Apple records. The probe was not
installed and no phone benchmark was obtained. No certificates were revoked or
replaced. A TestFlight measurement is still needed to establish the actual phone
speed and first-response change.

Speculative decoding remains disabled in this build. Its draft model, memory
admission, verification and rollback integration require separate correctness
and device measurements. The source research and publisher settings are in the
[web optimization audit](MINICPM_35B_BUILD11_WEB_OPTIMIZATION_AUDIT_2026-10-14.md).

## Test on iPhone

Reuse the installed MiniCPM 35B model. With the phone cool and Low Power Mode
off, compare a short first request, a longer answer and a follow-up. Record
first-response time separately from the decimal tokens/s value. Test Stop,
Continue and switching between Assistant and Lens. Export diagnostics after
those requests without restarting the app, so the generation timing entries
remain available.

The numeric evidence and release checks are retained in ignored
`build/minicpm-tuning-release-2026-10-14/`. Signed release artifacts belong in
ignored `build/appstore/1.0.1-12/`.

## Release packaging

Shipping Xcode **27A266a** produced the archive and manual App Store export with
the verified existing owner-team profiles for the app, share extension and
download activity extension. All three report **1.0.1 (12)**. Required framework
version/minimum-OS values, signatures, provisioning, entitlements, native UUIDs
and all eight private MiniCPM imports passed verification. Both the preserved
baseline and this candidate's isolated native library use the existing native
builder; its device binary declares iOS SDK and minimum OS **27.0**.

All **1,085** release input hashes remained unchanged through packaging and
upload. All **18** package checkouts matched their locked revisions. Model and
runtime notices matched the files included in the exported IPA. Temporary host
validation weights were removed; numeric logs, preparation receipt and manifest
were retained.

IPA size: **91,311,104 bytes**. SHA-256:
`c875f65d32bc4dc5cccfade424a37893d9dad69750693b80c0b81cf1de29c616`.
App Store Connect upload ID: `0c36265e-afbe-4e69-8361-32a9b27d9987`.
Processed build ID: `0c36265e-afbe-4e69-8361-32a9b27d9987`. External beta state
is `READY_FOR_BETA_SUBMISSION`; no public App Store submission was requested.
