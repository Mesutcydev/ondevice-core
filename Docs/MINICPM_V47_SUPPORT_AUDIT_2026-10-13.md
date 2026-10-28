# MiniCPM V 4.7 support audit

October 13, 2026

MiniCPM-V 4.7 **1B and experimental 35B A3B are added to Models → Discover**
for local image understanding in Lens. The 35B model is also available in the
Assistant picker through its guarded streaming text backend in build 9. The 1B model uses the existing llama.cpp
vision engine. The 35B model has a separate Lookahead Expert Scheduling (LES)
engine that streams its experts from storage, with memory, storage, thermal,
and lifecycle guards. Neither entry replaces the default Assistant model.

The initial 35B hold was a runtime limitation: recognizing its GGUF architecture
did not provide the expert streaming needed on iPhone. The official mobile
deployment requires a small resident GGUF and separate expert files; loading
the ordinary full GGUF can exceed the device's Metal memory limit.
[OpenBMB deployment guide](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/68f53d67a418dd6444659c39005dd5cc4097071c/README.md)

## Model downloads and device requirements

Sizes below are decimal GB and include the matching vision encoder.

| Library entry | Selected model file | Download | Runtime admission |
| --- | --- | --- | --- |
| MiniCPM-V 4.7 1B | `MiniCPM-V-4_7-1B-Q4_K_M.gguf` | 1.782 GB | Existing memory and thermal policy; catalog estimate 3.2 GB |
| MiniCPM-V 4.7 35B A3B experimental | `MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf` | 16.624 GB | 12 GB class device, at least 4.8 GB available model budget, exclusive coordinated residency |

The 35B download and preparation need approximately **35 GB free storage before
starting**. Preparation requires another roughly 17.5 GB after the source is
downloaded, including a storage margin. Source files remain available until
the complete prepared pack is activated. Pause preserves completed work;
Cancel abandons the download and reclaims its dedicated preparation directory.

Both models use a bounded 4,096-token context and up to 256 output tokens in
Lens. The 35B physical-memory threshold is 11,000,000,000 reported bytes to
recognize devices marketed with 12 GB RAM. Devices below that threshold refuse
the curated download and load. Renamed local folders and GGUF filenames still
receive their model family's admission and residency policy; bounded leading
GGUF metadata identifies the publisher's embedded `35a3_hf_v47_0923` name.

This integration handles single images and the existing camera analysis loop.
The 35B Assistant path uses ChatML instruct prompts, the existing sampling
settings, a 4,096-token context, and a maximum of 256 output tokens per turn.
It preserves memory admission, cancellation, thermal stops and exclusive
runtime ownership. Video, audio, tool calling and DSpark speculative decoding
remain outside this addition. The publisher's approximately 13 tokens/s and 3 GB
iPhone result applies to its deployment; it is not an app performance result.
[Publisher model card](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B/blob/f8ddcae6f94778efa90dca75d7f2714916a8132d/README.md),
[LES runtime documentation](https://github.com/OpenBMB/llama.cpp-omni/blob/0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2/docs/les/lookahead-expert-scheduling.md)

## Compatibility with existing models

The shared classifier/chat/vision framework remains llama.cpp **b11558**, commit
`c83f3058b6f876f2f7e6ccbada858b2446860c85`. It already recognizes the
`minicpmv4_7` vision encoder and Qwen3.5 text architectures, so the 1B entry uses
that engine. The pinned MLX model registry does not provide this MiniCPM vision
architecture; the selected downloads therefore use GGUF.

The existing Edge0 35B loader is specific to its release: affine four-bit
experts, Recover-LoRA, tokenizer, and routing contract. MiniCPM uses a different
tokenizer and Q3_K expert tensors with eight routed experts. Sharing the
35B/256-expert headline does not make the Edge0 checkpoint loader compatible.
The Edge0 implementation and catalog remain independent.
[Edge0 runtime contract](EDGE0_NATIVE_FOUNDATION.md),
[MiniCPM configuration](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B/blob/f8ddcae6f94778efa90dca75d7f2714916a8132d/config.json)

The new `ODMiniCPM` framework links its upstream runtime privately and exports
only six `od_mini47_*` functions. Its Objective-C Metal class has a distinct
name. Runtime selection changes only the MiniCPM 35B family; the existing
bridge remains the implementation for other GGUF vision models. Native
construction, generation, cancellation, retirement, and unload still belong
to `LlamaCppVLMService` for Lens and `CodingAssistantService` for text chat,
with the existing coordinated residency lifecycle.

## Pinned sources and licensing

| Component | Exact source revision | License |
| --- | --- | --- |
| [Official 1B GGUF](https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/tree/6c2f4cb8bde51a00247e11003bbf66ca7c4f9249) | `6c2f4cb8bde51a00247e11003bbf66ca7c4f9249` | Apache-2.0 |
| [Official 35B GGUF](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf/tree/1e04eae556a075a1e78808a50266ed0b11de9bf1) | `1e04eae556a075a1e78808a50266ed0b11de9bf1` | Apache-2.0 |
| [LES runtime](https://github.com/OpenBMB/llama.cpp-omni/tree/0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2) | `0b74404c9b3dfe2c6b11aebe0dd58fc23f133ee2` | MIT; accompanying JSON, stb_image, and miniaudio notices retained |
| [Official mobile app reference](https://github.com/OpenBMB/MiniCPM-V-Apps/tree/68f53d67a418dd6444659c39005dd5cc4097071c) | `68f53d67a418dd6444659c39005dd5cc4097071c` | MIT; deployment reference only |

The runtime archive is checked against SHA-256
`5dcdd70ce6f9d583eac0f1b142311cb1d057ba83729fd581ecff692ee19436c9`.
The adapter and Swift preparer are original project code. Model cards, full
Apache-2.0 texts, and runtime notices are preserved under `LICENSES/` and
included by the existing app notice bundling. The source distribution excludes
model weights, prepared packs, source caches, and generated frameworks.
See [third-party notices](../THIRD_PARTY_NOTICES.md) and [SBOM](../SBOM.spdx.json).

## Prepared 35B artifact contract

Preparation verifies the entire official source and projector before reading
the GGUF tensor table. It preserves the quantized expert bytes and top-eight
routing. The completed inventory contains 43 payload files:

- The stripped main GGUF, 1,662,732,800 bytes.
- The matching F16 vision encoder, 1,119,575,840 bytes.
- Forty expert files, each 346,030,080 bytes.
- The expert manifest, with 120 tensor-family entries.

Each layer has 256 experts. Gate, up, and down matrices are interleaved for each
expert, with a 1,351,680-byte expert stride. Checkpoints bound cancellation and
policy polling; one-MB I/O buffers and autorelease pools bound host allocations.
Completed layers have checksum sidecars for reuse after interruption.

The final receipt records the source revision and output checksums. Activation
uses an atomic directory exchange only after inventory and manifest validation.
Readiness requires all 40 complete expert files, valid GGUF headers, matching
revision, and an intact manifest. The generic GGUF-pair readiness shortcut is
not used for this curated model. The ordinary llama.cpp bridge refuses 35B
loads by default; the guarded Assistant adapter and Lens backend both require
the prepared contract and use the isolated streaming runtime.

| Selected payload | Bytes | SHA-256 |
| --- | --- | --- |
| 1B Q4_K_M source | 672,003,680 | `588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d` |
| 1B F16 projector | 1,110,117,984 | `fb9cc047a3cdad5317fd8433a4aeda2d22f00f02ca4bd93b34ad84165b25a900` |
| 35B mixed Q3 source | 15,503,944,896 | `51e32201f0ddaf87dbb9689ceef9e3aa1a1543a1366706aa2abbf3aabb34df6b` |
| 35B F16 projector | 1,119,575,840 | `bff3b688e14c300eca273092c37c50a0ddfcc2054e079af1a0480edeed5d20f1` |

## Verification

| Check | Result |
| --- | --- |
| Catalog, prompt, execution policy, local alias, artifact integrity, cancellation | 16 host tests passed |
| Existing model-load ownership and stale vision completion regressions | 10 XCTest tests passed |
| Both MiniCPM detail screens and their separate download actions | 2 simulator UI tests passed |
| Existing download preparation failure and pause/resume/cancel UI flows | 2 simulator UI tests passed |
| Real 1B inference through the production Swift bridge | Four successful synthetic image turns; cancellation/retry, unload/reload, ordinary 35B refusal passed |
| Real 35B inference through the isolated Metal engine | Four successful synthetic image turns; top-eight routing, cancellation/retry, unload/reload, shared-runtime coexistence passed |
| Renamed GGUF admission using actual publisher metadata | Ordinary bridge refused the 35B model before native construction |
| 35B preparation and readiness | 43 artifacts validated; all 40 expert hashes match independent published conversion metadata |
| Native framework generation | iPhone arm64, Mac Catalyst arm64, native Mac arm64 built; only six intended C exports |
| Production iPhone compile gate | Release `build-for-testing` passed with signing disabled; app imports all six streaming functions and embeds both runtimes |
| 35B Assistant text | Real arithmetic correctness, sampler controls, prompt/output counts, output-limit reporting, cancellation/retry and reload passed |
| Real Lens stage events | Image encoding → prompt prefill → answer decode order passed |
| Background restoration / cleanup | 18 host tests passed, including late callbacks after pause or cancellation |
| Repository hygiene and diff whitespace | Passed |

The 35B smoke process used about 4.3 GB maximum resident memory on this 16 GB
Apple-silicon Mac. This is a host observation for synthetic images, not an
iPhone memory or speed guarantee. Tests keep synthetic prompts and model output
in memory; they print pass/fail and runtime metrics.

The host's ordinary low-storage refusal kept the original download. The pause
check stopped after the first complete layer and the next source verification
confirmed that the original was intact. To fit the full test conversion on this
Mac, a disposable test harness reclaimed already-copied source expert blocks
and bypassed only its test capacity estimate. This harness is outside Git.
Production preparation keeps every original source byte until atomic activation;
it retains the storage guard. The resulting pack passed the unmodified
production validator and the real 35B inference checks.

Physical iPhone validation remains required for sustained camera use, large
documents, thermal recovery, background interruptions, and peak memory on
12 GB hardware. The production app requires a device because CoreAI is absent
from the Simulator SDK; simulator checks use `QA/NativeUI` with the production
`OnDeviceUI` package.

## Build and test commands

Generate the isolated native runtime before regenerating the project:

```bash
python3 scripts/bootstrap_minicpm_v47_runtime.py
xcodegen generate
pod install --no-repo-update
./scripts/test_minicpm_v47.sh
./scripts/test_model_loads.sh
./scripts/validate_open_source.sh
```

The bootstrap includes all three supported slices by default. It leaves the
shared llama.cpp framework and Git submodules intact. The existing native
dependencies are still required; follow [setup instructions](../SETUP_INSTRUCTIONS.md).
On this macOS 27 host the model-load XCTest suite completed in an attached
terminal; redirected restricted runners stalled and were cleaned up.

For locally downloaded official weights, the reusable host commands are:

```bash
./scripts/prepare_minicpm_v47.sh /path/to/pinned/35B/download
./scripts/test_minicpm_v47_live.sh /path/to/pinned/1B/pair
./scripts/test_minicpm_v47_35b_live.sh /path/to/prepared/35B
```

The compile gate used `xcodebuild build-for-testing` with workspace
`OnDeviceMax.xcworkspace`, scheme `OnDeviceMax`, configuration `Release`,
destination `generic/platform=iOS`, and `CODE_SIGNING_ALLOWED=NO`.

The live tests use Metal and require normal host access. They do not download
weights or print generated answers. Production downloads remain explicit user
actions in the app, with no remote inference fallback.
