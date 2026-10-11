import Foundation
import CryptoKit

@main
enum Edge0RepackerChecks {
    actor Stop {
        var stopped = false
        func trigger() { stopped = true }
        func check() throws { if stopped { throw CancellationError() } }
    }
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }

    struct Fixture: Sendable {
        let directory: URL
        let plan: Edge0_35BRepacker.Plan
        let experts: [Data]
        let resident: Data
        let original: Data
    }

    static func fixture(_ root: URL, _ name: String) throws -> Fixture {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var header = [String: Any](), payload = Data(), experts = [Data]()
        var parts = [Edge0_35BRepackedExperts.Part]()
        for (index, part) in Edge0_35BRepackedExperts.expectedParts.enumerated() {
            parts.append(.init(name: part.name, dtype: part.dtype,
                               shape: part.dtype == "U32" ? [2] : [4], offset: index * 8, bytes: 8))
        }
        for layer in 0..<2 {
            var blocks = [Data](repeating: Data(), count: 3)
            for (partIndex, part) in parts.enumerated() {
                let start = payload.count
                for expert in 0..<3 {
                    let bytes = Data(repeating: UInt8(1 + layer * 40 + partIndex * 3 + expert), count: 8)
                    payload.append(bytes)
                    blocks[expert].append(bytes)
                }
                header[Edge0_35BRepacker.Plan.tensorName(layer, part.name)] = [
                    "dtype": part.dtype, "shape": [3] + part.shape, "data_offsets": [start, payload.count]
                ]
            }
            experts += blocks
        }
        let resident = Data((0..<20).map(UInt8.init))
        header["resident.weight"] = ["dtype": "BF16", "shape": [10], "data_offsets": [payload.count, payload.count + resident.count]]
        payload.append(resident)
        var blob = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        blob.append(Data(repeating: 32, count: (8 - blob.count % 8) % 8))
        var length = UInt64(blob.count).littleEndian
        var original = withUnsafeBytes(of: &length) { Data($0) }
        original.append(blob); original.append(payload)
        try original.write(to: directory.appendingPathComponent("model.safetensors"))
        let map = Dictionary(uniqueKeysWithValues: header.keys.map { ($0, "model.safetensors") })
        try JSONSerialization.data(withJSONObject: ["weight_map": map]).write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        try Data("fixture config".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("original license notice".utf8).write(to: directory.appendingPathComponent("NOTICE"))
        let plan = try Edge0_35BRepacker.Plan(index: .openSharded(in: directory), layers: 2, experts: 3, parts: parts)
        return Fixture(directory: directory, plan: plan, experts: experts, resident: resident, original: original)
    }

    static func verify(_ fixture: Fixture, in directory: URL) throws {
        for layer in 0..<2 {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(Edge0_35BRepackedExperts.layerName(layer)))
            var expected = Data()
            for expert in 0..<3 { expected.append(fixture.experts[layer * 3 + expert]) }
            require(bytes == expected, "expert bytes or ordering changed")
        }
        let index = try Edge0SafetensorsIndex.openSharded(in: directory)
        require(index.tensorCount == 1, "resident index includes expert tensors")
        let location = try index.location("resident.weight")
        let bytes = try Edge0FileIO.readExactly(at: directory.appendingPathComponent(location.shard), offset: location.payloadOffset, count: Int(location.byteCount))
        require(bytes == fixture.resident, "resident bytes changed")
        let manifest = try JSONDecoder().decode(Edge0_35BRepackedExperts.self, from: Data(contentsOf: directory.appendingPathComponent("experts.json")))
        require(manifest.fileSHA256.count == 3, "incomplete checksum inventory")
        for (name, expected) in manifest.fileSHA256 {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            require(actual == expected, "manifest checksum mismatch")
        }
        require(try Data(contentsOf: directory.appendingPathComponent("NOTICE")) == Data("original license notice".utf8), "notice lost")
    }

    static func main() async throws {
        require(Edge0_35BRepacker.pauseMessage(isForeground: true, thermal: .nominal, hasMemoryPressure: false, modelIsLoaded: false) == nil, "safe preparation refused")
        require(Edge0_35BRepacker.pauseMessage(isForeground: true, thermal: .fair, hasMemoryPressure: false, modelIsLoaded: false) == nil, "fair thermals refused")
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            require(Edge0_35BRepacker.pauseMessage(isForeground: true, thermal: thermal, hasMemoryPressure: false, modelIsLoaded: false) != nil, "hot device allowed")
        }
        require(Edge0_35BRepacker.pauseMessage(isForeground: false, thermal: .nominal, hasMemoryPressure: false, modelIsLoaded: false) != nil, "background work allowed")
        require(Edge0_35BRepacker.pauseMessage(isForeground: true, thermal: .nominal, hasMemoryPressure: true, modelIsLoaded: false) != nil, "memory pressure allowed")
        require(Edge0_35BRepacker.pauseMessage(isForeground: true, thermal: .nominal, hasMemoryPressure: false, modelIsLoaded: true) != nil, "active runtime allowed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edge0-iphone-repack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = try fixture(root, "complete")
        try await Edge0_35BRepacker.convert(in: complete.directory, plan: complete.plan,
            checkpoint: { try Task.checkCancellation() }, report: { _ in }, validate: { try verify(complete, in: $0) })
        try verify(complete, in: complete.directory)
        require(!Edge0_35BRepacker.hasPendingPreparation(in: complete.directory), "committed model still blocks loading")
        require(try complete.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "prepared model lost its backup exclusion")
        require(!FileManager.default.fileExists(atPath: complete.directory.appendingPathComponent("model.safetensors").path), "old shard not reclaimed")
        require(!FileManager.default.fileExists(atPath: Edge0_35BRepacker.stagingDirectory(for: complete.directory).path), "staging not reclaimed")
        let publicFixture = try fixture(root, "public-revision")
        try await Edge0_35BRepacker.convert(in: publicFixture.directory, plan: publicFixture.plan,
            sourceRevision: Edge0ModelFamily.qwen35MoEPublicRevision,
            checkpoint: {}, report: { _ in }, validate: { try verify(publicFixture, in: $0) })
        let publicManifest = try JSONDecoder().decode(Edge0_35BRepackedExperts.self,
            from: Data(contentsOf: publicFixture.directory.appendingPathComponent("experts.json")))
        require(publicManifest.sourceRevision == Edge0ModelFamily.qwen35MoEPublicRevision, "public source provenance changed")
        let unsupported = try fixture(root, "unsupported-revision")
        do {
            try await Edge0_35BRepacker.convert(in: unsupported.directory, plan: unsupported.plan,
                sourceRevision: String(repeating: "0", count: 40), checkpoint: {}, report: { _ in }, validate: { _ in })
            preconditionFailure("unsupported source revision accepted")
        } catch Edge0_35BRepacker.Failure.invalidSource {}
        require(!Edge0_35BRepacker.hasPendingPreparation(in: unsupported.directory), "unsupported revision created staging")
        // A process exit just after the exchange leaves old files in staging.
        let old = try fixture(root, "old")
        try FileManager.default.moveItem(at: old.directory, to: Edge0_35BRepacker.stagingDirectory(for: complete.directory))
        // Fingerprints include dates, so simulate the actual original directory
        // using the source signature retained in the committed receipt.
        let receiptURL = complete.directory.appendingPathComponent(Edge0_35BRepacker.receiptName)
        var receipt = try JSONDecoder().decode(Edge0_35BRepacker.Receipt.self, from: Data(contentsOf: receiptURL))
        let stage = Edge0_35BRepacker.stagingDirectory(for: complete.directory)
        let files = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.contentModificationDateKey])
        receipt = .init(version: receipt.version, revision: receipt.revision,
            source: try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                .init(name: $0.lastPathComponent, size: try Edge0FileIO.fileSize(at: $0),
                      modified: try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)
            }, hashes: receipt.hashes)
        try JSONEncoder().encode(receipt).write(to: receiptURL)
        try Edge0_35BRepacker.cleanCommittedOriginal(in: complete.directory)
        require(!FileManager.default.fileExists(atPath: stage.path), "post-commit recovery failed")

        for corrupt in [false, true] {
            let interrupted = try fixture(root, corrupt ? "corrupt" : "resume")
            let stop = Stop()
            do {
                try await Edge0_35BRepacker.convert(in: interrupted.directory, plan: interrupted.plan,
                    checkpoint: { try await stop.check() }, report: { update in
                        if update.step == "Preparing model · 2 of 2" { await stop.trigger() }
                    }, validate: { try verify(interrupted, in: $0) })
                preconditionFailure("interruption ignored")
            } catch is CancellationError {}
            require(Edge0_35BRepacker.hasPendingPreparation(in: interrupted.directory), "partial preparation does not block loading")
            require(try Data(contentsOf: interrupted.directory.appendingPathComponent("model.safetensors")) == interrupted.original, "interrupted conversion changed source")
            let layer = Edge0_35BRepacker.stagingDirectory(for: interrupted.directory).appendingPathComponent("experts-L00.bin")
            let before = try layer.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if corrupt { try Data(repeating: 255, count: 216).write(to: layer) }
            try await Edge0_35BRepacker.convert(in: interrupted.directory, plan: interrupted.plan,
                checkpoint: { try Task.checkCancellation() }, report: { _ in }, validate: { try verify(interrupted, in: $0) })
            try verify(interrupted, in: interrupted.directory)
            if !corrupt {
                let after = try interrupted.directory.appendingPathComponent("experts-L00.bin").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                require(before == after, "verified completed layer was rewritten on resume")
            }
        }
        let invalid = try fixture(root, "validation-failure")
        do {
            try await Edge0_35BRepacker.convert(in: invalid.directory, plan: invalid.plan,
                checkpoint: {}, report: { _ in }, validate: { _ in throw Edge0_35BRepacker.Failure.invalidSource })
            preconditionFailure("invalid output was committed")
        } catch Edge0_35BRepacker.Failure.invalidSource {}
        require(try Data(contentsOf: invalid.directory.appendingPathComponent("model.safetensors")) == invalid.original, "failed validation changed source")
        try Edge0_35BRepacker.discardStaging(in: invalid.directory)

        let full = try fixture(root, "disk-full")
        do {
            try await Edge0_35BRepacker.convert(in: full.directory, plan: full.plan,
                checkpoint: {}, report: { _ in }, availableBytes: 0, validate: { _ in })
            preconditionFailure("insufficient storage accepted")
        } catch Edge0_35BRepacker.Failure.insufficientSpace {}
        require(try Data(contentsOf: full.directory.appendingPathComponent("model.safetensors")) == full.original, "disk refusal changed source")

        let changed = try fixture(root, "source-changed")
        do {
            try await Edge0_35BRepacker.convert(in: changed.directory, plan: changed.plan,
                checkpoint: {}, report: { update in
                    if update.step == "Verifying prepared model" {
                        try? Data("changed config".utf8).write(to: changed.directory.appendingPathComponent("config.json"))
                    }
                }, validate: { try verify(changed, in: $0) })
            preconditionFailure("changed source was committed")
        } catch Edge0_35BRepacker.Failure.sourceChanged {}
        require(try Data(contentsOf: changed.directory.appendingPathComponent("model.safetensors")) == changed.original, "source-change refusal deleted weights")
        let linked = try fixture(root, "linked")
        try FileManager.default.removeItem(at: linked.directory.appendingPathComponent("NOTICE"))
        try FileManager.default.createSymbolicLink(at: linked.directory.appendingPathComponent("NOTICE"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        do {
            try await Edge0_35BRepacker.convert(in: linked.directory, plan: linked.plan, checkpoint: {}, report: { _ in }, validate: { _ in })
            preconditionFailure("external symlink accepted")
        } catch Edge0_35BRepacker.Failure.unsafeDirectory {}
        print("iPhone repacker checks passed: byte parity, atomic activation/recovery, resume, corruption repair, disk/validation/source-change refusal, symlink containment")
    }
}
