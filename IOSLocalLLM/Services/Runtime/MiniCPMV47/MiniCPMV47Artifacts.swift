import Foundation
import CryptoKit
import Darwin

/// Original storage conversion of the publisher's GGUF. Expert bytes and
/// top-eight routing are unchanged; only file layout changes. No community
/// conversion is downloaded or bundled.
enum MiniCPMV47Artifacts {
    static let receiptName = "ondevice-minicpm47.json"
    static let format = "ondevice-minicpm47-les-v1"
    static let modelName = "MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf"
    static let projectorName = "mmproj-model-f16.gguf"
    static let sourceSHA256 = "51e32201f0ddaf87dbb9689ceef9e3aa1a1543a1366706aa2abbf3aabb34df6b"
    static let projectorSHA256 = "bff3b688e14c300eca273092c37c50a0ddfcc2054e079af1a0480edeed5d20f1"
    static let sourceBytes: UInt64 = 15_503_944_896
    static let expertBytes: UInt64 = 450_560
    static let layerBytes: UInt64 = expertBytes * 3 * 256

    struct FileRecord: Codable, Sendable { let path: String; let bytes: UInt64; let sha256: String }
    struct Receipt: Codable, Sendable {
        let format: String
        let repo: String
        let revision: String
        let sourceSHA256: String
        let files: [FileRecord]
    }
    struct Progress: Sendable { let fraction: Double; let step: String }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    static func pendingDirectory(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-minicpm47-preparing")
    }

    static func isPrepared(in root: URL) -> Bool { (try? validate(in: root)) != nil }

    @discardableResult
    static func validate(in root: URL) throws -> Receipt {
        let receiptURL = root.appendingPathComponent(receiptName)
        guard (try? size(receiptURL)) ?? UInt64.max < 100_000,
              let data = try? Data(contentsOf: receiptURL), data.count < 100_000,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.format == format, receipt.repo == MiniCPMV47Catalog.thirtyFiveBRepoID,
              receipt.revision == MiniCPMV47Catalog.thirtyFiveBRevision,
              receipt.sourceSHA256 == sourceSHA256, receipt.files.count == 43 else {
            throw Failure.invalid("MiniCPM 35B needs a complete, verified expert-streaming pack.")
        }
        let expected = Set([modelName, projectorName, "experts/manifest.json"]
            + (0..<40).map { String(format: "experts/layer_%03d.bin", $0) })
        guard Set(receipt.files.map(\.path)) == expected else { throw Failure.invalid("MiniCPM pack inventory mismatch.") }
        for file in receipt.files {
            let url = try checkedURL(file.path, in: root)
            guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }),
                  try size(url) == file.bytes else { throw Failure.invalid("MiniCPM pack is incomplete or damaged.") }
            if file.path.hasSuffix(".bin"), file.bytes != layerBytes { throw Failure.invalid("MiniCPM expert size mismatch.") }
        }
        guard try size(root.appendingPathComponent(modelName)) > 0,
              try size(root.appendingPathComponent(modelName)) < 2_000_000_000,
              try size(root.appendingPathComponent(projectorName)) == 1_119_575_840,
              receipt.files.first(where: { $0.path == projectorName })?.sha256 == projectorSHA256 else {
            throw Failure.invalid("MiniCPM needs the split main model and matching vision encoder.")
        }
        for name in [modelName, projectorName] {
            let reader = try FileHandle(forReadingFrom: root.appendingPathComponent(name))
            defer { try? reader.close() }
            guard try reader.read(upToCount: 8) == Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]) else {
                throw Failure.invalid("MiniCPM model header is damaged.")
            }
        }
        let manifestURL = try checkedURL("experts/manifest.json", in: root)
        guard try size(manifestURL) < 200_000 else { throw Failure.invalid("MiniCPM manifest is too large.") }
        let manifest = try Data(contentsOf: manifestURL)
        guard manifest.count < 200_000,
              SHA256.hash(data: manifest).map({ String(format: "%02x", $0) }).joined()
                == receipt.files.first(where: { $0.path == "experts/manifest.json" })?.sha256,
              let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["schema_version"] as? Int == 1,
              object["layout"] as? String == "layer_major_expert",
              object["experts_kind"] as? String == "omni_moe_gguf",
              let model = object["model"] as? [String: Any], model["arch"] as? String == "qwen35moe",
              model["expert_count"] as? Int == 256, model["expert_used_count"] as? Int == 8,
              let entries = object["entries"] as? [[String: Any]], entries.count == 120 else {
            throw Failure.invalid("MiniCPM expert manifest does not match the supported model.")
        }
        var names = Set<String>()
        for entry in entries {
            guard let layer = entry["layer"] as? Int, (0..<40).contains(layer),
                  let family = entry["tensor_family"] as? String,
                  let index = families.firstIndex(of: family),
                  entry["tensor_name"] as? String == "blk.\(layer).\(family).weight",
                  entry["quant_type"] as? String == "Q3_K",
                  entry["shape"] as? [Int] == (index == 2 ? [512, 2048, 256] : [2048, 512, 256]),
                  entry["bytes_per_expert"] as? UInt64 == expertBytes,
                  entry["expert_stride"] as? UInt64 == expertBytes * 3,
                  entry["repacked_offset"] as? UInt64 == UInt64(index) * expertBytes,
                  entry["repacked_file"] as? String == String(format: "layer_%03d.bin", layer),
                  names.insert("\(layer):\(family)").inserted else {
                throw Failure.invalid("MiniCPM expert tensor contract mismatch.")
            }
        }
        return receipt
    }

    static func prepare(in root: URL, sourceRevision: String,
                        checkpoint: @escaping @Sendable () async throws -> Void,
                        report: @escaping @Sendable (Progress) async -> Void) async throws {
        if isPrepared(in: root) { cleanCommittedSource(in: root); return }
        guard sourceRevision == MiniCPMV47Catalog.thirtyFiveBRevision else { throw Failure.invalid("Unsupported MiniCPM source revision.") }
        try await checkpoint()
        let source = root.appendingPathComponent(modelName)
        let sidecars = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ![modelName, projectorName].contains($0.lastPathComponent) }
        for url in sidecars {
            guard let bytes = try? size(url), bytes <= 1_048_576 else {
                throw Failure.invalid("Use a dedicated MiniCPM 35B folder. Unrelated files have been kept.")
            }
        }
        guard try size(source) == sourceBytes else { throw Failure.invalid("The complete pinned MiniCPM 35B download is required.") }
        await report(.init(fraction: 0, step: "Verifying model source"))
        guard try await hash(source, checkpoint: checkpoint) == sourceSHA256 else { throw Failure.invalid("MiniCPM source checksum mismatch.") }
        let projector = root.appendingPathComponent(projectorName)
        guard try await hash(projector, checkpoint: checkpoint) == projectorSHA256 else { throw Failure.invalid("MiniCPM vision encoder checksum mismatch.") }
        let input = try GGUF(source)
        guard input.architecture == "qwen35moe", input.layerCount == 40,
              input.expertCount == 256, input.expertsUsed == 8 else { throw Failure.invalid("Unsupported MiniCPM architecture or routing.") }
        let expertNames = Set((0..<40).flatMap { layer in families.map { "blk.\(layer).\($0).weight" } })
        let routed = input.tensors.filter { expertNames.contains($0.name) }
        guard routed.count == 120 else { throw Failure.invalid("MiniCPM routed expert inventory mismatch.") }
        let stage = pendingDirectory(for: root)
        let fm = FileManager.default
        try fm.createDirectory(at: stage.appendingPathComponent("experts"), withIntermediateDirectories: true)
        let values = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let filesystemFree = (try? fm.attributesOfFileSystem(forPath: stage.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        // Some SDK/volume combinations return zero for the optional
        // "important usage" estimate while statfs reports actual free space.
        // Fall back to real free space and keep the storage margin below.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let capacity = important > 0 ? min(important, filesystemFree) : filesystemFree
        // Completed outputs are reusable after interruption. Admission counts
        // only the remaining payload, with an additional storage margin.
        let already = (try? fm.contentsOfDirectory(at: stage.appendingPathComponent("experts"), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let reused = already.filter { $0.pathExtension == "bin" }.reduce(UInt64(0)) { $0 + ((try? size($1)) ?? 0) }
        guard capacity >= Int64(sourceBytes - min(sourceBytes, reused)) + 2_000_000_000 else {
            throw Failure.invalid("Preparing MiniCPM 35B needs about 17 GB more free storage (\(capacity / 1_000_000) MB available). Free storage, then resume; the original download is kept.")
        }
        var records: [FileRecord] = []
        var entries: [[String: Any]] = []
        for layer in 0..<40 {
            try await checkpoint()
            let tensors = try families.enumerated().map { index, family -> Tensor in
                guard let tensor = routed.first(where: { $0.name == "blk.\(layer).\(family).weight" }),
                      tensor.type == 11, tensor.shape == (index == 2 ? [512, 2048, 256] : [2048, 512, 256]),
                      tensor.span >= expertBytes * 256 else { throw Failure.invalid("MiniCPM expert geometry mismatch.") }
                return tensor
            }
            let name = String(format: "experts/layer_%03d.bin", layer)
            let output = stage.appendingPathComponent(name)
            let saved = output.appendingPathExtension("sha256")
            var digest: String?
            if (try? size(output)) == layerBytes, let previous = try? String(contentsOf: saved, encoding: .utf8),
               try await hash(output, checkpoint: checkpoint) == previous { digest = previous }
            if digest == nil {
                let partial = output.appendingPathExtension("partial")
                fm.createFile(atPath: partial.path, contents: nil)
                let writer = try FileHandle(forWritingTo: partial)
                do {
                    for expert in 0..<256 {
                        try await checkpoint()
                        for tensor in tensors {
                            try await input.copy(offset: input.dataStart + tensor.offset + UInt64(expert) * expertBytes,
                                                 bytes: expertBytes, to: writer, checkpoint: checkpoint)
                        }
                    }
                    try writer.synchronize(); try writer.close()
                } catch { try? writer.close(); throw error }
                digest = try await hash(partial, checkpoint: checkpoint)
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                try fm.moveItem(at: partial, to: output)
                try digest!.write(to: saved, atomically: true, encoding: .utf8)
            }
            records.append(.init(path: name, bytes: layerBytes, sha256: digest!))
            for (index, tensor) in tensors.enumerated() {
                entries.append([
                    "layer": layer, "tensor_family": families[index], "tensor_name": tensor.name,
                    "original_gguf_tensor_name": tensor.name, "quant_type": "Q3_K", "block_size": 256,
                    "shape": tensor.shape, "exact_byte_length": expertBytes * 256,
                    "bytes_per_expert": expertBytes, "source_shard": modelName,
                    "source_shard_index": 0, "source_offset": input.dataStart + tensor.offset,
                    "repacked_file": output.lastPathComponent, "repacked_offset": UInt64(index) * expertBytes,
                    "expert_stride": expertBytes * 3
                ])
            }
            await report(.init(fraction: Double(layer + 1) / 43, step: "Preparing model · \(layer + 1) of 40"))
        }
        let main = stage.appendingPathComponent(modelName)
        try await input.writeStripped(to: main, removing: expertNames, checkpoint: checkpoint)
        records.append(.init(path: modelName, bytes: try size(main), sha256: try await hash(main, checkpoint: checkpoint)))
        let vision = stage.appendingPathComponent(projectorName)
        if fm.fileExists(atPath: vision.path) { try fm.removeItem(at: vision) }
        try fm.copyItem(at: projector, to: vision)
        records.append(.init(path: projectorName, bytes: try size(vision), sha256: projectorSHA256))
        let manifest: [String: Any] = ["schema_version": 1, "layout": "layer_major_expert",
            "experts_kind": "omni_moe_gguf", "source": ["model_files": [modelName]],
            "model": ["arch": "qwen35moe", "expert_count": 256, "expert_used_count": 8], "entries": entries]
        let manifestURL = stage.appendingPathComponent("experts/manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        records.append(.init(path: "experts/manifest.json", bytes: try size(manifestURL), sha256: try await hash(manifestURL, checkpoint: checkpoint)))
        for from in sidecars {
            let to = stage.appendingPathComponent(from.lastPathComponent)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
        let receipt = Receipt(format: format, repo: MiniCPMV47Catalog.thirtyFiveBRepoID,
                              revision: sourceRevision, sourceSHA256: sourceSHA256, files: records)
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent(receiptName), options: .atomic)
        try validate(in: stage)
        try await checkpoint()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure.invalid("Could not activate the prepared MiniCPM pack; the original download is kept.")
        }
        // The old directory is now at our private staging path. Failure to
        // remove it affects storage only; the new complete pack is active.
        try? fm.removeItem(at: stage)
        await report(.init(fraction: 1, step: "Model prepared"))
    }

    private static let families = ["ffn_gate_exps", "ffn_up_exps", "ffn_down_exps"]
    static func cleanCommittedSource(in root: URL) {
        guard isPrepared(in: root) else { return }
        let pending = pendingDirectory(for: root)
        // A pending split also uses this path. Only a committed exchange puts
        // the original full-size GGUF here, so incomplete work is never swept.
        guard (try? size(pending.appendingPathComponent(modelName))) == sourceBytes else { return }
        try? FileManager.default.removeItem(at: pending)
    }
    private static func checkedURL(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains(":"), !path.contains("\\") else { throw Failure.invalid("Unsafe MiniCPM artifact path.") }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) != .typeSymbolicLink else {
                throw Failure.invalid("MiniCPM artifacts cannot be symbolic links.")
            }
        }
        return url
    }
    private static func size(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let number = attrs[.size] as? NSNumber else { throw Failure.invalid("MiniCPM artifact is not a regular file.") }
        return number.uint64Value
    }
    private static func hash(_ url: URL, checkpoint: @escaping @Sendable () async throws -> Void) async throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while true {
            try await checkpoint()
            let hasBytes = try autoreleasepool { () throws -> Bool in
                guard let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }
            if !hasBytes { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Tensor { let name: String; let shape: [Int]; let type: UInt32; let offset: UInt64; var span: UInt64; let info: Data }
    private final class GGUF {
        let file: FileHandle
        let length: UInt64
        var tensors: [Tensor] = []
        var metadataEnd: UInt64 = 0
        var dataStart: UInt64 = 0
        var alignment: UInt64 = 32
        var architecture = ""
        var layerCount: UInt32 = 0
        var expertCount: UInt32 = 0
        var expertsUsed: UInt32 = 0
        init(_ url: URL) throws {
            file = try FileHandle(forReadingFrom: url); length = try size(url)
            guard try read(4) == Data("GGUF".utf8), try number(4) == 3 else { throw Failure.invalid("Invalid MiniCPM GGUF header.") }
            let tensorCount = try number(8), kvCount = try number(8)
            guard tensorCount < 10_000, kvCount < 10_000 else { throw Failure.invalid("Invalid MiniCPM metadata counts.") }
            for _ in 0..<kvCount {
                let key = try string(), type = UInt32(try number(4))
                if key == "general.architecture", type == 8 { architecture = try string() }
                else if type == 4, ["general.alignment", "qwen35moe.block_count", "qwen35moe.expert_count", "qwen35moe.expert_used_count"].contains(key) {
                    let value = UInt32(try number(4))
                    switch key { case "general.alignment": alignment = UInt64(value)
                    case "qwen35moe.block_count": layerCount = value
                    case "qwen35moe.expert_count": expertCount = value
                    default: expertsUsed = value }
                } else { try skip(type) }
                guard try file.offset() < 64 * 1_048_576 else { throw Failure.invalid("MiniCPM metadata is too large.") }
            }
            metadataEnd = try file.offset()
            guard alignment > 0, alignment <= 4096, alignment.nonzeroBitCount == 1 else { throw Failure.invalid("Invalid GGUF alignment.") }
            for _ in 0..<tensorCount {
                let start = try file.offset(), name = try string(), dimensions = try number(4)
                guard dimensions > 0, dimensions <= 4 else { throw Failure.invalid("Invalid MiniCPM tensor rank.") }
                var shape: [Int] = []
                for _ in 0..<dimensions { let value = try number(8); guard value <= 1_000_000 else { throw Failure.invalid("Invalid tensor dimension.") }; shape.append(Int(value)) }
                let type = UInt32(try number(4)), offset = try number(8), end = try file.offset()
                try file.seek(toOffset: start); let info = try read(Int(end - start)); try file.seek(toOffset: end)
                tensors.append(.init(name: name, shape: shape, type: type, offset: offset, span: 0, info: info))
            }
            let tableEnd = try file.offset(); dataStart = (tableEnd + alignment - 1) / alignment * alignment
            guard dataStart <= length else { throw Failure.invalid("Truncated MiniCPM tensor table.") }
            let ordered = tensors.sorted { $0.offset < $1.offset }
            guard Set(ordered.map(\.name)).count == tensors.count,
                  Set(ordered.map(\.offset)).count == tensors.count else { throw Failure.invalid("Duplicate GGUF tensors.") }
            var spans: [UInt64: UInt64] = [:]
            for (i, tensor) in ordered.enumerated() {
                let next = i + 1 < ordered.count ? ordered[i + 1].offset : length - dataStart
                guard tensor.offset < next, next <= length - dataStart else { throw Failure.invalid("Invalid tensor range.") }
                spans[tensor.offset] = next - tensor.offset
            }
            tensors = tensors.map { var tensor = $0; tensor.span = spans[tensor.offset]!; return tensor }
        }
        deinit { try? file.close() }
        private func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= 64 * 1_048_576, let data = try file.read(upToCount: count), data.count == count else { throw Failure.invalid("Truncated MiniCPM GGUF.") }
            return data
        }
        private func number(_ bytes: Int) throws -> UInt64 {
            try autoreleasepool { try read(bytes).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        }
        private func string() throws -> String {
            let bytes = try number(8); guard bytes <= 1_048_576 else { throw Failure.invalid("Invalid GGUF string length.") }
            return try autoreleasepool {
                guard let value = String(data: try read(Int(bytes)), encoding: .utf8) else { throw Failure.invalid("Invalid GGUF text encoding.") }
                return value
            }
        }
        private func skip(_ type: UInt32) throws {
            if type == 8 { let bytes = try number(8); guard bytes <= 1_048_576 else { throw Failure.invalid("Invalid metadata string.") }; try advance(bytes); return }
            if type == 9 {
                let element = UInt32(try number(4)), count = try number(8)
                guard element != 9, count <= 1_000_000 else { throw Failure.invalid("Invalid metadata array.") }
                for _ in 0..<count { try autoreleasepool { try skip(element) } }; return
            }
            let sizes: [UInt32: UInt64] = [0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8]
            guard let bytes = sizes[type] else { throw Failure.invalid("Unknown GGUF metadata type.") }; try advance(bytes)
        }
        private func advance(_ bytes: UInt64) throws {
            let offset = try file.offset(); guard offset <= length, bytes <= length - offset else { throw Failure.invalid("Invalid metadata range.") }; try file.seek(toOffset: offset + bytes)
        }
        func copy(offset: UInt64, bytes: UInt64, to output: FileHandle,
                  checkpoint: @escaping @Sendable () async throws -> Void) async throws {
            guard offset <= length, bytes <= length - offset else { throw Failure.invalid("Invalid tensor copy range.") }
            try file.seek(toOffset: offset); var remaining = bytes
            while remaining > 0 {
                try await checkpoint()
                let copied = try autoreleasepool { () throws -> Int in
                    let data = try read(Int(min(remaining, 1_048_576)))
                    try output.write(contentsOf: data)
                    return data.count
                }
                remaining -= UInt64(copied)
            }
        }
        func writeStripped(to url: URL, removing: Set<String>, checkpoint: @escaping @Sendable () async throws -> Void) async throws {
            let kept = tensors.filter { !removing.contains($0.name) }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let out = try FileHandle(forWritingTo: url); defer { try? out.close() }
            func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
            try file.seek(toOffset: 0); var header = try read(24); header.replaceSubrange(8..<16, with: u64(UInt64(kept.count))); try out.write(contentsOf: header)
            try await copy(offset: 24, bytes: metadataEnd - 24, to: out, checkpoint: checkpoint)
            var offset: UInt64 = 0
            for tensor in kept {
                var info = tensor.info; info.replaceSubrange((info.count - 8)..<info.count, with: u64(offset)); try out.write(contentsOf: info)
                offset += tensor.span
            }
            let tableEnd = try out.offset(), padding = (alignment - tableEnd % alignment) % alignment
            if padding > 0 { try out.write(contentsOf: Data(repeating: 0, count: Int(padding))) }
            for tensor in kept { try await copy(offset: dataStart + tensor.offset, bytes: tensor.span, to: out, checkpoint: checkpoint) }
            try out.synchronize()
        }
    }
}
