import XCTest
@testable import IOSLocalLLM

final class MiniCPM35BTextProfileTests: XCTestCase {
    func testTextRequestsCanUseTheNormalAssistantReplyBudget() {
        XCTAssertGreaterThanOrEqual(MiniCPM35BTextProfile.maximumRequestedOutputTokens, 2_048)
        XCTAssertLessThanOrEqual(MiniCPM35BTextProfile.maximumRequestedOutputTokens, 4_096)
    }
    func testExpandedCacheRequiresItsFullLiveMemoryBudget() {
        XCTAssertEqual(profile(available: 5_500_000_000), .expanded)
        XCTAssertEqual(profile(available: 5_499_999_999), .conservative)
        XCTAssertEqual(profile(available: 0), .conservative)
        XCTAssertEqual(profile(available: -1), .conservative)
    }
    func testWarmDevicesKeepTheSmallerCache() {
        XCTAssertEqual(profile(available: 8_000_000_000, nominal: false), .conservative)
    }
    func testLowPowerModeKeepsTheSmallerCache() {
        XCTAssertEqual(profile(available: 8_000_000_000, lowPower: true), .conservative)
    }
    func testPressureRecoveryKeepsTheSmallerCache() {
        XCTAssertEqual(profile(available: 8_000_000_000, cooldown: true), .conservative)
    }
    func testExpandedCacheChargesExtraHeadroomWithoutLoweringAdmission() {
        XCTAssertEqual(MiniCPM35BTextProfile.conservative.cacheSlots, 16)
        XCTAssertEqual(MiniCPM35BTextProfile.expanded.cacheSlots, 24)
        XCTAssertEqual(MiniCPM35BTextProfile.conservative.minimumAvailableBytes, 4_800_000_000)
        XCTAssertGreaterThan(MiniCPM35BTextProfile.expanded.minimumAvailableBytes,
                             MiniCPM35BTextProfile.conservative.minimumAvailableBytes)
    }
    func testLargerCachesRequireHealthyLiveHeadroom() {
        XCTAssertEqual(profile(available: 5_899_999_999), .expanded)
        XCTAssertEqual(profile(available: 5_900_000_000), .balanced)
        XCTAssertEqual(profile(available: 6_199_999_999), .balanced)
        XCTAssertEqual(profile(available: 6_200_000_000), .highHeadroom)
        XCTAssertEqual(profile(available: 6_380_000_000), .highHeadroom)
        XCTAssertEqual(MiniCPM35BTextProfile.balanced.cacheSlots, 32)
        XCTAssertEqual(MiniCPM35BTextProfile.highHeadroom.cacheSlots, 48)
    }
    func testAllocationFallbackAlwaysMovesToSmallerCaches() {
        XCTAssertEqual(MiniCPM35BTextProfile.cacheFallbacks(from: 48), [48, 32, 24, 16])
        XCTAssertEqual(MiniCPM35BTextProfile.cacheFallbacks(from: 32), [32, 24, 16])
        XCTAssertEqual(MiniCPM35BTextProfile.cacheFallbacks(from: 24), [24, 16])
        XCTAssertEqual(MiniCPM35BTextProfile.cacheFallbacks(from: 16), [16])
    }
    func testPromptBatchAdmissionIncludesTotalCapacityAndIncrementalReserve() {
        XCTAssertEqual(batch(available: 6_380_000_000, cache: 48), 1024)
        XCTAssertEqual(batch(available: 2_800_000_000, cache: 48), 1024)
        XCTAssertEqual(batch(available: 1_799_999_999, cache: 48), 512)
        XCTAssertEqual(batch(available: 2_800_000_000, ceiling: 5_373_793_279, cache: 48), 512)
        XCTAssertEqual(batch(available: 2_800_000_000, ceiling: 5_373_793_280, cache: 48), 1024)
        XCTAssertEqual(batch(available: 1_299_999_999, cache: 48), 256)
        XCTAssertEqual(batch(available: 999_999_999, cache: 48), 128)
        XCTAssertEqual(batch(available: 6_380_000_000, ceiling: 4_900_000_000, cache: 48), 256)
        XCTAssertEqual(batch(available: 6_380_000_000, ceiling: 4_600_000_000, cache: 48), 128)
        XCTAssertEqual(batch(available: -1, cache: 16), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, cache: 256), 128)
    }
    func testPromptBatchBacksOffOnThermalsPowerAndPressure() {
        XCTAssertEqual(batch(available: 8_000_000_000, thermal: .serious), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, thermal: .critical), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, lowPower: true), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, cooldown: true), 128)
    }
    func testFairPromptBatchUsesAnAdmittedIntermediateCeiling() {
        XCTAssertEqual(batch(available: 2_628_511_752, cache: 48, thermal: .fair), 256)
        XCTAssertEqual(batch(available: 8_000_000_000, thermal: .fair), 256)
        XCTAssertEqual(batch(available: 999_999_999, thermal: .fair), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, thermal: .fair, lowPower: true), 128)
        XCTAssertEqual(batch(available: 8_000_000_000, thermal: .fair, cooldown: true), 128)
        XCTAssertEqual(profile(available: 8_000_000_000, nominal: false), .conservative)
    }
    func testPrefixCacheHasItsOwnLiveMemoryReserve() {
        let minimum = 1_500_000_000 + MiniCPM35BTextProfile.maximumPrefixStateBytes
        XCTAssertFalse(prefix(available: minimum - 1))
        XCTAssertTrue(prefix(available: minimum))
        XCTAssertFalse(prefix(available: -1))
        XCTAssertFalse(prefix(available: Int64.min))
        XCTAssertFalse(prefix(available: 6_000_000_000, ceiling: 0))
        XCTAssertFalse(prefix(available: 6_000_000_000, ceiling: 5_200_000_000))
        XCTAssertFalse(prefix(available: 6_000_000_000, cache: 256))
        XCTAssertLessThanOrEqual(MiniCPM35BTextProfile.maximumPrefixStateBytes, 128 * 1_024 * 1_024)
    }
    func testPrefixCacheDisablesOnPressurePowerAndUnsafeThermals() {
        XCTAssertTrue(prefix(available: 2_500_000_000, thermal: .nominal))
        XCTAssertTrue(prefix(available: 2_500_000_000, thermal: .fair))
        XCTAssertFalse(prefix(available: 6_000_000_000, thermal: .serious))
        XCTAssertFalse(prefix(available: 6_000_000_000, thermal: .critical))
        XCTAssertFalse(prefix(available: 6_000_000_000, lowPower: true))
        XCTAssertFalse(prefix(available: 6_000_000_000, cooldown: true))
    }
    func testPrefixReserveCanLowerTheAdmittedPromptBatch() {
        func reserved(_ available: Int64, ceiling: Int64 = 6_440_000_000) -> UInt32 {
            MiniCPM35BTextProfile.maximumPromptMicrobatch(availableMemory: available,
                processMemoryCeiling: ceiling, cacheSlots: 48, thermalState: .nominal,
                isLowPowerMode: false, hasPressureCooldown: false, reservingPrefixCache: true)
        }
        XCTAssertEqual(batch(available: 1_800_000_000), 1024)
        XCTAssertEqual(reserved(1_800_000_000), 512)
        XCTAssertEqual(reserved(1_800_000_000 + MiniCPM35BTextProfile.maximumPrefixStateBytes), 1024)
        XCTAssertEqual(reserved(6_000_000_000, ceiling: 5_373_793_280), 512)
        XCTAssertEqual(reserved(6_000_000_000, ceiling: 5_373_793_280 + MiniCPM35BTextProfile.maximumPrefixStateBytes), 1024)
        XCTAssertEqual(reserved(Int64.min), 128)
    }
    private func prefix(available: Int64, ceiling: Int64 = 6_440_000_000, cache: UInt32 = 48,
                        thermal: ProcessInfo.ThermalState = .nominal,
                        lowPower: Bool = false, cooldown: Bool = false) -> Bool {
        MiniCPM35BTextProfile.allowsPrefixCache(availableMemory: available,
            processMemoryCeiling: ceiling, cacheSlots: cache, thermalState: thermal,
            isLowPowerMode: lowPower, hasPressureCooldown: cooldown)
    }
    private func batch(available: Int64, ceiling: Int64 = 6_440_000_000, cache: UInt32 = 48,
                       thermal: ProcessInfo.ThermalState = .nominal,
                       lowPower: Bool = false, cooldown: Bool = false) -> UInt32 {
        MiniCPM35BTextProfile.maximumPromptMicrobatch(availableMemory: available,
            processMemoryCeiling: ceiling, cacheSlots: cache,
            thermalState: thermal, isLowPowerMode: lowPower, hasPressureCooldown: cooldown)
    }
    private func profile(available: Int64, nominal: Bool = true, lowPower: Bool = false,
                         cooldown: Bool = false) -> MiniCPM35BTextProfile {
        .resolve(availableMemory: available, isThermallyNominal: nominal,
                 isLowPowerMode: lowPower, hasPressureCooldown: cooldown)
    }
}
