import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0MLAStateParityTests
//
// Stateful MLA parity against upstream `BailingMLA` + mlx-lm KVCache:
// causal prefill, cached one-token decode at absolute position 4, sequential
// one-token prefill, and cross-checks between prefill-final and
// sequential-final state.

final class Edge0MLAStateParityTests: Edge0MLXTestCase {

    private struct Tiny {
        static let heads = 2
        static let nope = 8
        static let rope = 8
        static let vHead = 8
        static let qLora = 8
        static let kvLora = 16
        static let eps: Float = 1e-6
        static let ropeTheta: Float = 6_000_000
        static let tokens = 4
    }

    func testMLAStateMatchesUpstreamAcrossPrefillAndDecode() async throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("mla_state_tiny.safetensors")
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["mla_state_tiny.safetensors"]
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

        let sequence = try await tensor("sequence")
        let decodeToken = try await tensor("decode_token")

        // MARK: Prefill

        var prefillState = Edge0MLAState.empty
        let prefillOutput = attention(sequence, state: &prefillState)
        let prefillOutputMetrics = compare(
            prefillOutput,
            try await tensor("prefill_output")
        )
        let prefillKeyMetrics = compare(
            try XCTUnwrap(prefillState.keys),
            try await tensor("prefill_keys")
        )
        let prefillValueMetrics = compare(
            try XCTUnwrap(prefillState.values),
            try await tensor("prefill_values")
        )
        XCTAssertEqual(prefillState.offset, Tiny.tokens)

        // MARK: Cached one-token decode (absolute position 4)

        var decodeState = prefillState
        let decodeOutput = attention(decodeToken, state: &decodeState)
        let decodeOutputMetrics = compare(
            decodeOutput,
            try await tensor("decode_output")
        )
        let decodeKeyMetrics = compare(
            try XCTUnwrap(decodeState.keys),
            try await tensor("decode_keys")
        )
        let decodeValueMetrics = compare(
            try XCTUnwrap(decodeState.values),
            try await tensor("decode_values")
        )
        XCTAssertEqual(decodeState.offset, Tiny.tokens + 1)

        // MARK: Sequential one-token prefill

        var sequentialState = Edge0MLAState.empty
        for step in 0..<Tiny.tokens {
            let token = sequence[0..., step..<(step + 1), 0...]
            let output = attention(token, state: &sequentialState)
            let outputMetrics = compare(
                output,
                try await tensor("sequential_output_\(step)")
            )
            let keyMetrics = compare(
                try XCTUnwrap(sequentialState.keys),
                try await tensor("sequential_keys_\(step)")
            )
            let valueMetrics = compare(
                try XCTUnwrap(sequentialState.values),
                try await tensor("sequential_values_\(step)")
            )
            print("[Edge0 MLA state] step \(step) output=\(outputMetrics.relativeL2) keys=\(keyMetrics.relativeL2) values=\(valueMetrics.relativeL2)")
            XCTAssertLessThan(outputMetrics.relativeL2, 1e-4)
            XCTAssertLessThan(keyMetrics.relativeL2, 1e-4)
            XCTAssertLessThan(valueMetrics.relativeL2, 1e-4)
        }

        // MARK: Cross-checks

        let stepOutputs = [
            try await tensor("sequential_output_0"),
            try await tensor("sequential_output_1"),
            try await tensor("sequential_output_2"),
            try await tensor("sequential_output_3"),
        ]
        let sequentialOutput = MLX.concatenated(stepOutputs, axis: 1)
        let concatenatedMetrics = compare(
            prefillOutput,
            sequentialOutput
        )
        let finalKeyMetrics = compare(
            try XCTUnwrap(sequentialState.keys),
            try XCTUnwrap(prefillState.keys)
        )
        let finalValueMetrics = compare(
            try XCTUnwrap(sequentialState.values),
            try XCTUnwrap(prefillState.values)
        )

        print("[Edge0 MLA state] prefill output=\(prefillOutputMetrics.relativeL2) keys=\(prefillKeyMetrics.relativeL2) values=\(prefillValueMetrics.relativeL2)")
        print("[Edge0 MLA state] decode output=\(decodeOutputMetrics.relativeL2) keys=\(decodeKeyMetrics.relativeL2) values=\(decodeValueMetrics.relativeL2)")
        print("[Edge0 MLA state] prefill-vs-sequential output=\(concatenatedMetrics.relativeL2) keys=\(finalKeyMetrics.relativeL2) values=\(finalValueMetrics.relativeL2)")

        XCTAssertLessThan(prefillOutputMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(prefillKeyMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(prefillValueMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(decodeOutputMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(decodeKeyMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(decodeValueMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(concatenatedMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(finalKeyMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(finalValueMetrics.relativeL2, 1e-4)

        await stores.closeAll()
    }

    // MARK: - Helpers

    private func fixtureDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let url = URL(fileURLWithPath: directory)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("mla_state_tiny.safetensors").path
        ) else {
            throw XCTSkip("MLA state fixture not found in \(url.path)")
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
        precondition(a.count == e.count, "shape mismatch \(actual.shape) vs \(expected.shape)")
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
