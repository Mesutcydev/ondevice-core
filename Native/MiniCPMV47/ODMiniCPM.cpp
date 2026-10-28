#include "ODMiniCPM.h"
#include "ODMiniCPMTokenBudget.h"
#include "ODMiniCPMExecutionPolicy.h"
#include "ODMiniCPMPerformance.h"
#include "ODMiniCPMPrefixCache.h"
#include "llama.h"
#include "ggml.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <limits>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Original adapter. The upstream runtime is linked privately, with a distinct
// Objective-C Metal class name and only od_mini47_* exported by this framework.
struct od_mini47_engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    mtmd_context * vision = nullptr;
    llama_sampler * sampler = nullptr;
    std::atomic<bool> cancelled{false};
    od_mini47_abort external_abort = nullptr;
    void * abort_context = nullptr;
    std::string manifest;
    std::mutex generation;
    uint32_t context_size = 0;
    uint32_t context_microbatch = 0;
    od_mini47_metrics metrics{};
    // Complete recurrent/KV state for an exact, stable token prefix. Only
    // existing prefill boundaries are captured; no prompt text is logged.
    std::vector<llama_token> prefix_tokens;
    std::vector<uint8_t> prefix_state;
    uint32_t prefix_microbatch = 0;
    void clear_prefix() {
        std::vector<llama_token>().swap(prefix_tokens);
        std::vector<uint8_t>().swap(prefix_state);
        prefix_microbatch = 0;
    }
    ~od_mini47_engine() {
        if (sampler) llama_sampler_free(sampler);
        if (vision) mtmd_free(vision);
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

static bool abort_requested(void * opaque) {
    auto * e = static_cast<od_mini47_engine *>(opaque);
    return e->cancelled.load(std::memory_order_relaxed)
        || (e->external_abort && e->external_abort(e->abort_context));
}
static void ignore_log(ggml_log_level, const char *, void *) {}
static std::mutex initialization;
static double elapsed_ms(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

// Caller holds initialization when constructing a new context. The model stays
// owned by the same engine; contexts never overlap during a batch change.
static llama_context * make_context(od_mini47_engine * e, uint32_t microbatch) {
    auto cp = llama_context_default_params();
    cp.n_ctx = e->context_size;
    cp.n_batch = std::max(512u, microbatch);
    cp.n_ubatch = microbatch;
    cp.n_threads = cp.n_threads_batch = 4;
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cp.no_perf = false;
    cp.abort_callback = abort_requested;
    cp.abort_callback_data = e;
    auto * context = llama_init_from_model(e->model, cp);
    if (!context) return nullptr;
    llama_set_n_expert_used(context, 8);
    llama_set_moe_lookahead_prefetch_depth(context, 8);
    if (llama_n_expert_used(context) != 8) { llama_free(context); return nullptr; }
    return context;
}

static bool prepare_text_context(od_mini47_engine * e, uint32_t desired) {
    if (e->context && e->context_microbatch == desired) {
        llama_memory_clear(llama_get_memory(e->context), true);
        return true;
    }
    std::lock_guard<std::mutex> lock(initialization);
    if (abort_requested(e)) return false;
    if (e->context) {
        // The parked expert buffer is model-owned. A new context starts with
        // an unparked flag and must not inherit a nil Metal buffer from the old
        // context. Rewrap before replacing it, with no contexts overlapping.
        if (!llama_moe_unpark_for_context_rebuild(e->context)) return false;
        if (abort_requested(e)) return false;
        llama_free(e->context); e->context = nullptr;
    }
    char window[16];
    std::snprintf(window, sizeof(window), "%u", e->metrics.cache_slots);
    setenv("LLAMA_MOE_DECODE_WINDOW", window, 1);
    // Failed larger compute allocations release before the smaller attempt.
    for (uint32_t batch = desired; batch >= 128; batch /= 2) {
        e->context = make_context(e, batch);
        if (e->context) { e->context_microbatch = batch; return true; }
        if (abort_requested(e)) return false;
    }
    return false;
}

// Larger prompt batches speed prefill, but a small compute context is faster
// for one-token decode. Preserve the complete recurrent and KV state when
// switching. The first token is sampled before switching because
// this runtime's state reader does not restore sample-ready output logits.
static bool prepare_decode_context(od_mini47_engine * e) {
    const uint32_t previous = e->context_microbatch;
    if (previous <= 128) return true;
    const size_t bytes = llama_state_get_size(e->context);
    if (!bytes || bytes > 256u * 1024u * 1024u) return true; // retain valid larger context
    std::vector<uint8_t> state;
    try { state.resize(bytes); } catch (...) { return true; }
    if (llama_state_get_data(e->context, state.data(), state.size()) != bytes) return true;
    if (abort_requested(e)) return false;
    if (prepare_text_context(e, 128)
        && llama_state_set_data(e->context, state.data(), state.size()) == bytes) return true;
    if (abort_requested(e)) return false;
    // If the small context cannot restore, restore the previously admitted
    // profile instead. Never continue sampling from partially restored state.
    return prepare_text_context(e, previous)
        && llama_state_set_data(e->context, state.data(), state.size()) == bytes;
}

od_mini47_engine * od_mini47_create(
    const char * model, const char * projector, const char * manifest,
    uint32_t context_size, uint32_t cache_slots_per_layer,
    od_mini47_abort abort, void * abort_context, char * error, size_t error_size) {
    auto fail = [&](const char * reason) -> od_mini47_engine * {
        if (error && error_size) std::snprintf(error, error_size, "%s", reason);
        return nullptr;
    };
    if (!model || !manifest || context_size < 512 || context_size > 4096
        || cache_slots_per_layer < 8 || cache_slots_per_layer > (projector ? 16u : 48u)) {
        return fail("Invalid MiniCPM streaming configuration");
    }
    std::lock_guard<std::mutex> lock(initialization);
    const auto load_start = std::chrono::steady_clock::now();
    llama_log_set(ignore_log, nullptr);
    mtmd_log_set(ignore_log, nullptr);
    ggml_log_set(ignore_log, nullptr);
    llama_backend_init();
    // Set only this private runtime's MoE controls. Never reduce router K.
    setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH", "1", 1);
    setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH", "8", 1);
    setenv("LLAMA_MOE_WINDOW_MAX_ROWS", "4", 1);
    setenv("LLAMA_MOE_IO_THREADS", "4", 1);
    setenv("LLAMA_MOE_NO_OWN_ALLOC", "0", 1);
    setenv("LLAMA_MOE_SKIP_READ", "0", 1);
    setenv("LLAMA_MOE_PARK_WINDOW", "1", 1);
    unsetenv("LLAMA_MOE_LAYER_WINDOWS");
    unsetenv("LLAMA_MOE_PREWARM");
    char window[16];
    std::snprintf(window, sizeof(window), "%u", cache_slots_per_layer);
    setenv("LLAMA_MOE_DECODE_WINDOW", window, 1);

    std::unique_ptr<od_mini47_engine> e(new od_mini47_engine());
    e->manifest = manifest;
    e->external_abort = abort;
    e->abort_context = abort_context;
    e->context_size = context_size;
    // A full shared bank fits min(batch * top8, 256) for text prefill.
    // Lens retains its bounded four-token image execution profile.
    e->metrics.shared_bank_slots = projector ? 40 : 256;
    e->metrics.microbatch = projector ? 4 : 128;
    e->context_microbatch = e->metrics.microbatch;
    e->metrics.decode_microbatch = e->context_microbatch;
    e->metrics.cache_slots = cache_slots_per_layer;
    e->metrics.routed_experts = 8;
    e->metrics.has_vision = projector != nullptr;
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 999;
    mp.use_mmap = true;
    mp.moe_experts_path = e->manifest.c_str();
    mp.moe_slot_bank = int32_t(e->metrics.shared_bank_slots);
    mp.progress_callback = [](float, void * p) { return !abort_requested(p); };
    mp.progress_callback_user_data = e.get();
    e->model = llama_model_load_from_file(model, mp);
    if (!e->model) return fail("MiniCPM streaming model could not be loaded");
    e->context = make_context(e.get(), e->metrics.microbatch);
    if (!e->context) return fail("MiniCPM streaming context could not be created");
    llama_set_n_expert_used(e->context, 8);
    llama_set_moe_lookahead_prefetch_depth(e->context, 8);
    if (llama_n_expert_used(e->context) != 8) return fail("MiniCPM router configuration mismatch");
    if (projector) {
        auto vp = mtmd_context_params_default();
        vp.use_gpu = true;
        vp.n_threads = 4;
        vp.warmup = false; // first real request encodes; no extra load-time image spike
        vp.print_timings = false;
        e->vision = mtmd_init_from_file(projector, e->model, vp);
        if (!e->vision || !mtmd_support_vision(e->vision)) return fail("MiniCPM vision encoder could not be loaded");
    }
    e->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (!e->sampler) return fail("MiniCPM sampler could not be created");
    llama_sampler_chain_add(e->sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(e->sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(e->sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    e->metrics.load_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - load_start).count();
    return e.release();
}

void od_mini47_free(od_mini47_engine * e) { delete e; }
void od_mini47_cancel(od_mini47_engine * e) { if (e) e->cancelled.store(true); }
uint32_t od_mini47_routed_experts(od_mini47_engine * e) {
    return e && e->context ? uint32_t(llama_n_expert_used(e->context)) : 0;
}
bool od_mini47_get_metrics(od_mini47_engine * e, od_mini47_metrics * metrics) {
    if (!e || !metrics) return false;
    std::unique_lock<std::mutex> lock(e->generation, std::try_to_lock);
    if (!lock.owns_lock()) return false;
    *metrics = e->metrics;
    return true;
}

struct text_sampling {
    float temperature, top_p, repetition_penalty;
    int32_t top_k;
    uint32_t seed;
};

static int32_t generate(
    od_mini47_engine * e, const uint8_t * rgb, uint32_t width, uint32_t height,
    const char * prompt, uint32_t max_tokens, od_mini47_token token,
    void * token_context, double * tokens_per_second, const text_sampling * sampling,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit,
    uint32_t maximum_microbatch = 128, bool allow_prefix_cache = false) {
    const bool has_image = rgb != nullptr;
    if (!e || !prompt || (has_image && (!e->vision || !width || !height)) || width > 8192 || height > 8192
        || max_tokens < 1 || max_tokens > (has_image ? 256u : 4096u)) return -1;
    std::unique_lock<std::mutex> lock(e->generation, std::try_to_lock);
    if (!lock.owns_lock()) return -2;
    e->cancelled.store(false);
    const auto request_start = std::chrono::steady_clock::now();
    e->metrics.prompt_tokens = e->metrics.output_tokens = 0;
    e->metrics.prefill_ms = e->metrics.first_token_ms = e->metrics.decode_ms = 0;
    e->metrics.prompt_eval_api_ms = e->metrics.context_switch_ms = e->metrics.prefill_sampling_ms = 0;
    e->metrics.decode_api_ms = e->metrics.sampling_ms = e->metrics.callback_ms = e->metrics.park_ms = 0;
    e->metrics.expert_process_ms = e->metrics.expert_readids_ms = 0;
    e->metrics.expert_install_ms = e->metrics.expert_writeids_ms = 0;
    e->metrics.expert_misses = e->metrics.expert_read_bytes = 0;
    e->metrics.has_expert_counters = false;
    e->metrics.prefix_reused_tokens = e->metrics.prefix_checkpoint_tokens = 0;
    e->metrics.prefix_state_bytes = 0;
    if (sampling) {
        llama_sampler_free(e->sampler);
        e->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        if (!e->sampler) return -3;
        llama_sampler_chain_add(e->sampler, llama_sampler_init_penalties(64, sampling->repetition_penalty, 0, 0));
        llama_sampler_chain_add(e->sampler, llama_sampler_init_top_k(sampling->top_k));
        llama_sampler_chain_add(e->sampler, llama_sampler_init_top_p(sampling->top_p, 1));
        llama_sampler_chain_add(e->sampler, llama_sampler_init_temp(sampling->temperature));
        llama_sampler_chain_add(e->sampler, llama_sampler_init_dist(sampling->seed));
    }
    llama_sampler_reset(e->sampler);
    auto * bitmap = has_image ? mtmd_bitmap_init(width, height, rgb) : nullptr;
    if (has_image && !bitmap) return -3;
    auto * chunks = has_image ? mtmd_input_chunks_init() : nullptr;
    if (has_image && !chunks) { if (bitmap) mtmd_bitmap_free(bitmap); return -3; }
    struct cleanup {
        mtmd_bitmap * bitmap;
        mtmd_input_chunks * chunks;
        od_mini47_engine * engine;
        int64_t decode_counters[7]{};
        bool has_decode_counters = false;
        bool completed = false;
        ~cleanup() {
            if (!completed) engine->clear_prefix();
            if (chunks) mtmd_input_chunks_free(chunks);
            if (bitmap) mtmd_bitmap_free(bitmap);
            if (engine->context) {
                const auto parked = std::chrono::steady_clock::now();
                // Keep the existing request-end synchronization/parking.
                llama_moe_park_expert_memory(engine->context);
                engine->metrics.park_ms = elapsed_ms(parked);
                int64_t after[7]{};
                if (has_decode_counters && llama_moe_counters_snapshot(engine->context, after, 7)) {
                    using od_mini47_detail::counter_delta;
                    engine->metrics.expert_process_ms = counter_delta(decode_counters[0], after[0]) / 1e6;
                    engine->metrics.expert_readids_ms = counter_delta(decode_counters[1], after[1]) / 1e6;
                    engine->metrics.expert_install_ms = counter_delta(decode_counters[2], after[2]) / 1e6;
                    engine->metrics.expert_writeids_ms = counter_delta(decode_counters[3], after[3]) / 1e6;
                    engine->metrics.expert_misses = counter_delta(decode_counters[4], after[4]);
                    engine->metrics.expert_read_bytes = counter_delta(decode_counters[5], after[5]);
                    engine->metrics.has_expert_counters = true;
                }
            }
        }
    } cleanup{bitmap, chunks, e};
    std::vector<llama_token> text_tokens;
    size_t count = 0;
    const auto * vocab = llama_model_get_vocab(e->model);
    if (has_image) {
        mtmd_input_text text{prompt, true, true};
        const mtmd_bitmap * images[] = {bitmap};
        if (token) token(nullptr, 1, token_context);
        if (mtmd_tokenize(e->vision, chunks, &text, images, 1) != 0) return -4;
        count = mtmd_helper_get_n_tokens(chunks);
    } else {
        const size_t bytes = std::strlen(prompt);
        if (bytes > size_t(std::numeric_limits<int32_t>::max())) return -5;
        const int32_t needed = llama_tokenize(vocab, prompt, int32_t(bytes), nullptr, 0, true, true);
        if (needed >= 0 || needed == std::numeric_limits<int32_t>::min()) return -4;
        count = size_t(-needed);
        if (od_mini47_detail::output_limit(e->context_size, count, max_tokens, false) > 0) {
            text_tokens.resize(count);
            if (llama_tokenize(vocab, prompt, int32_t(bytes), text_tokens.data(), int32_t(count), true, true) != int32_t(count)) return -4;
        }
    }
    if (prompt_tokens) *prompt_tokens = uint32_t(count);
    e->metrics.prompt_tokens = uint32_t(count);
    const uint32_t generation_limit = od_mini47_detail::output_limit(e->context_size, count, max_tokens, has_image);
    if (!generation_limit) return -5;
    if (abort_requested(e)) return 1;
    const bool allow_prefix = !e->vision && allow_prefix_cache;
    size_t reuse_count = 0;
    if (allow_prefix && !e->prefix_state.empty()
        && od_mini47_detail::exact_prefix(e->prefix_tokens, text_tokens)) {
        reuse_count = e->prefix_tokens.size();
    } else {
        e->clear_prefix();
    }
    size_t stable_count = 0;
    if (allow_prefix) {
        const std::string serialized(prompt);
        const auto opener = serialized.rfind("<|im_start|>assistant\n");
        if (opener != std::string::npos && opener > 0) {
            const int32_t needed = llama_tokenize(vocab, prompt, int32_t(opener), nullptr, 0, true, true);
            if (needed < 0 && needed != std::numeric_limits<int32_t>::min()) {
                std::vector<llama_token> stable(size_t(-needed));
                if (llama_tokenize(vocab, prompt, int32_t(opener), stable.data(), int32_t(stable.size()), true, true) == int32_t(stable.size())) {
                    while (stable_count < stable.size() && stable_count < text_tokens.size()
                           && stable[stable_count] == text_tokens[stable_count]) ++stable_count;
                }
            }
        }
    }
    if (!e->vision) {
        const auto desired = od_mini47_detail::prompt_microbatch(count, maximum_microbatch);
        const auto switched = std::chrono::steady_clock::now();
        const bool prepared = prepare_text_context(e, desired);
        e->metrics.context_switch_ms += elapsed_ms(switched);
        if (!prepared) return abort_requested(e) ? 1 : -6;
        // A thermal/admission or allocation change selects a different
        // compute profile. Re-evaluate rather than mix its recurrent scan
        // with a checkpoint produced by another profile.
        if (reuse_count && e->prefix_microbatch != e->context_microbatch) {
            e->clear_prefix(); reuse_count = 0;
        }
        if (reuse_count) {
            const auto restore_started = std::chrono::steady_clock::now();
            if (llama_state_set_data(e->context, e->prefix_state.data(), e->prefix_state.size()) != e->prefix_state.size()) {
                e->clear_prefix(); reuse_count = 0;
                llama_memory_clear(llama_get_memory(e->context), true);
            }
            e->metrics.context_switch_ms += elapsed_ms(restore_started);
        }
        e->metrics.microbatch = e->context_microbatch;
    } else {
        llama_memory_clear(llama_get_memory(e->context), true);
    }
    llama_pos past = 0;
    if (has_image && token) token(nullptr, 2, token_context);
    const auto evaluation_start = std::chrono::steady_clock::now();
    if (has_image) {
        if (mtmd_helper_eval_chunks(e->vision, e->context, chunks, 0, 0, 512, true, &past) != 0) return abort_requested(e) ? 1 : -6;
    } else {
        const size_t batch_width = std::max(512u, e->context_microbatch);
        const size_t checkpoint = od_mini47_detail::prefix_checkpoint(stable_count, reuse_count, batch_width);
        for (size_t offset = reuse_count; offset < count; offset += batch_width) {
            if (abort_requested(e)) return 1;
            const int32_t width = int32_t(std::min(batch_width, count - offset));
            auto batch = llama_batch_get_one(text_tokens.data() + offset, width);
            if (llama_decode(e->context, batch) != 0) return abort_requested(e) ? 1 : -6;
            if (allow_prefix && checkpoint > reuse_count && offset + size_t(width) == checkpoint) {
                const size_t bytes = llama_state_get_size(e->context);
                if (bytes > 0 && bytes <= od_mini47_detail::maximum_prefix_state_bytes) {
                    e->clear_prefix();
                    try {
                        e->prefix_state.resize(bytes);
                        if (llama_state_get_data(e->context, e->prefix_state.data(), bytes) == bytes) {
                            e->prefix_tokens.assign(text_tokens.begin(), text_tokens.begin() + checkpoint);
                            e->prefix_microbatch = e->context_microbatch;
                        } else { e->clear_prefix(); }
                    } catch (...) { e->clear_prefix(); }
                }
            }
        }
    }
    e->metrics.prompt_eval_api_ms = elapsed_ms(evaluation_start);
    const bool has_first_token = !e->vision && e->context_microbatch > 128;
    llama_token first_token = -1;
    if (has_first_token) {
        const auto sampled = std::chrono::steady_clock::now();
        first_token = llama_sampler_sample(e->sampler, e->context, -1);
        e->metrics.prefill_sampling_ms = elapsed_ms(sampled);
        if (!llama_vocab_is_eog(vocab, first_token)) {
            const auto switched = std::chrono::steady_clock::now();
            const bool prepared = prepare_decode_context(e);
            e->metrics.context_switch_ms += elapsed_ms(switched);
            if (!prepared) return abort_requested(e) ? 1 : -6;
        }
    }
    e->metrics.decode_microbatch = e->context_microbatch;
    e->metrics.prefill_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - request_start).count();
    if (has_image && token) token(nullptr, 3, token_context);
    auto start = std::chrono::steady_clock::now();
    uint32_t generated = 0;
    for (; generated < generation_limit; ++generated) {
        if (abort_requested(e)) return 1;
        llama_token next;
        if (generated == 0 && has_first_token) { next = first_token; }
        else {
            const auto sampled = std::chrono::steady_clock::now();
            next = llama_sampler_sample(e->sampler, e->context, -1);
            if (generated == 0) e->metrics.prefill_sampling_ms += elapsed_ms(sampled);
            else e->metrics.sampling_ms += elapsed_ms(sampled);
        }
        // First sampling has already synchronized the prompt's output. Do
        // not attribute asynchronous prefill callbacks to decode counters.
        if (generated == 0) {
            cleanup.has_decode_counters = llama_moe_counters_snapshot(e->context, cleanup.decode_counters, 7);
        }
        if (llama_vocab_is_eog(vocab, next)) break;
        std::vector<char> piece(64);
        int n = llama_token_to_piece(vocab, next, piece.data(), int(piece.size()), 0, false);
        if (n < 0) {
            piece.resize(size_t(-n));
            n = llama_token_to_piece(vocab, next, piece.data(), int(piece.size()), 0, false);
        }
        if (n < 0) return -7;
        if (generated == 0) e->metrics.first_token_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - request_start).count();
        if (token && n > 0) {
            const auto emitted = std::chrono::steady_clock::now();
            token(piece.data(), size_t(n), token_context);
            e->metrics.callback_ms += elapsed_ms(emitted);
        }
        e->metrics.output_tokens = generated + 1;
        if (abort_requested(e)) return 1;
        auto batch = llama_batch_get_one(&next, 1);
        const auto decoded = std::chrono::steady_clock::now();
        const int result = llama_decode(e->context, batch);
        e->metrics.decode_api_ms += elapsed_ms(decoded);
        if (result != 0) return abort_requested(e) ? 1 : -6;
        ++past;
    }
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    e->metrics.decode_ms = seconds * 1000;
    if (tokens_per_second) {
        *tokens_per_second = seconds > 0 ? generated / seconds : 0;
    }
    if (output_tokens) *output_tokens = generated;
    if (hit_token_limit) *hit_token_limit = generated >= generation_limit;
    cleanup.completed = generated > 0;
    e->metrics.prefix_reused_tokens = uint32_t(reuse_count);
    e->metrics.prefix_checkpoint_tokens = uint32_t(e->prefix_tokens.size());
    e->metrics.prefix_state_bytes = e->prefix_state.size();
    return generated ? 0 : -8;
}

int32_t od_mini47_describe(
    od_mini47_engine * e, const uint8_t * rgb, uint32_t width, uint32_t height,
    const char * prompt, uint32_t max_tokens, od_mini47_token token,
    void * token_context, double * tokens_per_second) {
    if (!rgb) return -1;
    return generate(e, rgb, width, height, prompt, max_tokens, token, token_context,
                    tokens_per_second, nullptr, nullptr, nullptr, nullptr);
}

int32_t od_mini47_text(
    od_mini47_engine * e, const char * prompt, uint32_t max_tokens,
    float temperature, float top_p, int32_t top_k, float repetition_penalty, uint32_t seed,
    od_mini47_token token, void * token_context, double * tokens_per_second,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit) {
    if (temperature < 0 || temperature > 2 || top_p <= 0 || top_p > 1 || top_k < 0
        || repetition_penalty <= 0 || repetition_penalty > 2) return -1;
    text_sampling sampling{temperature, top_p, repetition_penalty, top_k, seed};
    return generate(e, nullptr, 0, 0, prompt, max_tokens, token, token_context,
                    tokens_per_second, &sampling, prompt_tokens, output_tokens, hit_token_limit);
}

int32_t od_mini47_text_optimized(
    od_mini47_engine * e, const char * prompt, uint32_t max_tokens, uint32_t maximum_microbatch,
    float temperature, float top_p, int32_t top_k, float repetition_penalty, uint32_t seed,
    od_mini47_token token, void * token_context, double * tokens_per_second,
    uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit) {
    if (!e || e->vision || (maximum_microbatch != 128 && maximum_microbatch != 256 && maximum_microbatch != 512 && maximum_microbatch != 1024)
        || temperature < 0 || temperature > 2 || top_p <= 0 || top_p > 1 || top_k < 0
        || repetition_penalty <= 0 || repetition_penalty > 2) return -1;
    text_sampling sampling{temperature, top_p, repetition_penalty, top_k, seed};
    return generate(e, nullptr, 0, 0, prompt, max_tokens, token, token_context,
                    tokens_per_second, &sampling, prompt_tokens, output_tokens, hit_token_limit, maximum_microbatch);
}

int32_t od_mini47_text_cached(
    od_mini47_engine * e, const char * prompt, uint32_t max_tokens, uint32_t maximum_microbatch,
    bool allow_prefix_cache, float temperature, float top_p, int32_t top_k,
    float repetition_penalty, uint32_t seed, od_mini47_token token, void * token_context,
    double * tokens_per_second, uint32_t * prompt_tokens, uint32_t * output_tokens, bool * hit_token_limit) {
    if (!e || e->vision || (maximum_microbatch != 128 && maximum_microbatch != 256 && maximum_microbatch != 512 && maximum_microbatch != 1024)
        || temperature < 0 || temperature > 2 || top_p <= 0 || top_p > 1 || top_k < 0
        || repetition_penalty <= 0 || repetition_penalty > 2) return -1;
    text_sampling sampling{temperature, top_p, repetition_penalty, top_k, seed};
    return generate(e, nullptr, 0, 0, prompt, max_tokens, token, token_context,
                    tokens_per_second, &sampling, prompt_tokens, output_tokens, hit_token_limit,
                    maximum_microbatch, allow_prefix_cache);
}
