# Ternary Bonsai 2 text and image support

Token supports `prism-ml/Ternary-Bonsai-2-9B-mlx-2bit`, audited revision
`f4e28a59531731c41b6dfac88cf271bd58f0a287`. Existing defaults and pinned
package versions are unchanged.

Select this model in Assistant for text and attached-image analysis. Assistant
loads its complete vision runtime when the memory envelope fits; it does not
require selecting the same model in Lens or opening the camera. User-turn image
pixels, including retained images in follow-up history, reach the processor.
Lens retains its camera workflow and separate saved model preference.

`Bonsai2MLXModel` and `Bonsai2VLMModel` use the same `Bonsai2PackedLayers`
installer with the pinned PrismML Hadamard modules. The VLM wrapper retains the
published FP16 Qwen3.5 vision tower, image processor and multimodal positions.
Grouped GDN weights are not permuted again. Converted vision tensors are not
transposed or quantized again. Strict format, geometry, image-token and packed
weight validation runs before publishing the runtime. Only the verified dense
9B schema-2 geometry is admitted; other Bonsai 2 variants remain blocked.

The approximately 3.5 GB download uses a conservative 5 GB catalog estimate,
high-memory iOS/Mac eligibility, a 2K Assistant context/cache policy and 128-token
prefill chunks. Full vision admission includes the existing phase-aware
weight/activation reserve and live process budget. If that envelope cannot fit,
the bounded text runtime remains available. Residency, cancellation, cleanup,
memory-pressure and thermal guards remain in force. Estimates are not measured
iPhone peaks.

## Validation — 2026-10-26

The real 3,462,149,260-byte checkpoint loaded through the production Swift VLM
factory on Apple Silicon. Greedy output tokens exactly matched the publisher's
Packed/FWHT layers with the Qwen3.5 Python vision implementation for colored
shapes, two text-reading probes, a mobile code screenshot, a two-image request,
a follow-up about an earlier image, and a text-only request. Independently
processed pixel tensors and grids were identical in the checked cases.

Both text-reading probes produced incorrect transcriptions in both runtimes.
Reference parity verifies integration, not OCR accuracy or general model quality.
Shape colors and the follow-up answer were correct; screenshot and multi-image
probes used a bounded 48-token response. Earlier text adapter checks matched a
short answer, complete code response and thinking prefix.

Run `scripts/test_quantization_policies.sh` for compatibility and memory policy
checks, and `scripts/test_mlx_quantization_runtime.sh` for existing GPU checks.
Evidence is in ignored `build/bonsai2-validation` and
`build/tokenai-2.0/artifacts/bonsai2-vision-2026-10-26`. Model weights are excluded
from the public source. Physical iPhone memory, sustained generation and thermal
behavior remain device-validation requirements. This local work does not upload
a new TestFlight build.
