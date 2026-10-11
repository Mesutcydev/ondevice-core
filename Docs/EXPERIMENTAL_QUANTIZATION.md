# Experimental quantization

## TurboQuant cache

Open **Settings → Models & AI → Advanced → TurboQuant cache (experimental)**.
The toggle is off by default, persists under `assistantTurboQuantEnabled`, and
is snapshotted for each reply. Turning it off restores the existing cache path
on the next reply without re-downloading or converting weights.

The first integration uses upstream MLX Swift LM 3.32.3's `turbo8v3` scheme:
8-bit affine keys and 3-bit TurboQuant values. It applies only to installed
dense Llama, Mistral, Qwen2, and Qwen3 text models with FP16/BF16 activations and
64/128/256 head dimensions, and only when the factory produces exclusively
plain `KVCacheSimple` entries. Unknown metadata, other head dimensions, vision,
and bounded/rotating/recurrent caches keep their existing policies. Context
limits, output limits, samplers, cancellation, thermal monitoring, coordinated
residency and the generation gate are preserved. Core AI, llama.cpp and Edge0
do not use this setting.

TurboQuant prefills in full precision. Generation admission budgets raw cache
storage plus compressed storage overlapping during conversion, as well as
existing prefill scratch and runtime reserves. It does not claim that smaller
decode caches make an otherwise unsafe prompt fit. If the experiment's prefill
does not fit, the app rechecks live headroom and uses the standard cache when
that path is safe, recording the reason in diagnostics.

The MLX pair is pinned together:

- `mlx-swift-lm` 3.32.3, `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`.
- PrismML `mlx-swift`, `2a673fa8324ca9900f37445db1f66f4400e4af15`, retaining
  Bonsai 1-bit affine kernels. Do not substitute upstream MLX.

Legacy prefill chunking is explicitly retained during the dependency upgrade.
Downloaded model tensors and quantization settings are not converted.

## LittleBit and LittleBit-2

LittleBit replaces dense weights with trained binary latent factors and learned
scales. Existing affine Bonsai kernels cannot directly load this format. The
official Python/CUDA reference uses CC BY-NC 4.0; no reference code or trained
weights are incorporated here. Imports and MLX load paths reject explicit
LittleBit metadata with an explanation before opening weights. An unsuccessful
import removes only its staging copy and preserves the user's original files.

A functional Apple backend requires a compatible, appropriately licensed
checkpoint, factorized layer loading and Metal operators, followed by quality
and hardware validation. It remains a separate future implementation.

## Validation

Run `bash scripts/test_quantization_policies.sh` and
`bash scripts/test_memory_budgets.sh`, followed by the repository validator.
The policy tests cover opt-in selection, unsupported shapes and families,
rotating-cache preservation, full-precision prefill admission, and LittleBit
metadata compatibility. `QA/NativeUI` exercises the production settings control
with `QuantizationSettingsFlows`, including persistence and large text.

On an Apple Silicon Mac, `bash scripts/test_mlx_quantization_runtime.sh` builds
against the production package pins and checks synthetic 1/4/8-bit affine
matmul, TurboQuant attention at each supported head dimension and dtype,
rotating-cache behavior, and cache reset without downloading model weights.

The 2026-10-09 validation passed the generic iOS production test build, 84
synthetic GPU checks, 134 memory-budget checks, six quantization policy tests,
two settings UI tests, and repository hygiene validation. The UI checks include
relaunch persistence, returning to the default, and reaching the explanation
at the largest accessibility text size.

The unchanged VoiceAgentOrb package also passed 25 tests using SwiftPM's native
build engine. The local Xcode 27 beta's default Swift Build engine failed when
compiling that package's Metal resource; the native-engine run is recorded
separately from the production iOS compile gate.

Before enabling TurboQuant by default, compare the same model, prompt, sampler
and seed on a physical iPhone with the toggle off/on. Check coding and tool-call
quality, peak memory during long prefill, sustained decode, cancellation,
unload/reload, backgrounding and thermal escalation. Desktop synthetic checks
and Simulator UI checks do not establish iPhone quality or performance gains.

Sources: [MLX release](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3),
[TurboQuant implementation](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/TurboQuantKVCache.swift),
[LittleBit repository](https://github.com/SamsungLabs/LittleBit),
[LittleBit-2 paper](https://arxiv.org/abs/2603.00042).
