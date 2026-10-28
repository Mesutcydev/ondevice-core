import XCTest
import CryptoKit
@testable import IOSLocalLLM

final class MiniCPMV47ArtifactTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("experts"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var records: [MiniCPMV47Artifacts.FileRecord] = []
        for layer in 0..<40 {
            let path = String(format: "experts/layer_%03d.bin", layer)
            try sparse(root.appendingPathComponent(path), bytes: MiniCPMV47Artifacts.layerBytes)
            records.append(.init(path: path, bytes: MiniCPMV47Artifacts.layerBytes, sha256: String(repeating: "0", count: 64)))
        }
        let header = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
        try sparse(root.appendingPathComponent(MiniCPMV47Artifacts.modelName), bytes: 8, header: header)
        try sparse(root.appendingPathComponent(MiniCPMV47Artifacts.projectorName), bytes: 1_119_575_840, header: header)
        records.append(.init(path: MiniCPMV47Artifacts.modelName, bytes: 8, sha256: String(repeating: "0", count: 64)))
        records.append(.init(path: MiniCPMV47Artifacts.projectorName, bytes: 1_119_575_840, sha256: MiniCPMV47Artifacts.projectorSHA256))
        let families = ["ffn_gate_exps", "ffn_up_exps", "ffn_down_exps"]
        let entries: [[String: Any]] = (0..<40).flatMap { layer in
            families.enumerated().map { index, family in
                ["layer": layer, "tensor_family": family, "tensor_name": "blk.\(layer).\(family).weight",
                 "quant_type": "Q3_K", "shape": index == 2 ? [512, 2048, 256] : [2048, 512, 256],
                 "bytes_per_expert": MiniCPMV47Artifacts.expertBytes,
                 "expert_stride": MiniCPMV47Artifacts.expertBytes * 3,
                 "repacked_offset": UInt64(index) * MiniCPMV47Artifacts.expertBytes,
                 "repacked_file": String(format: "layer_%03d.bin", layer)] as [String: Any]
            }
        }
        let manifest: [String: Any] = ["schema_version": 1, "layout": "layer_major_expert",
            "experts_kind": "omni_moe_gguf", "model": ["arch": "qwen35moe", "expert_count": 256, "expert_used_count": 8], "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("experts/manifest.json"))
        records.append(.init(path: "experts/manifest.json", bytes: UInt64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let receipt = MiniCPMV47Artifacts.Receipt(format: MiniCPMV47Artifacts.format,
            repo: MiniCPMV47Catalog.thirtyFiveBRepoID, revision: MiniCPMV47Catalog.thirtyFiveBRevision,
            sourceSHA256: MiniCPMV47Artifacts.sourceSHA256, files: records)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(MiniCPMV47Artifacts.receiptName))
        return root
    }

    private func sparse(_ url: URL, bytes: UInt64, header: Data = Data()) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: header))
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: bytes)
    }

    func testReadyRequiresAllFortyCompleteExpertLayers() throws {
        let root = try fixture()
        XCTAssertTrue(MiniCPMV47Artifacts.isPrepared(in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("experts/layer_039.bin"))
        XCTAssertFalse(MiniCPMV47Artifacts.isPrepared(in: root))
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
    }

    #if canImport(UIKit)
    @MainActor
    func testDownloaderCannotCallADamagedPreparedPairReady() throws {
        let root = try fixture()
        try Data("Publisher card".utf8).write(to: root.appendingPathComponent("README.md"))
        let downloader = HFModelDownloadManager(repoID: MiniCPMV47Catalog.thirtyFiveBRepoID,
            destination: root, branch: MiniCPMV47Catalog.thirtyFiveBRevision,
            fileAllowlist: MiniCPMV47Catalog.thirtyFiveB.fileAllowlist)
        downloader.checkIfReady()
        XCTAssertEqual(downloader.state, .ready)
        try FileManager.default.removeItem(at: root.appendingPathComponent("experts/layer_039.bin"))
        downloader.checkIfReady()
        XCTAssertNotEqual(downloader.state, .ready)
        XCTAssertEqual(downloader.progress, 0)
    }
    #endif

    func testTruncatedExpertLayerAndDamagedModelAreRefused() throws {
        let root = try fixture()
        let layer = try FileHandle(forWritingTo: root.appendingPathComponent("experts/layer_000.bin"))
        try layer.truncate(atOffset: 4); try layer.close()
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
        let other = try fixture()
        try Data(repeating: 0, count: 8).write(to: other.appendingPathComponent(MiniCPMV47Artifacts.modelName))
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: other))
    }

    func testManifestChangesAreRefusedEvenWhenByteCountMatches() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("experts/manifest.json")
        let original = try String(contentsOf: url, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "\"expert_used_count\":8", with: "\"expert_used_count\":4")
        XCTAssertNotEqual(original, changed)
        XCTAssertEqual(original.utf8.count, changed.utf8.count)
        try changed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
    }

    func testSymlinkCannotSubstituteAnExpertFile() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("experts/layer_000.bin")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("experts/layer_001.bin"))
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
    }

    func testWrongRevisionAndEscapingReceiptPathAreRefused() throws {
        let root = try fixture()
        let url = root.appendingPathComponent(MiniCPMV47Artifacts.receiptName)
        let original = try String(contentsOf: url, encoding: .utf8)
        let changed = original.replacingOccurrences(of: MiniCPMV47Catalog.thirtyFiveBRevision, with: String(repeating: "0", count: 40))
        try changed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["path"] = "../outside.bin"
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        XCTAssertThrowsError(try MiniCPMV47Artifacts.validate(in: root))
    }

    func testPreparationCancellationAndWrongRevisionKeepOriginalSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("original source".utf8)
        let model = root.appendingPathComponent(MiniCPMV47Artifacts.modelName)
        try original.write(to: model)
        for revision in ["unsupported", MiniCPMV47Catalog.thirtyFiveBRevision] {
            do {
                try await MiniCPMV47Artifacts.prepare(in: root, sourceRevision: revision,
                    checkpoint: { throw CancellationError() }, report: { _ in })
                XCTFail("Preparation should refuse or cancel")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: model), original)
            XCTAssertFalse(MiniCPMV47Artifacts.isPrepared(in: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: MiniCPMV47Artifacts.pendingDirectory(for: root).path))
        }
    }
}
