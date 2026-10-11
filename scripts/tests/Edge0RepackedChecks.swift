import Foundation

@main
enum Edge0RepackedChecks {
    static func require(_ value: Bool, _ message: String) {
        precondition(value, message)
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(message) } catch {}
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge0-repack-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        require(try Edge0_35BRepackedExperts.openIfPresent(in: directory) == nil, "ordinary imports must remain supported")

        let parts = Edge0_35BRepackedExperts.expectedParts
        require(parts.last!.offset + parts.last!.bytes == Edge0_35BRepackedExperts.blockBytes, "block layout")
        var hashes = [String: String]()
        for name in (0..<40).map(Edge0_35BRepackedExperts.layerName) {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: Edge0_35BRepackedExperts.layerBytes)
            try file.close()
            hashes[name] = String(repeating: "a", count: 64)
        }
        try Data(repeating: 0, count: 16).write(to: directory.appendingPathComponent("resident.safetensors"))
        hashes["resident.safetensors"] = String(repeating: "b", count: 64)
        let manifest = Edge0_35BRepackedExperts(
            format: Edge0_35BRepackedExperts.formatName,
            sourceRepo: Edge0ModelFamily.qwen35MoERepoID,
            sourceRevision: Edge0ModelFamily.qwen35MoEPinnedRevision,
            layers: 40, expertsPerLayer: 256,
            blockBytes: Edge0_35BRepackedExperts.blockBytes, parts: parts, fileSHA256: hashes
        )
        let manifestURL = directory.appendingPathComponent("experts.json")
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: manifestURL)
        let opened = try Edge0_35BRepackedExperts.openIfPresent(in: directory)!
        rejects("negative expert accepted") { _ = try opened.location(layer: 0, expert: -1) }
        rejects("overflow expert accepted") { _ = try opened.location(layer: 39, expert: Int.max) }
        rejects("unknown layer accepted") { _ = try opened.location(layer: 40, expert: 0) }
        var publicManifest = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        publicManifest["source_revision"] = Edge0ModelFamily.qwen35MoEPublicRevision
        try JSONSerialization.data(withJSONObject: publicManifest).write(to: manifestURL)
        let publicOpened = try Edge0_35BRepackedExperts.openIfPresent(in: directory)!
        require(publicOpened.sourceRevision == Edge0ModelFamily.qwen35MoEPublicRevision, "audited equivalent revision rejected")
        try encoded.write(to: manifestURL)

        // Exercise first/last addressing and the actual production read queue.
        let location = try opened.location(layer: 39, expert: 255)
        var block = Data()
        for (index, part) in parts.enumerated() {
            block.append(Data(repeating: UInt8(index + 1), count: part.bytes))
        }
        let lastFile = directory.appendingPathComponent(location.shard)
        let handle = try FileHandle(forWritingTo: lastFile)
        try handle.seek(toOffset: location.payloadOffset)
        try handle.write(contentsOf: block)
        try handle.close()
        let stores = try Edge0TensorStoreSet(directory: directory, shardNames: opened.expertFileNames, maxConcurrentReads: 2)
        let read = try await stores.read(location)
        require(read.bytes == block, "packed expert bytes changed")
        require(stores.readStatistics().totalReads == 1, "one expert must issue one read")
        let first = try await stores.read(opened.location(layer: 0, expert: 0))
        require(first.bytes == Data(repeating: 0, count: block.count), "first expert offset")
        await stores.closeAll()
        do {
            _ = try await stores.read(location)
            preconditionFailure("closed stores accepted a read")
        } catch {}

        var altered = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        altered["source_revision"] = String(repeating: "0", count: 40)
        try JSONSerialization.data(withJSONObject: altered).write(to: manifestURL)
        rejects("wrong release accepted") { _ = try Edge0_35BRepackedExperts.openIfPresent(in: directory) }
        altered = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var alteredParts = altered["parts"] as! [[String: Any]]
        alteredParts[1]["offset"] = 0
        altered["parts"] = alteredParts
        try JSONSerialization.data(withJSONObject: altered).write(to: manifestURL)
        rejects("overlapping tensors accepted") { _ = try Edge0_35BRepackedExperts.openIfPresent(in: directory) }
        try encoded.write(to: manifestURL)
        let truncated = try FileHandle(forWritingTo: lastFile)
        try truncated.truncate(atOffset: Edge0_35BRepackedExperts.layerBytes - 1)
        try truncated.close()
        rejects("truncated pack accepted") { _ = try Edge0_35BRepackedExperts.openIfPresent(in: directory) }
        try FileManager.default.removeItem(at: lastFile)
        try FileManager.default.createSymbolicLink(at: lastFile, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        rejects("external layer accepted") { _ = try Edge0_35BRepackedExperts.openIfPresent(in: directory) }
        print("Edge0 repacked storage checks passed")
    }
}
