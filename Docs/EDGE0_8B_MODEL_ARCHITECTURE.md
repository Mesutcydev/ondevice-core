# Edge0-8B model architecture (verified)

Implementation contract for native Edge0-8B inference. Every value below was
verified against the published checkpoint config
(`Edge0/Edge0-8B-A1B-preview`), the upstream reference source, or the
checkpoint's safetensors metadata — not inferred from the model name.

| Reference | Value |
| --- | --- |
| Upstream repo | `https://github.com/Edge0-AI/edge0` |
| Reference SHA | `0700e6532f45e0d0d99e9c588d7d8cd240538ea0` |
| MLX implementation | `src/edge0/backends/mlx/_impl/bailing_hybrid.py` (vendored Ling 3.0 backbone) |
| HF architecture string | `BailingMoeV3ForCausalLM` |

## Core dimensions

| Item | Value |
| --- | --- |
| hidden size | 1536 |
| layers | 24 |
| layer types | `[KDA ×3, MLA]` per group of 4 → **18 KDA + 6 MLA** (MLA at 3, 7, 11, 15, 19, 23) |
| layer 0 | dense MLP (`first_k_dense_replace = 1`) |
| MLP intermediate (dense) | 4608 |
| vocab size | 157184 |
| lm_head | untied (`tie_word_embeddings = false`) |
| embeddings | `model.word_embeddings.weight` |
| final norm | RMSNorm, eps 1e-6 |
| normalization | pre-norm: `input_layernorm`, `post_attention_layernorm` |
| context limit | `max_position_embeddings = 131072` |
| checkpoint quantization | 4-bit affine, group 64 (`U32` weights, `BF16` scales/biases) |
| conv/attention precision exceptions | short-conv stays fp; router gate 8-bit |

Special tokens (verified from the real tokenizer):
BOS `<|startoftext|>` = **156891**, EOS `<|role_end|>` = **156895**,
PAD `<|endoftext|>` = **156892**; the thinking cue is token **156903**
(`<think>`). The chat template wraps roles as `<role>SYSTEM</role>` /
`<role>HUMAN</role>` / `<role>ASSISTANT</role>`, ends every turn with
`<|role_end|>`, and the generation prompt appends
`<role>ASSISTANT</role>\n<think>` (thinking enabled by default).

## MLA (softmax attention layers)

| Item | Value |
| --- | --- |
| heads | 16 |
| qk nope / rope dims | 128 / 64 (qk head dim 192) |
| v head dim | 128 |
| q LoRA rank | 256 (`q_a_proj` → RMSNorm → `q_b_proj`) |
| kv LoRA rank | 512 (`kv_a_proj_with_mqa` → RMSNorm) |
| kv up-projection | `kv_b_proj` → `k_nope`, values |
| attention | SDPA, scale `192^-0.5` |
| RoPE | interleaved pairs, theta 6e6, 64 rotary dims (`partial_rotary_factor` 0.5) |
| output gate | V3-only **head-wise**: `out_h *= sigmoid(g_proj(x))_h` |
| output projection | checkpoint names it `dense` |
| qkv bias | none (`use_qkv_bias = false`) |

Notes:

- RoPE is applied to the 64 rope dims only; the upstream MLX reference
  hand-rolls the interleave form (consecutive pairs) because `mx.fast.rope`
  cannot express per-token positions during prefill.
- The upstream MLX module does **not** apply a separate QK norm in MLA.
  `use_qk_norm = true` in the config is not consumed by the vendored
  reference; KDA instead L2-normalizes q/k (below). Parity follows the
  vendored reference.

## KDA (linear-attention layers)

| Item | Value |
| --- | --- |
| heads | 16, head dim 128 (projection dim 2048) |
| short conv | causal depthwise, kernel 4, silu, rolling state `[B, 3, C]` |
| q/k normalization | L2 norm with eps 1e-6; q additionally scaled by `128^-0.5` |
| decay gate | safe-gate law: `g = lower_bound * sigmoid(exp(A_log) * (f + dt_bias))`, `lower_bound = -5` |
| f/g projections | direct (`no_kda_lora = true`): `f_proj`, `g_proj` hidden→2048 |
| beta | `sigmoid(b_proj(x))`, `b_proj` hidden→16 |
| recurrence | gated delta rule (mlx-lm `gated_delta_ops`/kernel), float32 state |
| output norm | RMSNorm over head dim (`o_norm`) |
| output gate | `out *= sigmoid(gate)` reshaped `[B,T,H,D]` |
| output projection | `o_proj` |

## Router / MoE

| Item | Value |
| --- | --- |
| routed experts | 128 per MoE layer |
| top-k | 8 |
| routing | sigmoid + noaux_tc expert bias; `n_group = 8`, `topk_group = 4` |
| group score | sum of the group's **top-2** selection scores |
| selection | `sigmoid(logits) + expert_bias`, top-k within surviving groups |
| weights | raw sigmoid of chosen experts (bias excluded), L1-normalized (`norm_topk_prob`), × 2.5 |
| shared expert | 1 resident SwiGLU MLP, intermediate 512 |
| routed expert quantization | 4-bit affine, group 64 |
| routed expert layout | separate `gate_proj`/`up_proj`/`down_proj` stacked on axis 0 |
| expert math order | `swiglu(up, gate) = silu(gate) * up` |
| dense layer-0 MLP | SwiGLU, intermediate 4608 |

Routed expert tensor geometry is recorded in
[EDGE0_NATIVE_FOUNDATION.md](EDGE0_NATIVE_FOUNDATION.md); the byte budget
(3,906,994,176 routed / 601,561,920 resident) is measured from the artifact.

## Prerouter (out of scope in Phase 3)

The checkpoint config carries `pregate_*` fields and the vendored module can
consume `prerouter_cache` logits. The production Edge0-8B profile sets
`patch_call = False` and `pregate_inference = false`; exact-mode inference
uses the **true router as the only routing authority**. The prerouter,
speculative prefetch, staging, and Recover-LoRA remain future work.

## Verified real-weight decoder blocks (Phase 3E)

Real checkpoint, real quantized resident weights, real streamed experts:

| Block | Implementation | Relative L2 |
| --- | --- | --- |
| Layer 0 (KDA + dense MLP) | `Edge0DecoderLayer` | **0.0** (bit-exact) |
| Layer 1 (KDA + streaming MoE) | `Edge0DecoderLayer` | **0.0** (bit-exact) |
| Layer 3 (MLA + streaming MoE) | `Edge0DecoderLayer` | 2.47e-07 |
| Layer 3 cached decode | `Edge0DecoderLayer` | 4.03e-07 |
| Router expert identity (layers 1, 3) | `Edge0Router` | 0/40 mismatches |
| KDA conv/recurrent state | `Edge0KDAAttention` | 0.0 / 0.0 |
| MLA KV cache (prefill/decode) | `Edge0MLAAttention` | 0.0 / 0.0 |

Three real port defects were found and fixed by the real-weight block tests:

1. `gather_qmm` MoE layout: upstream `SwitchGLU` expands the input by two
   singleton axes and squeezes only after the final down projection; the
   Phase 2/3 direct-call convention was structurally different.
2. RMSNorm must use the fused `MLXFast.rmsNorm` kernel (upstream
   `nn.RMSNorm`) rather than a manual `mean/rsqrt` composition.
3. KDA gate precision: `_kda_gate` casts `f`/`A_log`/`dt_bias` to float32,
   and the output-gate projection stays in its bf16 dtype; MoE aggregation
   must cast router weights to the expert dtype before the weighted sum.

## Status: exact native inference proven, factory active

The full 24-layer model executes natively from the real checkpoint with
layer parity at or below ~1e-6, exact argmax/top-20 logits, exact 16-token
greedy token identity, and bounded expert-pool stress. `.edge0MLX` now
resolves in `RuntimeEngineFactory` to `ManagedRuntimeEngine` →
`Edge0RuntimeBackend` → `Edge0Engine`.

What remains is product integration, not model math:

- The Assistant chat path (`CodingAssistantService`) and
  `LocalAIController`'s text facade still explicitly refuse `.edge0MLX`;
  they have not been re-routed through the factory/engine yet, so no
  catalog entry is added (a selectable model the UI cannot execute would
  be misleading).
- Top-k/top-p sampling filters are deferred; greedy and temperature
  sampling are supported.
- iOS device validation is outstanding.

## Verified resident quantized spine (real checkpoint)

| Comparison | Relative L2 |
| --- | --- |
| `model.layers.3.attention.q_b_proj` quantized linear | **0.0** |
| `model.word_embeddings` selected token rows | **0.0** |
| `lm_head` top-20 logits + argmax | **0.0 / exact** |

## Verified MLA state + tokenizer (real fixtures)

| Comparison | Relative L2 |
| --- | --- |
| MLA causal prefill output / keys / values | 8.1e-08 / 1.0e-07 / 6.9e-08 |
| MLA cached one-token decode output / keys / values | 1.4e-07 / 1.2e-07 / 1.0e-07 |
| MLA prefill-final vs sequential-final state | 2.3e-07 |
| Tokenizer plain texts (6 cases) | **exact IDs** |
| Chat template with generation prompt (34 IDs) | **exact IDs** |
