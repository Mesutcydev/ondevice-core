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
is still present on disk. Assistant tools use LFM3's native
`<tool_call><function=…>` format: the system turn ends with schemas for the
app tools in Liquid's `tool_to_json` layout, and results return in the `tool`
role. GitHub repository tools are listed by the existing prose catalog rather
than as schemas, because their 22 schemas and the GitHub contract overflowed
the 4K window. File text arguments (`content`, `oldText`, `newText`) keep
their whitespace exactly. As in Liquid's parser, a reply may answer before its
call; the call runs only when calls end the reply outside Markdown code, and
the answer text stays visible. Without a saved per-model profile, LFM3 chat
samples with the model card's values (temperature 0.1, top-k 50, repeat
penalty 1.1). LFM3-Omni-2B (Q4_0 with the Q8_0 projector) is offered only
when the linked runtime is b11960 or newer, detected by its
`mtmd_get_video_config` export; it answers about images through the LFM3 VL
path for now. Omni audio and video, LFM3 audio, and d1 models are not
implemented yet; see `Docs/LFM3_OMNI_PLAN.md`.

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

LFM3-Omni needs llama.cpp b11960. `python3 scripts/bootstrap_lfm3_omni_runtime.py`
prepares it in `build/LFM3OmniNative` and leaves `build/LFM3Native` (b11938)
untouched. To build against it, use the same command with
`-derivedDataPath "$PWD/build/LFM3OmniNative/DerivedData"`,
`"ONDEVICE_LLAMA_FRAMEWORK_DIR=$PWD/build/LFM3OmniNative"` and
`"ONDEVICE_LLAMA_SOURCE=$PWD/build/LFM3OmniNative/cache/llama.cpp-8642541b255bfb5dc39cd351a178be09013a55d6"`.
Switching back is the original command. The rollout is in `Docs/LFM3_OMNI_PLAN.md`.

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
