import Foundation

// MARK: - Edge0MemoryBudget
//
// Derived, Edge0-specific slice of the app's existing memory policy. This is
// NOT a second global policy: `Edge0MemoryBudget.current()` computes its
// inputs from `MemoryAdvisor` and `DeviceSafetyMonitor`, and only then
// partitions the available bytes into an expert pool allowance plus the
// resident/common, state/KV, scratch, and safety-reserve allowances.
//
// The checkpoint constants below are measured from the real Edge0-8B
// artifact (`Edge0/Edge0-8B-A1B-preview` @ 0700e65):
//   total            4,508,556,096 bytes
//   routed experts   3,906,994,176 bytes (23 layers × 128 experts)
//   resident/common    601,561,920 bytes
//   per expert         1,327,104 bytes

struct Edge0MemoryBudget: Sendable, Equatable {
    let expertPoolBytes: UInt64
    let expertPoolSlots: Int
    let residentCommonBytes: UInt64
    let stateKVBytes: UInt64
    let scratchBytes: UInt64
    let safetyReserveBytes: UInt64
    /// Advisory prerouter head residency (38.8 MB fp16 artifact + runtime
    /// maps). Counted unconditionally so admission and the safe-context
    /// estimate stay honest even when `.stagedPrerouter` is selected later.
    let prerouterResidentBytes: UInt64

    static let measuredCheckpointBytes: UInt64 = 4_508_556_096
    static let measuredRoutedExpertBytes: UInt64 = 3_906_994_176
    static let measuredResidentCommonBytes: UInt64 = 601_561_920
    static let expertBundleBytes: UInt64 = 1_327_104

    /// Discrete pool tiers, largest that fits the remaining headroom wins.
    static let poolTierBytes: [UInt64] = [64, 128, 256, 512].map {
        UInt64($0) * 1_048_576
    }

    /// Measured `prerouter_edge0_8b.safetensors` size (48 F16 tensors).
    static let prerouterResidentBytesConstant: UInt64 = 38_802_304
    static let minimumSafetyReserveBytes: UInt64 = 512 * 1_048_576
    static let scratchBytesConstant: UInt64 = 192 * 1_048_576
    static let minimumStateKVBytes: UInt64 = 384 * 1_048_576
    /// 8 GiB is the state/KV allowance needed to reach the checkpoint's
    /// architectural 131072-token context (131072 x 61440 bytes/token).
    /// Phones remain governed by the `ceilingBytes / 8` term, so this cap
    /// only lifts the limit for large-memory devices (Macs, future iPhones).
    static let maximumStateKVBytes: UInt64 = 8 * 1_073_741_824

    static func stateKVAllowance(ceilingBytes: UInt64) -> UInt64 {
        let scaled = ceilingBytes / 8
        return min(max(minimumStateKVBytes, scaled), maximumStateKVBytes)
    }

    static func safetyReserve(ceilingBytes: UInt64) -> UInt64 {
        max(minimumSafetyReserveBytes, ceilingBytes / 16)
    }

    /// Pure budget derivation. Tier selection is driven by the live headroom:
    /// the largest tier that still leaves every other allowance intact.
    static func resolve(
        availableBytes: UInt64,
        ceilingBytes: UInt64
    ) -> Edge0MemoryBudget {
        let resident = measuredResidentCommonBytes
        let state = stateKVAllowance(ceilingBytes: ceilingBytes)
        let scratch = scratchBytesConstant
        let reserve = safetyReserve(ceilingBytes: ceilingBytes)

        // Saturating sum keeps a corrupt/zero input from wrapping.
        var committed: UInt64 = 0
        for component in [
            resident, state, scratch, reserve,
            prerouterResidentBytesConstant,
        ] {
            let (sum, overflow) = committed.addingReportingOverflow(component)
            committed = overflow ? UInt64.max : sum
        }
        let headroom = availableBytes > committed
            ? availableBytes - committed
            : 0

        var chosen: UInt64 = 0
        for tier in poolTierBytes where tier <= headroom {
            chosen = tier
        }
        let slots = chosen / expertBundleBytes

        return Edge0MemoryBudget(
            expertPoolBytes: chosen,
            expertPoolSlots: Int(min(UInt64(Int.max), slots)),
            residentCommonBytes: resident,
            stateKVBytes: state,
            scratchBytes: scratch,
            safetyReserveBytes: reserve,
            prerouterResidentBytes: prerouterResidentBytesConstant
        )
    }

    var isPoolEnabled: Bool {
        expertPoolBytes > 0 && expertPoolSlots > 0
    }
}
