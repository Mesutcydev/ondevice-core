import Foundation

// MARK: - Edge0BenchmarkStatistics
//
// Pure statistics for the benchmark runner. Conventional median: sorted,
// even counts average the two middle values. Unrounded inputs only; the
// runner never rounds before reducing.

enum Edge0BenchmarkStatistics {

    /// Conventional median. Returns nil for an empty sample.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Arithmetic mean. Returns nil for an empty sample.
    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Relative change from the first to the last sample (0 when either is
    /// unusable). Used for same-mode drift detection.
    static func firstToLastChange(_ values: [Double]) -> Double {
        guard let first = values.first, let last = values.last,
              first > 0 else { return 0 }
        return (last - first) / first
    }
}
