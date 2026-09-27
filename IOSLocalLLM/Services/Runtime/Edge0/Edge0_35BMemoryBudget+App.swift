import Foundation

// MARK: - Edge0 35B budgets + app memory policy
//
// The only place the 35B family reads live app memory state. Values still
// come from `MemoryAdvisor` / `DeviceSafetyMonitor`; no new device limits are
// defined here.

extension Edge0_35BMemoryBudget {
    @MainActor
    static func current() -> Edge0_35BMemoryBudget {
        let memory = MemoryAdvisor.memorySnapshot
        return resolve(
            availableBytes: UInt64(memory.available),
            ceilingBytes: UInt64(memory.ceiling),
            accounting: Edge0EnginePreferences.edge0_35BPoolAccounting,
            maxContextTokens: Edge0_35BContextBudget.experimentalMaximumInputTokens
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
        let memory = MemoryAdvisor.memorySnapshot
        return resolve(
            availableBytes: UInt64(memory.available),
            ceilingBytes: UInt64(memory.ceiling),
            outputTokens: outputTokens,
            accounting: Edge0EnginePreferences.edge0_35BPoolAccounting
        )
    }

    @MainActor
    static func currentLimit(outputTokens: Int) -> Int {
        current(outputTokens: outputTokens).maxInputTokens
    }
}
