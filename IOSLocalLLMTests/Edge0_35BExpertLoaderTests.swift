import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0_35BExpertLoaderTests
//
// Small-geometry coverage of the 35B routed-expert read path: one resolved
// per-layer read plan (`Edge0_35BExpertReadPlan`, the Edge0-AI/Edge0#7
// "prepare typed reads once per layer" port) and per-expert axis-0 row
// reads that must be byte-identical to direct store range reads.
//
// No model weights anywhere: every byte is generated in the test. The
// geometry mirrors the Phase 5A contract (gate/up 512×2048, down 2048×512,
// 4-bit affine group 64) scaled down so a fixture is a few KB.

final class Edge0_35BExpertLoaderTests: XCTestCase {
    private var directory: URL!

    private let expertCount = 4

    /// Tiny stand-in for the production geometry: same shape relationships,
    /// byte-sized tensors.
    private let geometry = Edge0_35BExpertGeometry(
        gate: .init(name: "gate_proj", outputDim: 16, inputDim: 64),
        up: .init(name: "up_proj", outputDim: 16, inputDim: 64),
        down: .init(name: "down_proj", outputDim: 64, inputDim: 16),
        bits: 4,
        groupSize: 16
    )

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("edge0-35b-loader")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Read plan

    func testReadPlanResolvesRowGeometryOnce() throws {
        let index = try writeFixture(layer: 0)
        let plan = try Edge0_35BExpertReadPlan.build(
            layer: 0, index: index, geometry: geometry
        )

        XCTAssertEqual(plan.layer, 0)
        // gate/up weight rows: 16 × (64·4/32) U32 words = 512 bytes.
        XCTAssertEqual(plan.gate.weight.rowByteCount, UInt64(16 * 8 * 4))
        XCTAssertEqual(plan.up.weight.rowByteCount, UInt64(16 * 8 * 4))
        // gate/up scales/biases: 16 × (64/16) BF16 = 128 bytes.
        XCTAssertEqual(plan.gate.scales.rowByteCount, UInt64(16 * 4 * 2))
        XCTAssertEqual(plan.gate.biases.rowByteCount, UInt64(16 * 4 * 2))
        // down weight rows: 64 × (16·4/32) U32 = 512 bytes; scales 64 × 1 BF16.
        XCTAssertEqual(plan.down.weight.rowByteCount, UInt64(64 * 2 * 4))
        XCTAssertEqual(plan.down.scales.rowByteCount, UInt64(64 * 1 * 2))

        XCTAssertEqual(plan.gate.weightShape, [16, 8])
        XCTAssertEqual(plan.gate.scalesShape, [16, 4])
        XCTAssertEqual(plan.down.weightShape, [64, 2])
        XCTAssertEqual(plan.down.scalesShape, [64, 1])

        // Row addressing is pure geometry: offset = row bytes × expert.
        XCTAssertEqual(
            plan.gate.weight.rowOffset(3),
            3 * plan.gate.weight.rowByteCount
        )
        XCTAssertEqual(
            plan.down.scales.location.name,
            Edge0_35BExpertSpec.name(
                layer: 0, projection: "down_proj", part: "scales"
            )
        )
    }

    func testReadPlanFailsFastWhenTensorIsMissing() throws {
        let missing = Edge0_35BExpertSpec.name(
            layer: 1, projection: "down_proj", part: "biases"
        )
        let index = try writeFixture(layer: 1, omit: [missing])
        XCTAssertThrowsError(
            try Edge0_35BExpertReadPlan.build(
                layer: 1, index: index, geometry: geometry
            )
        ) { error in
            guard case Edge0SafetensorsError.missingTensor(let name)? =
                error as? Edge0SafetensorsError else {
                return XCTFail("Expected missingTensor, got \(error)")
            }
            XCTAssertEqual(name, missing)
        }
    }

    func testProductionInitFailsFastOnIncompleteCheckpoint() async throws {
        // Engine-style construction resolves the plan at init; an incomplete
        // checkpoint must be refused at model load, not mid-generation.
        let missing = Edge0_35BExpertSpec.name(
            layer: 3, projection: "gate_proj", part: "weight"
        )
        let index = try writeFixture(layer: 3, omit: [missing])
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"]
        )
        XCTAssertThrowsError(
            try Edge0_35BExpertLoader(index: index, stores: stores, layer: 3)
        ) { error in
            guard case Edge0SafetensorsError.missingTensor(let name)? =
                error as? Edge0SafetensorsError else {
                return XCTFail("Expected missingTensor, got \(error)")
            }
            XCTAssertEqual(name, missing)
        }
        await stores.closeAll()
    }

    // MARK: - Expert loads

    func testLoaderReadsExactPerExpertSlices() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let index = try writeFixture(layer: 0)
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"]
        )
        let plan = try Edge0_35BExpertReadPlan.build(
            layer: 0, index: index, geometry: geometry
        )
        let loader = Edge0_35BExpertLoader(stores: stores, readPlan: plan)

        let loaded = try await loader.load(Edge0ExpertKey(layer: 0, expert: 2))
        try await assertMatrixRows(loaded.gate, plan.gate, expert: 2, stores: stores)
        try await assertMatrixRows(loaded.up, plan.up, expert: 2, stores: stores)
        try await assertMatrixRows(loaded.down, plan.down, expert: 2, stores: stores)
        await stores.closeAll()
    }

    func testPlanReuseIsDeterministicAndExpertAddressed() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let index = try writeFixture(layer: 0)
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"]
        )
        let plan = try Edge0_35BExpertReadPlan.build(
            layer: 0, index: index, geometry: geometry
        )
        let loader = Edge0_35BExpertLoader(stores: stores, readPlan: plan)

        let first = try await loader.load(Edge0ExpertKey(layer: 0, expert: 0))
        let last = try await loader.load(Edge0ExpertKey(layer: 0, expert: 3))
        let repeatFirst = try await loader.load(Edge0ExpertKey(layer: 0, expert: 0))

        try await assertMatrixRows(first.up, plan.up, expert: 0, stores: stores)
        try await assertMatrixRows(last.up, plan.up, expert: 3, stores: stores)

        // Different experts read different slices; the same expert reads the
        // same bytes across loads through one plan.
        XCTAssertNotEqual(
            first.up.weight.asData().data,
            last.up.weight.asData().data
        )
        XCTAssertEqual(
            first.up.weight.asData().data,
            repeatFirst.up.weight.asData().data
        )
        await stores.closeAll()
    }

    func testReadaheadHintsDoNotChangeBytes() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let index = try writeFixture(layer: 0)
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"]
        )
        let plan = try Edge0_35BExpertReadPlan.build(
            layer: 0, index: index, geometry: geometry
        )
        let hinted = Edge0_35BExpertLoader(
            stores: stores, readPlan: plan, readaheadHints: true
        )
        let loaded = try await hinted.load(Edge0ExpertKey(layer: 0, expert: 1))
        try await assertMatrixRows(loaded.gate, plan.gate, expert: 1, stores: stores)
        await stores.closeAll()
    }

    // MARK: - Fixtures

    private func writeFixture(
        layer: Int,
        omit: Set<String> = []
    ) throws -> Edge0SafetensorsIndex {
        var tensors: [(name: String, dtype: String, shape: [Int], payload: Data)] = []

        func append(
            _ projection: Edge0_35BExpertGeometry.Projection,
            weightShape: [Int],
            scalesShape: [Int],
            salt: Int
        ) {
            let weightName = Edge0_35BExpertSpec.name(
                layer: layer, projection: projection.name, part: "weight"
            )
            let scalesName = Edge0_35BExpertSpec.name(
                layer: layer, projection: projection.name, part: "scales"
            )
            let biasesName = Edge0_35BExpertSpec.name(
                layer: layer, projection: projection.name, part: "biases"
            )
            if !omit.contains(weightName) {
                tensors.append((
                    weightName, "U32", weightShape,
                    saltedPayload(shape: weightShape, dtype: .u32, salt: salt)
                ))
            }
            if !omit.contains(scalesName) {
                tensors.append((
                    scalesName, "BF16", scalesShape,
                    saltedPayload(shape: scalesShape, dtype: .bf16, salt: salt + 1)
                ))
            }
            if !omit.contains(biasesName) {
                tensors.append((
                    biasesName, "BF16", scalesShape,
                    saltedPayload(shape: scalesShape, dtype: .bf16, salt: salt + 2)
                ))
            }
        }

        append(
            geometry.gate,
            weightShape: [expertCount, 16, 8],
            scalesShape: [expertCount, 16, 4],
            salt: 0
        )
        append(
            geometry.up,
            weightShape: [expertCount, 16, 8],
            scalesShape: [expertCount, 16, 4],
            salt: 40
        )
        append(
            geometry.down,
            weightShape: [expertCount, 64, 2],
            scalesShape: [expertCount, 64, 1],
            salt: 80
        )

        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: tensors)
        return try Edge0SafetensorsIndex.openSingleFile(at: url)
    }

    private func saltedPayload(
        shape: [Int],
        dtype: Edge0SafetensorsDType,
        salt: Int
    ) -> Data {
        let count = shape.reduce(1, *) * dtype.byteWidth
        return Data((0..<count).map { UInt8(($0 + salt) % 251) })
    }

    private func assertMatrixRows(
        _ loaded: Edge0ExpertQuantizedMatrix,
        _ plan: Edge0_35BExpertReadPlan.Projection,
        expert: Int,
        stores: Edge0TensorStoreSet,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let weightSlice = try await stores.readSlice(
            plan.weight.location,
            byteOffset: plan.weight.rowOffset(expert),
            byteLength: Int(plan.weight.rowByteCount)
        )
        let scalesSlice = try await stores.readSlice(
            plan.scales.location,
            byteOffset: plan.scales.rowOffset(expert),
            byteLength: Int(plan.scales.rowByteCount)
        )
        let biasesSlice = try await stores.readSlice(
            plan.biases.location,
            byteOffset: plan.biases.rowOffset(expert),
            byteLength: Int(plan.biases.rowByteCount)
        )

        XCTAssertEqual(loaded.weight.shape, plan.weightShape, file: file, line: line)
        XCTAssertEqual(loaded.scales.shape, plan.scalesShape, file: file, line: line)
        XCTAssertEqual(loaded.biases.shape, plan.scalesShape, file: file, line: line)
        XCTAssertEqual(loaded.weight.dtype, .uint32, file: file, line: line)
        XCTAssertEqual(loaded.scales.dtype, .bfloat16, file: file, line: line)
        XCTAssertEqual(loaded.biases.dtype, .bfloat16, file: file, line: line)
        XCTAssertEqual(
            loaded.weight.asData().data, weightSlice.bytes,
            file: file, line: line
        )
        XCTAssertEqual(
            loaded.scales.asData().data, scalesSlice.bytes,
            file: file, line: line
        )
        XCTAssertEqual(
            loaded.biases.asData().data, biasesSlice.bytes,
            file: file, line: line
        )
    }
}
