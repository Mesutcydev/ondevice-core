import XCTest
@testable import IOSLocalLLM

// MARK: - InstalledModelRegistryValidationTests
//
// Pins `InstalledModelRegistry.validateDirectory`, the on-disk probe that
// turns a model folder into an authoritative `InstalledModelRecord`. The
// import service and the download manager both treat a standalone GGUF as a
// complete model (GGUF embeds its tokenizer and ships no config.json), so the
// registry must agree or a legitimately-imported GGUF silently vanishes from
// every picker as "not downloaded".

@MainActor
final class InstalledModelRegistryValidationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func write(_ name: String, contents: Data, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name))
    }

    /// A 4-byte file beginning with the `GGUF` magic byte sequence, so
    /// `LocalModelFileValidator.isValidGGUFFile` accepts it.
    private let ggufMagic = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"

    func test_ggufOnlyDirectoryRegistersAsValidLlamaCpp() throws {
        let modelDir = tempDir.appendingPathComponent("qwen-gguf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try write("qwen-1.5b-instruct-q4_k_m.gguf", contents: ggufMagic, in: modelDir)

        // No config.json — the old code returned nil here.
        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "local/qwen-gguf")

        XCTAssertNotNil(record, "A GGUF-only directory must produce an installed record.")
        XCTAssertEqual(record?.engine, .llamaCpp)
        XCTAssertEqual(record?.validationState, .valid, "GGUF embeds its tokenizer, so it must be ready.")
    }

    func test_ggufDirectoryWithNestedWeightsStillValidates() throws {
        let modelDir = tempDir.appendingPathComponent("nested", isDirectory: true)
        let inner = modelDir.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true)
        try write("model.gguf", contents: ggufMagic, in: inner)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "nested")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .llamaCpp)
        XCTAssertEqual(record?.validationState, .valid)
    }

    func test_mlxDirectoryRegistersAsValidMlx() throws {
        let modelDir = tempDir.appendingPathComponent("mlx-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try write("config.json", contents: Data(#"{"architectures":["Qwen2ForCausalLM"]}"#.utf8), in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)
        try write("model.safetensors", contents: Data(repeating: 0, count: 32), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "mlx-model")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .mlx)
        XCTAssertEqual(record?.validationState, .valid)
    }

    func test_incompleteMlxDirectoryIsNotReady() throws {
        let modelDir = tempDir.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        // A tokenizer and config are present, but weights are incomplete.
        try write("config.json", contents: Data(#"{"architectures":["Qwen2ForCausalLM"]}"#.utf8), in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "partial")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .mlx)
        XCTAssertEqual(record?.validationState, .missingWeights)
    }

    func test_emptyDirectoryReturnsNil() throws {
        let modelDir = tempDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)

        XCTAssertNil(InstalledModelRegistry.validateDirectory(modelDir, repoID: "empty"))
    }

    // MARK: - Stale container re-anchoring

    func testPersistedRecordOutsideCurrentSandboxIsReanchoredOrDropped() throws {
        // Create a real valid model folder in the CURRENT container.
        let name = "Edge0-8B-A1B-preview-reanchor-\(UUID().uuidString.prefix(8))"
        let realDir = ModelStoragePaths.llmModelDirectory(named: name)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: realDir) }
        try writeEdge0Config(in: realDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: realDir)
        try write("model.safetensors", contents: Data(repeating: 0, count: 16), in: realDir)

        let valid = try XCTUnwrap(InstalledModelRegistry.validateDirectory(
            realDir, repoID: "Edge0/Edge0-8B-A1B-preview"
        ))
        XCTAssertEqual(valid.validationState, .valid)

        // Stale copy: same folder name, previous container UUID.
        let stale = InstalledModelRecord(
            id: UUID(),
            repoID: valid.repoID,
            displayName: valid.displayName,
            localURL: URL(fileURLWithPath:
                "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/LLMModels/\(name)"),
            engine: .edge0MLX,
            capabilities: valid.capabilities,
            architecture: valid.architecture,
            quantization: valid.quantization,
            parameterCount: valid.parameterCount,
            installedAt: valid.installedAt,
            validationState: .valid,
            downloadBytes: valid.downloadBytes
        )
        let reanchored = try XCTUnwrap(InstalledModelRegistry.reanchoredRecord(stale))
        XCTAssertEqual(reanchored.localURL.standardizedFileURL, realDir.standardizedFileURL)
        XCTAssertEqual(reanchored.validationState, .valid)

        // No folder with that name in the current container -> dropped.
        let orphan = InstalledModelRecord(
            id: UUID(),
            repoID: "Edge0/Edge0-8B-A1B-preview",
            displayName: "orphan",
            localURL: URL(fileURLWithPath:
                "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/LLMModels/missing-\(UUID().uuidString)"),
            engine: .edge0MLX,
            capabilities: [],
            architecture: nil,
            quantization: nil,
            parameterCount: nil,
            installedAt: Date(),
            validationState: .valid,
            downloadBytes: 0
        )
        XCTAssertNil(InstalledModelRegistry.reanchoredRecord(orphan))
    }

    // MARK: - Edge0 (native runtime)

    private func writeEdge0Config(in dir: URL) throws {
        let config = #"{"architectures":["BailingMoeV3ForCausalLM"]}"#
        try write("config.json", contents: Data(config.utf8), in: dir)
    }

    func test_edge0CheckpointRegistersAsEdge0ByArchitecture() throws {
        let modelDir = tempDir.appendingPathComponent("Edge0-8B-A1B-preview", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try writeEdge0Config(in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)
        try write("model.safetensors", contents: Data(repeating: 0, count: 32), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(
            modelDir, repoID: "Edge0/Edge0-8B-A1B-preview")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .edge0MLX,
                       "Declared BailingMoeV3ForCausalLM architecture must classify as Edge0, not MLX.")
        XCTAssertEqual(record?.validationState, .valid)
        // The architecture string is also surfaced for the picker.
        XCTAssertEqual(record?.architecture, "BailingMoeV3ForCausalLM")
    }

    func test_edge0NameWithoutArchitectureStaysMlx() throws {
        let modelDir = tempDir.appendingPathComponent("edge0-not-really", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        // Qwen architecture — the folder NAME mentions edge0 but the declared
        // architecture is what decides the engine. No filename heuristics.
        try write("config.json",
                  contents: Data(#"{"architectures":["Qwen2ForCausalLM"]}"#.utf8),
                  in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)
        try write("model.safetensors", contents: Data(repeating: 0, count: 32), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "edge0-not-really")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .mlx)
        XCTAssertEqual(record?.validationState, .valid)
    }

    func test_edge0ArchitectureWithoutCheckpointIsMissingWeights() throws {
        let modelDir = tempDir.appendingPathComponent("edge0-partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try writeEdge0Config(in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "edge0-partial")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .edge0MLX)
        XCTAssertEqual(record?.validationState, .missingWeights)
        XCTAssertFalse(record?.validationState.isActivatable ?? true)
    }
}
