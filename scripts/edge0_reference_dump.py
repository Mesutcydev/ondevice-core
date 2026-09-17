#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Dump deterministic parity fixtures from the Edge0 reference model code.

Development-only tool. It is never imported by the app and is not part of the
app runtime. It loads the vendored upstream MLX implementation directly from
an Edge0 checkout and writes compact fixtures (JSON + tiny safetensors) that
the Swift parity tests compare against.

Usage:

    python3 scripts/edge0_reference_dump.py \
        --edge0 /tmp/edge0-reference \
        --output /tmp/edge0-fixtures \
        --cases router mla moe

Reference commit: 0700e6532f45e0d0d99e9c588d7d8cd240538ea0
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

import mlx.core as mx
import mlx.nn as nn

REFERENCE_SHA = "0700e6532f45e0d0d99e9c588d7d8cd240538ea0"


def load_bailing_hybrid(edge0_root: str):
    path = os.path.join(
        edge0_root, "src", "edge0", "backends", "mlx", "_impl",
        "bailing_hybrid.py",
    )
    if not os.path.exists(path):
        raise SystemExit(f"vendored model not found: {path}")
    spec = importlib.util.spec_from_file_location("bailing_hybrid", path)
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolve annotations through sys.modules; register first.
    sys.modules["bailing_hybrid"] = module
    spec.loader.exec_module(module)
    return module


def tiny_arg_common(module):
    return dict(
        model_type="bailing_hybrid",
        hidden_size=64,
        num_hidden_layers=2,
        intermediate_size=64,
        num_attention_heads=2,
        num_key_value_heads=2,
        head_dim=8,
        rms_norm_eps=1e-6,
        vocab_size=64,
        max_position_embeddings=64,
        tie_word_embeddings=False,
        layer_group_size=1,
        first_k_dense_replace=1,
        short_conv_kernel_size=4,
        no_kda_lora=True,
        kda_safe_gate=True,
        kda_lower_bound=-5.0,
        q_lora_rank=8,
        kv_lora_rank=16,
        qk_nope_head_dim=8,
        qk_rope_head_dim=8,
        v_head_dim=8,
        rope_theta=6_000_000.0,
        rope_interleave=True,
        rope_scaling=None,
        use_qkv_bias=False,
        gated_attention_proj_granularity_type="head_wise",
        num_experts=8,
        num_experts_per_tok=2,
        num_shared_experts=1,
        moe_intermediate_size=64,
        moe_shared_expert_intermediate_size=64,
        n_group=4,
        topk_group=2,
        norm_topk_prob=True,
        routed_scaling_factor=2.5,
        moe_router_enable_expert_bias=True,
        prerouter_enabled=False,
    )


def deterministic_array(shape, scale=0.1, offset=0):
    count = 1
    for dim in shape:
        count *= dim
    values = [((i * 7919 + offset * 104729) % 4093) / 4093.0 - 0.5
              for i in range(count)]
    return (mx.array(values, dtype=mx.float32).reshape(shape) * scale).astype(
        mx.bfloat16
    ).astype(mx.float32)


def dump_router(module, output_dir: str):
    """Reference router selection on deterministic random logits."""
    args = module.ModelArgs(**tiny_arg_common(module))
    mx.random.seed(0)
    gate = module.BailingGate(args)

    weight = deterministic_array((args.num_experts, args.hidden_size), 0.5, 1)
    expert_bias = deterministic_array((args.num_experts,), 0.4, 2)
    gate.weight = weight
    gate.expert_bias = expert_bias

    hidden = deterministic_array((3, args.hidden_size), 0.5, 3)
    logits = hidden @ weight.T
    idx, weights = gate(hidden)

    scores = mx.sigmoid(logits.astype(mx.float32))
    select = scores + expert_bias
    grouped = select.reshape(3, args.n_group, args.num_experts // args.n_group)
    top2 = mx.topk(grouped, 2, axis=-1)
    group_scores = top2.sum(axis=-1)

    fixture = {
        "reference_sha": REFERENCE_SHA,
        "num_experts": args.num_experts,
        "num_experts_per_tok": args.num_experts_per_tok,
        "n_group": args.n_group,
        "topk_group": args.topk_group,
        "routed_scaling_factor": args.routed_scaling_factor,
        "norm_topk_prob": args.norm_topk_prob,
        "hidden_size": args.hidden_size,
        "hidden": hidden.astype(mx.float32).tolist(),
        "router_weight": weight.tolist(),
        "expert_bias": expert_bias.tolist(),
        "expected_logits": logits.astype(mx.float32).tolist(),
        "expected_scores": scores.tolist(),
        "expected_group_scores": group_scores.tolist(),
        "expected_indices": idx.tolist(),
        "expected_weights": weights.astype(mx.float32).tolist(),
    }
    path = os.path.join(output_dir, "router_fixture.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle)
    print(f"[oracle] router fixture: {path}")
    return fixture


def dump_mla(module, output_dir: str):
    """Tiny MLA weights + inputs + outputs/intermediates."""
    args = module.ModelArgs(**tiny_arg_common(module))
    mx.random.seed(1234)
    mla = module.BailingMLA(args)

    input_x = deterministic_array((1, 3, args.hidden_size), 0.3, 11)
    output = mla(input_x, mask="causal")

    q = mla.q_b_proj(mla.q_a_layernorm(mla.q_a_proj(input_x)))
    q = q.reshape(1, 3, args.num_attention_heads, mla.qk_head_dim).transpose(
        0, 2, 1, 3
    )
    q_nope, q_pe = mx.split(q, [mla.qk_nope_head_dim], axis=-1)
    compressed = mla.kv_a_proj_with_mqa(input_x)
    kv_latent, k_pe = mx.split(compressed, [mla.kv_lora_rank], axis=-1)
    kv_latent = mla.kv_a_layernorm(kv_latent)
    k_pe = k_pe.reshape(1, 3, 1, mla.qk_rope_head_dim).transpose(0, 2, 1, 3)
    positions = mx.arange(3)
    q_pe_rotated = module._rope_interleave_torch(q_pe, positions, mla.rope_theta)
    k_pe_rotated = module._rope_interleave_torch(k_pe, positions, mla.rope_theta)
    gate = mx.sigmoid(mla.g_proj(input_x))

    tensors = {
        "input": input_x.astype(mx.float32),
        "q_a_proj.weight": mla.q_a_proj.weight.astype(mx.float32),
        "q_a_layernorm.weight": mla.q_a_layernorm.weight.astype(mx.float32),
        "q_b_proj.weight": mla.q_b_proj.weight.astype(mx.float32),
        "kv_a_proj_with_mqa.weight": mla.kv_a_proj_with_mqa.weight.astype(mx.float32),
        "kv_a_layernorm.weight": mla.kv_a_layernorm.weight.astype(mx.float32),
        "kv_b_proj.weight": mla.kv_b_proj.weight.astype(mx.float32),
        "dense.weight": mla.dense.weight.astype(mx.float32),
        "g_proj.weight": mla.g_proj.weight.astype(mx.float32),
        "q_nope": q_nope.astype(mx.float32),
        "q_pe_rotated": q_pe_rotated.astype(mx.float32),
        "k_pe_rotated": k_pe_rotated.astype(mx.float32),
        "mla_gate": gate.astype(mx.float32),
        "output": output.astype(mx.float32),
    }
    path = os.path.join(output_dir, "mla_tiny.safetensors")
    mx.save_safetensors(path, tensors)
    print(f"[oracle] MLA fixture: {path}")
    return tensors


def dump_mla_state(module, output_dir: str):
    """Stateful MLA: causal prefill + cached single-token decode.

    Uses mlx-lm's KVCache exactly as the upstream model does, so mask and
    offset semantics are the reference. Cache tensors are tiny.
    """
    from mlx_lm.models.cache import KVCache

    args = module.ModelArgs(**tiny_arg_common(module))
    mx.random.seed(9001)
    mla = module.BailingMLA(args)

    sequence = deterministic_array((1, 4, args.hidden_size), 0.4, 31)
    decode_token = deterministic_array((1, 1, args.hidden_size), 0.4, 32)

    # Prefill with a fresh cache and the causal mask the model computes.
    prefill_cache = KVCache()
    prefill_mask = module.create_attention_mask(sequence, prefill_cache)
    prefill_output = mla(sequence, prefill_mask, prefill_cache)

    # Cached single-token decode at absolute position 4.
    decode_cache = KVCache()
    decode_cache.offset = prefill_cache.offset
    decode_cache.keys = prefill_cache.keys
    decode_cache.values = prefill_cache.values
    decode_output = mla(decode_token, None, decode_cache)

    # Sequential prefill: same sequence, one token at a time.
    sequential_cache = KVCache()
    sequential_outputs = []
    sequential_states = []
    for t in range(4):
        token = sequence[:, t:t + 1]
        mask = module.create_attention_mask(token, sequential_cache)
        y = mla(token, mask, sequential_cache)
        sequential_outputs.append(y)
        sequential_states.append(
            (
                sequential_cache.keys[..., :sequential_cache.offset, :],
                sequential_cache.values[..., :sequential_cache.offset, :],
            )
        )

    tensors = {
        "q_a_proj.weight": mla.q_a_proj.weight,
        "q_a_layernorm.weight": mla.q_a_layernorm.weight,
        "q_b_proj.weight": mla.q_b_proj.weight,
        "kv_a_proj_with_mqa.weight": mla.kv_a_proj_with_mqa.weight,
        "kv_a_layernorm.weight": mla.kv_a_layernorm.weight,
        "kv_b_proj.weight": mla.kv_b_proj.weight,
        "dense.weight": mla.dense.weight,
        "g_proj.weight": mla.g_proj.weight,
        "sequence": sequence,
        "decode_token": decode_token,
        "prefill_output": prefill_output,
        "prefill_keys": prefill_cache.keys[..., :prefill_cache.offset, :],
        "prefill_values": prefill_cache.values[..., :prefill_cache.offset, :],
        "decode_output": decode_output,
        "decode_keys": decode_cache.keys[..., :decode_cache.offset, :],
        "decode_values": decode_cache.values[..., :decode_cache.offset, :],
        "sequential_output": mx.concatenate(sequential_outputs, axis=1),
    }
    for t in range(4):
        tensors[f"sequential_output_{t}"] = sequential_outputs[t]
        tensors[f"sequential_keys_{t}"] = sequential_states[t][0]
        tensors[f"sequential_values_{t}"] = sequential_states[t][1]
    path = os.path.join(output_dir, "mla_state_tiny.safetensors")
    mx.save_safetensors(path, tensors)
    print(f"[oracle] MLA state fixture: {path}")
    return tensors


def dump_moe(module, output_dir: str):
    """Tiny quantized MoE: router + gathered experts + shared expert."""
    args = module.ModelArgs(**tiny_arg_common(module))
    mx.random.seed(77)
    moe = module.BailingSparseMoE(args)

    # Deterministic router + expert weights.
    moe.gate.weight = deterministic_array(
        (args.num_experts, args.hidden_size), 0.5, 21
    )
    moe.gate.expert_bias = deterministic_array(
        (args.num_experts,), 0.3, 22
    )

    hidden = deterministic_array((1, 2, args.hidden_size), 0.4, 23)

    gate_float = deterministic_array(
        (args.num_experts, args.moe_intermediate_size, args.hidden_size), 0.3, 24
    )
    up_float = deterministic_array(
        (args.num_experts, args.moe_intermediate_size, args.hidden_size), 0.3, 25
    )
    down_float = deterministic_array(
        (args.num_experts, args.hidden_size, args.moe_intermediate_size), 0.3, 26
    )
    quantized = {}
    for name, value in (("gate_proj", gate_float), ("up_proj", up_float),
                        ("down_proj", down_float)):
        wq, scales, biases = mx.quantize(value, group_size=64, bits=4)
        quantized[f"experts.{name}.weight"] = wq
        quantized[f"experts.{name}.scales"] = scales.astype(mx.bfloat16)
        quantized[f"experts.{name}.biases"] = biases.astype(mx.bfloat16)

    shared_gate = deterministic_array(
        (args.moe_shared_expert_intermediate_size, args.hidden_size), 0.3, 27
    )
    shared_up = deterministic_array(
        (args.moe_shared_expert_intermediate_size, args.hidden_size), 0.3, 28
    )
    shared_down = deterministic_array(
        (args.hidden_size, args.moe_shared_expert_intermediate_size), 0.3, 29
    )
    moe.shared_experts.gate_proj.weight = shared_gate
    moe.shared_experts.up_proj.weight = shared_up
    moe.shared_experts.down_proj.weight = shared_down

    idx, weights = moe.gate(hidden)
    indices = idx.astype(mx.int32)

    qmm = lambda x, w, s, b, i: mx.gather_qmm(
        x, w, s, b, rhs_indices=i, transpose=True,
        group_size=64, bits=4, mode="affine",
    )
    expanded = mx.expand_dims(hidden, (-2, -3))
    up = qmm(expanded, quantized["experts.up_proj.weight"],
             quantized["experts.up_proj.scales"],
             quantized["experts.up_proj.biases"], indices)
    gate = qmm(expanded, quantized["experts.gate_proj.weight"],
               quantized["experts.gate_proj.scales"],
               quantized["experts.gate_proj.biases"], indices)
    swiglu = nn.silu(gate) * up
    down = qmm(swiglu, quantized["experts.down_proj.weight"],
               quantized["experts.down_proj.scales"],
               quantized["experts.down_proj.biases"], indices).squeeze(-2)
    aggregate = (down * weights[..., None].astype(down.dtype)).sum(axis=-2)
    shared = moe.shared_experts(hidden)
    output = aggregate + shared

    tensors = {
        "input": hidden.astype(mx.float32),
        "gate.weight": moe.gate.weight.astype(mx.float32),
        "expert_bias": moe.gate.expert_bias.astype(mx.float32),
        "shared_gate.weight": shared_gate.astype(mx.float32),
        "shared_up.weight": shared_up.astype(mx.float32),
        "shared_down.weight": shared_down.astype(mx.float32),
        "expected_indices": indices,
        "expected_router_weights": weights.astype(mx.float32),
        "expert_up": up.astype(mx.float32),
        "expert_gate": gate.astype(mx.float32),
        "swiglu": swiglu.astype(mx.float32),
        "expert_down": down.astype(mx.float32),
        "moe_aggregate": aggregate.astype(mx.float32),
        "shared_output": shared.astype(mx.float32),
        "moe_output": output.astype(mx.float32),
    }
    for name, value in quantized.items():
        tensors[name] = value
    path = os.path.join(output_dir, "moe_tiny.safetensors")
    mx.save_safetensors(path, tensors)
    print(f"[oracle] MoE fixture: {path}")
    return tensors


def dump_kda(module, output_dir: str):
    """Tiny KDA fixture: conv, safe gate, delta rule, prefill + sequential.

    The fused Metal kernel is disabled so both sides use upstream's
    `gated_delta_ops` reference path (the kernel is an optimization of the
    same math and is deferred).
    """
    import mlx_lm.models.gated_delta as gated_delta

    gated_delta.gated_delta_kernel = None

    args = module.ModelArgs(**tiny_arg_common(module))
    mx.random.seed(4242)
    kda = module.BailingKDA(args, 0)

    hidden = args.hidden_size
    proj = args.num_attention_heads * args.head_dim

    def det(name, shape, salt):
        value = deterministic_array(shape, 0.4, salt)
        return value

    kda.q_proj.weight = det("q", (proj, hidden), 101)
    kda.k_proj.weight = det("k", (proj, hidden), 102)
    kda.v_proj.weight = det("v", (proj, hidden), 103)
    kda.f_proj.weight = det("f", (proj, hidden), 104)
    kda.g_proj.weight = det("g", (proj, hidden), 105)
    kda.b_proj.weight = det("b", (args.num_attention_heads, hidden), 106)
    kda.q_conv1d.conv.weight = det(
        "qc", (proj, args.short_conv_kernel_size, 1), 107
    )
    kda.k_conv1d.conv.weight = det(
        "kc", (proj, args.short_conv_kernel_size, 1), 108
    )
    kda.v_conv1d.conv.weight = det(
        "vc", (proj, args.short_conv_kernel_size, 1), 109
    )
    kda.A_log = det("A", (args.num_attention_heads,), 110)
    kda.dt_bias = det("dt", (proj,), 111)
    kda.o_norm.weight = det("on", (args.head_dim,), 112)
    kda.o_proj.weight = det("op", (hidden, proj), 113)

    x = deterministic_array((1, 4, hidden), 0.5, 114)

    # Prefill with cache capture (upstream stores conv/ssm state in the
    # ArraysCache list when one is provided).
    cache = [None, None, None, None]
    prefill_output = kda(x, None, cache)

    # Intermediates via upstream helpers.
    q_conv, q_conv_state = kda.q_conv1d(kda.q_proj(x), None)
    k_conv, k_conv_state = kda.k_conv1d(kda.k_proj(x), None)
    v_conv, v_conv_state = kda.v_conv1d(kda.v_proj(x), None)
    q = q_conv.reshape(1, 4, args.num_attention_heads, args.head_dim)
    k = k_conv.reshape(1, 4, args.num_attention_heads, args.head_dim)
    v = v_conv.reshape(1, 4, args.num_attention_heads, args.head_dim)
    qf = q.astype(mx.float32)
    kf = k.astype(mx.float32)
    q_norm = kda.scale * qf / (
        mx.linalg.norm(qf, axis=-1, keepdims=True) + 1e-6
    )
    k_norm = kf / (mx.linalg.norm(kf, axis=-1, keepdims=True) + 1e-6)
    f = kda.f_proj(x).reshape(1, 4, args.num_attention_heads, args.head_dim)
    g_log = module._kda_gate(
        f, kda.A_log, kda.dt_bias.reshape(args.num_attention_heads, args.head_dim),
        safe_gate=kda.safe_gate, lower_bound=kda.lower_bound,
    )
    beta = mx.sigmoid(kda.b_proj(x).astype(mx.float32))
    gate = kda.g_proj(x).reshape(1, 4, args.num_attention_heads, args.head_dim)

    # Sequential decode: same inputs fed one token at a time.
    recurrent = None
    step_outputs = []
    step_states = []
    for t in range(4):
        y_t, recurrent = module._kda_update(
            q_norm[:, t:t + 1], k_norm[:, t:t + 1], v[:, t:t + 1],
            g_log[:, t:t + 1], beta[:, t:t + 1], recurrent,
        )
        step_outputs.append(y_t)
        step_states.append(recurrent)
    sequential_output = mx.concatenate(step_outputs, axis=1)

    # True sequential module decode: one token at a time with a persistent
    # cache, so conv state advances exactly as it would in generation.
    decode_cache = [None, None, None, None]
    step_module_outputs = []
    for t in range(4):
        step_module_outputs.append(kda(x[:, t:t + 1], None, decode_cache))

    tensors = {
        "input": x,
        "q_proj.weight": kda.q_proj.weight,
        "k_proj.weight": kda.k_proj.weight,
        "v_proj.weight": kda.v_proj.weight,
        "f_proj.weight": kda.f_proj.weight,
        "g_proj.weight": kda.g_proj.weight,
        "b_proj.weight": kda.b_proj.weight,
        "q_conv.weight": kda.q_conv1d.conv.weight,
        "k_conv.weight": kda.k_conv1d.conv.weight,
        "v_conv.weight": kda.v_conv1d.conv.weight,
        "A_log": kda.A_log,
        "dt_bias": kda.dt_bias,
        "o_norm.weight": kda.o_norm.weight,
        "o_proj.weight": kda.o_proj.weight,
        "q_conv_out": q_conv,
        "k_conv_out": k_conv,
        "v_conv_out": v_conv,
        "q_conv_state": q_conv_state,
        "k_conv_state": k_conv_state,
        "v_conv_state": v_conv_state,
        "q_norm": q_norm,
        "k_norm": k_norm,
        "g_log": g_log,
        "beta": beta,
        "gate": gate,
        "prefill_output": prefill_output,
        "prefill_conv_state": cache[0],
        "prefill_recurrent_state": cache[3],
        "sequential_output": sequential_output,
        "sequential_final_state": step_states[-1],
    }
    for t in range(4):
        tensors[f"step_output_{t}"] = step_outputs[t]
        tensors[f"step_state_{t}"] = step_states[t]
        tensors[f"step_module_output_{t}"] = step_module_outputs[t]
    tensors["sequential_cache_conv_state"] = decode_cache[0]
    tensors["sequential_cache_recurrent_state"] = decode_cache[3]
    path = os.path.join(output_dir, "kda_tiny.safetensors")
    mx.save_safetensors(path, tensors)
    print(f"[oracle] KDA fixture: {path}")
    return tensors


def dump_real(output_dir: str, model_dir: str):
    """Real-checkpoint resident fixtures: one quantized projection, selected
    embedding rows, and lm_head top logits. Weights stay quantized; only
    sliced rows and reduced results are dumped."""
    path = os.path.join(model_dir, "model.safetensors")
    if not os.path.exists(path):
        raise SystemExit(f"real checkpoint not found: {path}")

    # One full load (the checkpoint is ~4.5 GB; the oracle host has the RAM).
    # bfloat16 has no numpy/safetensors-numpy representation, so use MLX.
    all_tensors = mx.load(path)

    def three(prefix):
        return (
            all_tensors[f"{prefix}.weight"],
            all_tensors[f"{prefix}.scales"],
            all_tensors[f"{prefix}.biases"],
        )

    # 1) Quantized linear: layer 3 MLA q_b_proj [3072, 256].
    qw, qs, qb = three("model.layers.3.attention.q_b_proj")
    x = deterministic_array((2, qw.shape[1] * 8), 0.5, 201).astype(mx.bfloat16)
    y = mx.quantized_matmul(
        x, qw, scales=qs, biases=qb, transpose=True, group_size=64, bits=4
    )

    # 2) Quantized embedding: selected token rows.
    ew, es, eb = three("model.word_embeddings")
    token_ids = [156895, 156892, 12345, 9707, 220, 16]
    ids = mx.array(token_ids, dtype=mx.int32)
    embed = mx.dequantize(
        ew[ids], scales=es[ids], biases=eb[ids], group_size=64, bits=4
    )

    # 3) lm_head: deterministic hidden -> full logits, reduced to top-20.
    lw, ls, lb = three("lm_head")
    hidden = deterministic_array((1, 1536), 0.5, 202).astype(mx.bfloat16)
    logits = mx.quantized_matmul(
        hidden, lw, scales=ls, biases=lb, transpose=True, group_size=64, bits=4
    )
    logits32 = logits.astype(mx.float32)
    top_values, top_indices = mx.topk(logits32, 20, axis=-1), None
    order = mx.argpartition(-logits32, kth=19, axis=-1)[..., :20]
    top_values = mx.take_along_axis(logits32, order, axis=-1)
    argmax = mx.argmax(logits32, axis=-1)

    tensors = {
        "q_b_proj.weight": qw,
        "q_b_proj.scales": qs,
        "q_b_proj.biases": qb,
        "quant_input": x,
        "quant_output": y.astype(mx.float32),
        "embed_ids": ids,
        "embed_output": embed.astype(mx.float32),
        "lm_hidden": hidden,
        "lm_top_indices": order.astype(mx.int32),
        "lm_top_values": top_values,
        "lm_argmax": argmax.astype(mx.int32),
    }
    fixture_path = os.path.join(output_dir, "real_tiny.safetensors")
    mx.save_safetensors(fixture_path, tensors)
    print(f"[oracle] real fixture: {fixture_path}")
    return tensors


def dump_tokenizer(output_dir: str, artifacts_dir: str):
    """Exact token IDs for fixed texts and the real chat template."""
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(
        artifacts_dir, trust_remote_code=False
    )
    texts = [
        "The capital of France is",
        "Hello, world!",
        "print('hello')",
        "Merhaba dünya",
        "你好世界",
        "line one\nline two",
    ]
    plain = {text: tokenizer.encode(text) for text in texts}

    messages = [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is 2+2?"},
    ]
    chat_ids = tokenizer.apply_chat_template(
        messages, tokenize=True, add_generation_prompt=True
    )["input_ids"]
    chat_text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    # Special token IDs from the actual vocabulary.
    special_tokens = {}
    for name in ("bos_token", "eos_token", "pad_token", "unk_token"):
        token = getattr(tokenizer, name, None)
        if token is not None:
            special_tokens[name] = {
                "token": str(token),
                "id": tokenizer.convert_tokens_to_ids(token),
            }
    special_ids = {}
    for token in (
        "<|startoftext|>", "<|endoftext|>", "<|role_start|>",
        "<|role_end|>", "<|assistant|>",
    ):
        value = tokenizer.convert_tokens_to_ids(token)
        if value is not None:
            special_ids[token] = value

    fixture = {
        "reference_sha": REFERENCE_SHA,
        "plain": plain,
        "chat_messages": messages,
        "chat_ids": chat_ids,
        "chat_text": chat_text,
        "special_tokens": special_tokens,
        "special_ids": special_ids,
    }
    path = os.path.join(output_dir, "tokenizer_fixture.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle, ensure_ascii=False)
    print(f"[oracle] tokenizer fixture: {path}")
    return fixture


def load_real_model(module, model_dir):
    """Load the real Edge0-8B checkpoint through mlx-lm with the vendored
    class pair (lazy mmap weights). Development-only oracle path."""
    from pathlib import Path
    from mlx_lm.utils import load_model as _load_model

    return _load_model(
        Path(model_dir), lazy=True, strict=False,
        model_config={"model_type": "bailing_hybrid"},
        get_model_classes=lambda config: (module.Model, module.ModelArgs),
    )


def dump_real_layers(module, output_dir: str, model_dir: str):
    """Real-checkpoint layer captures for layers 0, 1, 3 plus per-layer
    outputs for the full 24-layer forward on a fixed prompt.

    Compact only: small hidden sequences are stored fully; logits are
    reduced to top-20/argmax; states are sliced to their real offset.
    """
    import mlx.core as mx
    import mlx_lm.models.gated_delta as gated_delta

    # Parity runs both sides on the ops recurrence; the fused Metal kernel is
    # a performance path with a different accumulation order.
    gated_delta.gated_delta_kernel = None

    model, _config = load_real_model(module, model_dir)
    tokenizer_path = os.path.join(model_dir, "tokenizer.json")
    prompt_ids = [678, 7706, 300, 11406, 341]  # "The capital of France is"

    ids = mx.array([prompt_ids], dtype=mx.int32)
    embed = model.model.word_embeddings(ids)
    mx.eval(embed)

    # Full forward with per-layer output capture.
    caches = model.make_cache()
    captured = {}

    def after_layer(li, h):
        captured[li] = h

    logits = model(ids, cache=caches, after_layer_cb=after_layer)
    mx.eval(logits)
    hidden = captured[23]
    final_norm = model.model.norm(hidden)
    mx.eval(final_norm)
    last_logits = logits[0, -1].astype(mx.float32)
    order = mx.argpartition(-last_logits, kth=19)[:20]
    top_values = mx.take(last_logits, order)
    argmax = mx.argmax(last_logits)

    tensors = {
        "prompt_ids": ids,
        "embed": embed.astype(mx.float32).reshape(1, len(prompt_ids), -1),
        "final_norm": final_norm.astype(mx.float32),
        "logits_top_indices": order.astype(mx.int32),
        "logits_top_values": top_values,
        "logits_argmax": argmax.reshape(1).astype(mx.int32),
    }
    for li in range(24):
        tensors[f"layer_{li}_out"] = captured[li].astype(mx.float32)

    # Isolated block captures for the representative layers.
    def block_capture(li, x):
        layer = model.model.layers[li]
        cache = model.make_cache()[li]
        is_mla = layer.is_mla
        mask = module.create_attention_mask(x, cache) if is_mla else None
        normed = layer.input_layernorm(x)
        attention = layer.attention(normed, mask, cache)
        first_residual = x + attention
        mlp_norm = layer.post_attention_layernorm(first_residual)
        prefix = f"layer_{li}"
        result = {
            f"{prefix}_block_input": x.astype(mx.float32),
            f"{prefix}_input_norm": normed.astype(mx.float32),
            f"{prefix}_attention_out": attention.astype(mx.float32),
            f"{prefix}_first_residual": first_residual.astype(mx.float32),
            f"{prefix}_mlp_norm": mlp_norm.astype(mx.float32),
        }
        if isinstance(layer.mlp, module.BailingSparseMoE):
            idx, weights = layer.mlp.gate(mlp_norm)
            routed = layer.mlp.experts(mlp_norm, idx)
            aggregate = (
                routed * weights[..., None].astype(routed.dtype)
            ).sum(axis=-2)
            shared = layer.mlp.shared_experts(mlp_norm)
            mlp_out = aggregate + shared
            result[f"{prefix}_router_indices"] = idx.astype(mx.int32)
            result[f"{prefix}_router_weights"] = weights.astype(mx.float32)
            result[f"{prefix}_shared_out"] = shared.astype(mx.float32)
            result[f"{prefix}_routed_agg"] = aggregate.astype(mx.float32)
        else:
            mlp_out = layer.mlp(mlp_norm)
        result[f"{prefix}_mlp_out"] = mlp_out.astype(mx.float32)
        result[f"{prefix}_output"] = (first_residual + mlp_out).astype(mx.float32)
        if is_mla:
            result[f"{prefix}_keys"] = cache.keys[..., : cache.offset, :]
            result[f"{prefix}_values"] = cache.values[..., : cache.offset, :]
        else:
            result[f"{prefix}_kda_conv_state"] = cache[0]
            result[f"{prefix}_kda_recurrent"] = cache[3]
        return result

    for li in (0, 1, 3):
        layer_input = embed if li == 0 else captured[li - 1]
        tensors.update(block_capture(li, layer_input))

    # State snapshots for every layer after the full prefill.
    for li, cache in enumerate(caches):
        layer = model.model.layers[li]
        if layer.is_mla:
            tensors[f"state_{li}_keys"] = cache.keys[..., : cache.offset, :]
            tensors[f"state_{li}_values"] = cache.values[..., : cache.offset, :]
        else:
            tensors[f"state_{li}_conv"] = cache[0]
            tensors[f"state_{li}_recurrent"] = cache[3]

    # Greedy 16-token generation from the same prefill caches.
    generated = []
    token = int(argmax.item())
    generated.append(token)
    for step in range(16):
        step_logits = model(
            mx.array([[token]], dtype=mx.int32), cache=caches
        )
        last = step_logits[0, -1].astype(mx.float32)
        top_order = mx.argpartition(-last, kth=19)[:20]
        top_vals = mx.take(last, top_order)
        next_token = int(mx.argmax(last).item())
        if step == 0:
            tensors["decode0_top_indices"] = top_order.astype(mx.int32)
            tensors["decode0_top_values"] = top_vals
            tensors["decode0_argmax"] = mx.array([next_token], dtype=mx.int32)
        generated.append(next_token)
        token = next_token
    tensors["generated_ids"] = mx.array(generated, dtype=mx.int32)
    for li in (0, 3, 22):
        cache = caches[li]
        layer = model.model.layers[li]
        if layer.is_mla:
            tensors[f"decode16_state_{li}_keys"] = cache.keys[..., : cache.offset, :]
            tensors[f"decode16_state_{li}_values"] = cache.values[..., : cache.offset, :]
        else:
            tensors[f"decode16_state_{li}_conv"] = cache[0]
            tensors[f"decode16_state_{li}_recurrent"] = cache[3]

    # One cached decode step through layer 3 using a dedicated cache that is
    # re-filled by a fresh deterministic prefill of the same input, so the
    # shared generation caches stay pristine.
    from mlx_lm.models.cache import KVCache

    layer3 = model.model.layers[3]
    cache3 = KVCache()
    layer3_input = captured[2]
    _ = layer3(
        layer3_input,
        module.create_attention_mask(layer3_input, cache3),
        cache3,
    )
    next_token = int(argmax.item())
    decode_embed = model.model.word_embeddings(
        mx.array([[next_token]], dtype=mx.int32)
    )
    decode_out = layer3(decode_embed, None, cache3)
    tensors["layer_3_decode_input"] = decode_embed.astype(mx.float32)
    tensors["layer_3_decode_output"] = decode_out.astype(mx.float32)
    tensors["layer_3_decode_keys"] = cache3.keys[..., : cache3.offset, :]
    tensors["layer_3_decode_values"] = cache3.values[..., : cache3.offset, :]


    path = os.path.join(output_dir, "real_layers.safetensors")
    mx.save_safetensors(path, tensors)
    print(f"[oracle] real layers fixture: {path}")
    print(f"[oracle] next_token={next_token}")
    return tensors


def dump_prerouter(output_dir: str, model_dir: str, edge0_root: str) -> None:
    """Phase 4B-3 prerouter-head fixtures.

    Faithful upstream math: PrerouterHead (fc1 -> exact erf gelu -> fc2 +
    linear_init, fp16) on concat[hidden, this-token top-k one-hot,
    prev-token top-k one-hot], then the ling SIGMOID_GROUP selection
    (n_group 8, topk_group 4, routed_scaling 2.5, normalized).

    Inputs: real last-token hidden from the real_layers fixture
    (`layer_N_out`) for owners 7/15/22; deterministic one-hot ID sets so
    the fixture is stable and independent of router fixtures.
    """
    import sys
    import mlx.core as mx
    src_root = os.path.join(edge0_root, "src")
    if src_root not in sys.path:
        sys.path.insert(0, src_root)
    from edge0.prerouter.heads import PrerouterHead, topk_onehot
    from edge0.moe.routing import group_select_from_logits

    weights_path = os.path.join(model_dir, "prerouter_edge0_8b.safetensors")
    weights = mx.load(weights_path)
    fixture_path = os.path.join(output_dir, "real_layers.safetensors")
    fixtures = mx.load(fixture_path)

    this_ids = list(range(0, 8))
    prev_ids = list(range(8, 16))
    tensors = {
        "prerouter_this_ids": mx.array([this_ids], dtype=mx.int32).reshape(1, 1, 8),
        "prerouter_prev_ids": mx.array([prev_ids], dtype=mx.int32).reshape(1, 1, 8),
    }

    for owner in (7, 15, 22):
        head = PrerouterHead(
            hidden=1536, num_experts=128, prerouter_hidden=512,
            dtype=mx.float16,
        )
        head.fc1.weight = weights[f"layers.{owner}.fc1.weight"]
        head.fc2.weight = weights[f"layers.{owner}.fc2.weight"]
        head.linear_init.weight = weights[f"layers.{owner}.linear_init.weight"]

        hidden = fixtures[f"layer_{owner}_out"][:, -1:, :].astype(mx.float16)
        cur_oh = topk_onehot(
            tensors["prerouter_this_ids"], 128
        ).astype(mx.float16)
        prev_oh = topk_onehot(
            tensors["prerouter_prev_ids"], 128
        ).astype(mx.float16)
        logits = head(hidden, cur_oh, prev_oh)
        mx.eval(logits)

        idx, scores = group_select_from_logits(
            logits, 8, n_group=8, topk_group=4, routed_scaling=2.5
        )
        mx.eval(idx, scores)

        tensors[f"prerouter_{owner}_hidden"] = hidden.astype(mx.float32)
        tensors[f"prerouter_{owner}_logits"] = logits.astype(mx.float32)
        tensors[f"prerouter_{owner}_selected_ids"] = idx.astype(mx.int32)
        tensors[f"prerouter_{owner}_selected_scores"] = scores.astype(mx.float32)

    out_path = os.path.join(output_dir, "prerouter_fixture.safetensors")
    mx.save_safetensors(out_path, tensors)
    print(f"wrote {out_path} ({len(tensors)} tensors)")



def dump_35b_model(output_dir: str, model_dir: str, edge0_root: str) -> None:
    """Phase 5B full-model oracle for Edge0-35B-A3B-preview.

    Loads the vendored qwen3_5_moe backbone (lazy), applies the release
    Recover-LoRA, pins the MoE top_k to the released K=4, then captures a
    real-prompt forward: per-layer outputs, final norm, top-20 logits,
    argmax, representative linear/conv states + full-attention KV caches,
    one-step decode and a short greedy sequence. No prerouter, no staged
    execution — pure release-math correctness fixtures.
    """
    import sys
    import mlx.core as mx
    src_root = os.path.join(edge0_root, "src")
    if src_root not in sys.path:
        sys.path.insert(0, src_root)
    # Parity must use the OPS recurrence: the fused Metal kernel is a
    # performance path with a different accumulation order (same reason the
    # 8B fixtures disable it). The vendored qwen3_5 module imported
    # `gated_delta_update` by name, so re-bind it there to force
    # `use_kernel=False`.
    import mlx_lm.models.gated_delta as gated_delta
    _update_orig = gated_delta.gated_delta_update

    def _update_ops_only(q, k, v, a, b, A_log, dt_bias, state=None,
                         mask=None, use_kernel=True):
        return _update_orig(q, k, v, a, b, A_log, dt_bias, state, mask,
                            False)

    gated_delta.gated_delta_update = _update_ops_only
    import edge0.backends.mlx._impl.qwen3_5 as _qwen35
    _qwen35.gated_delta_update = _update_ops_only

    from edge0.backends.mlx.io import load_model
    from edge0.adapters.lora import install_lora
    from edge0.engine.qwen import _get_model_classes

    model_dir = os.path.abspath(model_dir)
    model, model_config = load_model(
        model_dir, lazy=True, strict=False,
        model_config={"model_type": "qwen3_5_moe"},
        get_model_classes=_get_model_classes)
    lm = model.language_model
    # K=4 release contract on every MoE block.
    k = 4
    for layer in lm.model.layers:
        mlp = layer.mlp
        if hasattr(mlp, "top_k"):
            mlp.top_k = k

    # Release Recover-LoRA.
    report = install_lora(
        model, os.path.join(model_dir, "lora_edge0_35b.safetensors"),
        r=16, alpha=32.0, strict=True)
    print(f"[edge0-35b] lora applied: {len(report.get('applied', []))} "
          f"scale={report.get('scale')}")

    tokenizer = mx_tokenizer_from(model_dir)
    prompt = "The capital of France is"
    ids = tokenizer.encode(prompt).ids
    print(f"[edge0-35b] prompt ids: {ids}")

    cache = lm.make_cache()
    captured = {}

    # ---- Focused layer-0 trace -------------------------------------------
    # The recurrence wrapper sees q/k/v AFTER the conv + rms_norm + scaling
    # and receives a/b BEFORE decay/beta are derived, so this isolates the
    # projection/conv/norm pipeline from the recurrence without duplicating
    # any math. Only the first (layer-0, prefill) call is captured.
    trace = {}
    update_ref = _qwen35.gated_delta_update

    def update_traced(q, k, v, a, b, A_log, dt_bias, state=None, mask=None,
                      use_kernel=True):
        if not trace:
            beta = mx.sigmoid(b)
            decay = gated_delta.compute_g(A_log, a, dt_bias)
            mx.eval(beta, decay)
            trace["l0_q"] = q
            trace["l0_k"] = k
            trace["l0_v"] = v
            trace["l0_decay"] = decay
            trace["l0_beta"] = beta
            tokens = q.shape[1]
            for t in range(1, tokens + 1):
                _, st = gated_delta.gated_delta_ops(
                    q[:, :t], k[:, :t], v[:, :t],
                    decay[:, :t], beta[:, :t], None, None)
                mx.eval(st)
                trace[f"l0_state_after_t{t}"] = st
        return update_ref(q, k, v, a, b, A_log, dt_bias, state, mask, False)

    _qwen35.gated_delta_update = update_traced

    # Capture the TRUE router selections per layer/token so routing flips can
    # be located exactly (amplification source when drift crosses a boundary).
    router_ids = {}
    gate_logits = {}
    moe_inputs = {}
    # Phase 5J prerouter fixture: capture the FIRST decode-step MoE input
    # and true executed expert ids for the released 35B owners (6..38).
    PR_OWNERS = {6, 12, 20, 30, 38}
    pr_armed = [False]
    pr_decode = {}
    for li, layer in enumerate(lm.model.layers):
        mlp = layer.mlp
        if not hasattr(mlp, "switch_mlp"):
            continue
        original_switch = mlp.switch_mlp
        original_gate = mlp.gate

        def make_switch(original_switch, li):
            def wrapped(x, inds):
                router_ids.setdefault(li, inds)
                if pr_armed[0] and li in PR_OWNERS:
                    pr_decode.setdefault(li, {})["inds"] = inds
                return original_switch(x, inds)
            return wrapped

        def make_gate(original_gate, li):
            def wrapped(x):
                out = original_gate(x)
                gate_logits.setdefault(li, out)
                moe_inputs.setdefault(li, x)
                if pr_armed[0] and li in PR_OWNERS:
                    pr_decode.setdefault(li, {})["x"] = x
                return out
            return wrapped

        mlp.switch_mlp = make_switch(original_switch, li)
        mlp.gate = make_gate(original_gate, li)

    # ---- Focused layer-3 (full attention) trace --------------------------
    # Wraps the REAL attention submodules so every intermediate comes from
    # the production path, not a re-implementation.
    l3trace = {}
    attn3 = lm.model.layers[3].self_attn
    _q3, _k3, _v3 = attn3.q_proj, attn3.k_proj, attn3.v_proj
    _rope3, _o3 = attn3.rope, attn3.o_proj

    def q3_wrapped(x):
        out = _q3(x)
        l3trace.setdefault("q_proj_out", out)
        return out

    def k3_wrapped(x):
        out = _k3(x)
        l3trace.setdefault("k_proj_out", out)
        return out

    def v3_wrapped(x):
        out = _v3(x)
        l3trace.setdefault("v_proj_out", out)
        return out

    def rope3_wrapped(x, offset=None):
        out = _rope3(x, offset=offset) if offset is not None else _rope3(x)
        if "rope_in" not in l3trace:
            l3trace["rope_in"] = x
            l3trace["rope_out"] = out
        elif "rope_in_k" not in l3trace:
            l3trace["rope_in_k"] = x
            l3trace["rope_out_k"] = out
        return out

    def o3_wrapped(x):
        l3trace.setdefault("o_proj_in", x)
        out = _o3(x)
        l3trace.setdefault("attn_out", out)
        return out

    attn3.q_proj = q3_wrapped
    attn3.k_proj = k3_wrapped
    attn3.v_proj = v3_wrapped
    attn3.rope = rope3_wrapped
    attn3.o_proj = o3_wrapped

    import edge0.backends.mlx._impl.qwen3_next as _qn
    _sdpa_orig = _qn.scaled_dot_product_attention

    def sdpa_wrapped(q, k, v, **kwargs):
        out = _sdpa_orig(q, k, v, **kwargs)
        l3trace.setdefault("sdpa_out", out)
        return out

    _qn.scaled_dot_product_attention = sdpa_wrapped

    def after_layer(li, h):
        captured[li] = h

    # The vendored TextModel returns NORMED hidden states; the engine
    # applies lm_head afterwards. Mirror that exactly.
    normed = lm.model(
        mx.array([ids], dtype=mx.int32), cache=cache,
        after_layer_cb=after_layer)
    mx.eval(normed)
    logits = lm.lm_head(normed[:, -1, :])
    mx.eval(logits)
    last = logits[0].astype(mx.float32)
    order = mx.argpartition(-last, kth=19)[:20]
    top_values = mx.take(last, order)
    argmax = mx.argmax(last)

    tensors = {
        "prompt_ids": mx.array([ids], dtype=mx.int32),
        "logits_top_indices": order.astype(mx.int32),
        "logits_top_values": top_values,
        "logits_argmax": argmax.reshape(1).astype(mx.int32),
        "final_norm": normed[0, -1].astype(mx.float32),
    }
    for li in range(40):
        tensors[f"layer_{li}_out"] = captured[li][0, -1].astype(mx.float32)

    # Layer-0 gate logits + MoE input + attention output (the residual
    # boundary after out_proj/LoRA).
    trace["l0_gate_logits"] = gate_logits.get(0)
    trace["l0_moe_input"] = moe_inputs.get(0)
    trace["l0_attn_out"] = (
        captured[0]
        - lm.model.embed_tokens(mx.array([ids], dtype=mx.int32))
    )

    # Router selections for all layers (5 prompt tokens).
    router_tensors = {}
    for li, tensor_ids in router_ids.items():
        router_tensors[f"router_ids_{li}"] = tensor_ids.astype(mx.int32)
    mx.eval(*router_tensors.values())
    router_path = os.path.join(output_dir, "edge0_35b_router_ids.safetensors")
    mx.save_safetensors(router_path, router_tensors)
    print(f"wrote {router_path} ({len(router_tensors)} layers)")

    # Layer-3 attention input (deterministic recomputation of the same op).
    if 3 in captured:
        trace["l3_input_norm"] = lm.model.layers[3].input_layernorm(
            captured[2]
        )
        for key, value in l3trace.items():
            trace[f"l3_{key}"] = value

    # Layer-0 attention input (deterministic recomputation of the same op).
    trace["l0_input_norm"] = lm.model.layers[0].input_layernorm(
        lm.model.embed_tokens(mx.array([ids], dtype=mx.int32))
    )
    trace["l0_embed"] = lm.model.embed_tokens(mx.array([ids], dtype=mx.int32))
    mx.eval(*trace.values())
    trace_path = os.path.join(output_dir, "edge0_35b_layer0_trace.safetensors")
    mx.save_safetensors(trace_path, {k: v for k, v in trace.items()})
    print(f"wrote {trace_path} ({len(trace)} tensors)")

    # Representative states after prefill.
    for li in (0, 20, 38):
        cache_l = cache[li]
        if hasattr(cache_l, "keys"):
            tensors[f"state_{li}_keys"] = cache_l.keys[0, :, :, :].astype(mx.float32)
            tensors[f"state_{li}_values"] = cache_l.values[0, :, :, :].astype(mx.float32)
        else:
            # ArraysCache for GatedDeltaNet: [conv_state, recurrent]
            tensors[f"state_{li}_conv"] = cache_l[0].astype(mx.float32)
            tensors[f"state_{li}_recurrent"] = cache_l[1].astype(mx.float32)

    # Greedy generation from the prefill cache. Emission contract:
    #   emitted_ids[0]   = token selected from the PREFILL logits (not a
    #                      decode output); it is fed as the first decode input
    #   emitted_ids[1...] = one argmax per decode call
    #   total length     = decode_calls + 1 (never truncated)
    prefill_argmax = int(argmax.item())
    decode_calls = 8
    emitted = [prefill_argmax]
    token = prefill_argmax
    eos_hit = False
    pr_armed[0] = True
    for step in range(decode_calls):
        step_hidden = lm.model(
            mx.array([[token]], dtype=mx.int32), cache=cache
        )
        step_logits = lm.lm_head(step_hidden[:, -1, :])
        last = step_logits[0].astype(mx.float32)
        next_token = int(mx.argmax(last).item())
        emitted.append(next_token)
        token = next_token
        if next_token in (248046, 248044):
            eos_hit = True
            break
    pr_armed[0] = False
    tensors["generated_ids"] = mx.array(emitted, dtype=mx.int32)
    assert emitted[0] == prefill_argmax
    assert len(emitted) == decode_calls + 1 or eos_hit
    # ---- Phase 5J prerouter fixture -------------------------------------
    pr_head_path = os.path.join(model_dir, "prerouter_edge0_35b.safetensors")
    if os.path.exists(pr_head_path) and len(pr_decode) == len(PR_OWNERS):
        head_weights = dict(mx.load(pr_head_path))
        pr_tensors = {}
        for owner in sorted(PR_OWNERS):
            entry = pr_decode[owner]
            m_in = entry["x"].astype(mx.float32)
            executed = entry["inds"].astype(mx.int32)
            eye = mx.eye(256, dtype=mx.float32)
            cur_oh = mx.take(eye, executed, axis=0).sum(axis=-2)
            prev_oh = mx.zeros((1, 1, 256), dtype=mx.float32)
            feats = mx.concatenate([m_in, cur_oh, prev_oh], axis=-1).astype(mx.float16)
            w1 = head_weights[f"layers.{owner}.fc1.weight"]
            w2 = head_weights[f"layers.{owner}.fc2.weight"]
            w3 = head_weights[f"layers.{owner}.linear_init.weight"]
            h1 = mx.matmul(feats, mx.transpose(w1))
            act = 0.5 * h1 * (1.0 + mx.erf(h1 / (2 ** 0.5)))
            fc2 = mx.matmul(act, mx.transpose(w2))
            lin = mx.matmul(feats, mx.transpose(w3))
            head_logits = lin + fc2
            gates = mx.softmax(head_logits, axis=-1, precise=True)
            sel = mx.argpartition(gates, kth=-4, axis=-1)[..., -4:]
            scores = mx.take_along_axis(gates, sel, axis=-1)
            scores = scores / scores.sum(axis=-1, keepdims=True)
            mx.eval(feats, h1, act, fc2, lin, head_logits, sel, scores)
            pr_tensors[f"pr_owner{owner}_features"] = feats
            pr_tensors[f"pr_owner{owner}_hidden"] = act.astype(mx.float16)
            pr_tensors[f"pr_owner{owner}_fc2"] = fc2.astype(mx.float16)
            pr_tensors[f"pr_owner{owner}_linear"] = lin.astype(mx.float16)
            pr_tensors[f"pr_owner{owner}_logits"] = head_logits.astype(mx.float16)
            pr_tensors[f"pr_owner{owner}_selected_ids"] = sel.astype(mx.int32)
        pr_path = os.path.join(output_dir, "edge0_35b_prerouter_fixture.safetensors")
        mx.save_safetensors(pr_path, pr_tensors)
        print(f"wrote {pr_path} ({len(pr_tensors)} tensors, owners {sorted(PR_OWNERS)})")
    else:
        print(f"[edge0-35b] prerouter fixture skipped: "
              f"artifact={os.path.exists(pr_head_path)} captures={sorted(pr_decode)}")

    print(f"[edge0-35b] emitted ids: {emitted} "
          f"(prefill_argmax={prefill_argmax}, decode_calls={decode_calls}, "
          f"eos_hit={eos_hit})")

    # Explicit, separately recorded metadata (no ambiguity for future
    # Swift acceptance tests).
    from importlib.metadata import version as pkg_version
    meta = {
        "edge0_sha": "0700e6532f45e0d0d99e9c588d7d8cd240538ea0",
        "model_repo": "Edge0/Edge0-35B-A3B-preview",
        "model_revision": "1ff9f4478890faec0368c5463b621d1036d5b518",
        "release_contract": {
            "base_checkpoint": True,
            "lora": {
                "file": "lora_edge0_35b.safetensors",
                "rank": 16,
                "alpha": 32.0,
                "scale": float(report.get("scale", 2.0)),
                "applied": len(report.get("applied", [])),
            },
            "execution_top_k": 4,
            "declared_top_k": 8,
            "norm_topk_prob": True,
            "prerouter": False,
            "execution": "plain vendored qwen3_5_moe (no staging, no prerouter)",
        },
        "versions": {
            "python_mlx": pkg_version("mlx"),
            "python_mlx_lm": pkg_version("mlx-lm"),
            "transformers": pkg_version("transformers"),
            "vendored_backbone": "mlx-lm 0.31.0 copy (upstream edge0)",
            "swift_mlx_revision": "e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230",
            "swift_mlx_c": "0.31.1",
        },
        "prompt": {"text": prompt, "ids": ids},
        "emission": {
            "prefill_argmax": prefill_argmax,
            "decode_calls": decode_calls,
            "emitted_ids": emitted,
            "emitted_ids_semantics": (
                "index 0 = prefill-selected argmax; indices 1..N = one argmax "
                "per decode call (fed back as the next input)"
            ),
            "stop_condition": "max_decode_steps_reached" if not eos_hit else "eos",
            "eos_hit": eos_hit,
            "eos_ids": [248046, 248044],
        },
        "fixture_tensors": len(tensors),
    }
    meta_path = os.path.join(output_dir, "edge0_35b_model_fixture_meta.json")
    with open(meta_path, "w") as fh:
        json.dump(meta, fh, indent=2)
    print(f"wrote {meta_path}")

    out_path = os.path.join(output_dir, "edge0_35b_model_fixture.safetensors")
    mx.save_safetensors(out_path, tensors)
    print(f"wrote {out_path} ({len(tensors)} tensors)")


def mx_tokenizer_from(model_dir: str):
    from tokenizers import Tokenizer
    return Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--edge0", default="/tmp/edge0-reference")
    parser.add_argument("--output", default="/tmp/edge0-fixtures")
    parser.add_argument("--model-dir", default="/tmp/edge0-model")
    parser.add_argument("--artifacts-dir", default="/tmp/edge0-artifacts")
    parser.add_argument(
        "--cases", nargs="+", default=["router", "mla", "moe"],
        choices=["router", "mla", "mla_state", "moe", "kda", "real", "real_layers", "prerouter", "35b_model", "tokenizer"],
    )
    options = parser.parse_args()

    module = load_bailing_hybrid(options.edge0)
    os.makedirs(options.output, exist_ok=True)

    if "router" in options.cases:
        dump_router(module, options.output)
    if "mla" in options.cases:
        dump_mla(module, options.output)
    if "mla_state" in options.cases:
        dump_mla_state(module, options.output)
    if "moe" in options.cases:
        dump_moe(module, options.output)
    if "kda" in options.cases:
        dump_kda(module, options.output)
    if "real" in options.cases:
        dump_real(options.output, options.model_dir)
    if "real_layers" in options.cases:
        dump_real_layers(module, options.output, options.model_dir)
    if "prerouter" in options.cases:
        dump_prerouter(options.output, options.model_dir, options.edge0)
    if "35b_model" in options.cases:
        dump_35b_model(options.output, options.model_dir, options.edge0)
    if "tokenizer" in options.cases:
        dump_tokenizer(options.output, options.artifacts_dir)

    print(f"[oracle] reference SHA: {REFERENCE_SHA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
