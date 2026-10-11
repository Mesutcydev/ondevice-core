import Foundation

/// Storage-only conversion of the pinned 35B checkpoint. Each expert's
/// gate/up/down weight, scale and bias bytes form one page-aligned block.
/// Resident tensors remain ordinary safetensors; routing and math are unchanged.
struct Edge0_35BRepackedExperts: Codable, Sendable {
    struct Part: Codable, Sendable, Equatable {
        let name: String
        let dtype: String
        let shape: [Int]
        let offset: Int
        let bytes: Int
    }

    static let manifestName = "experts.json"
    static let residentName = "resident.safetensors"
    static let formatName = "ondevice-edge0-35b-repack-v1"
    static let blockBytes = 1_769_472
    static let layerBytes = UInt64(blockBytes) * 256

    let format: String
    let sourceRepo: String
    let sourceRevision: String
    let layers: Int
    let expertsPerLayer: Int
    let blockBytes: Int
    let parts: [Part]
    let fileSHA256: [String: String]

    enum CodingKeys: String, CodingKey {
        case format, layers, parts
        case sourceRepo = "source_repo"
        case sourceRevision = "source_revision"
        case expertsPerLayer = "experts_per_layer"
        case blockBytes = "block_bytes"
        case fileSHA256 = "file_sha256"
    }

    static func layerName(_ layer: Int) -> String {
        String(format: "experts-L%02d.bin", layer)
    }

    static var expectedParts: [Part] {
        var offset = 0
        return ["gate_proj", "up_proj", "down_proj"].flatMap { projection in
            ["weight", "scales", "biases"].map { part in
                let down = projection == "down_proj"
                let weight = part == "weight"
                let shape = weight
                    ? (down ? [2048, 64] : [512, 256])
                    : (down ? [2048, 8] : [512, 32])
                let bytes = weight ? 524_288 : 32_768
                defer { offset += bytes }
                return Part(
                    name: "\(projection).\(part)", dtype: weight ? "U32" : "BF16",
                    shape: shape, offset: offset, bytes: bytes
                )
            }
        }
    }

    var expertFileNames: [String] {
        (0..<layers).map(Self.layerName)
    }

    /// A present but invalid manifest is an error, never a silent fallback.
    /// Only metadata is read here; no multi-GB payload is materialized.
    static func openIfPresent(in directory: URL) throws -> Self? {
        let url = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= 65_536 else {
            throw Failure.invalidManifest("invalid manifest size or file type")
        }
        let manifest: Self
        do { manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw Failure.invalidManifest("could not decode manifest") }
        try manifest.validate(in: directory)
        return manifest
    }

    func validate(in directory: URL) throws {
        guard format == Self.formatName,
              sourceRepo == Edge0ModelFamily.qwen35MoERepoID,
              Edge0ModelFamily.qwen35MoERepackRevisions.contains(sourceRevision),
              layers == 40, expertsPerLayer == 256,
              blockBytes == Self.blockBytes, parts == Self.expectedParts else {
            throw Failure.invalidManifest("unsupported release or expert layout")
        }
        let names = Set(expertFileNames + [Self.residentName])
        guard Set(fileSHA256.keys) == names,
              fileSHA256.values.allSatisfy({ digest in
                  digest.count == 64 && digest.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  }
              }) else {
            throw Failure.invalidManifest("incomplete checksum inventory")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == root,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw Failure.invalidFile(name)
            }
            let size = try Edge0FileIO.fileSize(at: url)
            if name == Self.residentName {
                guard size > 8 else { throw Failure.invalidFile(name) }
            } else if size != Self.layerBytes {
                throw Failure.invalidFile(name)
            }
        }
    }

    /// Opaque block location passed through the existing bounded I/O queue.
    func location(layer: Int, expert: Int) throws -> Edge0TensorLocation {
        guard (0..<layers).contains(layer), (0..<expertsPerLayer).contains(expert) else {
            throw Failure.invalidExpert(layer: layer, expert: expert)
        }
        return Edge0TensorLocation(
            name: "expert.\(layer).\(expert)", shard: Self.layerName(layer),
            payloadOffset: UInt64(expert) * UInt64(blockBytes),
            byteCount: UInt64(blockBytes), dtype: .u8, shape: [blockBytes]
        )
    }

    enum Failure: Error, LocalizedError {
        case invalidManifest(String)
        case invalidFile(String)
        case invalidExpert(layer: Int, expert: Int)

        var errorDescription: String? {
            switch self {
            case .invalidManifest(let detail):
                return "Edge0-35B repacked manifest is invalid: \(detail)."
            case .invalidFile(let name):
                return "Edge0-35B repacked file '\(name)' is missing, truncated or outside the model directory. Re-import a verified pack."
            case .invalidExpert(let layer, let expert):
                return "Edge0-35B expert \(expert) in layer \(layer) is out of range."
            }
        }
    }
}
