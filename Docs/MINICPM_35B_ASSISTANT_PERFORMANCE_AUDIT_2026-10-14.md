# MiniCPM 35B Assistant performance audit

October 14, 2026 · OnDevice: Max 1.0.1 (9)

This is the audit of build 9 before tuning. The
[implementation and TestFlight report](TESTFLIGHT_MINICPM_PERFORMANCE_2026-10-14.md)
records the three completed adjustments, staged host measurements and accepted
build 10.

The [build 11 follow-up](MINICPM_35B_BUILD11_WEB_OPTIMIZATION_AUDIT_2026-10-14.md)
compares the current publisher sources after the user confirmed long replies
complete but phone speed remains around 6 tokens/s. It includes the explicit
publisher iPhone benchmark and the remaining cache, batching and DSpark gaps.

There are useful adjustments to test, especially a dedicated text-only loader,
larger prompt-processing batches and an expert cache sized for available memory.
The user reported approximately **10 seconds to answer and 6 tokens/s in
Assistant on iPhone 17 Pro Max**. These are user observations. The prompt length,
output length, cold/warm state, thermal state and whether the ten seconds means
first token or completed answer are unknown. No online physical iPhone was
available on this host, so this audit does not establish a new phone throughput
or promise a particular improvement.

## Findings and priorities

| Priority | Finding in the shipped code | Recommended adjustment | Primary benefit |
| --- | --- | --- | --- |
| 1 | Assistant constructs `MiniCPMV47StreamingVLM`, which always initializes the full vision encoder | Give Assistant a text-only initialization and tokenization path; keep the image-capable path for Lens | Less load work and memory pressure; makes room for useful text-runtime buffers |
| 1 | The shared expert bank has 40 slots and the physical prompt batch is fixed at 4 tokens | Benchmark larger banks with matching safe batches, starting with 64/8 and 128/16, then 256/128 if measured headroom permits | Faster prompt preparation, especially for follow-up chat history |
| 2 | Decode uses a fixed 16-slot cache plus 8 prefetch slots per layer | Benchmark 24 cache slots after removing the unused vision encoder, with explicit admission accounting | Potential improvement to generated tokens/s by reducing expert reads |
| 2 | Compute and expert I/O both use four threads | Sweep I/O 1/2/4 and compute 2/4 independently on the phone | Test storage throughput, CPU contention and sustained thermal behavior |
| 3 | Every request clears the model's sequence state and evaluates the full rendered conversation again | Evaluate strict prefix reuse separately, with reset and recurrent-state correctness tests | Faster later turns in long chats |
| 3 | The adapter uses ordinary autoregressive decoding | Investigate DSpark only after measuring the simpler changes | Possible further decode improvement, with additional model, memory and rollback complexity |

The first two adjustments are the recommended implementation sequence. A
larger cache is a separate experiment; prompt batching and cache changes should
not be combined in the first comparison.

### 1. Assistant loads an unused vision encoder

`LlamaCppBridge.swift` creates the same streaming object used by Lens when
Assistant selects MiniCPM 35B. Its initializer calls `od_mini47_create`, and that
function unconditionally loads the projector with `mtmd_init_from_file`.
The pinned projector is **1,119,575,840 bytes**, about 1.1 GB on disk. Exact
resident-memory savings need measurement; file size is not a process footprint.

The text method sends no image, but it currently tokenizes through the loaded
MTMD context. Skipping the projector therefore requires a real text-only
tokenization/evaluation branch, not just passing a null pointer to the existing
implementation. Preserve ChatML, special-token handling, prompt/output counts,
sampler controls, output limits and cancellation. Lens should keep its current
image encoder and prepared-artifact validation.

The [official iOS loader](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/68f53d67a418dd6444659c39005dd5cc4097071c/MiniCPM-V-demo/Sources/Home/ViewController/MBHomeViewController%2BLoadModel.swift)
already distinguishes text-only expert inference from multimodal inference.
That is an implementation reference, not evidence of this app's speed gain.

### 2. Prompt processing is particularly conservative

The adapter sets `moe_slot_bank = 40`, `n_batch = 512` and `n_ubatch = 4`.
The 512-token logical batch still splits into physical batches of four. Native
logs from the previous Mac correctness smoke confirm four-token prefill steps
and repeated expert reads. Those logs establish the execution path, not iPhone
timings.

The worst-case routed expert union is `min(ubatch × 8, 256)`. It must fit the
shared bank. **Changing only the microbatch to 128 while leaving the bank at 40
is unsafe.** The pinned runtime supports a full 256-expert bank; at that size,
larger batches can fit the complete expert union. Its memory cost is shared
across layers rather than multiplied by all forty layers.

The official demo defaults to a 256-slot bank and adapts prompt batches using
128/256/512/1024/2048 steps, subject to bank capacity and memory constraints.
Its own source describes different outcomes for short and long prompts.
Therefore a fixed desktop-size batch is not a justified replacement for the
current setting.
[Official batch policy](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/68f53d67a418dd6444659c39005dd5cc4097071c/MiniCPM-V-demo/MTMDWrapper/Bridge/MBMtmd.mm),
[official 35B settings](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/68f53d67a418dd6444659c39005dd5cc4097071c/MiniCPM-V-demo/Sources/Settings/ModelConst/MiniCPMModelConst.swift).

### 3. Expert-cache capacity is a decode candidate

The current decoder has a uniform cache of 16 slots plus eight prefetch slots
per layer, with eight actual routed experts preserved. The native source uses a
unified LRU window, so the complete 24-slot width matters. Increasing the cache
may reduce storage traffic. It also allocates more GPU-visible expert memory.
The official demo computes its cache size from both process headroom and a
footprint ceiling, with reserves for other runtime allocations; its larger
settings should not be copied without the app's own admission policy.

For this exact prepared model, each packed expert occupies **1,351,680 bytes**
and there are forty MoE layers. Capacity arithmetic gives:

| Shared bank / physical batch / cache + prefetch | Extra expert-weight capacity versus build 9 |
| --- | ---: |
| 40 / 4 / 16 + 8 | Baseline |
| 64 / 8 / 16 + 8 | 30.94 MiB |
| 128 / 16 / 16 + 8 | 113.44 MiB |
| 256 / 128 / 16 + 8 | 278.44 MiB |
| 256 / 128 / 24 + 8 | 690.94 MiB |
| 256 / 128 / 32 + 8 | 1,103.44 MiB |

These totals cover changed expert-weight buffers only. Compute buffers, Metal
allocation overhead, KV/recurrent state, CPU buffers and app memory must also
be measured. Removing the text path's vision encoder may provide headroom for
some of these candidates, but subtracting file sizes does not prove admission
is safe.

The cache currently parks and invalidates its mappings after every generation.
Retaining it indefinitely would add idle memory cost, and simply disabling
parking does not establish valid cache reuse across prompt/decode transitions.
Keep cleanup behavior while measuring the first tuning changes.

### 4. Prefetch depth and threads need controlled tests

Increasing prefetch depth can read additional experts that are never used.
Compare depths 4 and 8 with the same total cache footprint; otherwise changed
LRU capacity can be mistaken for a prefetch improvement. Preserve top-eight
computation throughout.

The expert I/O thread setting is cached by a static initializer in the pinned
runtime. Each I/O-thread profile needs a fresh process; changing its environment
variable after the first load is not a valid comparison. The source's
single-thread path reads every pending expert, allowing an I/O 1/2/4 sweep
without changing which experts the model uses.

## Interpreting the speed reading

Assistant displays the native `result.tokensPerSecond`. Its timer starts after
prompt evaluation. The reading includes the sampling/streaming/decode loop but
excludes model loading and prompt preparation. Consequently, faster prompt
processing can shorten the wait without raising the displayed 6 tokens/s.

OpenBMB's LES document measures decode speed independently too. Its published
17.39 tokens/s result is for an **M4 iPad with 16 GB**, using the full pipeline
including DSpark; the same table reports 14.92 before that speculative stage.
These results do not establish a 13–17 tokens/s target for this app on iPhone.
[Publisher LES benchmark](https://github.com/OpenBMB/llama.cpp-omni/blob/0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2/docs/les/lookahead-expert-scheduling.md).

The official mobile app points to runtime revision
`96bbf61710d44421ea54e63f5194f9b17c20d877`; this app uses the separately pinned
`0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2`. Its broader bridge is not a drop-in
replacement for the app's isolated native ABI. The initial text-only, bank and
cache experiments can be developed against the existing pin.

## Measurement and acceptance plan

Start by recording load duration, prompt tokens, prefill duration, time to first
token, output tokens, decode duration, peak process footprint, available memory
and thermal state. Store numeric metrics only, with no prompts or output text.

Run a cold first answer and at least five warm repetitions for a short fresh
chat, a roughly 256-token prompt and a roughly 1,024-token conversation. Alternate
baseline and candidate runs with the same model, sampling, output budget and
fixtures. Keep Low Power Mode, charging, temperature and background downloads
consistent. An answer's output length must be recorded to compare decode rates.
Report median latency and rate, plus worst observed memory. Follow with a
sustained session to check thermal behavior.

First compare the text-only loader against build 9 with its original bank and
cache. Then sweep bank/batch pairs independently. Then compare cache 16 and 24
under the existing coordinated memory policy. A setting becomes a default only
after it shows a repeatable benefit without correctness, cancellation,
residency, background-cleanup or thermal regressions. Preserve the 4,096-token
context and 256-token output ceiling in these comparisons.

Prefix reuse needs additional checks for the model's recurrent state, prompt
edits, compaction, interrupted replies and model switches. DSpark additionally
needs its licensed draft artifact, integrity checks, memory admission and exact
target-model verification/rollback. These belong after the simpler changes.

## Audit verification and evidence

The four inspected runtime/bridge/Assistant source files match the fingerprint
of shipped build 9. Candidate expert-capacity calculations passed, including the
check that a 128-token microbatch cannot fit the current 40-slot bank. The
release native framework is already compiled with `-O3 -DNDEBUG`; this is not a
debug-build performance issue.

Ignored evidence is in `build/minicpm-performance-2026-10-14/`:
`audit-verification.json`, `tuning-capacity-model.json`, the official app tree
and a manifest of the exact reference source hashes. Original sources reviewed
were `ODMiniCPM.cpp`, `MiniCPMV47VisionBackend.swift`, `LlamaCppBridge.swift` and
`CodingAssistantService.swift`. This audit produced no new device measurements
or changed inference defaults.
