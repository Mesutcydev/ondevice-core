# Third-party notices

The top-level MIT license covers original iOS Local LLM code and documentation. It
does not replace the licenses of the components below.

## Source included in this repository

| Component | Location | License |
| --- | --- | --- |
| FastVLM sample implementation | `IOSLocalLLM/Services/FastVLM.swift` | [Apple Sample Code License](LICENSES/Apple-Sample-Code-License.txt) |
| MLX Stable Diffusion implementation | `IOSLocalLLM/Vendor/StableDiffusion/` | [MIT](IOSLocalLLM/Vendor/StableDiffusion/LICENSE) |
| CMU Pronouncing Dictionary | `IOSLocalLLM/Resources/Voice/cmudict.txt` | [CMUdict license](IOSLocalLLM/Resources/Voice/LICENSE) |
| thinking-orbs adaptations | `Packages/VoiceAgentOrb/` | [MIT](ThirdParty/thinking-orbs/LICENSE) |
| Edge0 native foundation | `IOSLocalLLM/Services/Runtime/Edge0/` | MIT (original Swift implementation) |
| Apple Core AI model runtime | `Packages/coreai-models/` | [BSD-3-Clause](LICENSES/CoreAI-Models-BSD-3-Clause.txt) |

The MIT license for iOS Local LLM applies only to the original changes and
integration around these components.

## Evaluated upstream reference (no source copied)

The native Edge0 storage/MoE foundation under
`IOSLocalLLM/Services/Runtime/Edge0/` was written as an original Swift
implementation after studying the public Edge0 reference. No Python source
was copied into this repository; the tensor names, quantization constants,
and math order below are interface facts of the published checkpoint.

| Component | Upstream | Commit | License |
| --- | --- | --- | --- |
| Edge0 reference runtime | <https://github.com/Edge0-AI/Edge0> | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0`, `fb4cd2c49ebe22bb230e1451ecb8fb4957ca62e6` | Apache-2.0 |
| Edge0 iOS contiguous expert layout (interface reference only) | <https://github.com/Edge0-AI/Edge0/tree/af5cd15e6b85c32ada9d23b4ba7b3c73b3661a94/ios> | `af5cd15e6b85c32ada9d23b4ba7b3c73b3661a94` | Apache-2.0 |
| Edge0-8B checkpoint and Recover-LoRA (metadata inspected only; downloaded by the app) | <https://huggingface.co/Edge0/Edge0-8B-A1B-preview> | `cadc35c7059469fad8569a63ce6c851172bbca61` | See model card |

See [Docs/EDGE0_NATIVE_FOUNDATION.md](Docs/EDGE0_NATIVE_FOUNDATION.md) for the
exact tensor naming, quantization layout, and the MLX primitive used.

The 35B repacked importer, on-device repacker, and `scripts/repack_edge0_35b.py` are original MIT
implementations of the published expert byte layout; no upstream Swift,
Metal, or Python source is copied. Conversion changes storage order only.
The model and adapters remain separately licensed and outside Git.

## Git submodules

| Component | Upstream | License |
| --- | --- | --- |
| llama.cpp | <https://github.com/ggml-org/llama.cpp> | MIT |
| whisper.cpp | <https://github.com/ggerganov/whisper.cpp> | MIT |

Each submodule retains its upstream notices and license.

## Direct package dependencies

iOS Local LLM resolves these dependencies through Swift Package Manager or
CocoaPods. Their source and license files are not copied into this repository.

| Dependency | Source | License |
| --- | --- | --- |
| MLX Swift (PrismML fork) | <https://github.com/PrismML-Eng/mlx-swift> | MIT |
| MLX Swift LM | <https://github.com/ml-explore/mlx-swift-lm> | MIT |
| swift-transformers-mlx | <https://github.com/DePasqualeOrg/swift-transformers-mlx> | MIT |
| Swift Transformers | <https://github.com/huggingface/swift-transformers> | [Apache-2.0](LICENSES/Apache-2.0.txt) |
| XGrammar | <https://github.com/mlc-ai/xgrammar> | [Apache-2.0](LICENSES/Apache-2.0.txt) ([NOTICE](LICENSES/XGrammar-NOTICE.txt)) |
| Swift Argument Parser | <https://github.com/apple/swift-argument-parser> | [Apache-2.0](LICENSES/Apache-2.0.txt) |
| ONNX Runtime | <https://github.com/microsoft/onnxruntime> | MIT |

Transitive packages are recorded in `Package.resolved` and retain their own
licenses in their source distributions. The source-distribution inventory is
also recorded in [SBOM.spdx.json](SBOM.spdx.json). The shared Apache-2.0 text
and required notices for SwiftASN1, SwiftCrypto, SwiftNIO, and XGrammar are in
`LICENSES/`; `project.yml` bundles this notice file and that directory into the
release app.

The optional TurboQuant cache integration uses MLX Swift LM **3.32.3**
(`3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`) and the PrismML MLX Swift
upstream-0.32.3 merge (`2a673fa8324ca9900f37445db1f66f4400e4af15`), both MIT.
Their upstream licenses remain in the package distributions. No Samsung
LittleBit/LittleBit-2 source or checkpoint is included. Its official reference
implementation is CC BY-NC 4.0; the app only recognizes incompatible checkpoint
metadata and reports that a factorized runtime is required.

## Models and generated artifacts not included

Downloaded language, vision, speech, and image-generation models are separate
works. Their license is shown in the model catalog or at the download source.
Do not assume that a model is open source merely because its loader is.

The Core AI catalog also links to these complete, user-downloaded conversions
(audited 2026-09-30; exact Hugging Face commit revisions are pinned in
`IOSLocalLLM/Models/CoreAIZooCatalog.swift`; no weights are included here):

| Conversion source | Upstream model | License |
| --- | --- | --- |
| [Qwen3 1.7B official-recipe iOS GPU](https://huggingface.co/mlboydaisuke/qwen3-1.7b-CoreAI-official) | Qwen/Qwen3-1.7B | Apache-2.0 |
| [Qwen2.5 0.5B Instruct](https://huggingface.co/kevinqz/Qwen2.5-0.5B-Instruct-CoreAI) | Qwen/Qwen2.5-0.5B-Instruct | Apache-2.0 |
| [Qwen2.5 Coder 0.5B Instruct](https://huggingface.co/kevinqz/Qwen2.5-Coder-0.5B-Instruct-CoreAI) | Qwen/Qwen2.5-Coder-0.5B-Instruct | Apache-2.0 |
| [Qwen2.5 Math 1.5B Instruct](https://huggingface.co/kevinqz/Qwen2.5-Math-1.5B-Instruct-CoreAI) | Qwen/Qwen2.5-Math-1.5B-Instruct | Apache-2.0 |
| [Qwen2.5 1.5B Instruct](https://huggingface.co/kevinqz/Qwen2.5-1.5B-Instruct-CoreAI) | Qwen/Qwen2.5-1.5B-Instruct | Apache-2.0 |
| [MiniCPM5 2B](https://huggingface.co/mlboydaisuke/MiniCPM5-2B-CoreAI) | openbmb/MiniCPM5-2B | Apache-2.0 |
| [Granite 4.0 H 350M](https://huggingface.co/aether-models/granite-4.0-h-350m) | ibm-granite/granite-4.0-h-350m | Apache-2.0 |
| [Qwen3 1.7B](https://huggingface.co/aether-models/qwen3-1.7b) | Qwen/Qwen3-1.7B | Apache-2.0 |
| [Granite 4.0 1B](https://huggingface.co/aether-models/granite-4.0-1b) | ibm-granite/granite-4.0-1b | Apache-2.0 |
| [EuroLLM 1.7B Instruct](https://huggingface.co/aether-models/eurollm-1.7b-instruct) | utter-project/EuroLLM-1.7B-Instruct | Apache-2.0 |
| [SmolLM3 3B](https://huggingface.co/aether-models/smollm3-3b) | HuggingFaceTB/SmolLM3-3B | Apache-2.0 |
| [Qwen3 4B Instruct 2507](https://huggingface.co/aether-models/qwen3-4b-instruct-2507) | Qwen/Qwen3-4B-Instruct-2507 | Apache-2.0 |
| [Julia 1 (Mac Core AI)](https://huggingface.co/mlboydaisuke/Julia-1-CoreAI) | SupersonicLabs/Julia-1; jhu-clsp/mmBERT-small base | Apache-2.0; base MIT |
| [Laya Multilingual](https://huggingface.co/mlboydaisuke/Laya-Multilingual-CoreAI) | convaiinnovations/laya; jhu-clsp/mmBERT-base base | Apache-2.0; base MIT |
| [FastContext 1.0 4B](https://huggingface.co/mlboydaisuke/FastContext-1.0-4B-CoreAI) | microsoft/FastContext-1.0-4B-SFT | MIT |
| [Youtu LLM 2B](https://huggingface.co/mlboydaisuke/Youtu-LLM-2B-CoreAI) | tencent/Youtu-LLM-2B | Youtu Community License; European Union use restriction |

See [the September 30 audit](Docs/COREAI_MODEL_AUDIT_2026-09-30.md) for selected
subtrees, conversion/source revisions, compatibility limits and deferred models.
The existing [Apache-2.0 text](LICENSES/Apache-2.0.txt) remains bundled. Downloaded
model files retain their upstream licenses and notices; a catalog entry does
not extend this project's MIT license to a checkpoint. The MatchRater-compatible
Core ML bridge contains original integration code and no private assets or
copied private implementations.

The following are deliberately excluded from Git:

- Apple FastVLM weights and derived Core ML artifacts (Apple Machine Learning
  Research Model License; research use only)
- SmolVLM GGUF weights
- KittenTTS, Kokoro, and Silero compiled model artifacts
- Generated llama.cpp and whisper.cpp XCFrameworks
- CocoaPods, Ruby bundles, archives, installers, and signing material

Anyone redistributing a build is responsible for reviewing and satisfying the
licenses of every model and binary they add.

## User-supplied app identity

The silver eye artwork used by `AppIcon`, `AppIconPreview`, `AppLogo`, and
`app_logo_small` was supplied by the project owner on 2026-09-05 for use as
this app's logo (attachment `codex-clipboard-7b8490cb-ee90-4ba0-97ef-adbed371f831.png`).
The app assets are resized copies of that artwork. This provenance note does
not assign a third-party license or extend the source-code MIT license to it.

## Bundled voice activity detector (sideload binary only)

The IPA includes the MIT-licensed FluidInference Core ML conversion of Silero VAD:
<https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96/silero_vad.mlmodelc>.
The bundled weight SHA-256 is `45846d0738d3bf5e4b6e9e7d2fddda7b1ad07da33d473f0405e51d3b6c4c11a9`, verified against that revision.
See `LICENSES/Silero-VAD-MIT.txt` for the upstream Silero Team notice.
This compiled model stays outside Git. Large chat, vision, and speech models
are downloaded separately by the app.
# Model license evidence for public-distribution review

The 2026-10-01 source/revision inventory is in
`Docs/audits/appstore-model-license-inventory-2026-10-01.json`. Copies of the
nonempty upstream license and notice files fetched at those revisions are in
`LICENSES/Models/`; the release notice collector preserves them in the app.
The inventory includes declared upstream bases, not just converted artifacts.
License tags are author declarations and do not alone establish product-use
rights, territory eligibility, revenue thresholds, or required registrations.
No model weights were downloaded for this inventory.

**Built with Llama.** Optional Llama 3.1 and Llama 3.2 text models are governed
by their respective Meta Community Licenses and Acceptable Use Policies. The
in-app Attributions page displays the required credit prominently. The
`LICENSES/Models/meta-llama--*/NOTICE` files retain Meta's required attribution
notices alongside the agreements, and the release collector bundles them.

LFM 2.5 models use the **LFM Open License v1.0**, not Apache-2.0. Its commercial
grant has an annual-revenue condition applying to the publisher and related
entities. SD Turbo and SDXL Turbo use the **Stability AI Community License**;
its commercial grant also requires registration and revenue eligibility, or a
separate agreement. Packaging license texts does not substitute for meeting
those conditions.

The public build blocks FastVLM research-model use and Youtu while its territory
limitations remain unresolved. This does not establish approval for every other
model in the catalog. Stability AI Turbo model registration/enterprise eligibility,
Llama/Gemma/Liquid/NVIDIA terms, image-model inherited licenses, and model-specific
use restrictions remain release checks described in the App Store audit.
