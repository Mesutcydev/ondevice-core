import Foundation

// MARK: - Edge0LatencyRing
//
// Bounded read-latency history shared by the expert pool's statistics.
// Previously the pool kept every read latency forever and sorted the whole
// array in `statistics()`; because the 35B MoE asked for a snapshot once per
// token per layer, that made per-token guard cost grow with the number of
// requests (the observed +2.33 s per identical prefill). The ring keeps the
// window bounded so a snapshot is O(window), and totals are preserved
// separately for diagnostics.

struct Edge0LatencyRing: Sendable, Equatable {
    static let capacity = 2_048

    private(set) var samples: [Double] = []
    private(set) var totalRecorded = 0
    private var nextIndex = 0

    mutating func record(_ seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        totalRecorded += 1
        if samples.count < Self.capacity {
            samples.append(seconds)
        } else {
            samples[nextIndex] = seconds
            nextIndex = (nextIndex + 1) % Self.capacity
        }
    }

    /// Mean over the bounded window (0 when empty).
    var average: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Exact percentile over the bounded window (0 when empty).
    var p95: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = Int(Double(sorted.count - 1) * 0.95)
        return sorted[min(max(0, index), sorted.count - 1)]
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
        nextIndex = 0
    }
}
