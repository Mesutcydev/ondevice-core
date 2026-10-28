#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OD_MINI_API __attribute__((visibility("default")))
typedef struct od_mini47_engine od_mini47_engine;
typedef bool (*od_mini47_abort)(void * context);
// A null bytes pointer reports stage 1 (image encoding), 2 (prompt prefill),
// or 3 (answer decoding) in length. Non-null bytes always carry UTF-8 text.
typedef void (*od_mini47_token)(const char * bytes, size_t length, void * context);

// Numeric diagnostics only; contains no model text or captured media.
typedef struct od_mini47_metrics {
    uint32_t prompt_tokens, output_tokens;
    uint32_t shared_bank_slots, microbatch, cache_slots, routed_experts;
    bool has_vision;
    double load_ms, prefill_ms, first_token_ms, decode_ms;
    uint32_t decode_microbatch;
    // API wall spans can include waits; these are not GPU utilization times.
    double prompt_eval_api_ms, context_switch_ms, prefill_sampling_ms;
    double decode_api_ms, sampling_ms, callback_ms, park_ms;
    // Expert callback spans overlap decode_api/sampling; do not add them.
    double expert_process_ms, expert_readids_ms, expert_install_ms, expert_writeids_ms;
    uint64_t expert_misses, expert_read_bytes;
    bool has_expert_counters;
    uint32_t prefix_reused_tokens, prefix_checkpoint_tokens;
    uint64_t prefix_state_bytes;
} od_mini47_metrics;

OD_MINI_API od_mini47_engine * od_mini47_create(
    // A null projector creates a text-only engine.
    const char * model, const char * projector, const char * manifest,
    uint32_t context_size, uint32_t cache_slots_per_layer,
    od_mini47_abort abort, void * abort_context, char * error, size_t error_size);
OD_MINI_API void od_mini47_free(od_mini47_engine * engine);
OD_MINI_API void od_mini47_cancel(od_mini47_engine * engine);
OD_MINI_API int32_t od_mini47_describe(
    od_mini47_engine * engine, const uint8_t * rgb, uint32_t width, uint32_t height,
    const char * prompt, uint32_t max_tokens, od_mini47_token token,
    void * token_context, double * tokens_per_second);
OD_MINI_API uint32_t od_mini47_routed_experts(od_mini47_engine * engine);
OD_MINI_API bool od_mini47_get_metrics(od_mini47_engine * engine, od_mini47_metrics * metrics);
OD_MINI_API int32_t od_mini47_text(
    od_mini47_engine * engine, const char * prompt, uint32_t max_tokens,
    float temperature, float top_p, int32_t top_k, float repetition_penalty, uint32_t seed,
    od_mini47_token token, void * token_context, double * tokens_per_second,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit);
// Text-only adaptive prefill. maximum_microbatch must be 128, 256, 512 or 1024;
// the host must admit this ceiling against the current memory/safety budget.
OD_MINI_API int32_t od_mini47_text_optimized(
    od_mini47_engine * engine, const char * prompt, uint32_t max_tokens,
    uint32_t maximum_microbatch,
    float temperature, float top_p, int32_t top_k, float repetition_penalty, uint32_t seed,
    od_mini47_token token, void * token_context, double * tokens_per_second,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit);
// The host admits the additional bounded state against live headroom. A false
// allow_prefix_cache clears retained state and uses ordinary prompt evaluation.
OD_MINI_API int32_t od_mini47_text_cached(
    od_mini47_engine * engine, const char * prompt, uint32_t max_tokens,
    uint32_t maximum_microbatch, bool allow_prefix_cache,
    float temperature, float top_p, int32_t top_k, float repetition_penalty, uint32_t seed,
    od_mini47_token token, void * token_context, double * tokens_per_second,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit);

#ifdef __cplusplus
}
#endif
