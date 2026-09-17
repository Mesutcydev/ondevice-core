import Foundation

// MARK: - Edge0 35B budgets + app memory policy
//
// The only place the 35B family reads live app memory state. Values still
// come from `MemoryAdvisor` / `DeviceSafetyMonitor`; no new device limits are
// defined here.

extension Edge0_35BMemoryBudget {
    @MainActor
    static func current() -> Edge0_35BMemoryBudget {
        resolve(
            availableBytes: UInt64(max(0, MemoryAdvisor.availableMemoryForModel)),
            ceilingBytes: UInt64(max(0, MemoryAdvisor.processMemoryCeiling))
        )
    }

    @MainActor
    static var isDeviceAdmitted: Bool {
        DeviceSafetyMonitor.shared.stopReason == nil
    }
}

extension Edge0_35BContextBudget {
    @MainActor
    static func current(outputTokens: Int) -> Edge0_35BContextBudget {
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
