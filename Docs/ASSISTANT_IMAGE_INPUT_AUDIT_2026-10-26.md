# Assistant image-input audit — 2026-10-26

## Follow-up — 2026-10-28

New photo and file attachments carry a bounded 1,600-pixel JPEG into image
inference. Photo OCR uses the source image's orientation, and text-model
handoffs retain both the visual description and independently recognized text,
with a bounded context and explicit uncertainty. An installed, explicitly
selected visual model is tried before the compact SmolVLM2 fallback. All
backends retain their existing admission and sequential residency controls.

The chat no longer combines a top-anchored scroll-position binding with
repeated bottom-follow scrolling. Sent image previews have fixed dimensions and
a cached, downsampled rendering. The simulator fixture covers the preview's
streaming phases; physical-device inference and long-running visual behavior
still require device validation. The historical 480-pixel and preference details
below describe the earlier implementation.

Assistant accepts text and image attachments; Lens keeps the camera workflow.
A model that directly supports both must not depend on the Lens selection.

The previous MLX policy required matching Assistant/Lens selections and could
therefore load only the text component of a multimodal model. The new
`AssistantVisionPolicy` removes that dependency while preserving full vision
memory admission. This covers Qwen3.5 4B/9B, Bonsai 27B binary/ternary and
Ternary Bonsai 2 9B, subject to platform eligibility and available memory.

Shared-container eligibility also excluded imported models. It now recognizes
installed unified architectures registered by both pinned factories: Qwen3.5,
Gemma 3, Gemma 4/unified and Ministral 3. Checkpoint/runtime validation still
applies. Imported model names and capability badges alone cannot enable vision.
Their vision capability is retained when selecting them for Assistant.

| Runtime/model path | Assistant image behavior |
| --- | --- |
| Supported MLX dual-role presets and unified imports | Direct pixels through the resident VLM, independent of Lens selection and gated by memory |
| Text-only MLX, including smaller original Bonsai models | Existing local visual-description handoff |
| llama.cpp/GGUF Assistant, including MiniCPM text execution | Existing local visual-description handoff; Assistant loads no projector and calls text generation |
| llama.cpp/mtmd Lens | Native image analysis with a compatible projector in its separate Lens service |
| Core AI, built-in/PCC text Assistant, Edge0 | Existing local visual-description handoff; current Assistant executors are text-only |
| Configured external API models | Direct image payloads when the selected model/provider enables images |

The handoff prefers installed SmolVLM2, then existing configured visual backends.
It runs sequentially, restores the selected Assistant, retains the description
on the user turn for follow-ups, and preserves attachments on failure. It stays
inside Assistant and does not silently use a cloud API. A separate model's
description is not represented as native pixel input to the selected text model.

Native GGUF image chat needs projector lifetime/admission and image-aware
multi-turn generation/cancellation tests. This audit does not turn on a flag over
the existing text generator. Core AI and Edge0 image encoders are not implemented.

Bonsai 2 has real-checkpoint/reference parity evidence; see `BONSAI2_SUPPORT.md`.
Other families received source/routing review and shared memory-policy checks,
not fresh model benchmarks for every checkpoint. Physical iPhone memory and
thermal behavior remain unmeasured. Assistant currently stores bounded 480-pixel
JPEG attachments, which can lose fine screenshot/document text; OCR quality also
varies by model. These changes do not establish full-resolution OCR accuracy.

The focused compatibility/memory suite passed all 20 tests with zero failures.
Repository localization and hygiene checks passed.

## Physical-device diagnostics — 2.1.1 (79), 2026-10-28

An iPhone 18,2 on iOS 27.2 reported **“Image analysis unavailable”** while
asking about a photo with the imported text model `LFM3-1.7B-Uncensored-AD-Q6_K`.
The exported diagnostics show the cause was the visual backend, not the image:

- Lens/Assistant tried the selected `prism-ml/Ternary-Bonsai-2-9B-mlx-2bit`
  vision model. Admission required ~6.26 GB (5.97 GB plus headroom); the
  device had ~5.85–6.15 GB available. The model was refused on both attempts.
- The bundled SmolVLM2 directory was absent, and no other visual model was
  installed, so the handoff had nothing left to try.
- LFM3 1.7B is text-only. It loaded and generated normally (37.27 tok/s), and
  voice/Lens lifecycle logs were healthy; this was not an LFM3 runtime fault.

The handoff now tries other installed `.vlm` models, lightest first, after the
selected backend fails. If none is installed it offers the lightest catalog
visual model (SmolVLM2 at ~520 MB) instead of the dead-end message.

## Final validation — 2.1.1 (80), 2026-10-28

- `AssistantImageInputTests` passed 4/4: the 1,600-pixel encoder keeps its
  limit, honors orientation and never upscales; visual description and OCR
  both reach the answering model; OCR-only and empty observations stay
  explicit and bounded.
- `AgentChatFlows.testAttachedImageKeepsItsFrameThroughStreamingPhases`
  passed after the preview thumbnail moved to a synchronous cache. With the
  earlier asynchronous load, the first layout could measure a 24×32 tile and
  then grow to 72×96 as the image appeared; the preview now renders at its
  final 72-point size from the first frame, and its accessibility frame stays
  within the 44-point hit target.
- `scripts/validate_open_source.sh` passed, including 1,173 localization keys
  across the six requested languages and repository hygiene.
- Production archive `TokenAI 2.1.1 (80)` built with Xcode 27.1 (27A9275) and
  the experimental LFM3 runtime; signed App Store export passed
  `verify_appstore.py --distribution` and the FoundationModels symbol check.
- The signed IPA (SHA-256 `5face3247b6d13af0bee65f17d186790302c5fdc644c916974f9d73458521256`)
  was uploaded to App Store Connect. Build 80 processed as `VALID` with
  `usesNonExemptEncryption: false`; the internal **Test** group has access to
  all builds and reports `IN_BETA_TESTING`.
- No physical-device inference ran in this session. Image-answer quality,
  long-image streaming, memory and thermal behavior still require iPhone
  validation.
