import XCTest
@testable import IOSLocalLLM

final class HFDownloadCancellationTests: XCTestCase {
    @MainActor func testInterruptedEdge0CancelRemovesFilesAndDoesNotRestoreReceipt() async throws {
        let repo = Edge0ModelFamily.qwen35MoERepoID
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repo.utf8).write(to: root.appendingPathComponent(".repoID"))
        try JSONEncoder().encode(["model.safetensors": Int64(8), "tokenizer.json": Int64(4)])
            .write(to: root.appendingPathComponent(".hf-expected.json"))
        try Data([1, 2]).write(to: root.appendingPathComponent("model.safetensors"))
        let manager = HFModelDownloadManager(repoID: repo, destination: root,
            fileAllowlist: ["model.safetensors", "tokenizer.json"])
        manager.checkIfReady()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(manager.hasResumableDownloadReceipt)
        manager.cancel()
        let deadline = Date().addingTimeInterval(10)
        while manager.isCancellingDownload && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(manager.isCancellingDownload)
        XCTAssertFalse(manager.hasResumableDownloadReceipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("model.safetensors").path))
        manager.checkIfReady()
        let restored = HFModelDownloadManager(repoID: repo, destination: root,
            fileAllowlist: ["model.safetensors", "tokenizer.json"])
        restored.checkIfReady()
        XCTAssertEqual(restored.state, .idle)
        XCTAssertFalse(restored.hasResumableDownloadReceipt)
    }
}
