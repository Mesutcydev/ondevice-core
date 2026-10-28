#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace od_mini47_detail {
// One spare context position keeps the final decode inside the allocated KV
// state. Text replies follow the requested budget up to that exact boundary.
// Lens retains its existing admission and short image-response profile.
inline uint32_t output_limit(uint32_t context, size_t prompt, uint32_t requested, bool image) {
    if (context < 2 || prompt >= context - 1 || requested == 0) return 0;
    const auto remaining = context - uint32_t(prompt) - 1;
    if (image && requested > remaining) return 0;
    return std::min(requested, remaining);
}
}
