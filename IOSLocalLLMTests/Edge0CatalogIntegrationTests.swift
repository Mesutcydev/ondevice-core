import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0CatalogIntegrationTests
//
// Pins the curated Edge0 catalog contract end to end: preset metadata, the
// explicit runtime tag, the download allowlist, and partial-vs-complete
// artifact acceptance. The 4.5 GB transfer itself is exercised on device;
// these tests cover everything around it deterministically.

@MainActor
final class Edge0CatalogIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func edge0Preset() throws -> AssistantModel {
        try XCTUnwrap(
            AssistantModelCatalog.presets.first { $0.runtime == .edge0MLX },
            "The catalog must declare exactly one Edge0 preset."
        )
    }

    private func write(_ name: String, in dir: URL, bytes: Int = 16) throws {
        try Data(repeating: 0, count: bytes).write(
            to: dir.appendingPathComponent(name)
        )
    }

    func testPresetMetadataIsExplicitAndBounded() throws {
        let preset = try edge0Preset()
        XCTAssertEqual(preset.repoID, "Edge0/Edge0-8B-A1B-preview")
        XCTAssertEqual(preset.runtime, .edge0MLX)
        XCTAssertEqual(preset.contextWindowTokens, 131_072)
        XCTAssertGreaterThan(
            preset.downloadSizeBytes ?? 0, 4_000_000_000,
            "The published checkpoint is ~4.5 GB; the size label must not understate it."
        )
        XCTAssertFalse(preset.supportsTools)
    }

    func testCatalogEntryCarriesRuntimeAndAllowlist() throws {
        let preset = try edge0Preset()
        let entry = try XCTUnwrap(
            ModelDownloadCenter.shared.models.first {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            },
            "The curated preset must produce a download catalog entry."
        )
        XCTAssertEqual(entry.runtime, .edge0MLX)

        let allowlist = try XCTUnwrap(entry.downloader?.fileAllowlist)
        XCTAssertTrue(allowlist.contains("model.safetensors"))
        XCTAssertTrue(allowlist.contains("config.json"))
        XCTAssertTrue(allowlist.contains("tokenizer.json"))
        XCTAssertTrue(allowlist.contains("tokenizer_config.json"))
        XCTAssertFalse(
            allowlist.contains { $0.hasSuffix(".gguf") },
            "Edge0 must never fetch GGUF artifacts."
        )
    }

    func testEdge0FootprintReflectsStorageBackedRuntime() throws {
        // Routed experts stream from disk through a bounded pool; the
        // measured device footprint while loaded is ~1.59 GB. A resident
        // 6 GB estimate wrongly hid the model from memory-fit filters.
        let preset = try edge0Preset()
        XCTAssertLessThanOrEqual(
            preset.approxRAMBytes, 2_500_000_000,
            "Edge0 must declare its storage-backed footprint, not a resident 8B estimate."
        )
        XCTAssertEqual(
            MemoryAdvisor.estimatedFootprint(for: preset.id),
            preset.approxRAMBytes,
            "The picker's fit filter reads the preset footprint; they must agree."
        )
    }

    func testCatalogDestinationStaysInsideSandboxDocuments() throws {
        let preset = try edge0Preset()
        let entry = try XCTUnwrap(
            ModelDownloadCenter.shared.models.first {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            }
        )
        let destination = try XCTUnwrap(entry.downloader?.destination)

        XCTAssertTrue(
            ModelStoragePaths.isInsideSandbox(destination),
            "Download destination must stay under Documents: \(destination.path)"
        )
        XCTAssertEqual(
            destination.deletingLastPathComponent(),
            ModelStoragePaths.llmModels
        )
        XCTAssertEqual(
            destination.lastPathComponent,
            ModelStoragePaths.directoryName(forRepoID: preset.repoID)
        )
    }

    func testPartialEdge0DownloadIsNotReady() throws {
        let preset = try edge0Preset()
        let entry = try XCTUnwrap(
            ModelDownloadCenter.shared.models.first {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            }
        )
        let allowlist = try XCTUnwrap(entry.downloader?.fileAllowlist)

        let dir = tempDir.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in allowlist where name != "model.safetensors" {
            try write(name, in: dir)
        }

        let downloader = HFModelDownloadManager(
            repoID: preset.repoID,
            destination: dir
        )
        downloader.fileAllowlist = allowlist
        downloader.checkIfReady()

        XCTAssertNotEqual(
            downloader.state, .ready,
            "A download missing model.safetensors must never read as ready."
        )
    }

    func testCompleteEdge0ArtifactsAreReadyAndRegistrable() throws {
        let preset = try edge0Preset()
        let entry = try XCTUnwrap(
            ModelDownloadCenter.shared.models.first {
                $0.id == preset.id || $0.sourceRepoID == preset.repoID
            }
        )
        let allowlist = try XCTUnwrap(entry.downloader?.fileAllowlist)

        let dir = tempDir.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in allowlist {
            try write(name, in: dir)
        }

        let downloader = HFModelDownloadManager(
            repoID: preset.repoID,
            destination: dir
        )
        downloader.fileAllowlist = allowlist
        downloader.checkIfReady()

        // Full artifact validation additionally decodes the real config and
        // weight geometry; that path is covered by the real-checkpoint
        // harness. Here the downloader contract is what is pinned.
        XCTAssertEqual(downloader.state, .ready)
    }
}
