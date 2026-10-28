import Foundation
import Testing
@testable import IOSLocalLLM

struct HFDownloadScopeTests {
    private func fixture(_ sizes: [String: Int64], repoID: String = "Edge0/Edge0-35B-A3B-preview") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repoID.utf8).write(to: root.appendingPathComponent(".repoID"))
        try JSONEncoder().encode(sizes).write(to: root.appendingPathComponent(".hf-expected.json"))
        return root
    }

    @Test func cancellationDoesNotMatchSiblingDirectoryPrefixes() {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: "/models/Edge0-35B"), fileAllowlist: nil)
        #expect(scope.contains(path: "/models/Edge0-35B/model.safetensors"))
        #expect(!scope.contains(path: "/models/Edge0-35B-other/model.safetensors"))
        #expect(!scope.contains(path: "/models/Edge0-35B/../other/model.safetensors"))
    }

    @Test func restoredTaskDestinationCanBeMatchedWithoutAnInMemoryRecord() {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: "/models/Edge0-35B"), fileAllowlist: ["model-00001.safetensors"])
        let restoredDescription = "/models/Edge0-35B/model-00001.safetensors"
        #expect(scope.contains(path: restoredDescription))
        #expect(!scope.contains(path: "/models/Edge0-35B/model-00001.safetensors.backup"))
    }

    @Test func directoryAllowlistsKeepSiblingVariantsSeparate() {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: "/voices"), fileAllowlist: ["nano/"])
        #expect(scope.contains(path: "/voices/nano/weights.npz"))
        #expect(!scope.contains(path: "/voices/mini/weights.npz"))
        #expect(!scope.contains(path: "/voices/nano-other/weights.npz"))
    }

    @Test func interruptedEdge0ReceiptStaysGoneAfterReconstruction() throws {
        let repo = "Edge0/Edge0-35B-A3B-preview"
        let root = try fixture(["model-00001.safetensors": 12, "tokenizer.json": 4])
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = HFDownloadScope(destination: root, fileAllowlist: ["model-00001.safetensors", "tokenizer.json"])
        #expect(scope.hasResumableReceipt(repoID: repo))
        try scope.discardReceipt(repoID: repo)
        let restored = HFDownloadScope(destination: root, fileAllowlist: scope.fileAllowlist)
        #expect(!restored.hasResumableReceipt(repoID: repo))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".hf-expected.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".repoID").path))
    }

    @Test func cancelingOneVariantKeepsSiblingReceiptAndFiles() throws {
        let repo = "test/shared-voices"
        let root = try fixture(["nano/weights.npz": 2, "mini/weights.npz": 3], repoID: repo)
        defer { try? FileManager.default.removeItem(at: root) }
        let mini = root.appendingPathComponent("mini")
        try FileManager.default.createDirectory(at: mini, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: mini.appendingPathComponent("weights.npz"))
        let nanoScope = HFDownloadScope(destination: root, fileAllowlist: ["nano/"])
        try nanoScope.discardReceipt(repoID: repo)
        #expect(!nanoScope.hasResumableReceipt(repoID: repo))
        #expect(HFDownloadScope(destination: root, fileAllowlist: ["mini/"]).hasResumableReceipt(repoID: repo))
        #expect(try Data(contentsOf: mini.appendingPathComponent("weights.npz")) == Data([1, 2, 3]))
    }

    @Test func differentRepositoryReceiptIsPreserved() throws {
        let root = try fixture(["mini/weights.npz": 3], repoID: "test/mini")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = HFDownloadScope(destination: root, fileAllowlist: ["mini/"])
        try scope.discardReceipt(repoID: "test/nano")
        #expect(scope.hasResumableReceipt(repoID: "test/mini"))
    }

    @Test func siblingOnlyAndMalformedReceiptsDoNotCreateInterruptedRows() throws {
        let repo = "test/shared"
        let root = try fixture(["mini/weights.npz": 3], repoID: repo)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!HFDownloadScope(destination: root, fileAllowlist: ["nano/"]).hasResumableReceipt(repoID: repo))
        try Data("invalid".utf8).write(to: root.appendingPathComponent(".hf-expected.json"))
        #expect(!HFDownloadScope(destination: root, fileAllowlist: nil).hasResumableReceipt(repoID: repo))
    }
}
