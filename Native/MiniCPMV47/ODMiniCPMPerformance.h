#pragma once
#include <stdint.h>

namespace od_mini47_detail {
inline uint64_t counter_delta(int64_t before, int64_t after) {
    return before >= 0 && after >= before
        ? uint64_t(after) - uint64_t(before) : 0;
}
}
