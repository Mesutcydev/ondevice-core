import Foundation

// MARK: - Edge0_35BMemoryBudget
//
// Family-specific slice of the app's existing memory policy for the Edge0-35B
// release. Like the 8B budget it is NOT a second global policy: inputs come
// from `MemoryAdvisor` / `DeviceSafetyMonitor`, and only the partitioning is
// family-specific. The 8B constants are deliberately not reused.
//
// Measured from the pinned Edge0-35B artifact (rev 1ff9f447):
//   resident base payload    1,389,394,176 bytes (1,397 tensors)
//   Recover-LoRA payload        42,332,160 bytes (620 F16 tensors, 310 modules)
//   routed expert payload   18,119,393,280 bytes (40 layers × 256 experts)
//   per expert bundle            1,769,472 bytes
//   fixed linear state          64,389,120 bytes (30 layers)
//   full-attention KV           20,480 bytes per consumed token (10 layers)
//
// Audit findings 1+2 (build-55 candidate): the pool budget used to reserve a
// flat `ceiling / 8` for state/KV regardless of the admitted context, and its
// tier list stopped at 2 GiB. On the 12 GB reference device that reserved
// ~1.06 GB against a ~148 MB admitted-context need, and the 2 GiB cap bound
// below the available headroom. `Edge0_35BPoolAccounting` names both
// accountings so the device A/B can compare them and the old behavior stays
// exactly reproducible as the control arm.

/// Pool-budget accounting for the 35B family.
///
/// - `legacy`: the pre-fix accounting — flat `ceiling / 8` state-KV reserve,
///   2 GiB tier cap. Production default until the device A/B accepts the
///   reclaimed arm.
/// - `reclaimed`: the reserve follows the admitted context
///   (`maxContextTokens × kvBytesPerToken + linearStateBytes`) and the tier
///   list gains a 3 GiB tier. Caching changes no math — exactness-inert.
enum Edge0_35BPoolAccounting: String, Sendable, Equatable, CaseIterable {
    case legacy
    case reclaimed
}

struct Edge0_35BMemoryBudget: Sendable, Equatable {
    let expertPoolBytes: UInt64
    let expertPoolSlots: Int
    let residentBaseBytes: UInt64
    let loraBytes: UInt64
    let stateKVBytes: UInt64
    let scratchBytes: UInt64
    let safetyReserveBytes: UInt64

    static let measuredResidentBaseBytes: UInt64 = 1_389_394_176
    static let measuredLoRAPayloadBytes: UInt64 = 42_332_160
    static let measuredRoutedExpertBytes: UInt64 = 18_119_393_280
    static let expertBundleBytes: UInt64 = 1_769_472
    static let linearStateBytes: UInt64 = 64_389_120
    static let kvBytesPerToken: UInt64 = 20_480
    static let architectureMaxContext = 262_144

    /// Top-4 true-router execution: an unusable pool is below this.
    static let minimumPoolSlots = 4
    /// Discrete pool tiers, largest that fits the remaining headroom wins.
    /// 1–2 GiB tiers are for high-memory devices (the first iPhone 35B
    /// baseline showed the 512 MiB tier fully saturated with ~45% hit rate
    /// and a third of prefill spent waiting on expert reads). The reclaimed
    /// accounting adds the 3 GiB tier its freed reserve funds: peak ≈ 5.4 GB
    /// on the 12 GB reference device — under the recorded build-45 Jetsam
    /// datapoint of ~5.6 GB.
    static func poolTierBytes(
        for accounting: Edge0_35BPoolAccounting
    ) -> [UInt64] {
        let tiersMiB: [UInt64] = [64, 128, 256, 512, 1024, 2048]
        switch accounting {
        case .legacy:
            return tiersMiB.map { $0 * 1_048_576 }
        case .reclaimed:
            return (tiersMiB + [3072]).map { $0 * 1_048_576 }
        }
    }

    static let minimumSafetyReserveBytes: UInt64 = 512 * 1_048_576
    static let scratchBytesConstant: UInt64 = 256 * 1_048_576
    static let minimumStateKVBytes: UInt64 = 256 * 1_048_576
    static let maximumStateKVBytes: UInt64 = 4 * 1_073_741_824

    /// State/KV reserve, in bytes.
    ///
    /// - `legacy`: flat `ceiling / 8`, clamped to the historical bounds.
    /// - `reclaimed`: what the admitted context can actually materialize —
    ///   `maxContextTokens × kvBytesPerToken + linearStateBytes`, floored at
    ///   `minimumStateKVBytes` and capped at `ceiling / 8` / the maximum.
    ///   At the 4,096-token experimental cap this is the 256 MiB floor
    ///   instead of ~1.06 GB on a 12 GB phone; the difference is headroom
    ///   the pool can actually use (a KV cache for tokens that cannot be
    ///   admitted does not exist).
    static func stateKVAllowance(
        ceilingBytes: UInt64,
        maxContextTokens: Int,
        accounting: Edge0_35BPoolAccounting
    ) -> UInt64 {
        switch accounting {
        case .legacy:
            let scaled = ceilingBytes / 8
            return min(max(minimumStateKVBytes, scaled), maximumStateKVBytes)
        case .reclaimed:
            let needed = UInt64(max(0, maxContextTokens)) * kvBytesPerToken
                + linearStateBytes
            return min(
                max(needed, minimumStateKVBytes),
                min(ceilingBytes / 8, maximumStateKVBytes)
            )
        }
    }

    static func safetyReserve(ceilingBytes: UInt64) -> UInt64 {
        max(minimumSafetyReserveBytes, ceilingBytes / 16)
    }

    static func resolve(
        availableBytes: UInt64,
        ceilingBytes: UInt64,
        loraPayloadBytes: UInt64 = measuredLoRAPayloadBytes,
        accounting: Edge0_35BPoolAccounting,
        maxContextTokens: Int
    ) -> Edge0_35BMemoryBudget {
        let resident = measuredResidentBaseBytes
        let lora = loraPayloadBytes
        let state = stateKVAllowance(
            ceilingBytes: ceilingBytes,
            maxContextTokens: maxContextTokens,
            accounting: accounting
        )
        let scratch = scratchBytesConstant
        let reserve = safetyReserve(ceilingBytes: ceilingBytes)

        var committed: UInt64 = 0
        for component in [resident, lora, state, scratch, reserve] {
            let (sum, overflow) = committed.addingReportingOverflow(component)
            committed = overflow ? UInt64.max : sum
        }
        let headroom = availableBytes > committed
            ? availableBytes - committed
            : 0

        var chosen: UInt64 = 0
        for tier in poolTierBytes(for: accounting) where tier <= headroom {
            chosen = tier
        }
        let slots = chosen / expertBundleBytes

        return Edge0_35BMemoryBudget(
            expertPoolBytes: chosen,
            expertPoolSlots: Int(min(UInt64(Int.max), slots)),
            residentBaseBytes: resident,
            loraBytes: lora,
            stateKVBytes: state,
            scratchBytes: scratch,
            safetyReserveBytes: reserve
        )
    }

    /// A pool below top-4 cannot execute the true router and is refused
    /// rather than deadlocked.
    var isPoolEnabled: Bool {
        expertPoolBytes > 0
            && expertPoolSlots >= Self.minimumPoolSlots
    }

    /// Resident bytes a loaded 35B model holds before state/KV/pool.
    var residentBytes: UInt64 {
        residentBaseBytes + loraBytes
    }
}

// MARK: - Edge0_35BContextBudget
//
// Dynamic, device-safe input admission for the 35B family. The checkpoint
// supports 262,144 positions; that is not a device-validated operating limit.
// Initial 35B bring-up is additionally clamped by a documented experimental
// test limit so first device runs stay short.

struct Edge0_35BContextBudget: Sendable, Equatable {
    let maxInputTokens: Int
    let cacheBudgetBytes: UInt64
    let outputTokens: Int
    let experimentalLimitApplied: Bool

    /// Documented bring-up limit. Raise only after device validation.
    static let experimentalMaximumInputTokens = 4_096
    static let minimumInputTokens = 512

    static func poolReservationBytes(
        accounting: Edge0_35BPoolAccounting
    ) -> UInt64 {
        Edge0_35BMemoryBudget.poolTierBytes(for: accounting).max() ?? 0
    }

    static func resolve(
        availableBytes: UInt64,
        ceilingBytes: UInt64,
        outputTokens: Int,
        experimentalMaximumInputTokens: Int = experimentalMaximumInputTokens,
        accounting: Edge0_35BPoolAccounting
    ) -> Edge0_35BContextBudget {
        let budget = Edge0_35BMemoryBudget.resolve(
            availableBytes: availableBytes,
            ceilingBytes: ceilingBytes,
            accounting: accounting,
            maxContextTokens: experimentalMaximumInputTokens
        )

        var committed: UInt64 = 0
        for component in [
            budget.residentBytes,
            budget.scratchBytes,
            budget.safetyReserveBytes,
            Edge0_35BMemoryBudget.linearStateBytes,
            poolReservationBytes(accounting: accounting),
        ] {
            let (sum, overflow) = committed.addingReportingOverflow(component)
            committed = overflow ? UInt64.max : sum
        }
        let headroom = availableBytes > committed ? availableBytes - committed : 0
        let cacheBudget = min(headroom, budget.stateKVBytes)
        let totalTokensByCache = Int(min(
            UInt64(Int.max),
            cacheBudget / Edge0_35BMemoryBudget.kvBytesPerToken
        ))
        let reservedOutput = max(0, outputTokens)
        let rawInput = max(0, totalTokensByCache - reservedOutput)
        let admissionLimited = min(
            rawInput, Edge0_35BMemoryBudget.architectureMaxContext
        )
        let limited = min(admissionLimited, experimentalMaximumInputTokens)
        let viable = max(limited, minimumInputTokens)

        return Edge0_35BContextBudget(
            maxInputTokens: viable,
            cacheBudgetBytes: cacheBudget,
            outputTokens: reservedOutput,
            experimentalLimitApplied: admissionLimited > limited
        )
    }
}
