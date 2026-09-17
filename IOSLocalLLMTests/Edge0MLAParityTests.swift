import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0MLAParityTests
//
// Compares the Swift MLA port against fixtures produced by upstream
// `BailingMLA` (scripts/edge0_reference_dump.py). Skips when fixtures absent.

final class Edge0MLAParityTests: XCTestCase {

    private struct Tiny {
        static let hiddenSize = 64
        static let heads = 2
        static let nope = 8
        static let rope = 8
        static let vHead = 8
        static let qLora = 8
        static let kvLora = 16
        static let eps: Float = 1e-6
        static let ropeTheta: Float = 6_000_000
    }

    func testMLAMatchesUpstream() async throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("mla_tiny.safetensors")
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["mla_tiny.safetensors"]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)

        func tensor(_ name: String) async throws -> MLXArray {
            try await loader.load(index.location(name))
        }

        let weights = Edge0MLAAttentionWeights(
            qAProj: .dense(try await tensor("q_a_proj.weight")),
            qALayernorm: try await tensor("q_a_layernorm.weight"),
            qBProj: .dense(try await tensor("q_b_proj.weight")),
            directQProj: nil,
            kvAProjWithMQA: .dense(try await tensor("kv_a_proj_with_mqa.weight")),
            kvALayernorm: try await tensor("kv_a_layernorm.weight"),
            kvBProj: .dense(try await tensor("kv_b_proj.weight")),
            dense: .dense(try await tensor("dense.weight")),
            gProj: .dense(try await tensor("g_proj.weight"))
        )
        let attention = Edge0MLAAttention(
            numHeads: Tiny.heads,
            qkNopeHeadDim: Tiny.nope,
            qkRopeHeadDim: Tiny.rope,
            vHeadDim: Tiny.vHead,
            kvLoraRank: Tiny.kvLora,
            qLoraRank: Tiny.qLora,
            scale: Float(pow(Double(Tiny.nope + Tiny.rope), -0.5)),
            gateKind: "head_wise",
            ropeTheta: Tiny.ropeTheta,
            eps: Tiny.eps,
            weights: weights
        )

        let input = try await tensor("input")
        let output = attention(input)
        let expectedOutput = try await tensor("output")
        let outputMetrics = compare(output, expectedOutput)
        print("[Edge0 MLA] output relL2=\(outputMetrics.relativeL2) maxAbs=\(outputMetrics.maxAbs)")

        // RoPE-specific check: q_pe after interleaved rotation.
        let qProjected = weights.qBProj!.apply(
            Edge0LinearMath.rmsNorm(
                weights.qAProj!.apply(input),
                weight: weights.qALayernorm!,
                eps: Tiny.eps
            )
        )
        let q = qProjected
            .reshaped([1, input.dim(1), Tiny.heads, Tiny.nope + Tiny.rope])
            .transposed(0, 2, 1, 3)
        let qPe = q.split(indices: [Tiny.nope], axis: -1)[1]
        let rotated = Edge0MLAAttention.ropeInterleave(
            qPe,
            positions: MLX.arange(input.dim(1)).asType(.float32),
            theta: Tiny.ropeTheta
        )
        let ropeMetrics = compare(rotated, try await tensor("q_pe_rotated"))
        print("[Edge0 MLA] q_pe rope relL2=\(ropeMetrics.relativeL2) maxAbs=\(ropeMetrics.maxAbs)")

        let gate = MLX.sigmoid(weights.gProj!.apply(input))
        let gateMetrics = compare(gate, try await tensor("mla_gate"))
        print("[Edge0 MLA] gate relL2=\(gateMetrics.relativeL2) maxAbs=\(gateMetrics.maxAbs)")

        XCTAssertLessThan(outputMetrics.relativeL2, 1e-3)
        XCTAssertLessThan(ropeMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(gateMetrics.relativeL2, 1e-6)
        await stores.closeAll()
    }

    // MARK: - Helpers

    private func fixtureDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let url = URL(fileURLWithPath: directory)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("mla_tiny.safetensors").path
        ) else {
            throw XCTSkip("MLA fixture not found in \(url.path)")
        }
        return url
    }

    private struct Metrics {
        let relativeL2: Double
        let maxAbs: Double
    }

    private func compare(_ actual: MLXArray, _ expected: MLXArray) -> Metrics {
        let a = actual.asType(.float32).asArray(Float.self)
        let e = expected.asType(.float32).asArray(Float.self)
        precondition(a.count == e.count)
        var squaredDifference = 0.0
        var squaredReference = 0.0
        var maxAbs = 0.0
        for index in 0..<a.count {
            let difference = Double(a[index] - e[index])
            squaredDifference += difference * difference
            squaredReference += Double(e[index]) * Double(e[index])
            maxAbs = max(maxAbs, abs(difference))
        }
        return Metrics(
            relativeL2: (squaredDifference / max(squaredReference, 1e-12)).squareRoot(),
            maxAbs: maxAbs
        )
    }
}
