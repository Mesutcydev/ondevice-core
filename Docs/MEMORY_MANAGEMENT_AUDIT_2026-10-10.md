# Memory management audit — 2026-10-10

The owner requested withdrawal of build 83 and fixes for the reported crash,
then an audit of memory management. Existing working-tree changes are retained.
Scope: heavy assistant, vision and image runtime admission, ownership,
cancellation, model switching, allocator caches, and background cleanup.

## Review withdrawal

App Store Connect confirmed **OnDevice: Max 1.0 (83)**, app `6818199563`,
version `9c6688e5-8a6f-4072-ad0c-b7ae9c84cebd`, as **DEVELOPER_REJECTED**
before the replacement submission.
Cancellation of submission `c38c130e-b3d1-4ecb-870a-c728136b7e32` completed;
its submission state is **COMPLETE**. The uploaded build remains available
in TestFlight. The owner subsequently requested a replacement beta;
[build 84 was uploaded and verified](TESTFLIGHT_MEMORY_FIXES_2026-10-10.md).
After the owner reported that it works fine and approved submission, build
**84** was submitted for App Review. The version and new review submission
`4886cf50-4729-48ec-81ee-8c6a57a6410f` now show **WAITING_FOR_REVIEW**.

## Evidence and interpretation

The supplied build 83 diagnostics show two admission/load requests for the
same imported MiMo/Qwen 9B MLX model within 17 milliseconds. Both early
snapshots saw over 6.35 GB available. The last recorded unload began at
6,088,595,592 bytes of footprint with only 353,855,352 bytes of headroom.
The device's reported process ceiling was 6,442,450,944 bytes despite
having 12 GB of physical RAM.

The source confirms a duplicate-admission race and runtime references that
could outlive teardown. The MLX gate serializes native operations, but that
alone does not serialize preparation or the lifetime of returned containers.
The diagnostic records an unclean exit, not an OS Jetsam report; it cannot
establish whether the final kill was memory pressure or a watchdog timeout.
The owner's earlier successful use is preserved as a regression report.
No model-specific prohibition or reduced hardware allowance is introduced.

## Findings and fixes

| Finding | Resulting behavior |
| --- | --- |
| Assistant checked `.loading` before several awaits, then set it only after teardown/admission. Multiple callers could pass the check. | `ModelLoadCoordinator` owns the operation before its first await. Repeated requests join one job; cancellation keeps admission closed until native work retires. Automatic requests also defer to an explicit model switch. |
| Unload invalidated a result token but did not join the full loader. That loader could retain a multi-gigabyte container while teardown measured or reclaimed memory. | External cleanup cancels and joins the load job before releasing runtimes. Internal retry cleanup preserves its owner and does not await itself. MLX containers are committed or discarded inside the GPU gate, and gate tasks return no container. |
| Normal assistant load estimates assumed a bounded allocator cache, while the loader inherited the global unbounded cache. | Load uses the same family cache bound as generation (64 MiB normally, zero for the existing large-model profiles/low-memory mode). Cache reclamation and restoration of previous limits remain inside the gate. No global allocator setting changes. |
| Lens and FastVLM could republish or report progress from a load superseded by unload, including a reload of the same repository. | Both use the existing request-lifetime policy: cancellation invalidates publication, admission stays closed until retirement, and stale progress/completions cannot affect a later load. Stale containers are released within the gate. |
| Image generation used memory sampled before downloads and gate waiting. Lens/image allocator caps could also invent a 1–2 GiB allowance under small or zero headroom. | Admission samples again immediately before native allocation. A shared total-allocation budget adds already-charged MLX buffers back once and subtracts the reserve. Zero/insufficient headroom refuses work instead of invoking a fixed floor or fallback grant. |
| Core AI admission and Edge0 pool sizing measured memory before competing runtimes drained. | They measure after cleanup, avoiding false refusals caused by the runtime being replaced. Every backend also waits for pending assistant cleanup before loading. |
| Foreground load recovery could reselect a saved default instead of the interrupted conversation's model. | Recovery joins the cancelled loader and resumes the explicit active selection. Ordinary unloaded models remain lazy. |

## Retained safeguards and limitations

`ProcessMemoryBudget` continues to honor the actual kernel grant, charge
resident allocations once, and refuse unknown accounting. Tensor sizing
reads bounded safetensors headers rather than model payloads. Import copies
stay off the main actor. Critical memory pressure, thermal refusal, inference
cancellation, and background teardown keep their coordinated paths.

Model/config estimates remain estimates. Unsupported architectures use a
conservative fallback, and native loading is not safely interruptible halfway
through a Metal operation. TestFlight entitlement diagnostics do not authorize
an assumed larger memory grant. Real MiMo/Gemma load, generation, repeated
switches and background/foreground recovery need acceptance on TestFlight
**1.0 (84)** on the owner's iPhone. Previous Xcode device testing was blocked by
installation error `0xe8008018`; this audit does not claim a new device test.

## Validation

- **10** deterministic load/lifecycle tests pass, including duplicate
  preparation requests, cancellation propagation, delayed native retirement,
  release of load-local references, immediate retry, and stale vision tickets.
- **140** memory-budget checks pass, including total allocator accounting,
  zero headroom, small grants, reserves and saturating byte math.
- **6** existing quantization policy tests pass.
- Repository hygiene validation and `git diff --check` pass.
- Shipping Xcode **27A266a** passes the final Release production
  `build-for-testing` check with **TEST BUILD SUCCEEDED**. All **12** captured
  compile input hashes, including both package-lock copies and the generated
  project, remain unchanged after compilation.

Evidence is retained locally under ignored `build/memory-audit-2026-10-10/`.
The final compile uses the App Store model policy, pinned package versions,
the generic physical-iOS destination, and no code signing. It is a compile gate,
not evidence of model quality or real-device memory peaks.
