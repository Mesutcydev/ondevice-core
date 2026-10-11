# Edge0-35B performance triage — 2026-10-02

The user reports approximately 6 tokens/sec on an iPhone 17 Pro Max with the
latest TestFlight build, consistently across tests. The user supplied a complete
counterbalanced A/B report (run `94DAC499-28D6-4728-AD4A-A8D7A1B8304B`).
The physical phone is unavailable to this Mac; no live native trace was captured.

## Reference and measurement

The [upstream iOS README](https://github.com/Edge0-AI/Edge0/blob/af5cd15e6b85c32ada9d23b4ba7b3c73b3661a94/ios/README.md#performance)
reports 6.4 decode tokens/sec for the 35B model on iPhone 16 Pro, iOS 26.6.2.
This is a different device and scenario, so it establishes a comparison point,
not a limit or expected rate for the user's iPhone 17 Pro Max.

`Edge0_35BEngine.generate` records separate prefill, first-token latency, decode
and end-to-end throughput. Its completion event currently sends end-to-end
throughput, which includes prompt processing, to the chat speed indicator.
The existing 35B speed diagnostic reports both decode and end-to-end rates.

## Storage layout

New pinned catalog downloads prepare the contiguous expert layout through
`HFModelDownloadManager.finishDownloadedModel`. Existing complete canonical
downloads can remain ready without starting a new preparation. The runtime
accepts either layout and logs `expertStorage=safetensors` or
`expertStorage=repacked-v1` when loading. The user's current layout has not
been established; do not assume the automatic preparation has run.

Repacking preserves tensor bytes and routing math. Its effect on this phone's
decoding speed needs measurement. Earlier diagnostic candidate flags remain
at their validated defaults; none were promoted based on this report.

## Next evidence

Four scored trials completed with identical output sequences, nominal thermal
state throughout and a stable session. The benchmark fixed the cache at 512 MiB
(303 slots), four concurrent reads, 118 prompt tokens and 64 output tokens.

| Metric | Exact (two trials) | Bounded Prefetch (two trials) |
| --- | --- | --- |
| Decode tokens/sec | 5.78, 6.09 (median 5.94) | 7.72, 7.76 (median 7.74) |
| Prefill seconds | 11.248, 10.868 | 10.023, 10.013 |
| End-to-end tokens/sec | 2.89, 3.02 | 3.52, 3.53 |
| Decode cache hit rate | 41% | 41% |
| Expert miss loads/output token | 92.73 | 92.75 |

Bounded Prefetch improved decode by 30.4% relative to Exact in this session.
This compares execution modes; it is not a before/after test of a new code fix
or storage repacking. Normal chat already defaults to `.staged`, which resolves
to bounded-prefetch decoding with staged prompt processing. The chat completion
counter includes prompt processing, while the diagnostic reports decode alone.

The report did not collect component profiles or storage-layout identity. Its
zero component timings mean instrumentation was off; they do not establish
zero compute cost. Aggregate acquisition waits overlap and cannot be treated
as serial wall-clock stalls (Bounded's reported wait exceeds decode wall time).

## Pool-budget result

The user subsequently supplied the completed counterbalanced pool-budget run
`92F9A123-6F3D-4AFB-8A6E-32D042A2FE77`. All four scored trials preserved output
parity and remained thermally nominal. Both arms used staged microbatch-4
prefill and bounded-prefetch decoding, with automatic pool selection.

| Metric | Legacy | Reclaimed |
| --- | --- | --- |
| Expert pool | 2 GiB / 1,213 slots | 3 GiB / 1,820 slots |
| Decode tokens/sec | 6.55, 7.43 (median 6.99) | 8.78, 8.74 (median 8.76) |
| Prefill median | 7.18 seconds | 7.38 seconds (+2.9%) |
| First-token latency median | 7.21 seconds | 7.43 seconds (+3.0%) |
| Decode cache hit rate | 70% | 80% |
| Expert miss loads/output token | 47.38 | 31.88 |
| Reported peak footprint | 4.24 GB | 5.17 GB |

The decode gain is 25.3%, accompanied by roughly one-third fewer expert miss
loads. This is evidence that cache budget affects this workload's speed; it
does not isolate every remaining compute or storage bottleneck.

The candidate's reported peak is only approximately 50 MB below the historical
5.22 GB Jetsam datapoint. That observation is not a guaranteed fixed OS limit.
The current acceptance rule checks `peak <= recordedJetsamFootprintBytes`, with
no additional headroom, and each scored trial generates only 64 tokens after
60 seconds of idle recovery. Passing this numerical rule does not establish
safe operation during long conversations or continuous inference. Keep the
production accounting default at legacy pending further evidence and a
meaningful headroom policy.

The existing `35B Sustained Run (thermal)` pins a 512 MiB pool, so it cannot
validate the reclaimed 3 GiB candidate as implemented. A candidate-specific
sustained run would require diagnostic changes or connected-device profiling.
## Expert-read result

The completed counterbalanced run `477503D7-9A01-4ADF-B353-87BFCF819466`
used a 512 MiB cache, staged microbatch-4 prefill and bounded-prefetch decode.
All four trials preserved output parity, with nominal thermal state and the
requested worker counts effective at load.

| Metric | Four concurrent reads | Six concurrent reads |
| --- | --- | --- |
| Decode tokens/sec | 6.92, 7.75 (median 7.33) | 6.78, 6.72 (median 6.75) |
| Prefill median | 7.01 seconds | 6.89 seconds (-1.7%) |
| Decode cache hit rate | 41% | 41% |
| Expert miss loads/output token | approximately 92.75 | approximately 92.75 |

Six read workers reduced decode throughput by 8.0% without reducing expert
misses. Keep the production default at four. This fixed-cache comparison
does not establish the result at the reclaimed 3 GiB cache size.

## Diagnostic cleanup correction

Source inspection found that `Edge0SpeedABRunner.performRun` restored
preferences but retained the last diagnostic engine. Pool capacity, read
concurrency, readahead and accounting are captured at engine load, so normal
chat could continue with the benchmark's 512 MiB cache or a cancelled
candidate arm. Restoring preference values alone cannot reconfigure it.
`finish` also hard-coded session reuse to enabled instead of restoring the
captured value; early load failure could leave it disabled.

The runner now awaits the existing Assistant unload-and-drain path before
restoring scoped preferences and publishing its terminal result. It keeps the
selected Edge0 model unloaded for normal lazy loading, and skips an unrelated
model selected by a failed switch rollback. Session reuse joins the captured
snapshot. Cancellation during loading/reloading and scored generation returns
a cancelled outcome through the same cleanup scope.

Two focused host tests exercise the actual preference scope: a controlled
drain barrier covers completion, thrown failure and cancellation, including a
load-captured cache/read/accounting configuration; a separate test checks both
session-reuse originals. All pass via `scripts/test_edge0_diagnostic_cleanup.sh`.
The production generic-iOS Release build and repository validator also pass.
This verifies restoration behavior, not a phone speed increase.

The runtime exports its loaded storage layout as `runtime.expertStorage` and
the diagnostic retains it per trial. Future reports identify `safetensors`
versus `repacked-v1` without requiring a separate breadcrumb lookup. The
user's existing pack layout remains unknown.

The independent Core AI deletion fix has passed its targeted tests and device
Release compile gate. On 2026-10-02, disk cleanup freed approximately 5.3 GiB,
allowing the verified shipping-Xcode archive and signed distribution export.
Build 1.0 (81) uploaded successfully, finished Apple processing and is assigned
to the existing Me internal TestFlight group with two testers. Its build ID is
`492e8259-b147-46cc-8185-ca3c5a33839f`. The signed archive, IPA, checksum and
TestFlight screenshot/status evidence are preserved under the ignored
`build/appstore/1.0-81/` directory. No new phone speed measurement was obtained.
