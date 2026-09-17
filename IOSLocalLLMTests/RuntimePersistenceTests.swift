import XCTest
@testable import IOSLocalLLM

// MARK: - RuntimePersistenceTests
//
// `ModelRuntime` is persisted inside installed-model records and settings.
// Adding `.edge0MLX` must not invalidate any stored value written by an
// older build.

final class RuntimePersistenceTests: XCTestCase {

    func testLegacyRawValuesStillDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decode("\"mlx\"", with: decoder), .mlx)
        XCTAssertEqual(try decode("\"llamaCpp\"", with: decoder), .llamaCpp)
        XCTAssertEqual(try decode("\"coreAI\"", with: decoder), .coreAI)
    }

    func testEdge0RawValueDecodes() throws {
        XCTAssertEqual(try decode("\"edge0MLX\"", with: JSONDecoder()), .edge0MLX)
    }

    func testRoundTripPreservesEveryRuntime() throws {
        for runtime in ModelRuntime.allCases {
            let data = try JSONEncoder().encode(runtime)
            XCTAssertEqual(
                try JSONDecoder().decode(ModelRuntime.self, from: data),
                runtime
            )
        }
    }

    func testLabelsAndAPIFieldsCoverEdge0() {
        XCTAssertEqual(ModelRuntime.edge0MLX.label, "EDGE0")
        XCTAssertEqual(ModelRuntime.edge0MLX.apiFormat, "edge0mlx")
        // Existing identifiers stay stable — they are part of the local API
        // and benchmark metadata contract.
        XCTAssertEqual(ModelRuntime.mlx.apiFormat, "mlx")
        XCTAssertEqual(ModelRuntime.llamaCpp.apiFormat, "gguf")
        XCTAssertEqual(ModelRuntime.coreAI.apiFormat, "coreai")
    }

    func testInstalledRecordWrittenWithLegacyEngineDecodes() throws {
        // A record persisted by a build whose JSON used "engine": "llamaCpp".
        let record = InstalledModelRecord(
            id: UUID(),
            repoID: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3-4B",
            localURL: URL(fileURLWithPath: "/tmp/qwen3"),
            engine: .mlx,
            capabilities: [.recommended],
            architecture: "Qwen3ForCausalLM",
            quantization: "4bit",
            parameterCount: 4,
            installedAt: Date(timeIntervalSince1970: 0),
            validationState: .valid,
            downloadBytes: 2_300_000_000
        )

        let encoded = try JSONEncoder().encode([record])
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        json[0]["engine"] = "llamaCpp"
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(
            [InstalledModelRecord].self,
            from: legacyData
        )
        XCTAssertEqual(decoded.first?.engine, .llamaCpp)
        XCTAssertEqual(decoded.first?.repoID, record.repoID)
    }

    func testInstalledRecordWithEdge0EngineRoundTrips() throws {
        let record = InstalledModelRecord(
            id: UUID(),
            repoID: "edge0/ling-mini",
            displayName: "Ling Mini",
            localURL: URL(fileURLWithPath: "/tmp/ling"),
            engine: .edge0MLX,
            capabilities: [],
            architecture: nil,
            quantization: nil,
            parameterCount: nil,
            installedAt: Date(timeIntervalSince1970: 0),
            validationState: .valid,
            downloadBytes: 0
        )
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([InstalledModelRecord].self, from: data)
        XCTAssertEqual(decoded.first?.engine, .edge0MLX)
    }

    // MARK: - Helpers

    private func decode(
        _ json: String,
        with decoder: JSONDecoder
    ) throws -> ModelRuntime {
        try decoder.decode(ModelRuntime.self, from: Data(json.utf8))
    }
}
