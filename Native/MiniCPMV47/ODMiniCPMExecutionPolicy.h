#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace od_mini47_detail {
// A full 256-slot shared bank fits the top-eight union for these batches.
// The caller admits the maximum against live memory before each request.
inline uint32_t prompt_microbatch(size_t tokens, uint32_t maximum) {
    const uint32_t desired = tokens <= 128 ? 128 : tokens <= 256 ? 256 : tokens <= 512 ? 512 : 1024;
    return std::min(desired, maximum);
}
}
