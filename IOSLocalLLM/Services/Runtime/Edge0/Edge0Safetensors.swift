import Foundation

// MARK: - Edge0SafetensorsError
//
// Typed failures for safetensors metadata parsing and range validation. The
// parser treats checkpoint files as untrusted input: every offset and length
// is validated with overflow-safe arithmetic before it can reach the store.

enum Edge0SafetensorsError: Error, Equatable, Sendable {
    case unreadableFile(String)
    case fileTooSmall(path: String, actual: UInt64, minimum: UInt64)
    case headerLengthOutOfRange(declared: UInt64, fileSize: UInt64)
    case headerTooLarge(declared: UInt64, maximum: UInt64)
    case malformedHeader(String)
    case unsupportedDType(String)
    case invalidShape(tensor: String)
    case invalidDataOffsets(tensor: String)
    case integerOverflow(tensor: String)
    case tensorRangeOutOfBounds(tensor: String)
    case duplicateTensor(String)
    case missingTensor(String)
    case unknownShard(String)
}

extension Edge0SafetensorsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "Could not read safetensors file at \(path)."
        case .fileTooSmall(let path, let actual, let minimum):
            return "Safetensors file \(path) is \(actual) bytes; at least \(minimum) are required."
        case .headerLengthOutOfRange(let declared, let fileSize):
            return "Safetensors header length \(declared) is invalid for a \(fileSize)-byte file."
        case .headerTooLarge(let declared, let maximum):
            return "Safetensors header length \(declared) exceeds the \(maximum)-byte safety limit."
        case .malformedHeader(let detail):
            return "Safetensors header is malformed: \(detail)"
        case .unsupportedDType(let dtype):
            return "Unsupported safetensors dtype '\(dtype)'."
        case .invalidShape(let tensor):
            return "Tensor '\(tensor)' has an invalid shape."
        case .invalidDataOffsets(let tensor):
            return "Tensor '\(tensor)' has invalid data_offsets."
        case .integerOverflow(let tensor):
            return "Tensor '\(tensor)' offsets overflow 64-bit arithmetic."
        case .tensorRangeOutOfBounds(let tensor):
            return "Tensor '\(tensor)' payload extends past the end of its shard."
        case .duplicateTensor(let name):
            return "Tensor '\(name)' is declared more than once."
        case .missingTensor(let name):
            return "Tensor '\(name)' is missing from the checkpoint index."
        case .unknownShard(let shard):
            return "Shard '\(shard)' is not part of this checkpoint."
        }
    }
}

// MARK: - Edge0SafetensorsDType

enum Edge0SafetensorsDType: String, Sendable, CaseIterable {
    case u8 = "U8"
    case i8 = "I8"
    case u16 = "U16"
    case i16 = "I16"
    case u32 = "U32"
    case i32 = "I32"
    case f16 = "F16"
    case bf16 = "BF16"
    case f32 = "F32"
    case f64 = "F64"

    var byteWidth: Int {
        switch self {
        case .u8, .i8: return 1
        case .u16, .i16, .f16, .bf16: return 2
        case .u32, .i32, .f32: return 4
        case .f64: return 8
        }
    }
}

// MARK: - Edge0TensorLocation

/// Where one tensor's bytes live. Only metadata; no payload is read to
/// produce a location.
struct Edge0TensorLocation: Sendable, Hashable {
    let name: String
    /// Shard file name, e.g. `model.safetensors`.
    let shard: String
    /// Absolute byte offset of the tensor payload in the shard.
    let payloadOffset: UInt64
    let byteCount: UInt64
    let dtype: Edge0SafetensorsDType
    let shape: [Int]

    /// Byte offset of one `axis 0` row (one expert) inside this tensor.
    /// Nil when the tensor has no first dimension.
    var rowByteCount: UInt64? {
        guard let rows = shape.first, rows > 0 else { return nil }
        return byteCount / UInt64(rows)
    }

    /// Slice of this tensor for one index along axis 0, with the row shape.
    func row(_ index: Int) throws -> Edge0TensorLocation {
        guard let rows = shape.first, index >= 0, index < rows,
              let perRow = rowByteCount else {
            throw Edge0SafetensorsError.invalidShape(tensor: name)
        }
        let (rowOffset, rowOverflow) = UInt64(index).multipliedReportingOverflow(by: perRow)
        let (offset, offsetOverflow) = payloadOffset.addingReportingOverflow(rowOffset)
        guard !rowOverflow, !offsetOverflow else {
            throw Edge0SafetensorsError.integerOverflow(tensor: name)
        }
        return Edge0TensorLocation(
            name: name,
            shard: shard,
            payloadOffset: offset,
            byteCount: perRow,
            dtype: dtype,
            shape: Array(shape.dropFirst())
        )
    }
}

// MARK: - Header parsing

/// Parses the safetensors header for one shard. Header shape:
/// `[8-byte little-endian JSON length][JSON][payload...]`.
enum Edge0SafetensorsHeaderParser {
    /// Hard ceiling on the JSON header so a corrupt length prefix cannot make
    /// the indexer allocate an unbounded buffer. Real Edge0-8B headers are
    /// ~141 KB.
    static let maximumHeaderBytes: UInt64 = 64 * 1024 * 1024

    static func parse(
        header: Data,
        payloadBase: UInt64,
        fileSize: UInt64,
        shard: String
    ) throws -> [String: Edge0TensorLocation] {
        // JSON itself permits duplicate object keys; a safetensors header
        // must not. Detect them before decoding (JSONDecoder keeps only the
        // last duplicate silently).
        var seenKeys = Set<String>()
        for key in topLevelKeys(in: header) {
            if !seenKeys.insert(key).inserted {
                throw Edge0SafetensorsError.duplicateTensor(key)
            }
        }

        let raw: RawHeader
        do {
            raw = try JSONDecoder().decode(RawHeader.self, from: header)
        } catch {
            throw Edge0SafetensorsError.malformedHeader(
                String(describing: error)
            )
        }

        var locations: [String: Edge0TensorLocation] = [:]
        locations.reserveCapacity(raw.tensors.count)

        for (name, tensor) in raw.tensors {
            if locations[name] != nil {
                throw Edge0SafetensorsError.duplicateTensor(name)
            }
            locations[name] = try Self.location(
                name: name,
                tensor: tensor,
                payloadBase: payloadBase,
                fileSize: fileSize,
                shard: shard
            )
        }
        return locations
    }

    private static func location(
        name: String,
        tensor: RawTensor,
        payloadBase: UInt64,
        fileSize: UInt64,
        shard: String
    ) throws -> Edge0TensorLocation {
        guard let dtype = Edge0SafetensorsDType(rawValue: tensor.dtype.uppercased()) else {
            throw Edge0SafetensorsError.unsupportedDType(tensor.dtype)
        }

        guard !tensor.shape.isEmpty else {
            throw Edge0SafetensorsError.invalidShape(tensor: name)
        }
        var shape: [Int] = []
        shape.reserveCapacity(tensor.shape.count)
        var elementCount: UInt64 = 1
        for dimension in tensor.shape {
            guard dimension > 0, dimension <= Int64(Int.max) else {
                throw Edge0SafetensorsError.invalidShape(tensor: name)
            }
            let (product, overflow) = elementCount.multipliedReportingOverflow(
                by: UInt64(dimension)
            )
            guard !overflow else {
                throw Edge0SafetensorsError.integerOverflow(tensor: name)
            }
            elementCount = product
            shape.append(Int(dimension))
        }

        guard tensor.dataOffsets.count == 2,
              tensor.dataOffsets[0] <= tensor.dataOffsets[1] else {
            throw Edge0SafetensorsError.invalidDataOffsets(tensor: name)
        }
        let begin = tensor.dataOffsets[0]
        let end = tensor.dataOffsets[1]
        let byteCount = end - begin

        let (start, startOverflow) = payloadBase.addingReportingOverflow(begin)
        guard !startOverflow else {
            throw Edge0SafetensorsError.integerOverflow(tensor: name)
        }
        let (endAbsolute, endOverflow) = start.addingReportingOverflow(byteCount)
        guard !endOverflow else {
            throw Edge0SafetensorsError.integerOverflow(tensor: name)
        }
        guard endAbsolute <= fileSize else {
            throw Edge0SafetensorsError.tensorRangeOutOfBounds(tensor: name)
        }

        // The shape, dtype width, and byte range must agree. A mismatch means
        // the header is corrupt or deliberately inconsistent.
        let (declaredBytes, widthOverflow) = elementCount.multipliedReportingOverflow(
            by: UInt64(dtype.byteWidth)
        )
        guard !widthOverflow, declaredBytes == byteCount else {
            throw Edge0SafetensorsError.invalidShape(tensor: name)
        }

        return Edge0TensorLocation(
            name: name,
            shard: shard,
            payloadOffset: start,
            byteCount: byteCount,
            dtype: dtype,
            shape: shape
        )
    }

    /// Returns the object keys at depth 1 in document order. Used only for
    /// duplicate detection; a malformed document yields whatever keys were
    /// scanned, and the JSON decode that follows reports the real error.
    static func topLevelKeys(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var keys: [String] = []
        var current: [UInt8] = []
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    current.append(byte)
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    if depth == 1 {
                        var look = index + 1
                        while look < bytes.count,
                              bytes[look] == 0x20 || bytes[look] == 0x09
                                || bytes[look] == 0x0A || bytes[look] == 0x0D {
                            look += 1
                        }
                        if look < bytes.count, bytes[look] == 0x3A {
                            keys.append(String(decoding: current, as: UTF8.self))
                        }
                    }
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(byte)
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                    current.removeAll(keepingCapacity: true)
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                default:
                    break
                }
            }
            index += 1
        }
        return keys
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct RawHeader: Decodable {
        var tensors: [String: RawTensor] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            for key in container.allKeys {
                if key.stringValue == "__metadata__" { continue }
                tensors[key.stringValue] = try container.decode(
                    RawTensor.self,
                    forKey: key
                )
            }
        }
    }

    private struct RawTensor: Decodable {
        let dtype: String
        let shape: [Int64]
        let dataOffsets: [UInt64]

        enum CodingKeys: String, CodingKey {
            case dtype
            case shape
            case dataOffsets = "data_offsets"
        }
    }
}

// MARK: - Edge0SafetensorsIndex

/// Metadata index over one or more safetensors shards. Indexing never reads a
/// tensor payload.
struct Edge0SafetensorsIndex: Sendable {
    let locations: [String: Edge0TensorLocation]
    let shardNames: [String]
    let fileSizes: [String: UInt64]

    init(
        locations: [String: Edge0TensorLocation],
        shardNames: [String],
        fileSizes: [String: UInt64]
    ) {
        self.locations = locations
        self.shardNames = shardNames
        self.fileSizes = fileSizes
    }

    var tensorCount: Int { locations.count }

    func contains(_ name: String) -> Bool {
        locations[name] != nil
    }

    func location(_ name: String) throws -> Edge0TensorLocation {
        guard let location = locations[name] else {
            throw Edge0SafetensorsError.missingTensor(name)
        }
        return location
    }

    /// Single-file checkpoint (`model.safetensors`), the layout Edge0-8B
    /// ships today.
    static func openSingleFile(at url: URL) throws -> Edge0SafetensorsIndex {
        let index = try parseShard(at: url)
        return Edge0SafetensorsIndex(
            locations: index,
            shardNames: [url.lastPathComponent],
            fileSizes: [url.lastPathComponent: try Edge0FileIO.fileSize(at: url)]
        )
    }

    /// Sharded checkpoint driven by `model.safetensors.index.json`. Kept
    /// general enough that a future Edge0 release can shard without changing
    /// the store or expert layout.
    static func openSharded(
        in directory: URL,
        indexFileName: String = "model.safetensors.index.json"
    ) throws -> Edge0SafetensorsIndex {
        let indexURL = directory.appendingPathComponent(indexFileName)
        let indexData: Data
        do {
            indexData = try Data(contentsOf: indexURL)
        } catch {
            throw Edge0SafetensorsError.missingTensor(indexFileName)
        }
        guard let json = try? JSONSerialization.jsonObject(with: indexData),
              let root = json as? [String: Any],
              let weightMap = root["weight_map"] as? [String: String] else {
            throw Edge0SafetensorsError.malformedHeader(indexFileName)
        }

        var shardNames = Set<String>()
        var tensorShard: [String: String] = [:]
        for (tensor, shard) in weightMap {
            if let existing = tensorShard[tensor], existing != shard {
                throw Edge0SafetensorsError.duplicateTensor(tensor)
            }
            tensorShard[tensor] = shard
            shardNames.insert(shard)
        }

        var locations: [String: Edge0TensorLocation] = [:]
        var fileSizes: [String: UInt64] = [:]
        for shard in shardNames.sorted() {
            let url = directory.appendingPathComponent(shard)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Edge0SafetensorsError.unknownShard(shard)
            }
            let parsed = try parseShard(at: url)
            fileSizes[shard] = try Edge0FileIO.fileSize(at: url)
            for (name, location) in parsed {
                guard tensorShard[name] == shard else { continue }
                if locations[name] != nil {
                    throw Edge0SafetensorsError.duplicateTensor(name)
                }
                locations[name] = location
            }
        }

        // Every tensor referenced by the weight map must resolve.
        for tensor in tensorShard.keys where locations[tensor] == nil {
            throw Edge0SafetensorsError.missingTensor(tensor)
        }

        return Edge0SafetensorsIndex(
            locations: locations,
            shardNames: shardNames.sorted(),
            fileSizes: fileSizes
        )
    }

    private static func parseShard(at url: URL) throws -> [String: Edge0TensorLocation] {
        let fileSize = try Edge0FileIO.fileSize(at: url)
        guard fileSize >= 8 else {
            throw Edge0SafetensorsError.fileTooSmall(
                path: url.path,
                actual: fileSize,
                minimum: 8
            )
        }
        let lengthData = try Edge0FileIO.readExactly(at: url, offset: 0, count: 8)
        guard let headerLength = lengthData.withUnsafeBytes({ raw -> UInt64? in
            guard raw.count == 8 else { return nil }
            var value: UInt64 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: raw)
            }
            return UInt64(littleEndian: value)
        }) else {
            throw Edge0SafetensorsError.malformedHeader("length prefix")
        }

        guard headerLength > 0, headerLength <= fileSize - 8 else {
            throw Edge0SafetensorsError.headerLengthOutOfRange(
                declared: headerLength,
                fileSize: fileSize
            )
        }
        guard headerLength <= Edge0SafetensorsHeaderParser.maximumHeaderBytes else {
            throw Edge0SafetensorsError.headerTooLarge(
                declared: headerLength,
                maximum: Edge0SafetensorsHeaderParser.maximumHeaderBytes
            )
        }

        let header = try Edge0FileIO.readExactly(
            at: url,
            offset: 8,
            count: Int(headerLength)
        )
        let (payloadBase, overflow) = UInt64(8).addingReportingOverflow(headerLength)
        guard !overflow else {
            throw Edge0SafetensorsError.integerOverflow(tensor: "__header__")
        }

        return try Edge0SafetensorsHeaderParser.parse(
            header: header,
            payloadBase: payloadBase,
            fileSize: fileSize,
            shard: url.lastPathComponent
        )
    }
}

// MARK: - Edge0FileIO

/// Small pread-based file helper shared by the indexer and the tensor store.
/// Reads are explicit ranges; opening a 4+ GB checkpoint never materializes
/// the file.
enum Edge0FileIO {
    static func fileSize(at url: URL) throws -> UInt64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw Edge0SafetensorsError.unreadableFile(url.path)
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw Edge0SafetensorsError.unreadableFile(url.path)
        }
        return size.uint64Value
    }

    static func readExactly(at url: URL, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else {
            throw Edge0SafetensorsError.malformedHeader("negative read length")
        }
        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }
        return try file.read(offset: offset, count: count)
    }
}
