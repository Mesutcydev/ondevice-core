import Foundation
import Testing
@testable import IOSLocalLLM

struct BackgroundDownloadJournalTests {
    private let revision = String(repeating: "a", count: 40)
    private func fixture() throws -> (URL, URL, BackgroundDownloadJob) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("Documents/models/test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = BackgroundDownloadOwner(kind: .hub, id: "test/model", repoID: "test/model",
            revision: revision, displayName: "Test model", fileAllowlist: ["weights.gguf", "projector.gguf"])
        let files = ["weights.gguf", "projector.gguf"].map {
            BackgroundDownloadFile(relativePath: $0,
                source: URL(string: "https://huggingface.co/test/model/resolve/\(revision)/\($0)")!, expectedBytes: 3)
        }
        return (home, root, try BackgroundDownloadJob(owner: owner, root: root, files: files, home: home))
    }

    @Test func completeBatchAndPauseSurviveProcessReconstruction() throws {
        let (home, _, initial) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("Library/queue.json")
        let journal = BackgroundDownloadJournal(url: url, home: home)
        try journal.save([initial.id: initial])
        let recovered = try #require(BackgroundDownloadJournal(url: url, home: home).load()[initial.id])
        #expect(recovered.files.count == 2)
        #expect(recovered.owner.revision == revision)
        var paused = recovered; paused.state = .paused; paused.files[0].completed = true
        try journal.save([paused.id: paused])
        #expect(journal.load()[paused.id]?.state == .paused)
        #expect(journal.load()[paused.id]?.files[0].completed == true)
        try journal.save([:])
        #expect(journal.load().isEmpty)
    }

    @Test func sandboxRelativePathsSurviveContainerMoves() throws {
        let (home, _, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let movedHome = home.appendingPathComponent("replacement")
        try job.validate(home: movedHome)
        #expect(job.destination(for: job.files[0], home: movedHome).path == movedHome.path + "/Documents/models/test/weights.gguf")
        #expect(BackgroundDownloadJob.identifier(root: job.root(in: movedHome), ownerID: job.owner.id,
            fileAllowlist: job.owner.fileAllowlist, home: movedHome) == job.id)
    }

    @Test func taskReferenceContainsOnlyJobAndRelativePath() throws {
        let (home, _, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let reference = BackgroundDownloadTaskReference(jobID: job.id, relativePath: job.files[0].relativePath)
        let recovered = try #require(BackgroundDownloadTaskReference(description: reference.description))
        #expect(recovered.jobID == job.id)
        #expect(recovered.relativePath == "weights.gguf")
        #expect(!reference.description!.contains(home.path))
        #expect(!reference.description!.contains("Authorization"))
    }

    @Test func siblingVariantsHaveIndependentDurableIdentifiers() throws {
        let (home, root, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let sibling = BackgroundDownloadJob.identifier(root: root, ownerID: job.owner.id,
            fileAllowlist: ["another.gguf"], home: home)
        #expect(sibling != job.id)
        #expect(BackgroundDownloadJob.identifier(root: root, ownerID: job.owner.id,
            fileAllowlist: ["projector.gguf", "weights.gguf"], home: home) == job.id)
    }

    @Test func malformedOrUnpinnedURLsAndPathsCannotRestoreTransfers() throws {
        let (home, _, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        for path in ["../other.gguf", "/outside.gguf", "nested//weights.gguf", "nested\\weights.gguf"] {
            var invalid = job; invalid.files[0].relativePath = path
            #expect(throws: (any Error).self) { try invalid.validate(home: home) }
        }
        for source in ["https://example.com/weights.gguf", "http://huggingface.co/test/model/resolve/\(revision)/weights.gguf",
                       "https://huggingface.co/test/model/resolve/main/weights.gguf",
                       "https://huggingface.co/test/model/resolve/\(revision)/weights.gguf?token=secret"] {
            var invalid = job; invalid.files[0].source = URL(string: source)!
            #expect(throws: (any Error).self) { try invalid.validate(home: home) }
        }
        var duplicate = job; duplicate.files.append(duplicate.files[0])
        #expect(throws: (any Error).self) { try duplicate.validate(home: home) }
    }

    @Test func receiptCannotCreditPartialOrEmptyFilesAsComplete() throws {
        let (home, _, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let destination = job.destination(for: job.files[0], home: home)
        try Data([1, 2]).write(to: destination)
        #expect(!BackgroundDownloadJob.fileIsComplete(job.files[0], at: destination))
        try Data([1, 2, 3]).write(to: destination)
        #expect(BackgroundDownloadJob.fileIsComplete(job.files[0], at: destination))
        var unknown = job.files[0]; unknown.expectedBytes = 0
        try Data().write(to: destination)
        #expect(!BackgroundDownloadJob.fileIsComplete(unknown, at: destination))
    }

    @Test func symlinkEscapeIsRejected() throws {
        let (home, root, job) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("weights.gguf"),
                                                  withDestinationURL: outside.appendingPathComponent("weights.gguf"))
        #expect(throws: (any Error).self) { try job.validate(home: home) }
    }
}
