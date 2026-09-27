# RAM calculation audit — 2026-09-26

The memory policy must estimate the next allocation and compare it with live
process headroom. Physical RAM, file size, process footprint, and available
allocation capacity are different quantities. An increased-memory entitlement
does not justify replacing a lower kernel report with a percentage of RAM.

## Findings and changes

| Finding | Change |
| --- | --- |
| Zero headroom invoked a physical-RAM fallback or skipped the final gate. | Zero now refuses additional loads, including reduced-reserve loads. Only platforms without the iOS reporting API use a heuristic fallback. |
| Separate footprint/headroom reads could describe different allocation states; failed footprint reads could imply an empty process. | `ProcessMemoryBudget` resolves a fresh `TASK_VM_INFO` snapshot, including `limit_bytes_remaining` when available. Missing footprint accounting admits no allocation. |
| Picker verdicts added loaded-model estimates to headroom that already deducted their allocations. | Resident memory is charged once. A resident target does not need a second weight allocation. |
| Every bounded MLX model was assigned only 250 MB beyond weights. | Supported models calculate KV cache, recurrent state, prefill workspace, allocator cache, and runtime slack separately. The 250 MB reserve is no longer the entire runtime estimate. |
| Qwen35's factory in the pinned MLX release returns `KVCacheSimple` even when `maxKVSize` is requested. | Assistant replaces ordinary attention caches with `RotatingKVCache` for bounded profiles; recurrent and custom caches are preserved. |
| Rotating caches were described as 4-bit although the pinned library does not quantize them. | Estimates use activation precision for rotating caches. Eligible plain caches include packed values and quantization scales/biases. |
| Increasing reply length after load could outgrow the load-time estimate. | Supported text-only MLX generations recheck workspace using the tokenized prompt and requested output, without charging resident weights again. |
| Admission could age while waiting for the serialized MLX gate. | A second live check runs inside the gate immediately before native loading. |
| Text and Lens IDs could use the same text-only tensor estimate. | Lens sizing has a distinct `vision:` key and includes the complete weight pack. |
| Corrupt/missing tensor shards could yield a partial small weight total; filesystem allocation was treated as weight size. | Header inspection rejects missing indexed shards, invalid/overlapping offsets, and truncated payloads. Fallbacks use logical weight-file sizes and exclude unrelated files. |
| Installation invalidation did not clear the separate tensor/model-type caches. | Those metadata caches now invalidate with the advisor cache. |
| A crash trail lacked the exact admission inputs. | Load preflight records estimated peak, footprint, kernel headroom, policy ceiling, and available bytes. It records no prompt or output. |

The existing thermal, pressure, lifecycle, and serialized-residency policies
remain in place. The explicitly confirmed experimental memory bypass remains
available; it is not evidence that an oversized model can run.

## Current calculation

```text
ceiling = min(platform policy cap, current footprint + kernel headroom)
available = min(kernel headroom, max(0, ceiling - current footprint))

model peak = text tensor bytes
           + KV cache
           + recurrent state
           + estimated prefill scratch
           + allocator cache allowance
           + runtime slack

admit when model peak + admission reserve <= available
```

GQA/MQA models use KV-head count, not query-head count. Qwen35 uses its full
attention interval and separately accounts for FP32 recurrent state and
convolution history. Cache growth includes allocation blocks and prefill
overshoot. For unknown architectures, the estimator keeps a heuristic instead
of applying a precise-looking but unsupported formula. Unknown model sizes do
not receive a comfortable verdict.

## MiMo OptiQ on the user's iPhone 17 Pro Max

The supplied build-70 log reports 12.26 GB physical RAM and 6.39 GB kernel
headroom after relaunch. Immediately before the MiMo load, the previous model
was drained to 132,745,656 bytes. The old calculated headroom was 8,367,254,344
bytes: those two numbers sum to exactly the synthetic 8.5 GB cap. MiMo started
loading at 21:18:00.253 UTC; the next launch recovered an unclean exit at
21:18:06.590 UTC, with no successful MiMo load entry in between.

This is consistent with a weight-load OOM, not a long-context cache overflow.
The app's unclean-exit marker cannot conclusively distinguish Jetsam from a
watchdog termination. The 6.39 GB report is after relaunch, not an atomic
measurement of the earlier failed load.

The public model metadata inspected on this date reports two safetensors
shards totaling 7,100,710,126 bytes. Its OptiQ configuration mixes 4-bit and
8-bit tensors, including 8-bit embeddings and many projection layers. The
model name alone therefore understates its weight cost.

Using those complete shard sizes as a slight upper bound for tensor bytes,
the new estimator gives this 2,048-token bounded text profile:

| Component | Decimal GB |
| --- | ---: |
| Weights, including small file headers | 7.101 |
| Unquantized attention cache | 0.071 |
| Recurrent/convolution state | 0.052 |
| Estimated prefill/cache transient | 0.086 |
| Runtime slack | 0.250 |
| Estimated peak | 7.560 |
| Normal admission requirement, including 0.5 GB reserve | 8.060 |

This is an estimate, not a measured phone peak. A 6.39 GB live budget cannot
support the full 7.10 GB resident weights. If a correctly installed build
receives enough actual headroom, admission can allow it; changing a constant
cannot create that headroom. A smaller quantization or a compatible GGUF
storage-backed runtime is a separate option, with its own compatibility and
performance validation.

Sources: [MiMo config](https://huggingface.co/mlx-community/MiMo-V2.6-Distill-Qwen-9B-OptiQ-4bit/blob/main/config.json),
[MiMo file metadata](https://huggingface.co/api/models/mlx-community/MiMo-V2.6-Distill-Qwen-9B-OptiQ-4bit/tree/main?recursive=true&expand=false).
Only configuration and file metadata were fetched; no weights were downloaded.

## OnDeviceLAS comparison

Reviewed `/Users/m/Desktop/OnDeviceLAS` without changing it. Its
`MemoryAdvisor.resolvedProcessCeilingCandidate` checks the installed signature's
increased-memory entitlement, then chooses the larger of the kernel ceiling
and the physical-RAM estimate when entitled and not in low-power mode. Its
high-memory iPhone policy cap is 9.2 GB. That more permissive admission rule
does not prove iOS grants 9.2 GB.

LAS also has useful load-phase diagnostics, measures the exact staged model
directory, and includes a family-specific KV estimate. Its context-configuration
rewrite enables YaRN for selected long-context models; it does not shrink
MiMo's weights. The current app already reports signature/profile memory
entitlement flags in exported diagnostics. Compare those flags and fresh kernel
headroom on the actual installations before attributing different behavior to
the UI or model runtime.

## Build 72 device follow-up

The user's export at 2026-09-26T08:27:40.610Z confirms build 72 on the same
iPhone18,2 and iOS 27.2.0. The increased-memory entitlement is present in both
the installed signature and provisioning profile. At MiMo admission, the app
records 51,955,648 bytes of footprint and 6,927,366,208 bytes of kernel
headroom. Their sum is 6,979,321,856 bytes: exactly 6,656 MiB (6.5 GiB, or
6.979 GB). The app's 8.5 GB policy cap is not the limiting factor in this sample.

The installed model's estimated peak is 7,559,517,824 bytes, exceeding live
headroom by 632,151,616 bytes even without the normal reserve. With the
500,000,000-byte admission reserve, the requirement is 8,059,517,824 bytes.
This trail contains an admission entry and no native MiMo load or crash entry;
it is consistent with the intended pre-load capacity refusal.

The SDK's `os/proc.h` explicitly documents `os_proc_available_memory()` as
equivalent to `task_vm_info.limit_bytes_remaining`. Using a coherent task-info
sample therefore does not explain LAS's higher number. LAS's local source
instead selects the larger of the kernel ceiling and a physical-RAM fraction
when its signature is entitled, then caps it at 9.2 GB. That can display roughly
2.2 GB more total capacity without evidence of a larger kernel grant. A LAS
diagnostic of its raw kernel values or a successful generation with this exact
model would be needed to establish a real runtime advantage.

Apple's [increased-memory entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
states that extra memory is device-dependent and directs apps to query available
memory. Presence of the entitlement does not itself establish a 9.2 GB budget.

## Validation and remaining uncertainty

- `bash scripts/test_memory_budgets.sh`: 134 portable assertions passed,
  including exhausted budgets, overflow, cache dimensions/precision,
  recurrent state, MiMo's lower-kernel-limit scenario, response growth, and
  damaged/missing tensor shards.
- App-level regression coverage in `DeviceTierAdvisorTests` exercises the
  actual advisor verdicts and MLX cache types. Device `build-for-testing`
  passed for the app and test targets; it does not execute tests on a phone.
- Repository hygiene validation passed.
- No application installation, IPA packaging, or physical-device memory or
  generation-quality measurement was performed by this audit.

Scratch space, compiler/load transients, and runtime slack still need device
calibration. Core AI, GGUF paging, vision activation costs, and unsupported
MLX architectures retain their existing specialized or heuristic estimates.
Future peak calibration should be keyed by model content, runtime version,
device/OS, and execution profile. A successful load alone must not lower the
estimate for a long generation or override a smaller live kernel budget.

API semantics were checked against the installed iPhoneOS 27 SDK's
`os/proc.h` and [Apple's available-memory API](https://developer.apple.com/documentation/os/os_proc_available_memory).
Cache behavior was checked against mlx-swift-lm 3.31.4, revision
`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`, specifically `KVCache.swift` and
`Qwen35.swift`. No dependency versions were changed.
