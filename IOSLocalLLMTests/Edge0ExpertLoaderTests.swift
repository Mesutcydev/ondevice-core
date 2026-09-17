import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0ExpertLoaderTests
//
// End-to-end (small) coverage of the storage pipeline: synthetic
// safetensors fixture → index → pread store → per-expert MLX arrays →
// bounded pool → gathered quantized math. Uses the tiny 4-bit group-64 spec
// so every byte is generated in the test.

final class Edge0ExpertLoaderTests: XCTestCase {
    private let spec = Edge0TestFixtures.tinySpec
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("loader")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoaderReadsExactPerExpertSlices() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let source = makeSource()
        let index = try writeFixture(source)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )
        let loader = try Edge0ExpertLoader(
            index: index,
            stores: stores,
            layout: Edge0ExpertLayout(spec: spec)
        )

        let key = Edge0ExpertKey(layer: 1, expert: 2)
        let loaded = try await loader.load(key)

        assertMatrix(loaded.up, source[.up]!, expert: key.expert)
        assertMatrix(loaded.gate, source[.gate]!, expert: key.expert)
        assertMatrix(loaded.down, source[.down]!, expert: key.expert)
        XCTAssertEqual(loaded.byteSize, expectedPerExpertBytes)
        await stores.closeAll()
    }

    func testLoadsForDifferentExpertsDoNotAlias() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let source = makeSource()
        let index = try writeFixture(source)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )
        let loader = try Edge0ExpertLoader(
            index: index,
            stores: stores,
            layout: Edge0ExpertLayout(spec: spec)
        )

        let first = try await loader.load(Edge0ExpertKey(layer: 1, expert: 0))
        let second = try await loader.load(Edge0ExpertKey(layer: 1, expert: 3))
        XCTAssertNotEqual(first.up.weight.asData().data, second.up.weight.asData().data)
        assertMatrix(first.up, source[.up]!, expert: 0)
        assertMatrix(second.up, source[.up]!, expert: 3)
        await stores.closeAll()
    }

    func testLoaderFailsFastWhenLayerTensorIsMissing() async throws {
        let omitName = Edge0ExpertTensorNaming.tensorName(
            layer: 2,
            projection: .gate,
            part: .biases
        )
        let url = directory.appendingPathComponent("model.safetensors")
        let tensors = Edge0TestFixtures.tinyExpertTensors(
            spec: spec,
            layers: [spec.firstExpertLayer, spec.lastExpertLayer],
            omit: [omitName]
        )
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: tensors)
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )

        // Layer resolution happens at construction (Edge0-AI/Edge0#7 port):
        // an incomplete checkpoint is refused at model load, not during
        // generation.
        XCTAssertThrowsError(
            try Edge0ExpertLoader(
                index: index,
                stores: stores,
                layout: Edge0ExpertLayout(spec: spec)
            )
        ) { error in
            guard case Edge0ExpertLayoutError.missingTensor(let name)? =
                error as? Edge0ExpertLayoutError else {
                return XCTFail("Expected missingTensor, got \(error)")
            }
            XCTAssertEqual(name, omitName)
        }
        await stores.closeAll()
    }

    func testPooledLoaderCyclesTinySlotCountDeterministically() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let source = makeSource()
        let index = try writeFixture(source)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"],
            maxConcurrentReads: 2
        )
        let loader = try Edge0ExpertLoader(
            index: index,
            stores: stores,
            layout: Edge0ExpertLayout(spec: spec)
        )
        let pool = Edge0ExpertPool<Edge0ExpertWeights>(
            configuration: .init(
                capacitySlots: 2,
                capacityBytes: 64 * 1_048_576
            ),
            loader: { key in try await loader.load(key) },
            sizeOf: { $0.byteSize }
        )

        var inputValues = [Float](repeating: 0, count: spec.hiddenSize)
        for index in 0..<spec.hiddenSize {
            inputValues[index] = Float((index * 13) % 127) / 127.0 - 0.5
        }
        let x = MLXArray(inputValues, [1, 1, spec.hiddenSize])

        let zero = Edge0ExpertKey(layer: 1, expert: 0)
        let one = Edge0ExpertKey(layer: 1, expert: 1)
        let two = Edge0ExpertKey(layer: 2, expert: 0)
        let three = Edge0ExpertKey(layer: 2, expert: 1)
        // Revisits `zero` between loads so a 2-slot pool records hits as
        // well as evictions under recycling.
        let keys = [zero, zero, one, zero, two, zero, three]
        var outputsByKey: [String: Data] = [:]

        for _ in 0..<20 {
            for key in keys {
                let lease = try await pool.acquire(key)
                let indices = MLXArray([Int32(key.expert)], [1, 1, 1])
                let output = Edge0ExpertMath.expertForward(
                    x,
                    up: lease.payload.up,
                    gate: lease.payload.gate,
                    down: lease.payload.down,
                    indices: indices
                )
                MLX.eval(output)
                let data = output.asData().data
                let label = "\(key.layer)-\(key.expert)"
                if let previous = outputsByKey[label] {
                    XCTAssertEqual(
                        data,
                        previous,
                        "expert \(label) must produce identical output across slot recycling"
                    )
                } else {
                    outputsByKey[label] = data
                }
                await pool.release(lease)
            }
        }

        let stats = await pool.statistics()
        XCTAssertLessThanOrEqual(stats.occupancySlots, 2)
        XCTAssertGreaterThan(stats.hits, 0)
        XCTAssertGreaterThan(stats.evictions, 0)
        await stores.closeAll()
    }

    // MARK: - Fixtures

    private struct SourceMatrix {
        let weight: MLXArray
        let scales: MLXArray
        let biases: MLXArray
    }

    private func makeSource() -> [Edge0ExpertProjection: SourceMatrix] {
        func build(out: Int, inFeatures: Int, salt: Float) -> SourceMatrix {
            let count = spec.numExperts * out * inFeatures
            var values = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let base = Float((index * 37) % 251) / 251.0 - 0.5
                values[index] = base * (0.75 + salt)
            }
            let weights = MLXArray(values, [spec.numExperts, out, inFeatures])
            let (quantized, scales, biases) = MLX.quantized(
                weights,
                groupSize: spec.quant.groupSize,
                bits: spec.quant.bits,
                mode: .affine
            )
            return SourceMatrix(
                weight: quantized,
                scales: (scales).asType(.bfloat16),
                biases: (biases ?? scales).asType(.bfloat16)
            )
        }

        return [
            .up: build(
                out: spec.expertIntermediateSize,
                inFeatures: spec.hiddenSize,
                salt: 0.10
            ),
            .gate: build(
                out: spec.expertIntermediateSize,
                inFeatures: spec.hiddenSize,
                salt: 0.40
            ),
            .down: build(
                out: spec.hiddenSize,
                inFeatures: spec.expertIntermediateSize,
                salt: 0.70
            ),
        ]
    }

    private func writeFixture(
        _ source: [Edge0ExpertProjection: SourceMatrix]
    ) throws -> Edge0SafetensorsIndex {
        var tensors: [(name: String, dtype: String, shape: [Int], payload: Data)] = []
        for layer in spec.firstExpertLayer...spec.lastExpertLayer {
            for projection in Edge0ExpertProjection.allCases {
                guard let matrix = source[projection] else { continue }
                for part in Edge0ExpertTensorPart.allCases {
                    let name = Edge0ExpertTensorNaming.tensorName(
                        layer: layer,
                        projection: projection,
                        part: part
                    )
                    let shape = spec.expectedShape(
                        projection: projection,
                        part: part
                    )
                    let dtype = spec.expectedDType(part: part).rawValue
                    let array: MLXArray
                    switch part {
                    case .weight: array = matrix.weight
                    case .scales: array = matrix.scales
                    case .biases: array = matrix.biases
                    }
                    tensors.append((name, dtype, shape, array.asData().data))
                }
            }
        }
        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: tensors)
        return try Edge0SafetensorsIndex.openSingleFile(at: url)
    }

    private var expectedPerExpertBytes: UInt64 {
        var total: UInt64 = 0
        for projection in Edge0ExpertProjection.allCases {
            for part in Edge0ExpertTensorPart.allCases {
                let shape = spec.expectedShape(projection: projection, part: part)
                let rowElements = shape.dropFirst().reduce(1, *)
                total += UInt64(rowElements * spec.expectedDType(part: part).byteWidth)
            }
        }
        return total
    }

    private func assertMatrix(
        _ loaded: Edge0ExpertQuantizedMatrix,
        _ source: SourceMatrix,
        expert: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(loaded.weight.shape, source.weight[expert].shape, file: file, line: line)
        XCTAssertEqual(loaded.scales.shape, source.scales[expert].shape, file: file, line: line)
        XCTAssertEqual(loaded.biases.shape, source.biases[expert].shape, file: file, line: line)
        XCTAssertEqual(loaded.weight.dtype, .uint32, file: file, line: line)
        XCTAssertEqual(loaded.scales.dtype, .bfloat16, file: file, line: line)
        XCTAssertEqual(loaded.weight.asData().data, source.weight[expert].asData().data, file: file, line: line)
        XCTAssertEqual(loaded.scales.asData().data, source.scales[expert].asData().data, file: file, line: line)
        XCTAssertEqual(loaded.biases.asData().data, source.biases[expert].asData().data, file: file, line: line)
    }
}
