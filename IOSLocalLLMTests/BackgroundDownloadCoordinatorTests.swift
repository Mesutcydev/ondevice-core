import Foundation
import Testing
@testable import IOSLocalLLM

@MainActor
struct BackgroundDownloadCoordinatorTests {
    private func fixture() throws -> (URL, BackgroundDownloadJob, BackgroundDownloadCoordinator) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("Documents/models/test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = BackgroundDownloadOwner(kind: .hub, id: "test/model", repoID: "test/model",
            revision: "main", displayName: "Test model")
        let files = ["weights.gguf", "projector.gguf"].map {
            BackgroundDownloadFile(relativePath: $0,
                source: URL(string: "https://huggingface.co/test/model/resolve/main/\($0)")!, expectedBytes: 3)
        }
        let job = try BackgroundDownloadJob(owner: owner, root: root, files: files, home: home)
        let journal = BackgroundDownloadJournal(url: home.appendingPathComponent("Library/queue.json"), home: home)
        try journal.save([job.id: job])
        return (home, job, BackgroundDownloadCoordinator(journal: journal, configuration: .ephemeral))
    }

    private func deliver(_ file: BackgroundDownloadFile, job: BackgroundDownloadJob,
                         coordinator: BackgroundDownloadCoordinator, home: URL) async throws {
        let location = home.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: location)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: file.source)
        task.taskDescription = BackgroundDownloadTaskReference(jobID: job.id, relativePath: file.relativePath).description
        // Reproduce iOS delivery after process relaunch: no in-memory Pending
        // continuation exists. The file move must finish before this returns.
        await Task.detached {
            coordinator.urlSession(session, downloadTask: task, didFinishDownloadingTo: location)
        }.value
        for _ in 0..<100 {
            if coordinator.jobs[job.id]?.files.first(where: { $0.relativePath == file.relativePath })?.completed == true { break }
            if coordinator.jobs[job.id] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }

    @Test func restoredBatchFinalizesEveryFileWithoutAConsumerAndWaitsForValidation() async throws {
        let (home, job, coordinator) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        for file in job.files { try await deliver(file, job: job, coordinator: coordinator, home: home) }
        #expect(coordinator.jobs[job.id]?.state == .verifying)
        #expect(coordinator.jobs[job.id]?.files.allSatisfy(\.completed) == true)
        for file in job.files {
            #expect(try Data(contentsOf: job.destination(for: file, home: home)) == Data([1, 2, 3]))
        }
        let journal = BackgroundDownloadJournal(url: home.appendingPathComponent("Library/queue.json"), home: home)
        #expect(journal.load()[job.id]?.state == .verifying)
    }

    @Test func cancelledRestoredTaskCannotRecreatePayloadOrReceipt() async throws {
        let (home, job, coordinator) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        coordinator.abandon(matching: job.root(in: home).path)
        try FileManager.default.removeItem(at: job.root(in: home))
        try await deliver(job.files[0], job: job, coordinator: coordinator, home: home)
        #expect(coordinator.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.root(in: home).path))
        #expect(BackgroundDownloadJournal(url: home.appendingPathComponent("Library/queue.json"), home: home).load().isEmpty)
    }

    @Test func lateCompletionCannotClearAUserPause() async throws {
        let (home, job, coordinator) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        coordinator.markPaused(matching: job.root(in: home).path)
        for file in job.files { try await deliver(file, job: job, coordinator: coordinator, home: home) }
        #expect(coordinator.jobs[job.id]?.state == .paused)
        #expect(coordinator.jobs[job.id]?.files.allSatisfy(\.completed) == true)
    }

    @Test func cancellingASharedFolderVariantKeepsTheSiblingJob() throws {
        let (home, job, _) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        var firstOwner = job.owner; firstOwner.fileAllowlist = ["weights.gguf", "projector.gguf"]
        let first = try BackgroundDownloadJob(owner: firstOwner, root: job.root(in: home), files: job.files, home: home)
        var siblingOwner = job.owner; siblingOwner.fileAllowlist = ["other.gguf", "projector.gguf"]
        var other = job.files[0]; other.relativePath = "other.gguf"
        let sibling = try BackgroundDownloadJob(owner: siblingOwner, root: job.root(in: home),
            files: [other, job.files[1]], home: home)
        let journal = BackgroundDownloadJournal(url: home.appendingPathComponent("Library/queue.json"), home: home)
        try journal.save([first.id: first, sibling.id: sibling])
        let coordinator = BackgroundDownloadCoordinator(journal: journal, configuration: .ephemeral)
        coordinator.markPaused(matching: first.root(in: home).path, fileAllowlist: firstOwner.fileAllowlist)
        #expect(coordinator.jobs[first.id]?.state == .paused)
        #expect(coordinator.jobs[sibling.id]?.state == .transferring)
        coordinator.abandon(matching: first.root(in: home).path, fileAllowlist: firstOwner.fileAllowlist)
        #expect(coordinator.jobs[first.id] == nil)
        #expect(coordinator.jobs[sibling.id]?.state == .transferring)
        #expect(journal.load()[sibling.id] != nil)
    }
}
