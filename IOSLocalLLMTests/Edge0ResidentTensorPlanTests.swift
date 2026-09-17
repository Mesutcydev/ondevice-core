import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0ResidentTensorPlanTests

final class Edge0ResidentTensorPlanTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("resident")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPlanExcludesRoutedExpertsAndKeepsSharedDenseAndAttention() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let names: [(String, [Int], Edge0SafetensorsDType)] = [
            ("model.word_embeddings.weight", [4, 8], .bf16),
            ("model.layers.0.mlp.gate_proj.weight", [8, 8], .bf16),
            ("model.layers.0.mlp.up_proj.weight", [8, 8], .bf16),
            ("model.layers.1.mlp.experts.gate_proj.weight", [8, 8], .u32),
            ("model.layers.1.mlp.experts.gate_proj.scales", [8, 2], .bf16),
            ("model.layers.1.mlp.shared_experts.gate_proj.weight", [8, 8], .bf16),
            ("model.layers.3.attention.q_a_proj.weight", [4, 8], .bf16),
            ("lm_head.weight", [4, 8], .bf16),
        ]
        try Edge0TestFixtures.writeSafetensors(
            at: url,
            tensors: names.map { name, shape, dtype in
                (
                    name,
                    dtype.rawValue,
                    shape,
                    Edge0TestFixtures.payload(shape: shape, dtype: dtype)
                )
            }
        )
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let plan = Edge0ResidentTensorPlan.classify(index)

        XCTAssertEqual(plan.routedExpertTensorCount, 2)
        XCTAssertEqual(plan.residentTensorCount, 6)
        XCTAssertFalse(
            plan.resident.contains { $0.name.contains(".mlp.experts.") },
            "resident plan must never include routed expert tensors"
        )
        XCTAssertTrue(
            plan.resident.contains {
                $0.name == "model.layers.1.mlp.shared_experts.gate_proj.weight"
            },
            "the shared expert is resident, not a routed expert"
        )
        XCTAssertTrue(
            plan.resident.contains {
                $0.name == "model.layers.0.mlp.gate_proj.weight"
            },
            "the dense layer-0 MLP is resident"
        )
        XCTAssertEqual(
            plan.routedExpert.map(\.name),
            [
                "model.layers.1.mlp.experts.gate_proj.scales",
                "model.layers.1.mlp.experts.gate_proj.weight",
            ]
        )
    }

    func testIsRoutedExpertTensorClassification() {
        XCTAssertTrue(
            Edge0ResidentTensorPlan.isRoutedExpertTensor(
                "model.layers.7.mlp.experts.up_proj.weight"
            )
        )
        XCTAssertFalse(
            Edge0ResidentTensorPlan.isRoutedExpertTensor(
                "model.layers.7.mlp.shared_experts.up_proj.weight"
            )
        )
        XCTAssertFalse(
            Edge0ResidentTensorPlan.isRoutedExpertTensor(
                "model.layers.0.mlp.up_proj.weight"
            )
        )
    }

    func testRealCheckpointResidentBudgetWhenModelAvailable() throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let url = URL(fileURLWithPath: modelDirectory)
            .appendingPathComponent("model.safetensors")
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let plan = Edge0ResidentTensorPlan.classify(index)

        XCTAssertEqual(plan.routedExpertBytes, 3_906_994_176)
        XCTAssertEqual(plan.residentBytes, 601_561_920)
        XCTAssertFalse(
            plan.resident.contains { $0.name.contains(".mlp.experts.") }
        )
        XCTAssertEqual(plan.routedExpertTensorCount, 23 * 3 * 3)
    }

    func testResidentLoaderReadsExactBytes() async throws {
        try Edge0TestDevice.requireSimulatorMLXSupport()
        let url = directory.appendingPathComponent("model.safetensors")
        let bf16Shape = [2, 3]
        let u32Shape = [4]
        let bf16Payload = Edge0TestFixtures.payload(shape: bf16Shape, dtype: .bf16)
        let u32Payload = Edge0TestFixtures.payload(shape: u32Shape, dtype: .u32)
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "BF16", bf16Shape, bf16Payload),
            ("b.weight", "U32", u32Shape, u32Payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)

        let a = try await loader.load(index.location("a.weight"))
        XCTAssertEqual(a.dtype, .bfloat16)
        XCTAssertEqual(a.shape, bf16Shape)
        XCTAssertEqual(a.asData().data, bf16Payload)

        let b = try await loader.load(index.location("b.weight"))
        XCTAssertEqual(b.dtype, .uint32)
        XCTAssertEqual(b.shape, u32Shape)
        XCTAssertEqual(b.asData().data, u32Payload)
        await stores.closeAll()
    }
}
