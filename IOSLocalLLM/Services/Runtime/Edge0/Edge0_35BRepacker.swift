import Foundation
import CryptoKit
import Darwin

/// CPU/file-only preparation. Never instantiates MLX arrays or loads a runtime.
/// The original directory remains loadable until one atomic directory exchange.
enum Edge0_35BRepacker {
    struct Update: Sendable {
        let fraction: Double
        let step: String
    }
    typealias Checkpoint = @Sendable () async throws -> Void
    typealias Report = @Sendable (Update) async -> Void
    static let bufferBytes = 1_048_576
    static let receiptName = ".edge0-repack-state.json"

    /// Storage preparation is optional heavy I/O. These gates are independent
    /// of whether the user has muted thermal warning banners.
    static func pauseMessage(isForeground: Bool, thermal: ProcessInfo.ThermalState,
                             hasMemoryPressure: Bool, modelIsLoaded: Bool) -> String? {
        if !isForeground { return "Preparation will resume when you return to the app." }
        if thermal == .serious || thermal == .critical || hasMemoryPressure {
            return "Preparation will resume when the device has cooled and memory is available."
        }
        if modelIsLoaded { return "Unload this model to resume preparation." }
        return nil
    }

    enum Failure: Error, LocalizedError {
        case invalidSource, unsafeDirectory, busy, sourceChanged, verification(String)
        case insufficientSpace(UInt64), swapFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .invalidSource: return "The model does not match the supported Edge0-35B checkpoint."
            case .unsafeDirectory: return "Model preparation found an unsafe file or directory."
            case .busy: return "This model is already being prepared."
            case .sourceChanged: return "The downloaded model changed during preparation. Retry preparation."
            case .verification(let name): return "Prepared model verification failed for \(name). Retry preparation."
            case .insufficientSpace(let bytes):
                return "Preparing this model needs about \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) more free space. Free storage, then resume. The original download has been kept."
            case .swapFailed: return "The prepared model could not replace the original. Resume to retry; the original download has been kept."
            }
        }
    }

    struct Fingerprint: Codable, Equatable, Sendable {
        let name: String
        let size: UInt64
        let modified: Date
    }
    struct Receipt: Codable, Sendable {
        let version: Int
        let revision: String
        let source: [Fingerprint]
        var hashes: [String: String]
    }

    /// Internal plan also supports small, byte-exact fixtures. Production always
    /// uses the pinned 40-layer/256-expert layout after native release validation.
    struct Plan: Sendable {
        let index: Edge0SafetensorsIndex
        let layers: Int
        let experts: Int
        let parts: [Edge0_35BRepackedExperts.Part]
        let resident: [Edge0TensorLocation]
        let blockBytes: Int

        init(index: Edge0SafetensorsIndex, layers: Int = 40, experts: Int = 256,
             parts: [Edge0_35BRepackedExperts.Part] = Edge0_35BRepackedExperts.expectedParts) throws {
            guard layers > 0, experts > 0, parts.count == 9 else { throw Failure.invalidSource }
            self.index = index
            self.layers = layers
            self.experts = experts
            self.parts = parts
            blockBytes = parts.reduce(0) { $0 + $1.bytes }
            var names = Set<String>()
            var offset = 0
            for part in parts {
                guard part.offset == offset, part.bytes > 0 else { throw Failure.invalidSource }
                offset += part.bytes
                for layer in 0..<layers {
                    let name = Self.tensorName(layer, part.name)
                    let location = try index.location(name)
                    guard location.shape == [experts] + part.shape,
                          location.dtype.rawValue == part.dtype,
                          location.byteCount == UInt64(part.bytes) * UInt64(experts) else {
                        throw Failure.invalidSource
                    }
                    names.insert(name)
                }
            }
            guard Set(index.locations.keys.filter { $0.contains(".mlp.switch_mlp.") }) == names else {
                throw Failure.invalidSource
            }
            resident = index.locations.values.filter { !names.contains($0.name) }.sorted { $0.name < $1.name }
        }

        static func tensorName(_ layer: Int, _ part: String) -> String {
            "language_model.model.layers.\(layer).mlp.switch_mlp.\(part)"
        }
    }

    static func stagingDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(".\(directory.lastPathComponent).edge0-repack", isDirectory: true)
    }

    static func hasPendingPreparation(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: stagingDirectory(for: directory).appendingPathComponent(receiptName).path)
    }

    static func prepare(in directory: URL,
                        sourceRevision: String = Edge0ModelFamily.qwen35MoEPinnedRevision,
                        checkpoint: @escaping Checkpoint,
                        report: @escaping Report) async throws {
        try await checkpoint()
        _ = try Edge0_35BModelArtifacts.validateForRuntime(directory: directory)
        if try Edge0_35BRepackedExperts.openIfPresent(in: directory) != nil {
            try cleanCommittedOriginal(in: directory)
            return
        }
        let plan = try Plan(index: Edge0SafetensorsIndex.openSharded(in: directory))
        try await convert(in: directory, plan: plan, sourceRevision: sourceRevision,
                          checkpoint: checkpoint, report: report) { output in
            _ = try Edge0_35BModelArtifacts.validateForRuntime(directory: output)
        }
    }

    static func convert(in directory: URL, plan: Plan,
                        sourceRevision: String = Edge0ModelFamily.qwen35MoEPinnedRevision,
                        checkpoint: @escaping Checkpoint,
                        report: @escaping Report, availableBytes: UInt64? = nil,
                        validate: @Sendable (URL) throws -> Void) async throws {
        let fm = FileManager.default
        guard Edge0ModelFamily.qwen35MoERepackRevisions.contains(sourceRevision) else {
            throw Failure.invalidSource
        }
        try requireDirectory(directory)
        let source = directory.resolvingSymlinksInPath().standardizedFileURL
        let staging = stagingDirectory(for: source)
        try requireDirectory(source)
        if fm.fileExists(atPath: staging.path) { try requireDirectory(staging) }
        // Nonblocking lock protects duplicate managers and concurrent imports.
        let lockURL = staging.appendingPathExtension("lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.unsafeDirectory }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(lock, LOCK_UN) }
        let sourceFiles = try fingerprints(in: source)
        var receipt = Receipt(version: 1, revision: sourceRevision,
                              source: sourceFiles, hashes: [:])
        if fm.fileExists(atPath: staging.path) {
            let saved = try readReceipt(in: staging)
            if saved.source == sourceFiles && saved.revision == sourceRevision { receipt = saved }
            else { try fm.removeItem(at: staging) }
        }
        if !fm.fileExists(atPath: staging.path) {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        }
        // The staging directory becomes the installed directory at commit.
        // Preserve the downloader's exclusion of re-downloadable model files.
        var stagingURL = staging
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try stagingURL.setResourceValues(resourceValues)
        try save(receipt, in: staging)

        var stores = [String: Edge0PreadFile]()
        defer { for store in stores.values { store.close() } }
        for name in plan.index.shardNames {
            stores[name] = try Edge0PreadFile(path: checkedFile(name, in: source).path)
        }
        let copied = sourceFiles.filter { !plan.index.shardNames.contains($0.name)
            && $0.name != "model.safetensors.index.json" && $0.name != receiptName }
        let residentBytes = plan.resident.reduce(UInt64(0)) { $0 + $1.byteCount }
        let layerBytes = UInt64(plan.blockBytes) * UInt64(plan.experts)
        let needed = UInt64(plan.layers) * layerBytes + residentBytes
            + copied.reduce(UInt64(0)) { $0 + $1.size } + 16_777_216
        let allocated = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            .reduce(UInt64(0)) { result, url in
                result + UInt64(max(0, (try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0))
            }
        let remaining = needed > allocated ? needed - allocated : 0
        let free = try availableBytes ?? UInt64(max(0, source.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0))
        guard free >= remaining else { throw Failure.insufficientSpace(remaining) }

        let units = plan.layers + 2 // expert files, resident, metadata + commit
        for layer in 0..<plan.layers {
            try await checkpoint()
            let name = Edge0_35BRepackedExperts.layerName(layer)
            let url = staging.appendingPathComponent(name)
            await report(Update(fraction: Double(layer) / Double(units), step: "Preparing model · \(layer + 1) of \(plan.layers)"))
            if !(try await reusable(name, size: layerBytes, receipt: receipt, in: staging, checkpoint: checkpoint)) {
                let output = try newFile(url)
                var digest = SHA256()
                do {
                    for expert in 0..<plan.experts {
                        try await checkpoint()
                        for part in plan.parts {
                            let location = try plan.index.location(Plan.tensorName(layer, part.name)).row(expert)
                            try copy(location, stores: stores, to: output, digest: &digest)
                        }
                        if expert % 16 == 0 {
                            await report(Update(fraction: (Double(layer) + Double(expert) / Double(plan.experts)) / Double(units),
                                                step: "Preparing model · \(layer + 1) of \(plan.layers)"))
                        }
                    }
                    try output.synchronize()
                    try output.close()
                } catch { try? output.close(); throw error }
                let expected = hex(digest.finalize())
                guard try await hash(url, checkpoint: checkpoint) == expected else { throw Failure.verification(name) }
                receipt.hashes[name] = expected
                try save(receipt, in: staging)
            }
        }
        await report(Update(fraction: Double(plan.layers) / Double(units), step: "Preparing shared model weights"))
        var header = [String: Any](), cursor: UInt64 = 0
        for tensor in plan.resident {
            header[tensor.name] = ["dtype": tensor.dtype.rawValue, "shape": tensor.shape,
                                   "data_offsets": [cursor, cursor + tensor.byteCount]]
            cursor += tensor.byteCount
        }
        var blob = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        blob.append(Data(repeating: 0x20, count: (8 - blob.count % 8) % 8))
        var length = UInt64(blob.count).littleEndian
        var prefix = withUnsafeBytes(of: &length) { Data($0) }
        prefix.append(blob)
        let residentName = Edge0_35BRepackedExperts.residentName
        let residentURL = staging.appendingPathComponent(residentName)
        if !(try await reusable(residentName, size: UInt64(prefix.count) + residentBytes,
                                receipt: receipt, in: staging, checkpoint: checkpoint)) {
            let output = try newFile(residentURL)
            var digest = SHA256()
            do {
                try output.write(contentsOf: prefix)
                digest.update(data: prefix)
                for tensor in plan.resident {
                    try await checkpoint()
                    try await copyLarge(tensor, stores: stores, to: output, digest: &digest, checkpoint: checkpoint)
                }
                try output.synchronize()
                try output.close()
            } catch { try? output.close(); throw error }
            let expected = hex(digest.finalize())
            guard try await hash(residentURL, checkpoint: checkpoint) == expected else { throw Failure.verification(residentName) }
            receipt.hashes[residentName] = expected
            try save(receipt, in: staging)
        }
        // Copy all non-shard files, including notices and download sidecars.
        for file in copied {
            try await checkpoint()
            let original = try checkedFile(file.name, in: source)
            let outputURL = staging.appendingPathComponent(file.name)
            if !(try await reusable(file.name, size: file.size, receipt: receipt, in: staging, checkpoint: checkpoint)) {
                let input = try Edge0PreadFile(path: original.path)
                defer { input.close() }
                let output = try newFile(outputURL)
                var digest = SHA256()
                do {
                    let location = Edge0TensorLocation(name: file.name, shard: file.name, payloadOffset: 0,
                                                      byteCount: file.size, dtype: .u8, shape: [Int(file.size)])
                    try await copyLarge(location, stores: [file.name: input], to: output, digest: &digest, checkpoint: checkpoint)
                    try output.synchronize()
                    try output.close()
                } catch { try? output.close(); throw error }
                let expected = hex(digest.finalize())
                guard try await hash(outputURL, checkpoint: checkpoint) == expected else { throw Failure.verification(file.name) }
                receipt.hashes[file.name] = expected
                try save(receipt, in: staging)
            }
        }
        let weightMap = Dictionary(uniqueKeysWithValues: plan.resident.map { ($0.name, residentName) })
        try durableWrite(JSONSerialization.data(withJSONObject: ["weight_map": weightMap], options: [.sortedKeys]),
                         to: staging.appendingPathComponent("model.safetensors.index.json"))
        let payloadNames = Set((0..<plan.layers).map(Edge0_35BRepackedExperts.layerName) + [residentName])
        let manifest = Edge0_35BRepackedExperts(format: Edge0_35BRepackedExperts.formatName,
            sourceRepo: Edge0ModelFamily.qwen35MoERepoID, sourceRevision: sourceRevision,
            layers: plan.layers, expertsPerLayer: plan.experts, blockBytes: plan.blockBytes, parts: plan.parts,
            fileSHA256: receipt.hashes.filter { payloadNames.contains($0.key) })
        try durableWrite(JSONEncoder().encode(manifest), to: staging.appendingPathComponent(Edge0_35BRepackedExperts.manifestName))
        await report(Update(fraction: Double(units - 1) / Double(units), step: "Verifying prepared model"))
        try validate(staging)
        guard try fingerprints(in: source) == sourceFiles else { throw Failure.sourceChanged }
        try await checkpoint()
        try Task.checkCancellation()
        // Both directories are on the same volume. No missing-directory window,
        // mixed old/new index, or recovery that guesses which rename completed.
        syncDirectory(staging)
        guard renamex_np(source.path, staging.path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.swapFailed(errno) }
        syncDirectory(source.deletingLastPathComponent())
        // After a kill here, prepare() recognizes a valid committed pack and
        // finishes removing the old directory on the next attempt.
        try? fm.removeItem(at: staging)
        await report(Update(fraction: 1, step: "Model ready"))
    }

    static func cleanCommittedOriginal(in directory: URL) throws {
        let staging = stagingDirectory(for: directory)
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        try requireDirectory(staging)
        let receipt = try readReceipt(in: directory)
        guard try fingerprints(in: staging) == receipt.source else { throw Failure.sourceChanged }
        try FileManager.default.removeItem(at: staging)
    }

    static func discardStaging(in directory: URL) throws {
        let staging = stagingDirectory(for: directory)
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        try requireDirectory(staging)
        _ = try readReceipt(in: staging)
        try FileManager.default.removeItem(at: staging)
    }

    private static func copy(_ tensor: Edge0TensorLocation, stores: [String: Edge0PreadFile],
                             to output: FileHandle, digest: inout SHA256) throws {
        guard let input = stores[tensor.shard] else { throw Failure.invalidSource }
        var offset: UInt64 = 0
        while offset < tensor.byteCount {
            try Task.checkCancellation()
            let count = Int(min(UInt64(bufferBytes), tensor.byteCount - offset))
            let bytes = try input.read(offset: tensor.payloadOffset + offset, count: count)
            try output.write(contentsOf: bytes)
            digest.update(data: bytes)
            offset += UInt64(count)
        }
    }

    private static func copyLarge(_ tensor: Edge0TensorLocation, stores: [String: Edge0PreadFile],
                                  to output: FileHandle, digest: inout SHA256, checkpoint: Checkpoint) async throws {
        var offset: UInt64 = 0
        while offset < tensor.byteCount {
            try await checkpoint()
            let count = min(UInt64(bufferBytes * 8), tensor.byteCount - offset)
            let slice = Edge0TensorLocation(name: tensor.name, shard: tensor.shard, payloadOffset: tensor.payloadOffset + offset,
                                           byteCount: count, dtype: .u8, shape: [Int(count)])
            try copy(slice, stores: stores, to: output, digest: &digest)
            offset += count
        }
    }

    private static func hash(_ url: URL, checkpoint: Checkpoint) async throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), chunks = 0
        while true {
            try Task.checkCancellation()
            if chunks % 8 == 0 { try await checkpoint() }
            guard let bytes = try file.read(upToCount: bufferBytes), !bytes.isEmpty else { break }
            digest.update(data: bytes)
            chunks += 1
        }
        return hex(digest.finalize())
    }

    private static func reusable(_ name: String, size: UInt64, receipt: Receipt, in directory: URL,
                                 checkpoint: Checkpoint) async throws -> Bool {
        guard let expected = receipt.hashes[name], expected.count == 64 else { return false }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        _ = try checkedFile(name, in: directory)
        guard try Edge0FileIO.fileSize(at: url) == size else { return false }
        return try await hash(url, checkpoint: checkpoint) == expected
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func newFile(_ url: URL) throws -> FileHandle {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try checkedFile(url.lastPathComponent, in: url.deletingLastPathComponent())
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure.verification(url.lastPathComponent) }
        return try FileHandle(forWritingTo: url)
    }

    private static func requireDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafeDirectory }
    }

    private static func checkedFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == directory.resolvingSymlinksInPath().standardizedFileURL,
              (try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.unsafeDirectory }
        return url
    }

    private static func fingerprints(in directory: URL) throws -> [Fingerprint] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                let file = try checkedFile(url.lastPathComponent, in: directory)
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values.contentModificationDate else { throw Failure.invalidSource }
                return Fingerprint(name: file.lastPathComponent, size: try Edge0FileIO.fileSize(at: file), modified: modified)
            }
    }

    private static func readReceipt(in directory: URL) throws -> Receipt {
        let url = try checkedFile(receiptName, in: directory)
        guard try Edge0FileIO.fileSize(at: url) <= 262_144 else { throw Failure.invalidSource }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard receipt.version == 1, Edge0ModelFamily.qwen35MoERepackRevisions.contains(receipt.revision) else { throw Failure.invalidSource }
        return receipt
    }

    private static func save(_ receipt: Receipt, in directory: URL) throws {
        try durableWrite(JSONEncoder().encode(receipt), to: directory.appendingPathComponent(receiptName))
    }

    private static func durableWrite(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: [.atomic])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}
