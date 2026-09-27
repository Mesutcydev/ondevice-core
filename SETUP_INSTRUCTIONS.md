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
```

Add `--with-catalyst` when you also need the Apple-Silicon Mac Catalyst target.
The script may apply the tracked iOS-only patch inside the generated
llama.cpp build checkout; do not commit that submodule worktree change.

Expected outputs:

```text
ThirdParty/llama.cpp/build-apple/llama.xcframework
ThirdParty/whisper.cpp/build-apple/whisper.xcframework
```

These outputs are generated files and must not be committed.

## Generate the workspace

`project.yml` is the source of truth for the Xcode project:

```bash
xcodegen generate
pod install
open OnDeviceMax.xcworkspace
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
3. Replace the app, extension, App Group, and CloudKit identifiers with values
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
  -workspace OnDeviceMax.xcworkspace \
  -scheme OnDeviceMax \
  -destination 'platform=iOS,name=YOUR_IPHONE'
```

Without a device, compile them as the gate:

```bash
xcodebuild build-for-testing \
  -workspace OnDeviceMax.xcworkspace \
  -scheme OnDeviceMax \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Thermal, Jetsam, Metal-residency, and battery claims require physical-device
validation; see [Docs/VALIDATION.md](Docs/VALIDATION.md).
