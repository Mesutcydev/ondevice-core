import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0KDAParityTests
//
// Compares the Swift KDA port against upstream `BailingKDA` fixtures.
// Both sides use mlx-lm's `gated_delta_ops` reference path (the fused Metal
// kernel is an optimization deferred to a later phase).
//
// Covers: short conv + conv state, q/k L2 normalization, safe gate, beta,
// delta-rule prefill, sequential single-token decode, and final state
// equality between the two execution modes.

final class Edge0KDAParityTests: XCTestCase {

    private struct Tiny {
        static let heads = 2
        static let headDim = 8
        static let convKernel = 4
        static let eps: Float = 1e-6
        static let lowerBound: Float = -5
        static let scale: Float = Float(pow(Double(8), -0.5))
        static let tokens = 4
    }

    func testKDAPrefillAndSequentialDecodeMatchUpstream() async throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("kda_tiny.safetensors")
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["kda_tiny.safetensors"]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)

        func tensor(_ name: String) async throws -> MLXArray {
            try await loader.load(index.location(name))
        }

        let weights = Edge0KDAWeights(
            qProj: .dense(try await tensor("q_proj.weight")),
            kProj: .dense(try await tensor("k_proj.weight")),
            vProj: .dense(try await tensor("v_proj.weight")),
            qConvWeight: try await tensor("q_conv.weight"),
            kConvWeight: try await tensor("k_conv.weight"),
            vConvWeight: try await tensor("v_conv.weight"),
            fProj: .dense(try await tensor("f_proj.weight")),
            gProj: .dense(try await tensor("g_proj.weight")),
            bProj: .dense(try await tensor("b_proj.weight")),
            aLog: try await tensor("A_log"),
            dtBias: try await tensor("dt_bias"),
            oNorm: try await tensor("o_norm.weight"),
            oProj: .dense(try await tensor("o_proj.weight"))
        )
        let attention = Edge0KDAAttention(
            numHeads: Tiny.heads,
            headDim: Tiny.headDim,
            convKernelSize: Tiny.convKernel,
            safeGate: true,
            lowerBound: Tiny.lowerBound,
            eps: Tiny.eps,
            scale: Tiny.scale,
            weights: weights
        )

        let input = try await tensor("input") // [1, 4, 64]

        // MARK: Intermediates

        let (qConv, qConvState) = attention.shortConv(
            weights.qProj.apply(input),
            weight: weights.qConvWeight,
            state: nil
        )
        let (kConv, kConvState) = attention.shortConv(
            weights.kProj.apply(input),
            weight: weights.kConvWeight,
            state: nil
        )
        let (vConv, _) = attention.shortConv(
            weights.vProj.apply(input),
            weight: weights.vConvWeight,
            state: nil
        )
        let qConvMetrics = compare(qConv, try await tensor("q_conv_out"))
        let kConvMetrics = compare(kConv, try await tensor("k_conv_out"))
        let vConvMetrics = compare(vConv, try await tensor("v_conv_out"))
        let qConvStateMetrics = compare(qConvState, try await tensor("q_conv_state"))
        let kConvStateMetrics = compare(kConvState, try await tensor("k_conv_state"))

        let qf = qConv.reshaped([1, Tiny.tokens, Tiny.heads, Tiny.headDim])
            .asType(.float32)
        let kf = kConv.reshaped([1, Tiny.tokens, Tiny.heads, Tiny.headDim])
            .asType(.float32)
        let qNorm = Tiny.scale * qf / (
            MLXLinalg.norm(qf, axes: [-1], keepDims: true) + 1e-6
        )
        let kNorm = kf / (
            MLXLinalg.norm(kf, axes: [-1], keepDims: true) + 1e-6
        )
        let qNormMetrics = compare(qNorm, try await tensor("q_norm"))
        let kNormMetrics = compare(kNorm, try await tensor("k_norm"))

        let f = weights.fProj.apply(input)
            .reshaped([1, Tiny.tokens, Tiny.heads, Tiny.headDim])
        let gLog = attention.kdaGate(f)
        let beta = MLX.sigmoid(
            weights.bProj.apply(input).asType(.float32)
        )
        let gate = weights.gProj.apply(input)
            .reshaped([1, Tiny.tokens, Tiny.heads, Tiny.headDim])
        let gMetrics = compare(gLog, try await tensor("g_log"))
        let betaMetrics = compare(beta, try await tensor("beta"))
        let gateMetrics = compare(gate, try await tensor("gate"))

        // MARK: Prefill

        var prefillState = Edge0KDAState.empty
        let prefillOutput = attention(input, state: &prefillState)
        let prefillOutputMetrics = compare(
            prefillOutput,
            try await tensor("prefill_output")
        )
        let prefillConvMetrics = compare(
            try XCTUnwrap(prefillState.qConv),
            try await tensor("prefill_conv_state")
        )
        let prefillRecurrentMetrics = compare(
            try XCTUnwrap(prefillState.recurrent),
            try await tensor("prefill_recurrent_state")
        )

        // MARK: Sequential decode (same tokens, one at a time)

        var decodeState = Edge0KDAState.empty
        for step in 0..<Tiny.tokens {
            let token = input[0..., step..<(step + 1), 0...]
            let output = attention(token, state: &decodeState)
            let stepOutputMetrics = compare(
                output,
                try await tensor("step_module_output_\(step)")
            )
            let stepStateMetrics = compare(
                try XCTUnwrap(decodeState.recurrent),
                try await tensor("step_state_\(step)")
            )
            print("[Edge0 KDA] step \(step) output relL2=\(stepOutputMetrics.relativeL2) state relL2=\(stepStateMetrics.relativeL2)")
            XCTAssertLessThan(stepOutputMetrics.relativeL2, 1e-4)
            XCTAssertLessThan(stepStateMetrics.relativeL2, 1e-4)
        }
        let decodeConvMetrics = compare(
            try XCTUnwrap(decodeState.qConv),
            try await tensor("sequential_cache_conv_state")
        )
        let decodeRecurrentMetrics = compare(
            try XCTUnwrap(decodeState.recurrent),
            try await tensor("sequential_cache_recurrent_state")
        )
        print("[Edge0 KDA] sequential conv state relL2=\(decodeConvMetrics.relativeL2) recurrent=\(decodeRecurrentMetrics.relativeL2)")
        XCTAssertLessThan(decodeConvMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(decodeRecurrentMetrics.relativeL2, 1e-6)

        // Prefill state and sequential state must agree: a recurrent
        // implementation can look right for one pass and still advance state
        // incorrectly.
        let finalSequentialMetrics = compare(
            try XCTUnwrap(decodeState.recurrent),
            try XCTUnwrap(prefillState.recurrent)
        )
        let convStateCrossMetrics = compare(
            try XCTUnwrap(decodeState.qConv),
            try XCTUnwrap(prefillState.qConv)
        )

        print("[Edge0 KDA] conv q relL2=\(qConvMetrics.relativeL2) k=\(kConvMetrics.relativeL2) v=\(vConvMetrics.relativeL2)")
        print("[Edge0 KDA] qNorm relL2=\(qNormMetrics.relativeL2) kNorm=\(kNormMetrics.relativeL2)")
        print("[Edge0 KDA] g relL2=\(gMetrics.relativeL2) beta=\(betaMetrics.relativeL2) gate=\(gateMetrics.relativeL2)")
        print("[Edge0 KDA] prefill output relL2=\(prefillOutputMetrics.relativeL2) recurrent relL2=\(prefillRecurrentMetrics.relativeL2) convState=\(prefillConvMetrics.relativeL2)")
        print("[Edge0 KDA] prefill-vs-sequential state relL2=\(finalSequentialMetrics.relativeL2) convState=\(convStateCrossMetrics.relativeL2)")

        XCTAssertLessThan(qConvMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(kConvMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(vConvMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(qConvStateMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(kConvStateMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(qNormMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(kNormMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(gMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(betaMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(gateMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(prefillOutputMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(prefillRecurrentMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(prefillConvMetrics.relativeL2, 1e-4)
        XCTAssertLessThan(finalSequentialMetrics.relativeL2, 1e-6)
        XCTAssertLessThan(convStateCrossMetrics.relativeL2, 1e-6)

        await stores.closeAll()
    }

    // MARK: - Helpers

    private func fixtureDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let url = URL(fileURLWithPath: directory)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("kda_tiny.safetensors").path
        ) else {
            throw XCTSkip("KDA fixture not found in \(url.path)")
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
