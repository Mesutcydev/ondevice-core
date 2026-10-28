#pragma once
#include <algorithm>
#include <cstddef>
#include <vector>

namespace od_mini47_detail {
// Optional request state is bounded independently of the expert cache.
constexpr size_t maximum_prefix_state_bytes = 128u * 1024u * 1024u;

template<class Token>
bool exact_prefix(const std::vector<Token> &prefix, const std::vector<Token> &request) {
    return !prefix.empty() && prefix.size() < request.size()
        && std::equal(prefix.begin(), prefix.end(), request.begin());
}

// Capture only an existing, complete prefill batch before the assistant opener.
// Never add a batch or alter a first request just to populate the cache.
inline size_t prefix_checkpoint(size_t stable_tokens, size_t reused_tokens, size_t batch_width) {
    if (!batch_width || stable_tokens < reused_tokens) return 0;
    return reused_tokens + ((stable_tokens - reused_tokens) / batch_width) * batch_width;
}
}
