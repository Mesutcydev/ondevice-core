# MiniCPM 35B: builds 13–14 audit and build 15 context follow-up

October 14, 2026 · OnDevice: Max 1.0.1 · Assistant

Build 14 adds bounded prompt-prefix reuse for longer conversations. It does
not establish a higher iPhone decode rate or a faster first request in a short
new chat. The storage/thread experiments did not show a consistent throughput
improvement, so the app retains four CPU threads, four expert I/O workers,
eight lookahead/prefetch slots, eight routed experts and the existing cache
admission policy.

## What the phone measured

The user's build 13 recording contains a complete, untruncated response:

| Measurement | iPhone 17 Pro Max, build 13 |
| --- | ---: |
| Input / output | 366 / 1,132 tokens |
| Time to first token | 7,730 ms |
| Decode time / rate | 169,356 ms / 6.68 tokens/s |
| Actual prompt / decode microbatch | 512 / 128 |
| Expert cache / shared bank | 48 / 256 slots |
| Expert installation span | 69,092 ms |
| Main-path expert misses / logical reads | 140,880 / 190,424,678,400 bytes |
| Exported footprint / process ceiling | 3.89 / 6.44 GB |

Expert installation accounts for about 40.8% of decode wall time. Main-path
reads average approximately 168 MB per output token. The miss count corresponds
to about 38.9% of 40-layer, top-eight lookups. These are logical reads, exclude
background prefetch and do not measure physical NAND bandwidth. Expert spans
overlap the API timings and must not be added to them.

Output callbacks occupied only 22 ms. This recording gives little reason to
change answer rendering to improve tokens/s. The title was retained without
another 35B generation. Low Power Mode was off; thermal state was nominal at
request start and fair at export. The recording does not identify when that
transition happened or establish throttling as the cause.

## Real-model comparisons

The temporary pack was prepared from the pinned OpenBMB source. All 43 files
passed full SHA-256 checks; all 42 weight assets match the build 13 pack byte
for byte. The baseline Mac framework also matched the accepted build 13
fingerprint. Experiments ran sequentially on a 16 GB Apple-silicon Mac, with
fresh processes for I/O settings because the runtime caches that setting.
Only synthetic inputs and numeric measurements were recorded.

Short arithmetic answers retained the same complete 64-token output under
I/O workers 1/2/4, CPU threads 2/4 and prefetch read budgets 0/2/4/8. Reducing
workers was slower. Prediction-only operation reduced total logical expert
reads by roughly 30%, but slowed decoding. An equal-memory allocation of
52 cache plus four prefetch slots was also slower than 48 plus eight in the
short screening. It was not promoted.

Six longer comparisons produced an identical, complete 867-token HTML document:

| Profile | Two-run rate range | Median rate |
| --- | ---: | ---: |
| Existing four CPU / four I/O / eight reads | 8.40–8.85 tokens/s | 8.63 |
| Four CPU / four I/O / two reads | 8.24–9.32 tokens/s | 8.78 |
| Two CPU / four I/O / eight reads | 8.41–8.57 tokens/s | 8.49 |

The small median difference for two reads is within the observed variation.
These measurements do not justify changing the app's default. Short arithmetic
and longer code have substantially different rates; neither is a phone forecast.

A bounded persistent-worker prototype passed task completion, exception/retry
and serial fallback checks. It reduced thread scheduling overhead in a synthetic
host test, but the absolute saving was too small to explain the phone's expert
installation span. It was not integrated.

## Guarded conversation reuse

The native engine saves complete recurrent and KV state at an existing prefill
batch boundary, before the final assistant opener. It never splits a first
prompt to populate this cache. Reuse requires an exact token-prefix match and
the same admitted compute profile. Changed prefixes, cancellation, context
errors and profile changes discard the checkpoint. Changing a later suffix
evaluates that suffix normally. Failed restoration falls back to full prompt
evaluation. Model unload and background cleanup release the state.

State is held only in memory and capped at 128 MiB. The host separately admits
that reserve against live headroom and the process ceiling. Low Power Mode,
pressure cooldown, serious/critical thermals and insufficient memory disable
it. Prompt compute admission also charges the reserve. Lens and other model
engines continue through their existing paths.

The production implementation reproduced build 13's exact outputs in the
eight-case conversation/recovery comparison. In the measured longer chat:

| Request | Full evaluation | 1,024-token prefix reused |
| --- | ---: | ---: |
| Follow-up, 1,241 input tokens | 10.50 s | 4.72 s |
| Third turn, 1,265 input tokens | 10.63 s | 4.84 s |

Those eligible Mac waits were approximately 55% shorter. Saved state occupied
86,856,693 bytes; measured peak footprint was 3.88 GB. A short fresh prompt
has no eligible checkpoint, and a conversation may need more than one turn
before a stable batch boundary can be reused. The phone still needs validation.

Long-response regressions completed an 856-token HTML document, exercised
Stop after 300 streamed pieces, continued a 384-token partial answer to the
same complete document and verified the small-context output boundary.
Fixed-seed temperature-0.7 sampling matched with caching disabled, populated,
reused and disabled again. Changing the compute profile discarded the old
checkpoint and matched fresh decoding under the new profile. The 36 focused
host tests, 32 App Store verification tests and repository checks passed.

## Build 14 phone follow-up

The user supplied a build 14 recording exported at
`2026-10-14T20:16:11.181Z`, followed by all three completed answers. They
confirmed that they backgrounded the app between turns to copy the next
prompt. The unloads are therefore expected lifecycle cleanup, not an
unexplained failure to retain the active foreground model.

| Request | Input / output | First token | Decode rate | Expert cache / prompt batch | Prefix reused / saved |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTML page | 429 / 1,074 | 7.733 s | 6.15 tokens/s | 48 / 512 | 0 / 0 tokens |
| Explanation | 929 / 118 | 26.774 s | 4.63 tokens/s | 16 / 256 | 0 / 512 tokens |
| Review | 784 / 160 | 22.819 s | 6.30 tokens/s | 16 / 256 | 0 / 512 tokens |

All three requests report `hitTokenLimit=false`. The fresh first prompt is
shorter than its 512-token compute batch, so it has no complete stable batch
to checkpoint. Each later request saves 76,360,693 bytes of prefix state.
The explanation's checkpoint is released during background cleanup before
the review request. No request
in this recording exercises a cache hit; it cannot establish a benefit or a
regression from restoring cached state.

The first request starts nominal with the admitted 48-slot expert cache.
The later requests start fair and reload with the conservative 16-slot cache
and 256-token prompt ceiling. The exported thermal state is serious, with
Low Power Mode off. These requests have different prompt lengths, expert
profiles and thermal conditions; their waits are not a controlled comparison.
The exact time of thermal transitions and the degree of any OS throttling are
not recorded. The app's own conservative profile selection is established by
the source and numeric logs.

Main-path logical expert reads per output token rise from about 183 MB in the
first request to 234–236 MB in the later requests. Expert installation still
occupies approximately 38–46% of decode wall time. Callback totals remain
3–22 ms. These counters reinforce the storage/compute bottleneck and do not
justify a response-rendering rewrite or relaxing device safety policies.

The answers demonstrate completed long output, rather than a decode-speed
improvement. The page includes all 12 buttons and the requested fallback,
but ignores the request to omit Markdown fences. The app's coding
instructions request fenced blocks, which can conflict with a user's raw
document request. The review recommends a viewport tag
already present in the page. Its GPU-acceleration recommendation is not a
measured improvement; the reduced-motion rule also leaves hover/active
transforms in place. The output region lacks an explicit live announcement
for screen readers. These are answer-quality observations, not evidence of
broken streaming.

The follow-up token counts are smaller than the full accumulated exchange.
The app's bounded context compactor and final input trim can shorten earlier
code, so the review does not prove that the model saw every original line.
The diagnostic export cannot identify the exact passages retained. Context
retention needs its own controlled regression before changing that policy.

A valid phone prefix test must keep the model foreground and use unchanged
conversation/system prefixes and compute profiles. The pass condition is a
positive `reused` token count, not merely `checkpoint=512` or `allowed=1`.
For a quick repeat, type short follow-ups directly in the same chat, then
export diagnostics after the last answer. Let the device cool first to make
the comparison useful. Apple documents the
thermal states and guidance in its
[Foundation reference](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).

Build 14's iPhone decode-speed target remains unmet. DSpark is still absent
and requires the separate correctness, memory and performance work below.

### Foreground repeat and context correction

The next recording, exported at `2026-10-14T20:37:00.479Z`, contains two
consecutive foreground requests with nominal thermals at request starts and
export, Low Power Mode off, cache 48 and the same 1,024-token prompt profile:

| Request | Input / output | First token | Decode rate | Saved / reused |
| --- | ---: | ---: | ---: | ---: |
| Brief summary | 806 / 82 | 9.585 s | 7.62 tokens/s | 0 / 0 tokens |
| Three improvements | 833 / 106 | 10.357 s | 6.45 tokens/s | 0 / 0 tokens |

There is no model unload between these two requests. The missing checkpoint
is established by the implementation: both prompts fit inside one compute
batch, and build 14 saves only completed stable batches before the generation
cue. The previous suggested short follow-ups therefore did not exercise the
feature. These short outputs do not establish a sustained decode-rate gain.
The transcript also repeats the already-present viewport recommendation.

Build 15's candidate adjusts MiniCPM's message preparation rather than the
native decoder. A long requested answer no longer reduces estimated source
space below 2,032 tokens in the existing 4,096-token context. The output
request remains unchanged and the native tokenizer still limits generation to
the exact remaining window. MiniCPM defers compaction while the complete
source fits that input budget; if earlier compaction already hid source,
the complete stored transcript can be recovered when it fits. Longer
conversations still compact normally. Other runtime compaction policies and
GGUF budget defaults retain their previous behavior.

Retaining complete source can increase the first uncached follow-up's prefill
work. A cache hit can reduce later eligible waits; this is not an improvement
to fresh-chat decoding or a promise that every short conversation can cache.

Explicit output-format requests now take priority over default code fences in
the shared prompt guidance and built-in Coder persona. This removes the
conflicting instruction; it is not a guarantee that a model always follows
the requested format.
The existing inline Markdown configuration also preserved a synthetic raw
HTML document literally in a host check, so removing fences does not make
its HTML tags disappear through that parser. This is not phone UI execution.

All **61** focused host tests pass, including preservation of a complete HTML
source through brief follow-ups, recovery from an earlier compaction cursor,
over-budget compaction, continuation prompt contracts, the requested output
limit, ordinary GGUF/Gemma profiles, title behavior and the existing MiniCPM
memory/thermal admission. The native context/output-boundary checks, **32**
App Store verifier tests and repository hygiene checks pass. Three older GGUF
test expectations still assumed pre-existing reply caps; they were updated to
the already-shipped behavior. The expanded host harness initially included
unrelated device tests; its selection was corrected before the passing run.

Native source, all three framework slices, metrics ABI, expert routing,
model catalog and model preparation are unchanged from build 14. No model
weights were downloaded for this correction. A native cache hit was already
validated in build 14's host tests; this follow-up changes which conversation
source reaches that unchanged engine. The effect on this phone still needs
measurement. Build **1.0.1 (15)** has passed the shipping-Xcode Release
generic-iPhone app/test-bundle compile, signed archive and distribution-export
verification. Apple processing is **VALID** and internal TestFlight is
**IN_BETA_TESTING**. English testing notes were published and read back;
the local IPA checksum was verified after upload. All 1,191
frozen source/framework/test inputs and 18 locked dependency checkouts match
the verified candidate; all six MiniCPM download links passed fresh checks.

- Build 15 ID: `f766a8c9-666f-4e07-b09c-20ba34bed5e7`.
- Uploaded: `2026-10-15T00:04:06+03:00` Europe/Istanbul.
- IPA: `build/appstore/1.0.1-15/export/OnDeviceMax.ipa`.
- SHA-256: `576ab2a918e1c8a82dd57007b63572c91b444ddf6ea248b564cd23b5b4ec329d`.
- Evidence: `build/minicpm-build14-context-audit-2026-10-14`.

For a more reliable cache test, paste the complete previously generated HTML
into a new chat and ask the model to reply only `READY`. Then type two short
follow-ups in that same foreground chat. The longer input can populate the
existing batch checkpoint without a three-minute generated answer heating the
phone. As before, the diagnostic's positive `reused` count is the criterion.

## Remaining decode work

The publisher's advertised phone speed combines LES, mixed quantization and
DSpark. The app uses the first two; build 14 does not add a draft model or
speculative decoder. [Official release documentation](https://github.com/OpenBMB/MiniCPM-V/blob/main/docs/minicpm_v4dot7_en.md).

DSpark remains a separate integration: target hidden-state transfer, target
verification, rejected-token rollback, sampler correctness, memory admission
and fallback all need validation before enabling it. Its licensed checkpoint
is trained for this exact target/tokenizer; it is not a switch in the current
adapter. [Official DSpark model card](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-DSpark).

## Storage cleanup and release

At the user's request, MiniCPM5-2B was removed from BeetCode's managed storage
and its installed entries in BeetCode and Vamp Companion were removed. The
apps were not running, no model file was open and no download manifest was
active. Other installed entries were preserved. This recovered about 4.8 GB;
inactive Xcode intermediates, indexes and compiler caches recovered another
7.1 GB. Source, other models, signed releases, preferences and conversations
were preserved.

The build 14 candidate uses the existing distribution setup. All three native
slices have matching 200-byte metric headers, nine isolated C exports and the
required minimum-OS/version metadata. The model catalog and preparation format
are unchanged; all six MiniCPM download URLs passed fresh length/header probes.
The temporary validation weights were removed after testing, leaving about
20.2 GB free before the production compile began. Receipts and test evidence
were retained.

Build **1.0.1 (14)** passed shipping-Xcode generic iPhone `build-for-testing`
for the app and test bundles, signed archive verification and distribution
export verification. Apple processing is **VALID** and internal TestFlight is
**IN_BETA_TESTING**. The existing **Me** group has access to all builds.
The English What to Test notes were published and read back. The subsequent
user phone recording above measures decode speed, but does not verify a
prefix-cache hit. Automated device test execution remains unverified; the
production compile gate is not an on-device run.

- Build ID: `241525f2-27bd-4aa1-9761-9e2cc2d77e7f`
- IPA: `build/appstore/1.0.1-14/export/OnDeviceMax.ipa`
- SHA-256: `e08b1830eb8cbcf0dd2a70d4f7c5f6ee780d1af58ac7b8a0d09eff18563ac460`
- Frozen production inputs: 1,089; clean, locked package checkouts: 18.
- Evidence: `build/minicpm-build13-decode-audit-2026-10-14`.

Test the existing 35B download in one longer conversation with at least two
follow-ups, then export diagnostics without restarting. The new
`MiniCPM prefix cache` entry reports eligibility, reused tokens and state size.
Fresh short chats may show zero reuse. Check Stop, Continue, changing chats,
switching models and Lens. Decode-speed improvement on the phone is not
demonstrated by this release.
