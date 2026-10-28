import Foundation

/// The text runtime can spend part of the unused vision budget on expert reuse.
/// Admission still uses MemoryAdvisor's live, platform-bounded headroom.
struct MiniCPM35BTextProfile: Equatable, Sendable {
    /// The native tokenizer reserves one context position and gives the reply
    /// only the remaining space. The Assistant's user/thermal policy applies
    /// first; this is a bound for direct native callers, not a reply-length cap.
    static let maximumRequestedOutputTokens = 4_096
    static let maximumPrefixStateBytes: Int64 = 128 * 1_024 * 1_024

    let cacheSlots: UInt32
    let minimumAvailableBytes: Int64

    static let conservative = Self(cacheSlots: 16, minimumAvailableBytes: 4_800_000_000)
    static let expanded = Self(cacheSlots: 24, minimumAvailableBytes: 5_500_000_000)
    static let balanced = Self(cacheSlots: 32, minimumAvailableBytes: 5_900_000_000)
    static let highHeadroom = Self(cacheSlots: 48, minimumAvailableBytes: 6_200_000_000)

    static func resolve(availableMemory: Int64, isThermallyNominal: Bool,
                        isLowPowerMode: Bool, hasPressureCooldown: Bool) -> Self {
        guard availableMemory >= expanded.minimumAvailableBytes,
              isThermallyNominal, !isLowPowerMode, !hasPressureCooldown else {
            return .conservative
        }
        if availableMemory >= highHeadroom.minimumAvailableBytes { return .highHeadroom }
        if availableMemory >= balanced.minimumAvailableBytes { return .balanced }
        return .expanded
    }

    static func cacheFallbacks(from requested: UInt32) -> [UInt32] {
        [requested] + [32, 24, 16].filter { $0 < requested }
    }

    /// Check both total runtime capacity and incremental compute headroom.
    /// Parked host pages can remain resident; do not charge them twice against
    /// remaining headroom. The caller reads ceiling/headroom in one snapshot.
    static func maximumPromptMicrobatch(availableMemory: Int64, processMemoryCeiling: Int64,
        cacheSlots: UInt32,
        thermalState: ProcessInfo.ThermalState, isLowPowerMode: Bool, hasPressureCooldown: Bool,
        reservingPrefixCache: Bool = false) -> UInt32 {
        let reserve = reservingPrefixCache ? maximumPrefixStateBytes : 0
        guard availableMemory > reserve, processMemoryCeiling > reserve else { return 128 }
        let availableMemory = availableMemory - reserve
        let processMemoryCeiling = processMemoryCeiling - reserve
        guard thermalState == .nominal || thermalState == .fair,
              !isLowPowerMode, !hasPressureCooldown,
              [16, 24, 32, 40, 48].contains(cacheSlots) else { return 128 }
        let slotBytes: Int64 = 1_351_680
        let expertCapacity = (Int64(cacheSlots) + 8) * 40 * slotBytes + 256 * slotBytes
        if thermalState == .nominal, availableMemory >= 1_800_000_000,
           processMemoryCeiling >= expertCapacity + 2_000_000_000 { return 1024 }
        // Fair permits foreground work, but keep a smaller compute ceiling
        // and reduce discretionary work rather than increasing thermal load.
        if thermalState == .nominal, availableMemory >= 1_300_000_000,
           processMemoryCeiling >= expertCapacity + 1_600_000_000 { return 512 }
        if availableMemory >= 1_000_000_000,
           processMemoryCeiling >= expertCapacity + 1_300_000_000 { return 256 }
        return 128
    }

    /// The cache is optional and released on the next request if admission
    /// changes. It contains native state, never a persisted conversation.
    static func allowsPrefixCache(availableMemory: Int64, processMemoryCeiling: Int64,
        cacheSlots: UInt32, thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool, hasPressureCooldown: Bool) -> Bool {
        guard thermalState == .nominal || thermalState == .fair,
              !isLowPowerMode, !hasPressureCooldown,
              [16, 24, 32, 40, 48].contains(cacheSlots),
              availableMemory >= 1_500_000_000 + maximumPrefixStateBytes else { return false }
        let expertCapacity = (Int64(cacheSlots) + 8) * 40 * 1_351_680 + 256 * 1_351_680
        return processMemoryCeiling >= expertCapacity + 1_700_000_000 + maximumPrefixStateBytes
    }
}
