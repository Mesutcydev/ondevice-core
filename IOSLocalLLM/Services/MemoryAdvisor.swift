import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MemoryAdvisor
// Helps decide whether loading a given model is safe on the current device.
//
// Admission uses a live process snapshot, bounded by physical/platform caps.
// Estimated model peaks are incremental to that snapshot. They include
// weights and runtime state; the app's current footprint is already charged.

enum MemoryAdvisor {

    // MARK: - Load-time headroom

    // Legacy weight-to-peak heuristic for callers without a tensor/config
    // breakdown (primarily Lens). Never multiply an already-estimated peak.
    static let loadSpikeMultiplier = 1.6

    // Fallback for unknown architectures. Supported text models instead use
    // explicit KV/recurrent/workspace estimates in MLXModelMemoryEstimate.
    static let workingSetOverhead = 1.3

    // Additional margin for concurrent app growth and estimation uncertainty.
    // The current app footprint is already deducted from live headroom.
    static let loadHeadroomReserve: Int64 = 500_000_000

    // Runtime slack in addition to the explicitly calculated KV, recurrent
    // state, and prefill workspace. Rotating caches remain unquantized.
    static let boundedKVRuntimeReserve: Int64 = 250_000_000

    // Reserve used in edge / developer mode (`AppSettings.showEdgeModels`).
    // Zero so a "tight" model whose peak just fits the live ceiling is allowed
    // to load. This is the opt-in risky path; the normal path keeps the full
    // `loadHeadroomReserve` to reduce the chance of memory-pressure failures.
    static let edgeHeadroomReserve: Int64 = 0

    // Conservative footprint assumed when a model can't be sized (custom /
    // imported repos with no preset match and no readable on-disk folder).
    // 3.5 GB covers an unknown mid/large model; with `loadHeadroomReserve` an
    // unsized model needs ~4 GB free to load — strict, since "we don't know
    // its size" should fail safe, but no longer wildly over-stated.
    static let unknownFootprintFloor: Int64 = 3_500_000_000

    // MARK: - Post-pressure load cooldown
    //
    // After the kernel reports CRITICAL memory pressure, MemoryPressureCoordinator
    // dumps model weights. For a short window afterward we refuse new HEAVY
    // loads: reloading immediately races iOS while it is still reclaiming, which
    // leaves the dumped model AND its reload both resident for a moment — the
    // exact spike that gets the process Jetsam-killed. Small recovery models
    // that comfortably fit current headroom are still allowed so the user is
    // never fully stuck.

    static let pressureCooldown: TimeInterval = 20
    /// A model at/under this peak may still load during the cooldown if it fits
    /// the live headroom — lets a small camera VLM recover the lens immediately.
    static let smallRecoveryModelCeiling: Int64 = 1_073_741_824   // 1 GB

    /// When set and in the future, heavy loads are on cooldown. MainActor-only;
    /// written by `notePressureDump()` and read by `safetyBlocker()`.
    @MainActor private(set) static var pressureLoadBlockedUntil: Date?

    /// Open the post-pressure cooldown. Called after an emergency weight dump.
    @MainActor static func notePressureDump() {
        pressureLoadBlockedUntil = Date().addingTimeInterval(pressureCooldown)
    }

    /// Seconds remaining on the post-critical-pressure cooldown, or nil when
    /// no cooldown is active. Single home for the date math so `safetyBlocker`
    /// and the VLM load gates (LensInferenceLoop.switchTo) enforce the same
    /// window — a heavy VLM reload must not race the kernel's reclaim either.
    @MainActor static var pressureCooldownRemaining: TimeInterval? {
        guard let until = pressureLoadBlockedUntil, until.timeIntervalSinceNow > 0 else {
            return nil
        }
        return until.timeIntervalSinceNow
    }

    // MARK: - Device

    /// Total physical RAM in bytes.
    static var deviceTotalRAM: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// RAM available for app use after a 30% headroom for OS + other apps.
    static var availableRAM: Int64 {
        Int64(Double(deviceTotalRAM) * 0.70)
    }

    /// Live per-process memory headroom in bytes — how much more this app can
    /// allocate before iOS kills it for memory. On iOS this ceiling sits well
    /// below physical RAM (a 6 GB device often gives a process only ~3 GB even
    /// with the increased-memory entitlement), so it's the real OOM limit.
    /// Zero on an iOS app means no headroom, not permission to use a fallback.
    static var processAvailableMemory: Int64 {
        memorySnapshot.kernelHeadroom ?? 0
    }

    /// Device RAM not resident in THIS process (deviceTotalRAM − our own
    /// `resident_size`), in bytes. NOT "free physical memory" — other apps'
    /// and the OS's pages still count as available here. Useful only to
    /// recover an approximate resident size (`deviceTotalRAM − this`), e.g.
    /// the `processMemoryCeiling` fallback and the diagnostics snapshots.
    /// Reports 0 on failure.
    static var nonResidentRAMEstimate: Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let used = Int64(info.resident_size)
            return max(0, deviceTotalRAM - used)
        }
        return 0
    }

    /// This process's current `phys_footprint` in bytes — the SAME accounting
    /// the kernel uses to decide `os_proc_available_memory()` and to Jetsam the
    /// app. Reports 0 on failure.
    ///
    /// This is deliberately NOT `mach_task_basic_info.resident_size`. The two
    /// diverge for GPU / IOKit allocations: an MLX/Metal model's weight buffers
    /// count toward `phys_footprint` (and therefore against the memory limit)
    /// but are largely absent from `resident_size`. Mixing the two — as the old
    /// `processMemoryCeiling` did (`os_proc_available_memory() + resident_size`)
    /// — made the ceiling read ~1 GB+ LOW whenever a VLM was resident, because
    /// `os_proc_available_memory()` had already subtracted the GPU footprint
    /// while `resident_size` never added it back. That's the "open the Lens
    /// VLM, switch to Assistant, Qwen3-4B is suddenly too large for this
    /// device" bug: the ceiling was polluted by the just-used VLM's GPU memory.
    private static func taskMemoryInfo() -> (footprint: Int64, remaining: Int64?)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // The remaining-limit field arrived in TASK_VM_INFO revision 4.
        let remainingOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.limit_bytes_remaining)!
        let hasRemaining = Int(count) * MemoryLayout<natural_t>.size >= remainingOffset + MemoryLayout<UInt64>.size
        return (Int64(clamping: info.phys_footprint),
                hasRemaining ? Int64(clamping: info.limit_bytes_remaining) : nil)
    }

    static var physFootprint: Int64 {
        taskMemoryInfo()?.footprint ?? 0
    }

    // MARK: - Platform bounds

    /// Heuristic only for hosts without iOS process-limit reporting. An
    /// entitlement never authorizes exceeding a reported kernel limit.
    private static var entitlementCeilingFraction: Double {
        switch DeviceTierAdvisor.current {
        case .lite, .entry: return 0.55   // ≤4 GB — keep very tight
        case .mid:          return 0.62   // 6 GB
        case .pro:          return 0.72   // 8 GB  → ~6.2 GB usable
        case .max:          return 0.76   // 12 GB+ (12 GiB) → ~9.8 GB usable
        }
    }

    /// Hard reserve always kept for the OS + other apps, regardless of tier.
    private static let physicalOSReserve: Int64 = 1_500_000_000

    /// Conservative process cap for iPhones below the 12 GB Max tier.
    static let maximumIPhoneProcessCeiling: Int64 = 6_200_000_000

    /// Upper policy bound for high-memory iPhones, not a guaranteed grant.
    /// A smaller live kernel budget always wins.
    static let maximumHighMemoryIPhoneProcessCeiling: Int64 = 8_500_000_000
    static let highMemoryIPhoneRAMThreshold: Int64 = 10_000_000_000

    private static var isIPhoneProcess: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// Applies physical and platform bounds to a candidate process ceiling.
    /// Kept injectable so the real-device Jetsam regression is unit-testable
    /// without depending on the test host's RAM or interface idiom.
    static nonisolated func clampedProcessCeiling(
        candidate: Int64,
        totalRAM: Int64,
        isPhone: Bool
    ) -> Int64 {
        let physicalCap = max(0, totalRAM - physicalOSReserve)
        let phoneCap = totalRAM >= highMemoryIPhoneRAMThreshold
            ? maximumHighMemoryIPhoneProcessCeiling
            : maximumIPhoneProcessCeiling
        let platformCap = isPhone ? min(physicalCap, phoneCap) : physicalCap
        return min(max(0, candidate), platformCap)
    }

    /// Read footprint and headroom together from task_info when available.
    /// Limits can change during the app lifecycle, so this is never cached.
    /// A tier fraction is only for platforms without the iOS limit API.
    static var memorySnapshot: ProcessMemoryBudget {
        let info = taskMemoryInfo()
        let headroom: Int64?
        #if os(iOS) && !targetEnvironment(simulator)
        headroom = info?.remaining ?? Int64(clamping: os_proc_available_memory())
        #else
        headroom = nil
        #endif
        return ProcessMemoryBudget.resolve(
            footprint: info?.footprint,
            kernelHeadroom: headroom,
            fallbackCeiling: MemoryBytes.count(Double(deviceTotalRAM) * entitlementCeilingFraction),
            platformCap: clampedProcessCeiling(
                candidate: .max, totalRAM: deviceTotalRAM, isPhone: isIPhoneProcess
            )
        )
    }

    /// Current estimated ceiling, not a guarantee of future allocations.
    static var processMemoryCeiling: Int64 { memorySnapshot.ceiling }

    /// Incremental allocations available now, with the current app footprint
    /// already deducted. Zero is a valid exhausted budget.
    static var availableMemoryForModel: Int64 { memorySnapshot.available }

    // MARK: - Device fit (for suggestion badges)

    enum Fit {
        case fits        // comfortably within the ceiling, with reserve to spare
        case tight       // fits, but with little headroom — may throttle / fail under pressure
        case over        // exceeds the ceiling — won't load on this device

        var label: String {
            switch self {
            case .fits:  return "fits"
            case .tight: return "tight"
            case .over:  return "too big"
            }
        }
    }

    /// Classifies an additional model load using the same headroom and
    /// reserve as admission. Visited workspaces can still hold allocations.
    static func fit(forFootprint footprint: Int64) -> Fit {
        fit(forFootprint: footprint, available: memorySnapshot.available)
    }

    static func fit(forFootprint footprint: Int64, available: Int64) -> Fit {
        let assumed = footprint > 0 ? footprint : unknownFootprintFloor
        if MemoryBytes.add(assumed, loadHeadroomReserve) <= available { return .fits }
        if assumed <= available { return .tight }
        return .over
    }

    /// Convenience: fit verdict for a model id, using its estimated peak.
    static func fit(forModelID modelID: String) -> Fit {
        let footprint = estimatedFootprint(for: modelID)
        return fit(forFootprint: footprint > 0 ? footprint : unknownFootprintFloor)
    }

    // MARK: - Model footprints (working-set estimates)

    /// Best-effort working-set estimate per model, in bytes.
    /// Falls back to AssistantModelCatalog preset metadata and finally to an
    /// on-disk weight estimate so downloaded / imported models are no
    /// longer reported as "0 — fits anywhere".
    static func estimatedFootprint(for modelID: String) -> Int64 {
        // A Lens estimate must include the vision tower and image workspace.
        // Never feed its selection through the text-only tensor estimator.
        if modelID.hasPrefix("vision:") {
            let repoID = String(modelID.dropFirst("vision:".count))
            // GGUF pairs materialize only the projector (mirrors the
            // LlamaCppVLMService load gate); the LLM weights stay mmap'd.
            if let dir = LlamaCppVLMService.stagedDirectory(for: repoID),
               let mmproj = LlamaCppVLMService.resolveMmprojPath(in: dir),
               let bytes = (try? URL(fileURLWithPath: mmproj).resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return MemoryBytes.add(MemoryBytes.count(Double(bytes) * loadSpikeMultiplier),
                                       GGUFLoadPolicy.storageBackedHeadroom)
            }
            return onDiskWeightsSize(forRepoID: repoID)
                .map { MemoryBytes.count(Double($0) * loadSpikeMultiplier) } ?? 0
        }
        // 0. An installed MLX preset is sized from what it will actually load.
        //    Its catalog number stays the estimate before download; several
        //    were padded for an 8.5 GB ceiling iOS never granted.
        if let preset = AssistantModelCatalog.model(forID: modelID), preset.runtime == .mlx,
           let measured = measuredPresetFootprint(preset) {
            return measured
        }
        // 1. Built-ins with hand-tuned numbers
        switch modelID {
        case "qwen3-1.7b":       return 1_500_000_000   // ~1.5 GB peak
        case "qwen3-4b":         return 3_800_000_000   // ~3.8 GB peak
        case "qwen3-8b":         return 6_500_000_000   // ~6.5 GB peak
        case FastVLMService.modelID: return 1_400_000_000   // ~1.4 GB peak
        case "kittentts-nano":   return 250_000_000     // ~250 MB
        case "kittentts-mini":   return 700_000_000     // ~700 MB
        case "kokoro":           return 400_000_000     // ~400 MB
        default: break
        }
        // 2. Preset bytes from the assistant catalog
        if let preset = AssistantModelCatalog.model(forID: modelID) {
            return preset.approxRAMBytes
        }
        // 2b. Core AI catalog packs (including vision/utility, which are not
        //     Assistant presets) and installed Application Support trees.
        if modelID.hasPrefix("coreai:") {
            if let zoo = CoreAIZooCatalog.model(forSelectionID: modelID) {
                return zoo.approxDownloadBytes + 500_000_000
            }
            if let onDisk = onDiskCoreAISize(forSelectionID: modelID), onDisk > 0 {
                return MemoryBytes.add(MemoryBytes.count(Double(onDisk) * workingSetOverhead), 500_000_000)
            }
        }
        // 3. Installed text models use their actual tensors and execution
        // profile. Unsized folders keep a conservative floor.
        if let repoID = nonPresetRepoID(from: modelID) {
            if let directory = localModelDirectory(forRepoID: repoID),
               let measured = measuredFootprint(repoID: repoID, directory: directory) {
                return measured
            }
            // mmap'd GGUF weights are not charged to the footprint: report
            // exactly what GGUFLoadPolicy admits, not file size × overhead.
            if let directory = localModelDirectory(forRepoID: repoID),
               let gguf = LocalModelFileValidator.ggufLLM(in: directory),
               let bytes = (try? gguf.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return GGUFLoadPolicy.resolve(
                    fileBytes: Int64(bytes),
                    pagingEnabled: AppSettings.shared.largeModelLowMemoryEnabled
                ).minimumAvailableBytes
            }
            if let onDisk = onDiskWeightsSize(forRepoID: repoID), onDisk > 0 {
                return max(unknownFootprintFloor, MemoryBytes.count(Double(onDisk) * workingSetOverhead))
            }
        }
        return 0
    }

    /// Estimate actual text tensors and the execution profile's cache/state.
    /// Metadata-backed models expose a breakdown; unknown architectures keep
    /// the proportional fallback rather than a universal 250 MB envelope.
    static func measuredFootprint(repoID: String, directory: URL) -> Int64? {
        let key = "text:\(repoID):\(directory.standardizedFileURL.path)"
        _diskSizeLock.lock()
        if let cached = _diskSizeCache[key] {
            _diskSizeLock.unlock()
            return cached < 0 ? nil : cached
        }
        _diskSizeLock.unlock()
        let measured = uncachedTextFootprint(repoID: repoID, directory: directory)
        _diskSizeLock.lock()
        _diskSizeCache[key] = measured ?? -1
        _diskSizeLock.unlock()
        return measured
    }

    private static func uncachedTextFootprint(repoID: String, directory: URL) -> Int64? {
        guard let weights = LocalModelRegistry.textWeightBytes(in: directory), weights > 0 else { return nil }
        let profile = MLXAssistantExecutionProfile.resolve(
            repoID: repoID,
            architecture: LocalModelRegistry.declaredModelType(in: directory)
        )
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let estimate = MLXModelMemoryEstimate.estimate(
                weights: weights, config: config,
                contextTokens: profile.maxKVSize ?? (DeviceTierAdvisor.current == .max ? 16_384 : 8_192),
                rotatingCache: profile.maxKVSize != nil, kvBits: profile.kvBits,
                prefillTokens: profile.prefillStepSize,
                allocatorCache: Int64(profile.cacheLimitBytes),
                runtimeReserve: boundedKVRuntimeReserve
           ) {
            return estimate.peak
        }
        return max(MemoryBytes.add(weights, boundedKVRuntimeReserve),
                   MemoryBytes.count(Double(weights) * workingSetOverhead))
    }

    /// Memoized with the disk-size cache (invalidated when installs change):
    /// this runs for every Models-tab fit badge.
    private static func measuredPresetFootprint(_ preset: AssistantModel) -> Int64? {
        let key = "measured:\(preset.id)"
        _diskSizeLock.lock()
        if let cached = _diskSizeCache[key] {
            _diskSizeLock.unlock()
            return cached < 0 ? nil : cached
        }
        _diskSizeLock.unlock()
        let measured = CodingAssistantService.preStagedDirectory(for: preset)
            .flatMap { measuredFootprint(repoID: preset.repoID, directory: $0) }
        _diskSizeLock.lock()
        _diskSizeCache[key] = measured ?? -1
        _diskSizeLock.unlock()
        return measured
    }

    /// Pulls the bare repoID out of `downloaded:…`, `imported:…`, `custom:…`.
    private static func nonPresetRepoID(from modelID: String) -> String? {
        let unwrapped = LocalModelRegistry.unwrapAssistantSelectionID(modelID)
        return unwrapped == modelID ? nil : unwrapped
    }

    // On-disk size cache. `allocatedSizeOfDirectory` recursively sums every
    // file in a multi-GB model folder — far too expensive to run per row on
    // every scroll frame, which is exactly what `estimatedFootprint` did once
    // it started driving the Models-tab fit badges. The result is stable while
    // browsing (a folder doesn't change size unless a download completes), so
    // we memoize it. `-1` is the "checked, nothing on disk" sentinel so a
    // not-yet-downloaded repo isn't re-walked every frame either.
    private static let _diskSizeLock = NSLock()
    nonisolated(unsafe) private static var _diskSizeCache: [String: Int64] = [:]

    /// Drops the on-disk size cache. Call when the installed set changes (a
    /// download finishes, a model is deleted) so freshly-sized repos are
    /// re-measured on next access. Cheap; safe to call liberally.
    static func invalidateFootprintCache() {
        LocalModelRegistry.invalidateMemoryMetadataCache()
        _diskSizeLock.lock()
        _diskSizeCache.removeAll(keepingCapacity: true)
        _diskSizeLock.unlock()
    }

    /// Where a non-preset repo lives: Discovery downloads use
    /// `HFModels/<author>_<name>`, Files imports `HFModels/local_<name>`
    /// (repo `local/local_<name>`), catalog-style copies `LLMModels/<name>`.
    static func localModelDirectory(forRepoID repoID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tail = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let candidates = [
            docs.appendingPathComponent("HFModels").appendingPathComponent(repoID.replacingOccurrences(of: "/", with: "_")),
            docs.appendingPathComponent("HFModels").appendingPathComponent(tail),
            docs.appendingPathComponent("LLMModels").appendingPathComponent(tail),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            ?? candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Logical weight-file bytes, excluding tokenizer/docs and filesystem
    /// allocation/compression effects. Memoized —
    /// see `_diskSizeCache`. Returns nil if the directory doesn't exist.
    private static func onDiskWeightsSize(forRepoID repoID: String) -> Int64? {
        _diskSizeLock.lock()
        if let cached = _diskSizeCache[repoID] {
            _diskSizeLock.unlock()
            return cached < 0 ? nil : cached
        }
        _diskSizeLock.unlock()

        let result: Int64? = localModelDirectory(forRepoID: repoID)
            .flatMap { directory -> Int64? in
                guard let files = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return nil }
                var total: Int64 = 0
                for case let file as URL in files {
                    guard ["safetensors", "gguf", "npz", "bin"].contains(file.pathExtension) else { continue }
                    guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, let size = values.fileSize else { return nil }
                    total = MemoryBytes.add(total, Int64(size))
                }
                return total > 0 ? total : nil
            }

        _diskSizeLock.lock()
        _diskSizeCache[repoID] = result ?? -1
        _diskSizeLock.unlock()
        return result
    }

    /// Allocated size of an installed Core AI pack, keyed by `coreai:` selection
    /// id. Walks Application Support manifests because install folders are
    /// named by version, not catalog id.
    private static func onDiskCoreAISize(forSelectionID selectionID: String) -> Int64? {
        let rawID = selectionID.hasPrefix("coreai:")
            ? String(selectionID.dropFirst("coreai:".count))
            : selectionID
        let cacheKey = "coreai-disk:\(rawID)"
        _diskSizeLock.lock()
        if let cached = _diskSizeCache[cacheKey] {
            _diskSizeLock.unlock()
            return cached < 0 ? nil : cached
        }
        _diskSizeLock.unlock()

        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreAIModels", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            _diskSizeLock.lock()
            _diskSizeCache[cacheKey] = -1
            _diskSizeLock.unlock()
            return nil
        }

        var measured: Int64?
        for folder in children {
            let manifestURL = folder
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else { continue }
            let installedRaw = id.hasPrefix("coreai:") ? String(id.dropFirst("coreai:".count)) : id
            guard installedRaw == rawID else { continue }
            measured = try? FileManager.default.allocatedSizeOfDirectory(at: folder)
            break
        }

        _diskSizeLock.lock()
        _diskSizeCache[cacheKey] = measured ?? -1
        _diskSizeLock.unlock()
        return measured
    }

    // MARK: - Verdicts

    enum Verdict {
        case fitsComfortably
        case marginal(String)        // uncertain size or >85% of live headroom
        case wontFit(String)         // peak + reserve exceeds live headroom

        var color: String {
            switch self {
            case .fitsComfortably: return "green"
            case .marginal:        return "orange"
            case .wontFit:         return "red"
            }
        }

        var isBlocking: Bool {
            if case .wontFit = self { return true }
            return false
        }
    }

    /// Live headroom already includes resident allocations.
    static func verdict(for modelID: String) -> Verdict {
        verdict(forFootprint: estimatedFootprint(for: modelID))
    }

    static func verdict(
        forFootprint footprint: Int64
    ) -> Verdict {
        verdict(
            forFootprint: footprint, available: memorySnapshot.available,
            reserve: AppSettings.shared.showEdgeModels ? edgeHeadroomReserve : loadHeadroomReserve
        )
    }

    static func verdict(forFootprint footprint: Int64, available: Int64, reserve: Int64) -> Verdict {
        let needed = MemoryBytes.required(peak: footprint, reserve: reserve, unknownFloor: unknownFootprintFloor)
        let budget = max(0, available)
        if needed > budget {
            return .wontFit(String(
                format: "Estimated additional peak is ~%.1f GB including reserve; ~%.1f GB is available to the app right now. Unload a model and retry.",
                Double(needed) / 1_000_000_000, Double(budget) / 1_000_000_000
            ))
        }
        // Unknown size must never earn a reassuring green badge.
        if footprint <= 0 {
            return .marginal("Model size is unknown. Admission reserves at least \(unknownFootprintFloor.formattedBytes); actual memory use may be higher.")
        }
        if Double(needed) / Double(max(1, budget)) > 0.85 {
            return .marginal("This model fits, but uses most of the app's ~\(budget.formattedBytes) current memory headroom.")
        }
        return .fitsComfortably
    }

    @MainActor
    static func verdictWithCurrentlyLoaded(for modelID: String) -> Verdict {
        verdictWithCurrentlyLoaded(forFootprint: estimatedFootprint(for: modelID), excludingModelID: modelID)
    }

    /// A currently resident target needs no second copy. Other runtimes are
    /// already charged to the live snapshot; don't subtract estimates again.
    @MainActor
    static func verdictWithCurrentlyLoaded(
        forFootprint footprint: Int64,
        excludingModelID modelID: String? = nil
    ) -> Verdict {
        if let modelID,
           (CodingAssistantService.shared.state == .ready && CodingAssistantService.shared.activeModel.id == modelID)
            || (modelID == FastVLMService.modelID && FastVLMService.shared.componentStatus.canGenerate) {
            return .fitsComfortably
        }
        return verdict(forFootprint: footprint)
    }

    // MARK: - Combined device-safety verdict

    /// Combined verdict: RAM + live free memory + thermal state + low-power.
    /// Use this before kicking off a model load. Returns nil when it's safe.
    ///
    /// Thermal handling here follows Apple's actual guidance: only block
    /// at `.critical`. The previous threshold (block >1.5 GB models at
    /// `.serious`) refused Qwen3-4B (~2.3 GB) the moment the device got
    /// even moderately warm, which on an A19 Pro is the working state
    /// during sustained inference. iOS's own thermal scheduler already
    /// throttles CPU/GPU clocks at `.serious`; we don't need to layer a
    /// hard refuse on top.
    @MainActor
    static func safetyBlocker(
        for modelID: String,
        allowTightFit: Bool = false,
        runtime: ModelRuntime? = nil,
        allowUnsafeMemoryLoad: Bool = false
    ) -> String? {
        // Callers that can start MLX work must await
        // `MLXGenerationGate.clearCacheWhenIdle()` before entering this
        // synchronous measurement. A state-based "nothing is generating"
        // check is racy: a native load or a just-cancelled Metal command can
        // still be live after the published UI state changes.

        // 1. Thermal: only refuse at .critical. .serious is workable on
        //    modern silicon and iOS already does its own backoff there.
        if DeviceSafetyMonitor.shared.thermalState == .critical {
            return "Device is too hot to safely load this model. Let it cool for a minute, then retry."
        }

        // A user-confirmed experimental attempt bypasses memory-capacity
        // admission for this call only. Critical thermal protection remains:
        // adding a known-oversized allocation while iOS is already throttling
        // at its highest level is not a useful model test.
        if allowUnsafeMemoryLoad {
            return nil
        }

        // Size before sampling: filesystem work should not age the live budget.
        let footprint = estimatedFootprint(for: modelID)
        let assumed = footprint > 0 ? footprint : unknownFootprintFloor
        let memory = memorySnapshot
        Diagnostics.shared.breadcrumb(
            "memory admission · model=\(modelID) · estimatedPeak=\(assumed) · footprint=\(memory.footprint) · kernelHeadroom=\(memory.kernelHeadroom.map(String.init) ?? "unavailable") · ceiling=\(memory.ceiling) · available=\(memory.available)",
            category: "memory"
        )
        if let remaining = pressureCooldownRemaining,
           MemoryBytes.add(assumed, loadHeadroomReserve) > memory.available {
            let secs = max(1, Int(remaining.rounded(.up)))
            return "iOS just reported a memory-pressure spike. Wait ~\(secs)s for it to recover memory, then retry."
        }
        let reserve = (AppSettings.shared.showEdgeModels || allowTightFit)
            ? edgeHeadroomReserve : loadHeadroomReserve
        return capacityBlocker(
            footprint: assumed, memory: memory, reserve: reserve,
            runtime: runtime, lowMemoryEnabled: allowTightFit
        )
    }

    /// Pure admission path used by the live gate and deterministic regressions.
    static func capacityBlocker(
        footprint: Int64, memory: ProcessMemoryBudget, reserve: Int64,
        runtime: ModelRuntime?, lowMemoryEnabled: Bool
    ) -> String? {
        let assumed = footprint > 0 ? footprint : unknownFootprintFloor
        let needed = MemoryBytes.add(assumed, reserve)
        guard needed > memory.available else { return nil }
        if assumed > memory.ceiling {
            return hardCeilingMessage(
                neededBytes: needed, ceilingBytes: memory.ceiling,
                runtime: runtime, lowMemoryEnabled: lowMemoryEnabled
            )
        }
        if reserve > 0, assumed <= memory.available {
            return String(
                format: "This model needs ~%.1f GB and fits the ~%.1f GB available only without the %.1f GB safety reserve. A reduced reserve increases the risk that iOS closes the app during inference.",
                Double(assumed) / 1_000_000_000,
                Double(memory.available) / 1_000_000_000, Double(reserve) / 1_000_000_000
            )
        }
        return String(
            format: "Not enough memory to load this model safely (~%.1f GB needed, only ~%.1f GB available to the app). Unload other models or close some apps, then retry.",
            Double(needed) / 1_000_000_000, Double(memory.available) / 1_000_000_000
        )
    }

    /// Explains a hard process-ceiling refusal without implying that the
    /// low-memory switch can page every model format. MLX can reduce retained
    /// allocator/KV cache, but its full weights still count against the iOS
    /// process limit. Only llama.cpp's GGUF path can keep weights file-backed
    /// and let iOS reclaim clean pages.
    static nonisolated func hardCeilingMessage(
        neededBytes: Int64,
        ceilingBytes: Int64,
        runtime: ModelRuntime?,
        lowMemoryEnabled: Bool
    ) -> String {
        let neededGB = Double(neededBytes) / 1_000_000_000
        let ceilingGB = Double(ceilingBytes) / 1_000_000_000
        if runtime == .mlx, lowMemoryEnabled {
            return String(
                format: "This MLX model needs ~%.1f GB, but this app can use ~%.1f GB on this device. Low-memory mode cannot page MLX weights. Choose a smaller MLX model (4B or 1.7B), or import a GGUF quantization for storage-backed paging.",
                neededGB,
                ceilingGB
            )
        }
        if runtime == .coreAI {
            return String(
                format: "This Core AI pack needs ~%.1f GB, but this app can use ~%.1f GB on this device. Core AI cannot page weights like GGUF. Choose a smaller pack, such as Qwen3 0.6B.",
                neededGB,
                ceilingGB
            )
        }
        return String(
            format: "This model is too large for this device (~%.1f GB needed, but the app can use at most ~%.1f GB here). Pick a smaller model — a 4B or 1.7B fits comfortably.",
            neededGB,
            ceilingGB
        )
    }

    /// Capacity failures cannot be fixed by retrying the same model. Keep the
    /// classification beside the messages it recognizes so recovery UI does
    /// not depend on a particular model name or byte estimate.
    static nonisolated func isHardCapacityFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("this mlx model needs")
            || normalized.contains("this core ai pack needs")
            || normalized.contains("model is too large for this device")
    }

    // MARK: - Device summary

    static var deviceSummary: String {
        "\(deviceTotalRAM.formattedBytes) total · ~\(availableMemoryForModel.formattedBytes) available to load"
    }
}
