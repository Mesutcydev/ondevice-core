import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0ExpertLayoutTests

final class Edge0ExpertLayoutTests: XCTestCase {
    private var directory: URL!
    private let spec = Edge0TestFixtures.tinySpec

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("layout")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Valid mapping

    func testBundleResolvesExactTensorNamesShapesAndDtypes() throws {
        let index = try makeIndex()
        let layout = Edge0ExpertLayout(spec: spec)
        let bundle = try layout.bundleLocation(
            for: Edge0ExpertKey(layer: 1, expert: 2),
            in: index
        )
        try bundle.validateNameConformance()
        try layout.validateQuantizationGeometry(bundle)

        XCTAssertEqual(
            bundle.up.weight.name,
            "model.layers.1.mlp.experts.up_proj.weight"
        )
        XCTAssertEqual(
            bundle.gate.weight.name,
            "model.layers.1.mlp.experts.gate_proj.weight"
        )
        XCTAssertEqual(
            bundle.down.weight.name,
            "model.layers.1.mlp.experts.down_proj.weight"
        )
        XCTAssertEqual(
            bundle.up.scales.name,
            "model.layers.1.mlp.experts.up_proj.scales"
        )
        XCTAssertEqual(
            bundle.down.biases.name,
            "model.layers.1.mlp.experts.down_proj.biases"
        )

        XCTAssertEqual(
            bundle.up.weight.shape,
            [spec.numExperts, spec.expertIntermediateSize, spec.hiddenSize * spec.quant.bits / 32]
        )
        XCTAssertEqual(
            bundle.up.scales.shape,
            [spec.numExperts, spec.expertIntermediateSize, spec.hiddenSize / spec.quant.groupSize]
        )
        XCTAssertEqual(
            bundle.down.weight.shape,
            [spec.numExperts, spec.hiddenSize, spec.expertIntermediateSize * spec.quant.bits / 32]
        )
        XCTAssertEqual(bundle.down.scales.dtype, .bf16)
        XCTAssertEqual(bundle.down.weight.dtype, .u32)

        // Bundle order is the math order: up, gate, down.
        XCTAssertEqual(
            Edge0ExpertProjection.bundleOrder,
            [.up, .gate, .down]
        )
    }

    func testEveryExpertInEveryTinyLayerResolves() throws {
        let index = try makeIndex()
        let layout = Edge0ExpertLayout(spec: spec)
        var resolved = 0
        for layer in spec.firstExpertLayer...spec.lastExpertLayer {
            for expert in 0..<spec.numExperts {
                _ = try layout.bundleLocation(
                    for: Edge0ExpertKey(layer: layer, expert: expert),
                    in: index
                )
                resolved += 1
            }
        }
        XCTAssertEqual(resolved, spec.layerCount * spec.numExperts)
    }

    // MARK: - Failure cases

    func testGateUpSwapIsRejected() throws {
        let index = try makeIndex()
        let layout = Edge0ExpertLayout(spec: spec)
        let bundle = try layout.bundleLocation(
            for: Edge0ExpertKey(layer: 1, expert: 0),
            in: index
        )
        let swapped = Edge0ExpertBundleLocation(
            key: bundle.key,
            up: bundle.gate,
            gate: bundle.up,
            down: bundle.down
        )
        XCTAssertThrowsError(try swapped.validateNameConformance()) { error in
            guard case .projectionNameMismatch? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected projectionNameMismatch, got \(error)")
            }
        }
    }

    func testMalformedExpertTensorNameIsRejected() {
        XCTAssertNil(Edge0ExpertTensorNaming.parse("not.a.tensor"))
        XCTAssertNil(Edge0ExpertTensorNaming.parse("model.layers.1.mlp.experts"))
        XCTAssertNil(Edge0ExpertTensorNaming.parse("model.layers.x.mlp.experts.up_proj.weight"))
        XCTAssertNil(Edge0ExpertTensorNaming.parse("model.layers.1.mlp.experts.bogus_proj.weight"))
        XCTAssertNil(Edge0ExpertTensorNaming.parse("model.layers.1.mlp.experts.up_proj.bogus"))

        // A routed bundle whose location carries a malformed name.
        let bad = location(name: "not.a.tensor", shape: [2, 2], dtype: .u32)
        let goodProjection = Edge0ExpertProjectionLocation(
            weight: location(name: "model.layers.1.mlp.experts.up_proj.weight", shape: [4, 64, 16]),
            scales: location(name: "model.layers.1.mlp.experts.up_proj.scales", shape: [4, 64, 2], dtype: .bf16),
            biases: location(name: "model.layers.1.mlp.experts.up_proj.biases", shape: [4, 64, 2], dtype: .bf16)
        )
        let badProjection = Edge0ExpertProjectionLocation(
            weight: bad,
            scales: goodProjection.scales,
            biases: goodProjection.biases
        )
        let bundle = Edge0ExpertBundleLocation(
            key: Edge0ExpertKey(layer: 1, expert: 0),
            up: badProjection,
            gate: goodProjection,
            down: goodProjection
        )
        XCTAssertThrowsError(try bundle.validateNameConformance()) { error in
            guard case .malformedName? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected malformedName, got \(error)")
            }
        }
    }

    func testExpertAndLayerRangeValidation() throws {
        let index = try makeIndex()
        let layout = Edge0ExpertLayout(spec: spec)

        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 0, expert: 0),
                in: index
            )
        ) { error in
            guard case .layerOutOfRange(let layer)? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected layerOutOfRange, got \(error)")
            }
            XCTAssertEqual(layer, 0)
        }

        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 99, expert: 0),
                in: index
            )
        ) { error in
            guard case .layerOutOfRange(let layer)? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected layerOutOfRange, got \(error)")
            }
            XCTAssertEqual(layer, 99)
        }

        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 1, expert: spec.numExperts),
                in: index
            )
        ) { error in
            guard case .expertOutOfRange(let layer, let expert)? =
                error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected expertOutOfRange, got \(error)")
            }
            XCTAssertEqual(layer, 1)
            XCTAssertEqual(expert, spec.numExperts)
        }
    }

    func testLayerLocationsMatchBundleResolution() throws {
        let index = try makeIndex()
        let layout = Edge0ExpertLayout(spec: spec)
        let locations = try layout.layerLocations(for: 1, in: index)
        XCTAssertEqual(locations.layer, 1)
        try locations.validateNameConformance()
        try layout.validateQuantizationGeometry(locations)

        // Per-layer resolution must agree with the per-bundle path for every
        // expert in the layer — the loader's fail-fast plan depends on it.
        for expert in [0, 1, spec.numExperts - 1] {
            let bundle = try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 1, expert: expert),
                in: index
            )
            XCTAssertEqual(bundle.up, locations.up)
            XCTAssertEqual(bundle.gate, locations.gate)
            XCTAssertEqual(bundle.down, locations.down)
        }
    }

    func testUnsupportedProjectionDoesNotParse() {
        XCTAssertNil(
            Edge0ExpertTensorNaming.parse(
                "model.layers.1.mlp.experts.q_proj.weight"
            )
        )
    }

    func testMissingPartnerTensorThrows() throws {
        let missingName = Edge0ExpertTensorNaming.tensorName(
            layer: 2,
            projection: .down,
            part: .weight
        )
        let index = try makeIndex(omit: [missingName])
        let layout = Edge0ExpertLayout(spec: spec)
        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 2, expert: 1),
                in: index
            )
        ) { error in
            guard case .missingTensor(let name)? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected missingTensor, got \(error)")
            }
            XCTAssertEqual(name, missingName)
        }
    }

    func testShapeMismatchThrows() throws {
        let name = Edge0ExpertTensorNaming.tensorName(
            layer: 1,
            projection: .gate,
            part: .weight
        )
        let index = try makeIndex(shapeOverrides: [name: [4, 64, 20]])
        let layout = Edge0ExpertLayout(spec: spec)
        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 1, expert: 0),
                in: index
            )
        ) { error in
            guard case .shapeMismatch(let tensor, _, _)? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected shapeMismatch, got \(error)")
            }
            XCTAssertEqual(tensor, name)
        }
    }

    func testDTypeMismatchIsRejected() throws {
        let name = Edge0ExpertTensorNaming.tensorName(
            layer: 1,
            projection: .up,
            part: .scales
        )
        let index = try makeIndex(dtypeOverrides: [name: "F16"])
        let layout = Edge0ExpertLayout(spec: spec)
        XCTAssertThrowsError(
            try layout.bundleLocation(
                for: Edge0ExpertKey(layer: 1, expert: 0),
                in: index
            )
        ) { error in
            guard case .dtypeMismatch(let tensor, let expected, let actual)? =
                error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected dtypeMismatch, got \(error)")
            }
            XCTAssertEqual(tensor, name)
            XCTAssertEqual(expected, "BF16")
            XCTAssertEqual(actual, "F16")
        }
    }

    func testQuantizationGeometryMismatchIsRejected() throws {
        let layout = Edge0ExpertLayout(spec: spec)
        let wrongScales = location(
            name: "model.layers.1.mlp.experts.down_proj.scales",
            shape: [4, 128, 4],
            dtype: .bf16
        )
        let projection = Edge0ExpertProjectionLocation(
            weight: location(
                name: "model.layers.1.mlp.experts.down_proj.weight",
                shape: [4, 128, 8]
            ),
            scales: wrongScales,
            biases: location(
                name: "model.layers.1.mlp.experts.down_proj.biases",
                shape: [4, 128, 4],
                dtype: .bf16
            )
        )
        let validUp = Edge0ExpertProjectionLocation(
            weight: location(
                name: "model.layers.1.mlp.experts.up_proj.weight",
                shape: [4, 64, 16]
            ),
            scales: location(
                name: "model.layers.1.mlp.experts.up_proj.scales",
                shape: [4, 64, 2],
                dtype: .bf16
            ),
            biases: location(
                name: "model.layers.1.mlp.experts.up_proj.biases",
                shape: [4, 64, 2],
                dtype: .bf16
            )
        )
        let bundle = Edge0ExpertBundleLocation(
            key: Edge0ExpertKey(layer: 1, expert: 0),
            up: validUp,
            gate: validUp,
            down: projection
        )
        XCTAssertThrowsError(try layout.validateQuantizationGeometry(bundle)) { error in
            guard case .quantizationMismatch? = error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected quantizationMismatch, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeIndex(
        omit: Set<String> = [],
        shapeOverrides: [String: [Int]] = [:],
        dtypeOverrides: [String: String] = [:]
    ) throws -> Edge0SafetensorsIndex {
        let url = directory.appendingPathComponent("model.safetensors")
        let tensors = Edge0TestFixtures.tinyExpertTensors(
            spec: spec,
            layers: [spec.firstExpertLayer, spec.lastExpertLayer],
            omit: omit,
            shapeOverrides: shapeOverrides,
            dtypeOverrides: dtypeOverrides
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: tensors)
        return try Edge0SafetensorsIndex.openSingleFile(at: url)
    }

    private func location(
        name: String,
        shape: [Int],
        dtype: Edge0SafetensorsDType = .u32
    ) -> Edge0TensorLocation {
        Edge0TensorLocation(
            name: name,
            shard: "model.safetensors",
            payloadOffset: 0,
            byteCount: UInt64(shape.reduce(1, *) * dtype.byteWidth),
            dtype: dtype,
            shape: shape
        )
    }
}
