import Foundation

// MARK: - Edge0ExpertKey

/// Identifies one routed expert inside one MoE layer.
struct Edge0ExpertKey: Hashable, Sendable, Comparable {
    let layer: Int
    let expert: Int

    static func < (lhs: Edge0ExpertKey, rhs: Edge0ExpertKey) -> Bool {
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        return lhs.expert < rhs.expert
    }
}

// MARK: - Projections and parts

/// Edge0-8B stores gate/up/down as separate stacked tensors
/// (`WeightLayout.SEPARATE` upstream). Bundle order for the math is
/// up, gate, down — matching `_swiglu(up, gate) = silu(gate) * up`.
enum Edge0ExpertProjection: String, CaseIterable, Sendable {
    case gate = "gate_proj"
    case up = "up_proj"
    case down = "down_proj"

    static let bundleOrder: [Edge0ExpertProjection] = [.up, .gate, .down]
}

enum Edge0ExpertTensorPart: String, CaseIterable, Sendable {
    case weight
    case scales
    case biases
}

// MARK: - Quantization spec

struct Edge0QuantSpec: Sendable, Equatable {
    let bits: Int
    let groupSize: Int
    let mode: String

    /// 4-bit affine, group 64 — the shipped Edge0-8B quantization.
    static let edge0_8B = Edge0QuantSpec(bits: 4, groupSize: 64, mode: "affine")
}

// MARK: - Edge0ExpertSpec

/// Shape contract for one Edge0 expert tier. Production uses `.edge0_8B`;
/// tests build tiny synthetic specs so the full index → store → bundle →
/// cache → gathered-QMM pipeline runs on small fixtures.
struct Edge0ExpertSpec: Sendable, Equatable {
    let numExperts: Int
    let firstExpertLayer: Int
    let lastExpertLayer: Int
    let hiddenSize: Int
    let expertIntermediateSize: Int
    let quant: Edge0QuantSpec

    /// Edge0-8B (`Edge0/Edge0-8B-A1B-preview`): 24 layers with layer 0 dense,
    /// 128 routed experts, hidden 1536, expert intermediate 512, 4-bit
    /// affine group 64.
    static let edge0_8B = Edge0ExpertSpec(
        numExperts: 128,
        firstExpertLayer: 1,
        lastExpertLayer: 23,
        hiddenSize: 1536,
        expertIntermediateSize: 512,
        quant: .edge0_8B
    )

    var layerCount: Int { lastExpertLayer - firstExpertLayer + 1 }

    var packedWordsPerHidden: Int {
        hiddenSize * quant.bits / 32
    }

    var packedWordsPerIntermediate: Int {
        expertIntermediateSize * quant.bits / 32
    }

    func expectedShape(
        projection: Edge0ExpertProjection,
        part: Edge0ExpertTensorPart
    ) -> [Int] {
        let outFeatures: Int
        let inFeatures: Int
        switch projection {
        case .gate, .up:
            outFeatures = expertIntermediateSize
            inFeatures = hiddenSize
        case .down:
            outFeatures = hiddenSize
            inFeatures = expertIntermediateSize
        }
        switch part {
        case .weight:
            return [numExperts, outFeatures, inFeatures * quant.bits / 32]
        case .scales, .biases:
            return [numExperts, outFeatures, inFeatures / quant.groupSize]
        }
    }

    func expectedDType(
        part: Edge0ExpertTensorPart
    ) -> Edge0SafetensorsDType {
        switch part {
        case .weight: return .u32
        case .scales, .biases: return .bf16
        }
    }
}

// MARK: - Edge0ExpertLayoutError

enum Edge0ExpertLayoutError: Error, Equatable, Sendable {
    case malformedName(String)
    case unsupportedProjection(String)
    case unsupportedPart(String)
    case layerOutOfRange(Int)
    case expertOutOfRange(layer: Int, expert: Int)
    case missingTensor(String)
    case shapeMismatch(tensor: String, expected: [Int], actual: [Int])
    case dtypeMismatch(tensor: String, expected: String, actual: String)
    case quantizationMismatch(String)
    case projectionNameMismatch(tensor: String, expected: String)
    case invalidSpec(String)
}

extension Edge0ExpertLayoutError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .malformedName(let name):
            return "Malformed Edge0 expert tensor name '\(name)'."
        case .unsupportedProjection(let projection):
            return "Unsupported Edge0 expert projection '\(projection)'."
        case .unsupportedPart(let part):
            return "Unsupported Edge0 expert tensor part '\(part)'."
        case .layerOutOfRange(let layer):
            return "Edge0 expert tensor layer \(layer) is outside the expert layer range."
        case .expertOutOfRange(let layer, let expert):
            return "Edge0 expert \(expert) is out of range for layer \(layer)."
        case .missingTensor(let name):
            return "Edge0 expert tensor '\(name)' is missing."
        case .shapeMismatch(let tensor, let expected, let actual):
            return "Tensor '\(tensor)' shape \(actual) does not match expected \(expected)."
        case .dtypeMismatch(let tensor, let expected, let actual):
            return "Tensor '\(tensor)' dtype \(actual) does not match expected \(expected)."
        case .quantizationMismatch(let detail):
            return "Edge0 quantization layout mismatch: \(detail)"
        case .projectionNameMismatch(let tensor, let expected):
            return "Tensor '\(tensor)' does not name the expected projection '\(expected)'."
        case .invalidSpec(let detail):
            return "Invalid Edge0 expert spec: \(detail)"
        }
    }
}

// MARK: - Tensor naming

/// Exact Edge0-8B naming:
/// `model.layers.{layer}.mlp.experts.{proj}.{part}` for routed experts and
/// `model.layers.{layer}.mlp.shared_experts.{proj}.{part}` for the resident
/// shared expert.
enum Edge0ExpertTensorNaming {
    enum Scope: Equatable, Sendable {
        case routed
        case shared
    }

    struct Parsed: Equatable, Sendable {
        let layer: Int
        let scope: Scope
        let projection: Edge0ExpertProjection
        let part: Edge0ExpertTensorPart
    }

    static func tensorName(
        layer: Int,
        projection: Edge0ExpertProjection,
        part: Edge0ExpertTensorPart
    ) -> String {
        "model.layers.\(layer).mlp.experts.\(projection.rawValue).\(part.rawValue)"
    }

    static func parse(_ name: String) -> Parsed? {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 7,
              components[0] == "model",
              components[1] == "layers",
              let layer = Int(components[2]),
              components[3] == "mlp",
              components[5].isEmpty == false,
              let projection = Edge0ExpertProjection(rawValue: String(components[5])),
              let part = Edge0ExpertTensorPart(rawValue: String(components[6]))
        else {
            return nil
        }
        let scope: Scope
        switch components[4] {
        case "experts": scope = .routed
        case "shared_experts": scope = .shared
        default: return nil
        }
        return Parsed(
            layer: layer,
            scope: scope,
            projection: projection,
            part: part
        )
    }
}

// MARK: - Locations

struct Edge0ExpertProjectionLocation: Sendable, Equatable {
    let weight: Edge0TensorLocation
    let scales: Edge0TensorLocation
    let biases: Edge0TensorLocation

    func location(for part: Edge0ExpertTensorPart) -> Edge0TensorLocation {
        switch part {
        case .weight: return weight
        case .scales: return scales
        case .biases: return biases
        }
    }
}

/// All nine tensors (three projections × weight/scales/biases) that make up
/// one routed expert.
struct Edge0ExpertBundleLocation: Sendable, Equatable {
    let key: Edge0ExpertKey
    let up: Edge0ExpertProjectionLocation
    let gate: Edge0ExpertProjectionLocation
    let down: Edge0ExpertProjectionLocation

    func location(for projection: Edge0ExpertProjection) -> Edge0ExpertProjectionLocation {
        switch projection {
        case .up: return up
        case .gate: return gate
        case .down: return down
        }
    }

    var allProjections: [(Edge0ExpertProjection, Edge0ExpertProjectionLocation)] {
        [(.up, up), (.gate, gate), (.down, down)]
    }

    /// Verifies each location's tensor name actually encodes the projection
    /// and part it is filed under. Catches a swapped gate/up bundle.
    func validateNameConformance() throws {
        try Edge0ExpertNameConformance.validate(
            layer: key.layer, projections: allProjections
        )
    }
}

// MARK: - Edge0ExpertLayerLocations

/// All nine resolved tensor locations for one expert layer. Locations do
/// not depend on the expert index, so one resolution per layer serves every
/// expert load in that layer — the native form of upstream
/// `perf: prepare typed mmap expert reads once per layer` (Edge0-AI/Edge0#7).
struct Edge0ExpertLayerLocations: Sendable, Equatable {
    let layer: Int
    let up: Edge0ExpertProjectionLocation
    let gate: Edge0ExpertProjectionLocation
    let down: Edge0ExpertProjectionLocation

    func location(for projection: Edge0ExpertProjection) -> Edge0ExpertProjectionLocation {
        switch projection {
        case .up: return up
        case .gate: return gate
        case .down: return down
        }
    }

    var allProjections: [(Edge0ExpertProjection, Edge0ExpertProjectionLocation)] {
        [(.up, up), (.gate, gate), (.down, down)]
    }

    /// Byte size of one expert bundle: all nine axis-0 row slices.
    var perExpertBytes: UInt64 {
        var total: UInt64 = 0
        for (_, projection) in allProjections {
            for part in Edge0ExpertTensorPart.allCases {
                total += projection.location(for: part).rowByteCount ?? 0
            }
        }
        return total
    }

    /// Pure assembly for one expert within this layer; callers have already
    /// resolved and validated the locations.
    func bundle(for key: Edge0ExpertKey) -> Edge0ExpertBundleLocation {
        Edge0ExpertBundleLocation(key: key, up: up, gate: gate, down: down)
    }

    /// Verifies each location's tensor name actually encodes the projection
    /// and part it is filed under. Catches a swapped gate/up bundle.
    func validateNameConformance() throws {
        try Edge0ExpertNameConformance.validate(
            layer: layer, projections: allProjections
        )
    }
}

/// Shared name-conformance check for layer-level and bundle-level callers.
private enum Edge0ExpertNameConformance {
    static func validate(
        layer: Int,
        projections: [(Edge0ExpertProjection, Edge0ExpertProjectionLocation)]
    ) throws {
        let expectedScope = Edge0ExpertTensorNaming.Scope.routed
        for (projection, location) in projections {
            for part in Edge0ExpertTensorPart.allCases {
                let tensor = location.location(for: part)
                guard let parsed = Edge0ExpertTensorNaming.parse(tensor.name) else {
                    throw Edge0ExpertLayoutError.malformedName(tensor.name)
                }
                guard parsed.scope == expectedScope,
                      parsed.layer == layer,
                      parsed.projection == projection,
                      parsed.part == part else {
                    throw Edge0ExpertLayoutError.projectionNameMismatch(
                        tensor: tensor.name,
                        expected: "\(projection.rawValue).\(part.rawValue)"
                    )
                }
            }
        }
    }
}

// MARK: - Edge0ExpertLayout

/// Resolves and validates the exact Edge0-8B routed-expert tensor layout
/// against an index. Never guesses: missing partners, shape mismatches, and
/// incompatible quantization metadata are typed errors.
struct Edge0ExpertLayout: Sendable {
    let spec: Edge0ExpertSpec

    init(spec: Edge0ExpertSpec = .edge0_8B) {
        self.spec = spec
    }

    /// Resolves and validates the nine routed-expert tensors of one layer.
    /// The locations are per-layer facts, so one resolution serves every
    /// expert load in that layer (upstream Edge0-AI/Edge0#7 pattern).
    func layerLocations(
        for layer: Int,
        in index: Edge0SafetensorsIndex
    ) throws -> Edge0ExpertLayerLocations {
        guard layer >= spec.firstExpertLayer,
              layer <= spec.lastExpertLayer else {
            throw Edge0ExpertLayoutError.layerOutOfRange(layer)
        }

        var resolved: [Edge0ExpertProjection: Edge0ExpertProjectionLocation] = [:]
        for projection in Edge0ExpertProjection.allCases {
            var parts: [Edge0ExpertTensorPart: Edge0TensorLocation] = [:]
            for part in Edge0ExpertTensorPart.allCases {
                let name = Edge0ExpertTensorNaming.tensorName(
                    layer: layer,
                    projection: projection,
                    part: part
                )
                guard let location = index.locations[name] else {
                    throw Edge0ExpertLayoutError.missingTensor(name)
                }
                try validate(
                    location,
                    projection: projection,
                    part: part,
                    expectedName: name
                )
                parts[part] = location
            }
            guard let weight = parts[.weight],
                  let scales = parts[.scales],
                  let biases = parts[.biases] else {
                throw Edge0ExpertLayoutError.missingTensor(
                    "\(layer).\(projection.rawValue)"
                )
            }
            resolved[projection] = Edge0ExpertProjectionLocation(
                weight: weight,
                scales: scales,
                biases: biases
            )
        }

        guard let up = resolved[.up],
              let gate = resolved[.gate],
              let down = resolved[.down] else {
            throw Edge0ExpertLayoutError.missingTensor(
                "layer \(layer)"
            )
        }

        let locations = Edge0ExpertLayerLocations(
            layer: layer, up: up, gate: gate, down: down
        )
        try locations.validateNameConformance()
        return locations
    }

    func bundleLocation(
        for key: Edge0ExpertKey,
        in index: Edge0SafetensorsIndex
    ) throws -> Edge0ExpertBundleLocation {
        guard key.layer >= spec.firstExpertLayer,
              key.layer <= spec.lastExpertLayer else {
            throw Edge0ExpertLayoutError.layerOutOfRange(key.layer)
        }
        guard key.expert >= 0, key.expert < spec.numExperts else {
            throw Edge0ExpertLayoutError.expertOutOfRange(
                layer: key.layer,
                expert: key.expert
            )
        }
        return try layerLocations(for: key.layer, in: index)
            .bundle(for: key)
    }

    func validate(
        _ location: Edge0TensorLocation,
        projection: Edge0ExpertProjection,
        part: Edge0ExpertTensorPart,
        expectedName: String? = nil
    ) throws {
        if let expectedName, location.name != expectedName {
            throw Edge0ExpertLayoutError.projectionNameMismatch(
                tensor: location.name,
                expected: expectedName
            )
        }
        let expectedShape = spec.expectedShape(projection: projection, part: part)
        guard location.shape == expectedShape else {
            throw Edge0ExpertLayoutError.shapeMismatch(
                tensor: location.name,
                expected: expectedShape,
                actual: location.shape
            )
        }
        let expectedDType = spec.expectedDType(part: part)
        guard location.dtype == expectedDType else {
            throw Edge0ExpertLayoutError.dtypeMismatch(
                tensor: location.name,
                expected: expectedDType.rawValue,
                actual: location.dtype.rawValue
            )
        }
    }

    /// Checks a bundle's weight/scales group geometry end to end. Separate
    /// from `validate` so callers can run the full check once per bundle.
    func validateQuantizationGeometry(
        _ bundle: Edge0ExpertBundleLocation
    ) throws {
        try validateQuantizationGeometry(
            projections: bundle.allProjections
        )
    }

    /// Layer-level form: one check per layer instead of one per expert.
    func validateQuantizationGeometry(
        _ locations: Edge0ExpertLayerLocations
    ) throws {
        try validateQuantizationGeometry(
            projections: locations.allProjections
        )
    }

    private func validateQuantizationGeometry(
        projections: [(Edge0ExpertProjection, Edge0ExpertProjectionLocation)]
    ) throws {
        for (projection, location) in projections {
            let weight = location.weight
            let scales = location.scales
            let biases = location.biases

            guard weight.shape.count == 3,
                  scales.shape.count == 3,
                  biases.shape.count == 3 else {
                throw Edge0ExpertLayoutError.quantizationMismatch(
                    "\(projection.rawValue) tensors must be rank 3"
                )
            }
            guard weight.shape[0] == spec.numExperts,
                  weight.shape[1] == scales.shape[1],
                  weight.shape[1] == biases.shape[1],
                  scales.shape[0] == spec.numExperts,
                  biases.shape[0] == spec.numExperts,
                  scales.shape[2] == biases.shape[2] else {
                throw Edge0ExpertLayoutError.quantizationMismatch(
                    "\(projection.rawValue) expert/feature dimensions disagree"
                )
            }
            let inputFeatures = scales.shape[2] * spec.quant.groupSize
            let expectedWords = inputFeatures * spec.quant.bits / 32
            guard weight.shape[2] == expectedWords else {
                throw Edge0ExpertLayoutError.quantizationMismatch(
                    "\(projection.rawValue) packed width \(weight.shape[2]) != \(expectedWords) words for group \(spec.quant.groupSize)"
                )
            }
        }
    }
}
