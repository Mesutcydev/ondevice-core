import Foundation

// MARK: - Edge0RuntimeResourceSnapshot
//
// App-layer bridge from the live Edge0 engines to the typed run-boundary
// snapshot. Optional fields stay nil when a runtime cannot measure them;
// the benchmark refuses to claim a clean boundary on an incomplete snapshot.

extension Edge0_35BEngine {
    func resourceSnapshot() async -> RuntimeResourceSnapshot? {
        guard let configuration = engineConfiguration,
              let pool else { return nil }
        let stats = await pool.statistics()
        let reads = stores?.readStatistics()
        return RuntimeResourceSnapshot(
            family: family.rawValue,
            isGenerationActive: isGenerationInFlight,
            activeExpertLeases: stats.activeLeases,
            pinnedExpertSlots: stats.pinnedSlots,
            inFlightExpertLoads: stats.inFlightLoads,
            queuedExpertRequests: stats.waitingAcquireCalls,
            activeTensorReads: reads?.activeReadsAtSnapshot,
            configuredMaxConcurrentReads: configuration.maxConcurrentReads,
            poolCapacitySlots: stats.capacitySlots,
            poolOccupancySlots: stats.occupancySlots
        )
    }
}

extension Edge0Engine {
    func resourceSnapshot() async -> RuntimeResourceSnapshot? {
        guard let configuration = engineConfiguration,
              let pool else { return nil }
        let stats = await pool.statistics()
        let reads = stores?.readStatistics()
        return RuntimeResourceSnapshot(
            family: Edge0ModelFamily.bailing8B.rawValue,
            isGenerationActive: isGenerationInFlight,
            activeExpertLeases: stats.activeLeases,
            pinnedExpertSlots: stats.pinnedSlots,
            inFlightExpertLoads: stats.inFlightLoads,
            queuedExpertRequests: stats.waitingAcquireCalls,
            activeTensorReads: reads?.activeReadsAtSnapshot,
            configuredMaxConcurrentReads: configuration.maxConcurrentReads,
            poolCapacitySlots: stats.capacitySlots,
            poolOccupancySlots: stats.occupancySlots
        )
    }
}

extension Edge0RuntimeBackend: RuntimeResourceProviding {
    func resourceSnapshot() async -> RuntimeResourceSnapshot? {
        switch loadedFamily {
        case .bailing8B:
            guard let engine8B else { return nil }
            return await engine8B.resourceSnapshot()
        case .qwen35MoE:
            guard let engine35B else { return nil }
            return await engine35B.resourceSnapshot()
        case nil:
            return nil
        }
    }
}
