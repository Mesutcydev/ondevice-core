# Development setup

This guide builds the source-only distribution. Model weights, compiled native
frameworks, CocoaPods, and signing profiles are not stored in Git.

## Prerequisites

- Apple-silicon Mac
- Xcode 27 or newer (the app targets iOS 27)
- Xcode command-line tools
- Homebrew
- At least 15 GB of free space for native framework builds and package caches

Install the project tools:

```bash
brew install cmake xcodegen cocoapods
```

## Clone

The llama.cpp and whisper.cpp sources are Git submodules:

```bash
git clone --recurse-submodules https://github.com/Mesutcydev/ios-local-llm.git
cd ios-local-llm
```

If the repository was cloned without submodules:

```bash
git submodule update --init --recursive
```

## Build native frameworks

IOSLocalLLM links locally generated llama.cpp and whisper.cpp XCFrameworks.
The tracked root script builds the required slices from pinned submodules:

```bash
./scripts/build_native_frameworks.sh
python3 scripts/bootstrap_classifier_runtime.py
python3 scripts/bootstrap_minicpm_v47_runtime.py
```

Add `--with-catalyst` to the first two commands when you also need the Apple-Silicon Mac Catalyst target.
The MiniCPM bootstrap produces iPhone, Apple-silicon Mac Catalyst, and native Mac
slices by default. Its isolated LES engine is required for the experimental
MiniCPM-V 4.7 35B library entry and leaves the shared llama.cpp engine intact.
The script may apply the tracked iOS-only patch inside the generated
llama.cpp build checkout; do not commit that submodule worktree change.

Expected outputs:

```text
ThirdParty/llama.cpp/build-apple/llama.xcframework
ThirdParty/whisper.cpp/build-apple/whisper.xcframework
build/ClassifierNative/llama.xcframework
build/MiniCPMNative/ODMiniCPM.xcframework
```

These outputs are generated files and must not be committed.

MiniCPM 1B downloads its model and vision encoder (about 1.78 GB). MiniCPM 35B
requires at least 12 GB physical RAM, downloads about 16.62 GB, and temporarily
needs about 35 GB free storage before download and preparation. Preparation
verifies the pinned source and creates a resumable expert-streaming pack before
the model becomes ready. See [the audit](Docs/MINICPM_V47_SUPPORT_AUDIT_2026-10-13.md).

## Generate the workspace

`project.yml` is the source of truth for the Xcode project:

```bash
xcodegen generate
pod install
open TokenAI.xcworkspace
```

Open the workspace, not the `.xcodeproj`, so the ONNX Runtime pods are
available.

SwiftPM may report a conflicting `mlx-swift` identity because the project pins
the PrismML fork for one-bit model kernels while another package declares the
upstream repository transitively. This is a documented forward-compatibility
risk in [Docs/XCODE_SECURITY_SETTINGS.md](Docs/XCODE_SECURITY_SETTINGS.md), not
a missing package in the current lockfile.

## Simulator and device builds

The app runs only on a physical iPhone with iOS 27. The vendored `CoreAIShared` package imports the iOS-27 `CoreAI` module, which
ships in the iPhoneOS SDK but not in the iPhoneSimulator SDK. A Simulator
destination therefore fails to resolve that import; use a device destination
(`generic/platform=iOS`) for compile verification. See
`Docs/MAX_RELEASE_AUDIT.md`.

For UI review in the Simulator, use the [`QA/NativeUI`](QA/NativeUI/README.md)
host, which runs the production `OnDeviceUI` package against stub services
and needs no paid Apple Developer Program membership.

The source-only build starts without bundled AI weights. Features that depend
on a model become available after the user downloads a compatible model from
the app's model catalog.

## Run on a physical device

Use your own signing identity:

1. Select the IOSLocalLLM project in Xcode.
2. For the app, share extension, unit-test, and UI-test targets, select your
   development team.
3. Replace the app, extension, and App Group identifiers with values
   owned by your team, following [Docs/FORK_CONFIGURATION.md](Docs/FORK_CONFIGURATION.md).
4. Build and run on your device.

If you regenerate the project, make permanent identifier changes in
`project.yml`; XcodeGen overwrites manual project-file changes.

## Optional models

Models are deliberately separate from the repository.

- Use the in-app catalog for normal language, vision, and voice model
  downloads.
- `scripts/download_voice_models.sh` can stage supported voice models for
  development.
- `scripts/export_fastvlm_coreml.sh` documents an experimental FastVLM export
  path.

Read the upstream license before downloading or redistributing any model.
Apple FastVLM model weights are research-only and must not be presented as MIT
licensed or as part of this open-source distribution.

### Edge0-35B preparation on iPhone

The curated, pinned Edge0-35B download now prepares its storage automatically
on the iPhone. Open **Models**, choose **Edge0-35B A3B Preview**, and download it.
After the download, **Preparing model** shows progress through the forty expert
layers. No Mac conversion is required for this path.

Allow roughly 40 GB for the original download and prepared output together,
plus a storage margin. Preparation uses 1 MiB copy buffers and verifies each
output file by SHA-256 readback. It preserves model bytes and notices, activates
the complete validated directory with an atomic exchange, then removes the
original shards. Completed files are checked and reused when resuming.

Preparation pauses when the app backgrounds, the device needs to cool, memory
pressure persists, or this model is still loaded. It resumes automatically after
returning to the foreground or a safe thermal/runtime transition. A manual Pause
stays paused until Resume. If storage is insufficient or verification fails,
the original download is retained and model details explain how to resume.
Preparation must finish before this new download appears as installed.

Existing original-format installs remain usable. Resuming a complete original
download with pending preparation converts it locally without downloading the
complete model again.
This flow applies to the original revision listed below and the audited public
revision `3fe15cbf2bd5bbcdfd611035e1ac88971ff1cdab`. Hugging Face file metadata
confirms their model, adapter, configuration, index and tokenizer hashes match;
only the model card differs. The manifest records the actual downloaded source
revision. Other Edge0 families and revisions keep their existing behavior.

### Optional Edge0-35B repacked import from Mac

The native runtime also accepts a storage conversion of the supported
`Edge0/Edge0-35B-A3B-preview` revision
`1ff9f4478890faec0368c5463b621d1036d5b518`. It places each routed expert's
nine tensors into one contiguous block, reducing nine range reads to one.
Tensor bytes, quantization, top-4 routing and Recover-LoRA stay unchanged.
The iPhone downloads the original four-shard format and then prepares this
same repacked layout locally.

Choose a model directory outside this repository. If you need to download the
checkpoint, allow at least 40 GB of free space for the source and converted
output together, plus a margin for other work. The required download is about
19.57 GB. An external drive is suitable.

Install the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/en/guides/cli)
if `hf` is unavailable (`brew install hf`). Replace `YOUR_DRIVE` below with
your actual drive name, then download exactly the release this runtime supports:

```bash
EDGE0_SETUP_ROOT="/Volumes/YOUR_DRIVE/OnDeviceMaxModels"
hf download Edge0/Edge0-35B-A3B-preview \
  config.json generation_config.json tokenizer.json tokenizer_config.json \
  chat_template.jinja model.safetensors.index.json lora_edge0_35b.safetensors \
  model-00001-of-00004.safetensors model-00002-of-00004.safetensors \
  model-00003-of-00004.safetensors model-00004-of-00004.safetensors README.md \
  --revision 1ff9f4478890faec0368c5463b621d1036d5b518 \
  --local-dir "$EDGE0_SETUP_ROOT/edge0-35b-original" --max-workers 2
```

Read and retain the downloaded model card and any upstream notices. The
optional prerouter is not required for this conversion. Use the pinned revision
above rather than `main`, which can change independently of this runtime.

Convert and verify the downloaded checkpoint:

```bash
python3 scripts/repack_edge0_35b.py pack \
  "$EDGE0_SETUP_ROOT/edge0-35b-original" "$EDGE0_SETUP_ROOT/edge0-35b-repacked"
python3 scripts/repack_edge0_35b.py verify "$EDGE0_SETUP_ROOT/edge0-35b-repacked"
```

If you already have the complete pinned checkpoint, skip the download and use
its folder as the source instead:

```bash
python3 scripts/repack_edge0_35b.py pack /path/to/original /path/to/repacked
python3 scripts/repack_edge0_35b.py verify /path/to/repacked
```

The output must be a new directory outside the source. Allow about 20 GB of
free space for conversion in addition to the source checkpoint. The tool
uses bounded buffers, leaves the source untouched, verifies every generated
payload by SHA-256 readback, and publishes the output only on success.
It copies model notices when present; retain the original model's license.

Import the entire resulting folder through the app's existing model import
flow. It contains resident safetensors, forty `experts-L*.bin` files, the
`experts.json` manifest, tokenizer/configuration files and adapters. The phone
needs only this output, not the original weight shards. Remove an existing
35B preset through the app before importing its replacement.

The runtime checks release identity, exact expert layout, complete file sizes,
resident tensor geometry and the existing adapter contract before loading.
Full checksum verification is the desktop `verify` command; startup does not
scan 18 GB of payload. Memory admission, pool limits and read concurrency are
shared with the original loader. Diagnostics identify `repacked-v1` storage.
Physical-device throughput and memory measurements are required before
claiming a speed improvement. No weights or converted files belong in Git.

Run the source-only storage tests with `bash scripts/test_edge0_repacked.sh`.

## Regenerating dependencies

After changing `project.yml` or `Podfile`:

```bash
xcodegen generate
pod install
```

Commit `project.yml`, `Podfile`, `Podfile.lock`, the generated shared Xcode
project, and shared package resolution files. Do not commit `Pods`,
`xcuserdata`, model weights, archives, signing material, or generated
frameworks.

## Tests

Run the standalone voice-orb package tests:

```bash
swift test --package-path Packages/VoiceAgentOrb
```

If that fails with `unable to spawn process …/metal` after an Xcode or
toolchain update, the package's build directory still points at a removed
toolchain mount (for example a `MetalToolchain-…` cryptex from a previous
beta). This is an environment issue, not a code failure — clear the stale
build output and rerun:

```bash
rm -rf Packages/VoiceAgentOrb/.build
swift test --package-path Packages/VoiceAgentOrb
```

App unit tests are hosted in the app, so they run only on a connected iPhone:

```bash
xcodebuild test \
  -workspace TokenAI.xcworkspace \
  -scheme TokenAI \
  -destination 'platform=iOS,name=YOUR_IPHONE'
```

Without a device, compile them as the gate:

```bash
xcodebuild build-for-testing \
  -workspace TokenAI.xcworkspace \
  -scheme TokenAI \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Thermal, Jetsam, Metal-residency, and battery claims require physical-device
validation; see [Docs/VALIDATION.md](Docs/VALIDATION.md).
