# Classifier app audit and integration — October 12, 2026

Reference: the owner's `/Users/m/Desktop/class` app, especially
`Packages/ClassifierKit/Sources/ClassifierKit/Catalog/ClassifierCatalog.swift`,
the Core ML/GGUF backend contracts, and its model-library documentation.
That checkout has no committed HEAD. The catalog and runtime sources were
inspected locally; no model weights, private conversion, or source-app user
data were added to this repository.

## Result

OnDevice Max's existing classifier workspace now accepts portable local decision
and image models. It retains the sidebar shell, visited workspaces, leading
keyboard-dismiss control, and shared host runtime lifetime.

The classifier shelf has 16 entries: 13 portable downloads, the existing Laya
Core AI entry, and two informational Mac-only Julia Core AI exports. The new
512-token Mac entry complements the existing 1,024-token export. Mac-only
exports remain unavailable for iPhone download.

| Models | Variants | Adapter |
| --- | --- | --- |
| Julia-1 | Q8_0, BF16; 1,024 tokens | llama.cpp CPU typed decision head |
| Laya English | Q8_0, BF16; 512 tokens | llama.cpp CPU typed decision head |
| Laya Multilingual | e8 at 128/256/512/1,024; FP16 at 512 | Core ML marker-map decisions |
| Laya English | FP16 at 128/512 | Core ML, automatic compute |
| FastViT | T8, MA36 | Core ML fixed ImageNet dictionary |
| Julia Core AI | FP32 at 512/1,024 | Mac-only catalog information |

`ClassifierCatalog.swift` pins each portable artifact's exact source revision,
selected model subtree, tokenizer and license sidecars. `CoreAIZooCatalog.swift`
retains the Core AI revisions. The public-distribution revision allowlist includes
the six portable source repositories.

## Improvements from the audit

- Saved classifiers persist instructions, labels, rubric and yes/no criteria.
  Saving excludes input text, photos and model selection. Loading a task keeps
  the current input draft; text and image drafts remain independent.
- FastViT selection changes the editor to a photo/file picker and its fixed
  categories. Images are bounded to 20 MB, decoded with orientation, and
  downsampled for inference/preview. Custom text tasks return when switching back.
- Results rank the model's scores, show actual elapsed time and export model ID,
  runtime, source revision and all scores. Image results show the top ten.
  Apple's two ImageNet `crane` labels share a dictionary key; the adapter preserves
  the actual 999-key dictionary without inventing or renormalizing scores.
- The existing downloader now selects only the chosen portable artifact and
  required sidecars. LFS files use SHA-256; ordinary classifier files use Git blob
  SHA-1. Preparation compiles Core ML packages and inspects model descriptions
  without specializing their weights. GGUF preparation validates the vocabulary
  and decision metadata without loading inference weights. Publication is atomic.
- Pause/cancel keeps the writer tracked until it drains. Resume waits for that
  drain, stale progress is ignored, and canceled delegate callbacks cannot write
  a late file. Resume retains completed files; an interrupted individual file is
  downloaded again. CDN redirects drop Hugging Face authorization.
- Download admission reserves room for both temporary Core ML compiler output
  and its staged copy. Device storage totals include installed classifier packs,
  including compiled artifacts. Token-count previews are canceled and drained
  alongside inference before a runtime or its files are released.

## Runtime ownership

All adapters are held by `CoreAIInferenceService` through `ClassifierRuntimeSession`.
Activation drains other producers through `ModelResidency.prepareForClassifier`,
uses `MemoryAdvisor`'s live admission/cooldown gate with an explicit peak estimate,
and checks `DeviceSafetyMonitor` before inference. Backgrounding, stopping,
replacement and removal drain the shared native jobs before releasing files.
The adapters do not admit independent heavy loads or fall back to a remote service.

Julia/Laya keep typed choice, score and yes/no question rows, strict context and
option limits, marker positions, source temperatures and separately requested
fitted calibration. Portable Laya reads its action probability from the same
Core ML graph. That value remains advisory and never starts tools.

The existing bearer-authenticated classifier API also accepts installed portable
text decision IDs (`classifier:julia-1-q8`, for example). Its existing text request
schema stays bounded. Image classification is available in the native workspace;
image entries are omitted from the API's text-classifier listing.

## Native dependency

The previous llama.cpp snapshot lacked the ModernBERT decision executor.
`scripts/bootstrap_classifier_runtime.py` pins release **b11558**, commit
`c83f3058b6f876f2f7e6ccbada858b2446860c85`, with checksums for the upstream source
archive and prebuilt framework. Its recipe adapts the owner's classifier-app
bootstrap and adds mtmd to the simulator slice. The existing Catalyst helper
also accepts this pinned source and retains the new vendor-hash library.

The app links this single runtime for both classifier and existing chat/vision
paths. The two existing chat penalty-sampler calls now supply the vocabulary
size required by that runtime's API. Generated binaries, sources, symbols and
build caches stay under ignored `build/ClassifierNative`.

```sh
python3 scripts/bootstrap_classifier_runtime.py
# Optional Apple-silicon Mac Catalyst slice:
python3 scripts/bootstrap_classifier_runtime.py --with-catalyst
xcodegen generate
```

## Validation

Evidence and command logs are in the ignored `build/classifier-audit` folder.
Fast host checks: `scripts/test_coreai_classifiers.sh`. Portable adapter checks:
`bash scripts/test_portable_classifiers.sh`; real inference is opt-in through
`CLASSIFIER_RUNTIME_FIXTURES` and `CLASSIFIER_RUNTIME_IMAGE`, and reuses existing
audited model folders. No test downloads weights automatically.

The production `QA/NativeUI` host includes the expanded catalog and fixtures for
decision/image editing and saved tasks. These fixtures establish UI behavior,
not device inference. Physical iPhone memory, thermal, camera and accuracy checks
remain separate from host tests and the generic iOS compile gate.

Completed checks:

| Check | Result |
| --- | --- |
| Classifier/store/workbench host suite | 41 tests passed |
| Real cached Mac inference and cancellation recovery | 5 tests passed; Julia GGUF, English Laya GGUF, multilingual Laya Core ML, FastViT T8 |
| Classifier library contracts | 4 tests passed |
| Native classifier flows | 6 flows passed, including large text, saved tasks, image input, activation refusal and cancellation |
| Native UI simulator compile | Passed |
| Production generic iOS build-for-testing | Passed with signing disabled |
| b11558 framework build | iPhone, Mac, Apple-silicon Simulator and Mac Catalyst slices prepared |
| Repository hygiene and whitespace checks | Passed |

The large-text workspace flow passed in a focused rerun after its test was
updated to scroll to lazily rendered fields. An additional catalog/download
routing UI probe stalled in Xcode and was interrupted before producing a test
result; it is excluded from the passing counts above. Its log is
`build/classifier-audit/library-ui-tests.log`.

Original simulator captures are under `build/classifier-audit/screenshots`.
Their inference outputs are explicitly UI fixtures. The separate cached Mac
checks perform real inference; they are contract checks, not accuracy benchmarks.

The update was subsequently uploaded as **1.0.1 (6)** and processed **VALID**
for internal TestFlight. The [upload record](TESTFLIGHT_CLASSIFIERS_2026-10-12.md)
includes signed-candidate verification and fresh download probes. Those probes
also corrected the informational Mac Julia 512-token entry's download size to
the exact pinned subtree size.
