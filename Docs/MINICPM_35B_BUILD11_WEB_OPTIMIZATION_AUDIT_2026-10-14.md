# MiniCPM 35B performance follow up for build 11

October 14, 2026 · OnDevice: Max 1.0.1 (11) · Assistant on iPhone 17 Pro Max

The next performance pass should compare larger expert caches and adaptive
prompt batches on the phone, with each change admitted through the existing
memory and residency policy. These are concrete differences from the publisher's
iOS implementation. DSpark is another credible candidate, but requires a draft
model and correct speculative verification rather than a configuration switch.

The user confirms that long responses now complete, while generation remains
around 6 tokens/s and the initial wait feels unchanged. The supplied diagnostics
end after launch, at a 62.4 MB footprint. They do not include the loaded runtime
or a generation. Consequently, they cannot identify which stage dominates that
wait or whether the 16-slot or 24-slot profile ran.

## Publisher results and their meaning

OpenBMB explicitly claims **13+ tokens/s on iPhone 17 Pro Max**, using LES,
fine-grained mixed quantization and DSpark together. The app already uses LES
and the official `mix_q3gud_im` weights, repacked into contiguous expert files.
Its Assistant decoder does not use DSpark.
[Official model card](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B).

The separately published M4 iPad benchmark goes from **14.92 tokens/s with LES
and mixed quantization to 17.39 with DSpark**, about 17% more throughput. That
increment belongs to the iPad experiment; it is not an estimate of the gain on
this phone. Cache, storage access, prompt length and runtime settings also need
comparison before attributing the difference to DSpark.
[LES benchmark](https://github.com/OpenBMB/llama.cpp-omni/blob/0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2/docs/les/lookahead-expert-scheduling.md).

The [earlier audit](MINICPM_35B_ASSISTANT_PERFORMANCE_AUDIT_2026-10-14.md)
describes build 9. Its iPad benchmark should be read alongside the explicit
iPhone claim above. The [build 10 report](TESTFLIGHT_MINICPM_PERFORMANCE_2026-10-14.md)
records the completed text-only loader, larger bank and 24-slot experiments;
their host results do not establish a phone improvement.

## Current Assistant settings

| Setting | Build 11 behavior |
| --- | --- |
| Vision encoder | Skipped for Assistant; Lens keeps its image-capable runtime |
| Shared expert bank | 256 slots |
| Prompt microbatch | Fixed at 128; logical batch 512 |
| Expert cache | 16 slots, or 24 with at least 5.5 GB live headroom and nominal thermal state, without Low Power Mode or pressure cooldown |
| Lookahead prefetch | 8 slots per layer |
| CPU and expert I/O threads | 4 each |
| GPU and weight mapping | Full GPU offload; mmap enabled; Flash Attention AUTO |
| Context and output | 4,096-token context; reply bounded by user/thermal policy and actual remaining context |
| Conversation state | Cleared before each request; full conversation evaluated again |
| Expert memory after a reply | Parked; expert-cache mappings invalidated |
| Thinking | Explicitly disabled in the Assistant prompt |
| Speculative decoding | Absent from the app adapter |

These settings are in `Native/MiniCPMV47/ODMiniCPM.cpp`,
`MiniCPM35BTextProfile.swift` and `CodingAssistantService.swift`. The footer
measures the decode loop, excluding model loading and prompt evaluation. Faster
prompt processing can therefore improve waiting time without changing tokens/s.

## Experiments in order

### 1. Increase the cache within a measured memory budget

The publisher's iOS settings request **48 cache slots on 12 GB devices**, then
clamp the request to available process memory and a footprint ceiling, with a
reserve for the rest of the runtime. Our maximum is 24. This makes cache capacity
the first decode-speed experiment, rather than establishing that 48 is safe or
faster here.
[Official cache policy](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/d07e77fc11d0905550d964f7e8c4b4f9e5560972/MiniCPM-V-demo/Sources/Settings/ModelConst/MiniCPMModelConst.swift).

Compare 24, 32, 40 and 48 while keeping the bank, microbatch, eight routed
experts and eight prefetch slots fixed. For the installed model, packed expert
storage is 1,351,680 bytes per slot over 40 layers:

| Cache slots | Cache plus prefetch capacity | Additional capacity over 24 |
| --- | ---: | ---: |
| 24 | 1,650 MiB | 0 |
| 32 | 2,062.5 MiB | 412.5 MiB |
| 40 | 2,475 MiB | 825 MiB |
| 48 | 2,887.5 MiB | 1,237.5 MiB |

This is expert-buffer capacity, not the total app footprint. Admission must
also include nonexpert weights, compute buffers, recurrent/KV state and app
overhead. Start with 32, retain fallback to 24/16, and preserve pressure,
thermal, cancellation, unload and background cleanup. A profile becomes a
default only after repeated phone measurements show a benefit at a sustainable
footprint. Lens should keep its existing profile during this experiment.

### 2. Adapt prompt batches to prompt length

The official bridge chooses microbatches from a 128/256/512/1024/2048 ladder,
subject to expert-bank capacity and a ceiling when the decode window is active.
Our fixed 128 can cause repeated expert reads for longer conversations.
[Official prompt batch selection](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/d07e77fc11d0905550d964f7e8c4b4f9e5560972/MiniCPM-V-demo/MTMDWrapper/Bridge/MBMtmd.mm).

Begin with 128, 256 and 512, changing this separately from the cache. Retain
128 for short prompts and increase only when the measured prompt length and
compute-memory budget justify it. Keep the full 256-slot shared bank and
4,096-token context. Select or rebuild the context before evaluating a fresh
sequence; changing it during an active sequence would discard state.

### 3. Tune storage threads and prefetch after the cache comparison

Compare I/O threads 1/2/4 and CPU threads 2/4 independently. The runtime caches
the I/O setting at first use, so each I/O profile requires a fresh process.
Measure prefetch depths 4 and 8 at the same total expert-window capacity to
separate prediction effects from extra cache memory. Keep mmap enabled; it is
already enabled in both implementations.

Do not enable the runtime's skip-read path or reduce its eight routed experts.
Those would change the computation used to produce the answer.

### 4. Reuse an exact conversation prefix

The app clears sequence memory for every MiniCPM request. Reusing a verified
token prefix could shorten follow-up latency by evaluating only the new suffix.
This is a later-turn improvement; it cannot remove the first request's initial
prompt evaluation.

The model mixes attention and recurrent state. Reuse needs exact token-prefix
matching and correct state handling for the final generated token and EOS.
Prompt edits, conversation changes, compaction, cancellation and model switches
must reset or restore the correct state. Keep expert-memory parking and the
shared residency policy while testing this independently.

### 5. Add DSpark as a guarded Assistant experiment

The licensed official draft has about **389 million parameters** and is trained
for this exact target model and tokenizer. Its reported acceptance length varies
by task, so draft length should be adaptive rather than copied from a server
example.
[Official DSpark checkpoint](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-DSpark).

An official F16 GGUF is now available in the Apache 2.0 model repository:
[`dspark-MiniCPM-V-4_7-35B-A3B-F16.gguf`](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/blob/3c3f7e84f14a760ff26d17ab5932d4aa996227c0/dspark-MiniCPM-V-4_7-35B-A3B-F16.gguf).
Its listed size is 789,442,368 bytes and its LFS SHA-256 is
`dbeca717b96448ecbb2240864ae00d2f90fe069bc3a8ce08c58084c8b7b96c0f`.
Use this file directly for a prototype, or derive Q8 and record its checksum;
both paths need target-compatibility validation before integration. The smaller
community repack has no declared license in its Hugging Face metadata; use the
official source for provenance.

The pinned runtime already contains DSpark source support. Integration must
add a draft context, target hidden-state transfer, verification and rejected-token
rollback inside the isolated native adapter. Add explicit memory admission and
fallback to ordinary decoding. Begin with small verification batches that fit
the actual expert window; the adapter currently limits window batches to four
rows. Test greedy token agreement, sampler behavior, EOS, context exhaustion,
long replies, continuation and cancellation before enabling it for users.

The publisher's mobile switch is also off by default and has memory guards.
Copying its bridge wholesale would bypass the app's isolated ABI and coordinated
residency design.
[Official mobile DSpark guards](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/d07e77fc11d0905550d964f7e8c4b4f9e5560972/MiniCPM-V-demo/Sources/Settings/ModelConst/MiniCPMModelConst.swift#L538).

## Runtime version comparison

The official mobile app currently points to `tc-mb/llama.cpp-omni` revision
`96bbf61710d44421ea54e63f5194f9b17c20d877`. Our isolated runtime uses the OpenBMB
snapshot `0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2`.

A complete comparison against the mobile revision found **3,437 matching files**
and six differences: local build integration, a copyright line, two LES wording
changes and the declaration/location of the image-slice setter. Expert loading,
LES scheduling, Metal kernels, the Qwen 3.5 MoE implementation and speculative
code match. This comparison provides no decode-speed reason to update the pin.
Evidence is saved in `build/minicpm-web-optimization-2026-10-14/`, including the
full tree comparison, source hashes and the six diffs.

## Phone diagnostics and the next measurement

The supplied launch snapshot reports a 6.44 GB app limit despite 12.26 GB physical
memory, nominal thermal state and Low Power Mode off. The signature/profile
entitlement mismatch deserves a capability audit, but it does not establish that
the process can use more memory or that signing causes the speed reading.
Apple describes the limit as device-dependent and directs apps to measure live
headroom; it can change during the app lifecycle.
[Apple memory entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit),
[Apple available process memory](https://developer.apple.com/documentation/os/os_proc_available_memory).

Generate one longer answer and one follow-up, then export diagnostics without
restarting the app. Build 11 already records `GGUF assistant load`,
`GGUF generation start`, `MiniCPM text timings` and `GGUF generation complete`.
The timings include input/output token counts, prefill, first token, decode,
bank, batch and selected cache. Native `load` is the engine's construction time,
not a new load on every request; use the load events to distinguish cold and
warm requests. The diagnostic ring is in memory and a restart removes the
previous generation entries.

For each candidate, compare a cold answer and at least five warm runs of the
same short, medium and long synthetic fixtures. Record median time to first
token, decode tokens/s and sampled peak footprint, then check a sustained session
for thermals and cancellation. Preserve the completed long-response fix throughout.

This audit describes the build 11 baseline. The subsequent cache and prompt
implementation is recorded in the
[build 12 report](TESTFLIGHT_MINICPM_TUNING_2026-10-14.md).
