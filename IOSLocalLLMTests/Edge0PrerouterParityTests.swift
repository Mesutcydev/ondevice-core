import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0PrerouterParityTests
//
// Phase 4B-3 gate: the native Swift prerouter head + SIGMOID_GROUP selection
// must match the upstream MLX implementation (`PrerouterHead` +
// `group_select_from_logits`) before predictions are used for any I/O.

final class Edge0PrerouterParityTests: Edge0MLXTestCase {

    func testPrerouterHeadsMatchUpstreamFixture() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let fixtureDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_FIXTURE_DIR"
        ] ?? "/tmp/edge0-fixtures"
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let configuration = try Edge0ModelConfiguration.decode(
            from: Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        )
        try configuration.validateEdge0_8B()

        let loadedPrerouter = try await Edge0Prerouter.load(
            directory: modelURL, configuration: configuration
        )
        let prerouter = try XCTUnwrap(
            loadedPrerouter,
            "prerouter_edge0_8b.safetensors must be present for this test"
        )
        XCTAssertEqual(prerouter.ownerLayers, Array(7...22))

        let fixtureURL = URL(fileURLWithPath: fixtureDirectory)
            .appendingPathComponent("prerouter_fixture.safetensors")
        let fixtureIndex = try Edge0SafetensorsIndex.openSingleFile(at: fixtureURL)
        let fixtureStores = try Edge0TensorStoreSet(
            directory: URL(fileURLWithPath: fixtureDirectory),
            shardNames: ["prerouter_fixture.safetensors"]
        )
        let fixtureLoader = Edge0ResidentTensorLoader(
            index: fixtureIndex, stores: fixtureStores
        )
        defer { Task { await fixtureStores.closeAll() } }

        let thisIDs = try await fixtureLoader
            .load(fixtureIndex.location("prerouter_this_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let prevIDs = try await fixtureLoader
            .load(fixtureIndex.location("prerouter_prev_ids"))
            .asType(.int32).asArray(Int32.self).map { Int($0) }
        let thisOH = Edge0Prerouter.oneHot(
            ids: thisIDs, numExperts: configuration.numExperts
        )
        let prevOH = Edge0Prerouter.oneHot(
            ids: prevIDs, numExperts: configuration.numExperts
        )

        for owner in [7, 15, 22] {
            let hidden = try await fixtureLoader
                .load(fixtureIndex.location("prerouter_\(owner)_hidden"))
            let expectedLogits = try await fixtureLoader
                .load(fixtureIndex.location("prerouter_\(owner)_logits"))
                .asType(.float32)
            let expectedIDs = try await fixtureLoader
                .load(fixtureIndex.location("prerouter_\(owner)_selected_ids"))
                .asType(.int32).asArray(Int32.self).map { Int($0) }

            let head = try XCTUnwrap(prerouter.heads[owner])
            let actualLogits = head.logits(
                hidden: hidden.asType(.float16),
                thisOneHot: thisOH,
                prevOneHot: prevOH
            ).asType(.float32)
            MLX.eval(actualLogits)

            let diff = MLX.abs(actualLogits - expectedLogits)
            let maxAbs = diff.max().item(Float.self)
            let denom = MLX.abs(expectedLogits).max().item(Float.self)
            let relL2 = maxAbs / max(denom, 1e-6)

            let result = try XCTUnwrap(prerouter.predict(
                owner: owner,
                hidden: hidden.asType(.float16),
                thisOneHot: thisOH,
                prevOneHot: prevOH,
                topK: configuration.numExpertsPerTok
            ))
            let actualIDs = result.indices
                .asType(.int32).asArray(Int32.self).map { Int($0) }

            print("[Edge0 prerouter] owner \(owner) maxAbs=\(maxAbs) relMax=\(relL2)")
            print("[Edge0 prerouter] owner \(owner) expected=\(expectedIDs.sorted())")
            print("[Edge0 prerouter] owner \(owner) actual  =\(actualIDs.sorted())")

            // fp16 head accumulation floor; upstream and Swift run the same
            // op sequence, so this bound is tight.
            XCTAssertLessThan(maxAbs, 1e-3, "owner \(owner) head logits maxAbs")
            XCTAssertEqual(
                actualIDs.sorted(), expectedIDs.sorted(),
                "owner \(owner) selected expert IDs must match upstream"
            )
        }
    }
}
