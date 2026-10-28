# LFM3 experimental support

Liquid AI released LFM3 on October 27, 2026. Token AI's experimental build
adds the publisher's LFM3 1.7B text model and LFM3 VL 2B image model, both in
QAD Q4_0 GGUF. The vision download also contains the matching Q8_0 projector.
The app uses a bounded 4,096-token runtime context and existing residency,
memory, cancellation, and thermal controls. The model's larger advertised
context is not allocated by this integration.

The normal build continues to use llama.cpp b11558. LFM3 requires b11938, so
the experimental framework is built separately and the catalog is hidden
unless the build explicitly opts in. A normal build refuses LFM3 selections
before unloading the current model, including when an experimental download
is still present on disk. LFM3's XML tool-call format is not yet wired into
the app's tool protocol; the text preset does not advertise tools. LFM3 audio,
omni, video, and d1 models are not implemented by this integration.

## Experimental build

The following commands prepare a separate framework without replacing the
normal one. A Mac Catalyst experiment additionally needs `--with-catalyst`
on the bootstrap command. Model weights are not included in the repository.

```bash
python3 scripts/bootstrap_lfm3_runtime.py
xcodegen generate
xcodebuild -workspace TokenAI.xcworkspace -scheme TokenAI \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath "$PWD/build/LFM3Native/DerivedData" \
  ONDEVICE_LFM3_SWIFT_FLAG=LFM3_EXPERIMENTAL \
  "ONDEVICE_LLAMA_FRAMEWORK_DIR=$PWD/build/LFM3Native" \
  "ONDEVICE_LLAMA_SOURCE=$PWD/build/LFM3Native/cache/llama.cpp-19cce6919992fdffd92e0ac152caaf1e2b8f254e" \
  build-for-testing
```

The separate DerivedData directory prevents Xcode from reusing a module built
against the normal framework's headers. The build checks that the experimental
framework and headers match the pinned revision. Download the models explicitly
from Models in the experimental app.
Liquid's LFM Open License v1.0 applies, including its commercial revenue
condition; the model cards and licenses are downloaded with the artifacts.

## Verification and release gate

The model-free host checks run through `scripts/test_minicpm_v47.sh` and
`scripts/test_minicpm_v47.sh --lfm3-experimental`; they
cover LFM3 artifacts, prompt formatting, the disabled-build guard, and the
existing MiniCPM and GGUF contracts. The release must additionally verify on
a physical iPhone: LFM3 text and repeated Lens requests, model switching and
cancellation, memory/thermal behavior, and existing GGUF chat, vision, and
classifier models against b11938. A successful macOS inference or simulator
fixture does not establish those device behaviors. Keep the normal runtime
and catalog default unchanged until those checks pass.
