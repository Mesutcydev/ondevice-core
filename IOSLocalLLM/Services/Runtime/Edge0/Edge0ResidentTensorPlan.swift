import Foundation
import MLX

// MARK: - Edge0ResidentTensorPlan
//
// Splits a checkpoint index into resident/common tensors and routed-expert
// tensors. The resident path must never materialize routed expert payloads:
// those are streamed through `Edge0ExpertPool` on demand.
//
// Measured against `Edge0/Edge0-8B-A1B-preview` @ 0700e65:
//   resident/common   601,561,920 bytes
//   routed experts  3,906,994,176 bytes
// Routed experts are *not* part of the resident plan.

struct Edge0ResidentTensorPlan: Sendable {
    struct Entry: Sendable, Equatable {
        let name: String
        let location: Edge0TensorLocation
    }

    let resident: [Entry]
    let routedExpert: [Entry]

    var residentTensorCount: Int { resident.count }
    var routedExpertTensorCount: Int { routedExpert.count }

    var residentBytes: UInt64 {
        resident.reduce(0) { $0 + $1.location.byteCount }
    }

    var routedExpertBytes: UInt64 {
        routedExpert.reduce(0) { $0 + $1.location.byteCount }
    }

    var totalBytes: UInt64 { residentBytes + routedExpertBytes }

    /// A routed expert tensor is anything under `*.mlp.experts.*`. The
    /// resident shared expert lives under `*.mlp.shared_experts.*` and stays
    /// resident; the dense layer-0 MLP (`*.mlp.gate_proj.*` etc.) also stays.
    static func isRoutedExpertTensor(_ name: String) -> Bool {
        name.contains(".mlp.experts.")
    }

    static func classify(_ index: Edge0SafetensorsIndex) -> Edge0ResidentTensorPlan {
        var resident: [Entry] = []
        var routed: [Entry] = []
        resident.reserveCapacity(index.locations.count)
        for (name, location) in index.locations {
            let entry = Entry(name: name, location: location)
            if isRoutedExpertTensor(name) {
                routed.append(entry)
            } else {
                resident.append(entry)
            }
        }
        resident.sort { $0.name < $1.name }
        routed.sort { $0.name < $1.name }
        return Edge0ResidentTensorPlan(
            resident: resident,
            routedExpert: routed
        )
    }
}

// MARK: - Edge0ResidentTensorLoaderError

enum Edge0ResidentTensorLoaderError: Error, Equatable, Sendable {
    case unsupportedDType(String)
    case byteCountMismatch(name: String, expected: Int, actual: Int)
}

extension Edge0ResidentTensorLoaderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedDType(let dtype):
            return "Resident tensor dtype '\(dtype)' is not supported."
        case .byteCountMismatch(let name, let expected, let actual):
            return "Resident tensor '\(name)' expected \(expected) bytes, read \(actual)."
        }
    }
}

// MARK: - Edge0ResidentTensorLoader
//
// Reads resident/common tensor payloads through the range-based store and
// builds MLX arrays. Quantized resident tensors (U32 weights plus BF16
// scales/biases) are returned in their stored form; dequantization is the
// model layer's business.

struct Edge0ResidentTensorLoader: Sendable {
    let index: Edge0SafetensorsIndex
    let stores: Edge0TensorStoreSet

    func load(_ entry: Edge0ResidentTensorPlan.Entry) async throws -> MLXArray {
        try await load(entry.location)
    }

    func load(_ location: Edge0TensorLocation) async throws -> MLXArray {
        let bytes = try await stores.read(location)
        guard let dtype = Self.mlxDType(for: location.dtype) else {
            throw Edge0ResidentTensorLoaderError.unsupportedDType(
                location.dtype.rawValue
            )
        }
        let expected = location.shape.reduce(1, *) * location.dtype.byteWidth
        guard bytes.byteCount == expected else {
            throw Edge0ResidentTensorLoaderError.byteCountMismatch(
                name: location.name,
                expected: expected,
                actual: bytes.byteCount
            )
        }
        return MLXArray(bytes.bytes, location.shape, dtype: dtype)
    }

    static func mlxDType(for dtype: Edge0SafetensorsDType) -> DType? {
        switch dtype {
        case .u8: return .uint8
        case .i8: return .int8
        case .u16: return .uint16
        case .i16: return .int16
        case .u32: return .uint32
        case .i32: return .int32
        case .f16: return .float16
        case .bf16: return .bfloat16
        case .f32: return .float32
        case .f64: return .float64
        }
    }
}
