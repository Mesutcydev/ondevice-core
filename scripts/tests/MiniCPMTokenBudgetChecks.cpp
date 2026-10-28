#include "../../Native/MiniCPMV47/ODMiniCPMTokenBudget.h"
#include "../../Native/MiniCPMV47/ODMiniCPMExecutionPolicy.h"
#include "../../Native/MiniCPMV47/ODMiniCPMPerformance.h"
#include "../../Native/MiniCPMV47/ODMiniCPMPrefixCache.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using od_mini47_detail::counter_delta;
    using od_mini47_detail::exact_prefix;
    using od_mini47_detail::prefix_checkpoint;
    assert(!exact_prefix(std::vector<int>{}, std::vector<int>{1, 2}));
    assert(!exact_prefix(std::vector<int>{1, 2}, std::vector<int>{1, 2}));
    assert(!exact_prefix(std::vector<int>{1, 2, 3}, std::vector<int>{1, 2}));
    assert(!exact_prefix(std::vector<int>{1, 3}, std::vector<int>{1, 2, 3}));
    assert(exact_prefix(std::vector<int>{1, 2}, std::vector<int>{1, 2, 3}));
    assert(prefix_checkpoint(350, 0, 512) == 0); // short first prompt unchanged
    assert(prefix_checkpoint(1140, 0, 1024) == 1024);
    assert(prefix_checkpoint(1230, 1024, 1024) == 1024); // keep existing checkpoint
    assert(prefix_checkpoint(3100, 1024, 1024) == 3072);
    assert(prefix_checkpoint(1000, 1024, 1024) == 0);
    assert(prefix_checkpoint(3100, 1024, 0) == 0);
    assert(od_mini47_detail::maximum_prefix_state_bytes == 128u * 1024u * 1024u);
    for (size_t stable = 0; stable < 4096; ++stable) {
        const size_t point = prefix_checkpoint(stable, 0, 512);
        assert(point <= stable && point % 512 == 0);
    }
    assert(counter_delta(5, 9) == 4);
    assert(counter_delta(9, 5) == 0);
    assert(counter_delta(-1, 9) == 0);
    assert(counter_delta(0, std::numeric_limits<int64_t>::max()) == uint64_t(std::numeric_limits<int64_t>::max()));
    using od_mini47_detail::prompt_microbatch;
    assert(prompt_microbatch(54, 512) == 128);
    assert(prompt_microbatch(128, 512) == 128);
    assert(prompt_microbatch(129, 512) == 256);
    assert(prompt_microbatch(256, 512) == 256);
    assert(prompt_microbatch(257, 512) == 512);
    assert(prompt_microbatch(512, 1024) == 512);
    assert(prompt_microbatch(513, 1024) == 1024);
    assert(prompt_microbatch(999, 1024) == 1024);
    assert(prompt_microbatch(1154, 1024) == 1024);
    assert(prompt_microbatch(1024, 256) == 256);
    assert(prompt_microbatch(1024, 128) == 128);
    using od_mini47_detail::output_limit;
    assert(output_limit(4096, 54, 2048, false) == 2048);
    assert(output_limit(4096, 54, 3568, false) == 3568);
    assert(output_limit(4096, 3000, 2048, false) == 1095);
    assert(output_limit(4096, 4094, 2048, false) == 1);
    assert(output_limit(4096, 4095, 2048, false) == 0);
    assert(output_limit(4096, 5000, 2048, false) == 0);
    assert(output_limit(4096, std::numeric_limits<size_t>::max(), 2048, false) == 0);
    assert(output_limit(512, 450, 2048, false) == 61);
    assert(output_limit(4096, 54, 32, false) == 32);
    assert(output_limit(4096, 54, 0, false) == 0);
    assert(output_limit(0, 0, 100, false) == 0);
    assert(output_limit(1, 0, 100, false) == 0);
    assert(output_limit(4096, 54, 256, true) == 256);
    assert(output_limit(4096, 3900, 256, true) == 0);
    // Sweep the context boundary: text can never write past the final spare
    // position, and every short prompt can receive more than 256 tokens.
    for (size_t prompt = 0; prompt < 4200; ++prompt) {
        const auto limit = output_limit(4096, prompt, 4096, false);
        assert(limit == 0 || prompt + limit < 4096);
        if (prompt < 2048) assert(limit >= 2048);
    }
    std::puts("PASS: long text, exact context boundary, small contexts and unchanged Lens admission");
}
