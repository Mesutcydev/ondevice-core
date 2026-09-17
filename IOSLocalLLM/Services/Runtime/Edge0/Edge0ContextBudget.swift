import Foundation

// MARK: - Edge0ContextBudget
//
// Dynamic, device-safe input-context admission for Edge0-8B.
//
// The checkpoint supports 131072 positions, but the MLA cache grows linearly
// with the total sequence length and may not fit a phone's process budget.
// This estimator derives the largest SAFE input length from the actual state
// architecture — never from a generic transformer KV formula.
//
// Verified state shapes (Edge0-8B, bf16 MLA cache, fp32 KDA recurrent state):
//
//   MLA cache (6 layers, 16 heads):
//     keys   [B, 16, T, 192]  -> 192 = qk_nope 128 + qk_rope 64
//     values [B, 16, T, 128]
//     bytes/token = 6 * 16 * (192 + 128) * 2 = 61,440
//
//   KDA fixed state (18 layers; sequence-length independent):
//     3 conv rings [B, 3, 2048] bf16 -> 3 * 3 * 2048 * 2
//     recurrent    [B, 16, 128, 128] fp32 -> 16 * 128 * 128 * 4
//     per layer 1,085,440 bytes; total 19,537,920 bytes
//
// Admission is conservative and monotone by construction:
//   - the full largest pool tier is reserved in the cost model, so the
//     estimate never assumes headroom the pool might consume;
//   - `cacheBudgetBytes` is capped by the existing `stateKVBytes` policy
//     allowance, so context growth cannot starve the pool/reserve;
//   - decreasing available memory can only decrease (never increase) the
//     allowed input length, and a larger output reservation can only
//     decrease the allowed input length.

struct Edge0ContextBudget: Sendable, Equatable {
    /// Largest safe input tokens for this generation (already clamped).
    let maxInputTokens: Int
    let cacheBudgetBytes: UInt64
    let outputTokens: Int

    static let architectureMaxContext = 131_072
    static let minimumInputTokens = 512

    /// bf16 MLA cache, 6 layers x 16 heads x (192 keys + 128 values).
    static let mlaBytesPerToken: UInt64 = 61_440
    /// fp32 KDA recurrent states + bf16 short-conv rings, 18 layers.
    static let kdaFixedStateBytes: UInt64 = 19_537_920

    /// The estimator reserves the largest pool tier rather than the tier a
    /// specific launch picks. A larger reservation is strictly safer, and it
    /// keeps admission monotone in `availableBytes` (the chosen tier steps
    /// down as memory drops, which would otherwise raise the estimate).
    static var poolReservationBytes: UInt64 {
        Edge0MemoryBudget.poolTierBytes.max() ?? 0
    }

    /// Pure derivation. `availableBytes` mirrors
    /// `MemoryAdvisor.availableMemoryForModel`; `ceilingBytes` mirrors
    /// `MemoryAdvisor.processMemoryCeiling`.
    static func resolve(
        availableBytes: UInt64,
        ceilingBytes: UInt64,
        outputTokens: Int
    ) -> Edge0ContextBudget {
        let budget = Edge0MemoryBudget.resolve(
            availableBytes: availableBytes,
            ceilingBytes: ceilingBytes
        )

        // Saturating fixed-cost sum.
        var committed: UInt64 = 0
        for component in [
            budget.residentCommonBytes,
            budget.prerouterResidentBytes,
            budget.scratchBytes,
            budget.safetyReserveBytes,
            kdaFixedStateBytes,
            poolReservationBytes,
        ] {
            let (sum, overflow) = committed.addingReportingOverflow(component)
            committed = overflow ? UInt64.max : sum
        }

        let headroom = availableBytes > committed ? availableBytes - committed : 0
        let cacheBudget = min(headroom, budget.stateKVBytes)
        let totalTokensByCache = Int(min(
            UInt64(Int.max),
            cacheBudget / mlaBytesPerToken
        ))
        let reservedOutput = max(0, outputTokens)
        let rawInput = max(0, totalTokensByCache - reservedOutput)
        let clamped = min(rawInput, architectureMaxContext)
        let viable = max(clamped, minimumInputTokens)

        return Edge0ContextBudget(
            maxInputTokens: viable,
            cacheBudgetBytes: cacheBudget,
            outputTokens: reservedOutput
        )
    }

}
