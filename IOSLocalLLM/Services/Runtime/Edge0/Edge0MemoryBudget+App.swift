import Foundation

// MARK: - Edge0MemoryBudget + app memory policy
//
// The only place Edge0 reads live app memory state. The values still come
// from `MemoryAdvisor` (the entitlement-aware process ceiling and live
// headroom) — Edge0 does not define its own device limits.

extension Edge0MemoryBudget {
    @MainActor
    static func current() -> Edge0MemoryBudget {
        resolve(
            availableBytes: UInt64(max(0, MemoryAdvisor.availableMemoryForModel)),
            ceilingBytes: UInt64(max(0, MemoryAdvisor.processMemoryCeiling))
        )
    }

    /// Thermal / pressure admission still belongs to `DeviceSafetyMonitor`.
    @MainActor
    static var isDeviceAdmitted: Bool {
        DeviceSafetyMonitor.shared.stopReason == nil
    }
}

extension Edge0ContextBudget {
    /// Live device admission used by the Assistant path. The estimator itself
    /// stays portable (Foundation only); this bridge is the single place the
    /// live `MemoryAdvisor` values enter it.
    @MainActor
    static func current(outputTokens: Int) -> Edge0ContextBudget {
        resolve(
            availableBytes: UInt64(max(0, MemoryAdvisor.availableMemoryForModel)),
            ceilingBytes: UInt64(max(0, MemoryAdvisor.processMemoryCeiling)),
            outputTokens: outputTokens
        )
    }

    @MainActor
    static func currentLimit(outputTokens: Int) -> Int {
        current(outputTokens: outputTokens).maxInputTokens
    }
}
