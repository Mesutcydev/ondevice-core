import Foundation
import CryptoKit
import Network

// MARK: - BackgroundDownloadCoordinator
// Shared URLSession with background configuration so model downloads continue
// when the app is suspended. Each file download is registered with a UUID
// key and routed back to its async continuation when finished.
//
// Architecture:
//   • One singleton URLSession created with .background(withIdentifier:)
//   • Map: URLSessionDownloadTask.taskIdentifier → continuation + destination
//   • Delegate methods translate progress callbacks back to per-task closures
//
// When iOS relaunches the app for background-session events, AppDelegate
// calls reattach() so the (lazy) session is re-created and its delegate
// receives the queued events; each task's destination is recovered from
// taskDescription since the in-memory Pending map didn't survive.

@MainActor
final class BackgroundDownloadCoordinator: NSObject {

    static let shared = BackgroundDownloadCoordinator()
    static let sessionIdentifier = "com.token.TokenAI.background-downloads"

    private let journal: BackgroundDownloadJournal
    private var suppliedConfiguration: URLSessionConfiguration?
    private(set) var jobs: [String: BackgroundDownloadJob]
    private var cancelledJobs: [String: BackgroundDownloadJob] = [:]
    private var queuedTasks: [String: URLSessionDownloadTask] = [:]
    private var completedTransfers: [String: Result<URL, Error>] = [:]
    private var receivedBytes: [String: Int64] = [:]
    private var responseSizes: [String: Int64] = [:]
    private var progressObservers: [String: (BackgroundDownloadProgress) -> Void] = [:]

    private override init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        journal = BackgroundDownloadJournal(
            url: home.appendingPathComponent("Library/Application Support/BackgroundDownloads/queue.json"), home: home)
        jobs = journal.load()
        super.init()
    }

    init(journal: BackgroundDownloadJournal, configuration: URLSessionConfiguration) {
        self.journal = journal
        self.jobs = journal.load()
        self.suppliedConfiguration = configuration
        super.init()
    }

    struct BackgroundDownloadProgress {
        let fraction: Double
        let downloadedBytes: Int64
        let totalBytes: Int64
        let filesDone: Int
        let filesTotal: Int
        let currentFile: String
    }

    /// Commit the complete batch before handing every pending file to iOS.
    /// Consumers still validate files and install models through their existing
    /// managers; the OS queue doesn't depend on those Swift tasks staying alive.
    func enqueue(_ job: BackgroundDownloadJob,
                 progress: @escaping (BackgroundDownloadProgress) -> Void) async throws {
        try job.validate(home: journal.home)
        try Task.checkCancellation()
        let existingTasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        var recorded = job
        for index in recorded.files.indices {
            let file = recorded.files[index]
            recorded.files[index].completed = BackgroundDownloadJob.fileIsComplete(file, at: recorded.destination(for: file, home: journal.home))
        }
        recorded.state = recorded.files.allSatisfy(\.completed) ? .verifying : .transferring
        jobs[job.id] = recorded
        do { try journal.save(jobs) } catch { jobs.removeValue(forKey: job.id); throw error }
        FileManager.excludeFromBackup(journal.url.deletingLastPathComponent())
        progressObservers[job.id] = progress
        _ = DownloadLiveActivityManager.shared.start(repoID: job.id, displayName: job.owner.displayName)
        for file in recorded.files where !file.completed {
            let destination = recorded.destination(for: file, home: journal.home)
            let key = transferKey(path: destination.path, jobID: job.id)
            if let task = existingTasks.first(where: {
                $0.state != .canceling && $0.state != .completed
                    && taskDestination($0)?.standardizedFileURL == destination.standardizedFileURL
                    && $0.originalRequest?.url == file.source
                    && (BackgroundDownloadTaskReference(description: $0.taskDescription)?.jobID == job.id
                        || BackgroundDownloadTaskReference(description: $0.taskDescription) == nil)
            }) as? URLSessionDownloadTask {
                queuedTasks[key] = task
                if pendingByTaskID[task.taskIdentifier] == nil {
                    pendingByTaskID[task.taskIdentifier] = Pending(destination: destination,
                        expectedSize: file.expectedBytes, progress: { _, _ in }, continuation: nil)
                }
                task.taskDescription = BackgroundDownloadTaskReference(jobID: job.id, relativePath: file.relativePath).description
                task.resume()
            } else if queuedTasks[key] == nil {
                completedTransfers.removeValue(forKey: key)
                let task = try makeTask(from: file.source, to: destination, expectedSize: file.expectedBytes)
                task.taskDescription = BackgroundDownloadTaskReference(jobID: job.id, relativePath: file.relativePath).description
                queuedTasks[key] = task
                task.resume()
            }
        }
        publishProgress(jobID: job.id)
    }

    func markPaused(matching root: String, fileAllowlist: [String]? = nil) {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: root), fileAllowlist: fileAllowlist)
        for id in matchingJobs(scope) { jobs[id]?.state = .paused; progressObservers.removeValue(forKey: id) }
        persistJournal()
    }

    /// Remove durable ownership before cancelling writers, so a relaunch or
    /// late completion cannot reconstruct a download the user abandoned.
    func abandon(matching root: String, fileAllowlist: [String]? = nil) {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: root), fileAllowlist: fileAllowlist)
        for id in matchingJobs(scope) {
            cancelledJobs[id] = jobs.removeValue(forKey: id); progressObservers.removeValue(forKey: id)
            DownloadLiveActivityManager.shared.cancel(repoID: id)
        }
        for (id, pending) in pendingByTaskID where scope.contains(path: pending.destination.path) {
            let task = queuedTasks.values.first { $0.taskIdentifier == id }
            if task.map({ taskMatches($0, scope: scope) }) ?? true { abandonedTaskIDs.insert(id) }
        }
        for key in Array(completedTransfers.keys) {
            let path = String(key.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            if scope.contains(path: path) { completedTransfers.removeValue(forKey: key) }
        }
        persistJournal()
    }

    func finish(jobID: String) {
        jobs.removeValue(forKey: jobID); progressObservers.removeValue(forKey: jobID)
        persistJournal()
        DownloadLiveActivityManager.shared.finish(repoID: jobID)
    }

    func fail(jobID: String) {
        jobs[jobID]?.state = .failed; progressObservers.removeValue(forKey: jobID)
        persistJournal()
        DownloadLiveActivityManager.shared.fail(repoID: jobID, reason: "Open Downloads to retry")
    }

    func restoreSession() async {
        reattach()
        let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        for id in Array(jobs.keys) {
            guard var job = jobs[id] else { continue }
            for index in job.files.indices {
                job.files[index].completed = BackgroundDownloadJob.fileIsComplete(job.files[index], at: job.destination(for: job.files[index], home: journal.home))
            }
            if job.state == .transferring {
                if job.files.allSatisfy(\.completed) { job.state = .verifying }
                else if !tasks.contains(where: { BackgroundDownloadTaskReference(description: $0.taskDescription)?.jobID == id }) {
                    // Force quitting / OS cancellation requires a visible Retry.
                    job.state = .failed
                }
            }
            jobs[id] = job
            publishProgress(jobID: id)
        }
        persistJournal()
    }

    private func matches(_ job: BackgroundDownloadJob, scope: HFDownloadScope) -> Bool {
        if job.root(in: journal.home).standardizedFileURL == scope.destination.standardizedFileURL,
           let rules = scope.fileAllowlist {
            return job.owner.fileAllowlist?.sorted() == rules.sorted()
        }
        return job.files.contains { scope.contains(path: job.destination(for: $0, home: journal.home).path) }
    }

    private func matchingJobs(_ scope: HFDownloadScope) -> [String] {
        jobs.values.filter { matches($0, scope: scope) }.map(\.id)
    }

    private func taskMatches(_ task: URLSessionTask, scope: HFDownloadScope) -> Bool {
        if let reference = BackgroundDownloadTaskReference(description: task.taskDescription),
           let job = jobs[reference.jobID] ?? cancelledJobs[reference.jobID] { return matches(job, scope: scope) }
        return taskDestination(task).map { scope.contains(path: $0.path) } == true
    }

    private func transferKey(path: String, jobID: String?) -> String { (jobID ?? "") + "\n" + path }


    private func persistJournal() {
        do { try journal.save(jobs) }
        catch { Diagnostics.shared.error("Could not save background download state", category: "hf-download") }
    }

    private func taskDestination(_ task: URLSessionTask) -> URL? {
        if let pending = pendingByTaskID[task.taskIdentifier] { return pending.destination }
        if let reference = BackgroundDownloadTaskReference(description: task.taskDescription),
           let job = jobs[reference.jobID] ?? cancelledJobs[reference.jobID], let file = job.files.first(where: { $0.relativePath == reference.relativePath }) {
            return job.destination(for: file, home: journal.home)
        }
        // Legacy tasks used an absolute path, before the durable batch journal.
        guard let path = task.taskDescription, path.hasPrefix(journal.home.path + "/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func publishProgress(jobID: String, currentFile: String = "") {
        guard let job = jobs[jobID] else { return }
        var done = 0, downloaded: Int64 = 0, total: Int64 = 0
        for file in job.files {
            let key = job.destination(for: file, home: journal.home).path
            let expected = max(file.expectedBytes, responseSizes[key] ?? 0)
            total += expected
            if file.completed { done += 1; downloaded += expected }
            else { downloaded += min(max(0, receivedBytes[key] ?? 0), expected > 0 ? expected : Int64.max) }
        }
        let fraction = min(0.99, total > 0 ? Double(downloaded) / Double(total) : Double(done) / Double(job.files.count))
        progressObservers[jobID]?(.init(fraction: fraction, downloadedBytes: downloaded, totalBytes: total,
                                      filesDone: done, filesTotal: job.files.count, currentFile: currentFile))
        switch job.state {
        case .transferring, .verifying:
            DownloadLiveActivityManager.shared.update(repoID: jobID, progress: fraction,
                downloadedBytes: downloaded, totalBytes: total,
                currentFile: job.state == .verifying ? "Open app to finish" : currentFile,
                filesDone: done, filesTotal: job.files.count,
                phase: job.state == .verifying ? .verifying : .downloading)
        case .paused: DownloadLiveActivityManager.shared.pause(repoID: jobID)
        case .failed: DownloadLiveActivityManager.shared.fail(repoID: jobID, reason: "Open Downloads to retry")
        }
    }

    private func completeTransfer(taskID: Int, reference: BackgroundDownloadTaskReference?,
                                  pending: Pending?, result: Result<URL, Error>) {
        let key = pending.map { transferKey(path: $0.destination.path, jobID: reference?.jobID) }
        if let key { queuedTasks.removeValue(forKey: key) }
        if let reference, var job = jobs[reference.jobID],
           let index = job.files.firstIndex(where: { $0.relativePath == reference.relativePath }) {
            switch result {
            case .success:
                job.files[index].completed = true
                if job.state == .transferring && job.files.allSatisfy(\.completed) { job.state = .verifying }
            case .failure(let error):
                let ns = error as NSError
                if progressObservers[job.id] == nil && !(error is CancellationError) && ns.code != NSURLErrorCancelled { job.state = .failed }
            }
            jobs[job.id] = job; persistJournal(); publishProgress(jobID: job.id, currentFile: reference.relativePath)
        }
        if let continuation = pending?.continuation { continuation.resume(with: result) }
        else if let key { completedTransfers[key] = result }
    }


    // Public completion handler hook used by AppDelegate when iOS wakes us up
    // to deliver finished events. ContentView/App can wire this if needed.
    var systemCompletionHandler: (() -> Void)?

    // MARK: - URLSession

    private lazy var session: URLSession = {
        let cfg = suppliedConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.httpMaximumConnectionsPerHost = 2
        // "Wi-Fi only downloads" setting (Settings → Models). The config is
        // frozen at session creation, so download() ALSO enforces it
        // per-task at enqueue time — this just covers tasks the system
        // restores across relaunches.
        let wifiOnly = AppSettings.shared.wifiOnlyDownloads
        cfg.allowsCellularAccess = !wifiOnly
        cfg.allowsExpensiveNetworkAccess = !wifiOnly
        cfg.waitsForConnectivity = true
        // didFinishDownloadingTo must move/copy the temporary file before its
        // callback returns. A cross-volume fallback can copy several GB; on
        // the main queue that blocks UI and can trigger the iOS watchdog at
        // 100%. Keep callbacks serial, but perform file finalization off-main.
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.token.TokenAI.download-finalization"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }()

    /// Watches the current network path so enqueue-time checks can tell
    /// whether we're on an expensive (cellular / hotspot) link.
    private let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.token.TokenAI.download-path-monitor"))
        return monitor
    }()

    /// Re-creates the background URLSession after iOS relaunches the app to
    /// deliver background-session events. The session is `lazy`, so without
    /// touching it here the delegate was never attached on relaunch and the
    /// queued events were silently dropped.
    func reattach() { _ = session }

    // MARK: - Per-task tracking

    private struct Pending {
        let destination: URL
        let expectedSize: Int64
        var progress: (Int64, Int64) -> Void
        var continuation: CheckedContinuation<URL, Error>?
    }
    private var pendingByTaskID: [Int: Pending] = [:]
    private var abandonedTaskIDs: Set<Int> = []

    // MARK: - Public API

    /// Downloads `url` to `destination` and reports progress. Survives app
    /// backgrounding. Returns the final destination URL.
    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        jobID: String? = nil,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let key = transferKey(path: destination.path, jobID: jobID)
        if let result = completedTransfers.removeValue(forKey: key) { return try result.get() }
        let task: URLSessionDownloadTask
        if let queued = queuedTasks[key], queued.state != .canceling, queued.state != .completed {
            task = queued
        } else {
            task = try makeTask(from: url, to: destination, expectedSize: expectedSize)
            queuedTasks[key] = task
            if let job = jobID.flatMap({ jobs[$0] }) ?? jobs.values.first(where: { job in job.files.contains { job.destination(for: $0, home: self.journal.home) == destination } }),
               let file = job.files.first(where: { job.destination(for: $0, home: self.journal.home) == destination }) {
                task.taskDescription = BackgroundDownloadTaskReference(jobID: job.id, relativePath: file.relativePath).description
                jobs[job.id]?.state = .transferring
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingByTaskID[task.taskIdentifier] = Pending(destination: destination, expectedSize: expectedSize,
                                                              progress: progress, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func makeTask(from url: URL, to destination: URL, expectedSize: Int64) throws -> URLSessionDownloadTask {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let host = url.host?.lowercased(), host == "huggingface.co" || host.hasSuffix(".huggingface.co") {
            HFTokenStore.authorize(&request)
        }
        if AppSettings.shared.wifiOnlyDownloads {
            request.allowsCellularAccess = false; request.allowsExpensiveNetworkAccess = false
            if pathMonitor.currentPath.isExpensive {
                throw NSError(domain: "HFDownload", code: -5, userInfo: [NSLocalizedDescriptionKey:
                    "Wi-Fi only downloads is on. Connect to Wi-Fi or turn the setting off in Settings → Models."])
            }
        }
        let task: URLSessionDownloadTask
        if request.value(forHTTPHeaderField: "Authorization") == nil, let data = Self.consumeResumeData(for: url) {
            task = session.downloadTask(withResumeData: data)
        } else {
            Self.clearResumeData(for: url)
            task = session.downloadTask(with: request)
        }
        task.taskDescription = destination.path
        pendingByTaskID[task.taskIdentifier] = Pending(destination: destination, expectedSize: expectedSize,
                                                    progress: { _, _ in }, continuation: nil)
        task.countOfBytesClientExpectsToReceive = expectedSize > 0 ? expectedSize : NSURLSessionTransferSizeUnknown
        return task
    }

    // MARK: - Resume data persistence
    //
    // URLSession hands back opaque resume data when a download task fails
    // (didCompleteWithError → NSURLSessionDownloadTaskResumeData). It's
    // persisted to a temp sidecar keyed by a hash of the source URL, and
    // consumed by the next download() for the same URL.

    private nonisolated static func resumeDataSidecar(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-resume-\(name).dat")
    }

    nonisolated static func storeResumeData(_ data: Data, for url: URL?) {
        guard let url else { return }
        try? data.write(to: resumeDataSidecar(for: url), options: [.atomic])
    }

    /// Returns persisted resume data for `url` (deleting the sidecar — it's
    /// single-use either way: consumed by the new task or invalid).
    nonisolated static func consumeResumeData(for url: URL) -> Data? {
        let sidecar = resumeDataSidecar(for: url)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        try? FileManager.default.removeItem(at: sidecar)
        return data
    }

    nonisolated static func clearResumeData(for url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: resumeDataSidecar(for: url))
    }

    /// Total bytes held by abandoned URLSession resume sidecars. These are
    /// useful for retrying a failed transfer, but once the user explicitly
    /// chooses storage cleanup they should not remain as invisible cache.
    nonisolated static func staleResumeDataBytes() -> Int64 {
        resumeDataSidecars().reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }

    /// Removes every persisted HF resume sidecar and returns bytes reclaimed.
    /// Active downloads do not have resume sidecars; the files are written only
    /// after URLSession reports an interrupted task.
    @discardableResult
    nonisolated static func clearAllResumeData() -> Int64 {
        let sidecars = resumeDataSidecars()
        let bytes = sidecars.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
        for url in sidecars { try? FileManager.default.removeItem(at: url) }
        return bytes
    }

    private nonisolated static func resumeDataSidecars() -> [URL] {
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            $0.lastPathComponent.hasPrefix("hf-resume-") && $0.pathExtension == "dat"
        }
    }

    /// Cancels every in-flight download.
    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// Cancels in-flight tasks whose pending destination path begins with the
    /// given root. Used to abort one repo's downloads without stomping others.
    func cancelTasks(matching destinationPrefix: String, fileAllowlist: [String]? = nil) async {
        abandon(matching: destinationPrefix, fileAllowlist: fileAllowlist)
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: destinationPrefix), fileAllowlist: fileAllowlist)
        let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        for task in tasks {
            guard taskMatches(task, scope: scope) else { continue }
            abandonedTaskIDs.insert(task.taskIdentifier)
            Self.clearResumeData(for: task.originalRequest?.url ?? task.currentRequest?.url)
            if let download = task as? URLSessionDownloadTask {
                await withCheckedContinuation { continuation in
                    download.cancel(byProducingResumeData: { _ in continuation.resume() })
                }
            } else {
                task.cancel()
            }
        }
        // A restored task has no Swift continuation to await. Drain a file
        // finalization already on the serial delegate queue before deleting
        // its directory; later callbacks observe abandonedTaskIDs instead.
        await withCheckedContinuation { continuation in
            session.delegateQueue.addBarrierBlock { continuation.resume() }
        }
    }

    /// Stop matching transfers while retaining URLSession resume data. The
    /// callback is awaited before a new transfer can consume its sidecar.
    func pauseTasks(matching destinationPrefix: String, fileAllowlist: [String]? = nil) async {
        let scope = HFDownloadScope(destination: URL(fileURLWithPath: destinationPrefix), fileAllowlist: fileAllowlist)
        markPaused(matching: destinationPrefix, fileAllowlist: fileAllowlist)
        let allTasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        let matchingIDs = Set(allTasks.compactMap { task -> Int? in
            return taskMatches(task, scope: scope) ? task.taskIdentifier : nil
        })

        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let group = DispatchGroup()
                for case let task as URLSessionDownloadTask in tasks
                    where matchingIDs.contains(task.taskIdentifier) {
                    group.enter()
                    let url = task.originalRequest?.url ?? task.currentRequest?.url
                    task.cancel(byProducingResumeData: { resumeData in
                        if let resumeData {
                            Self.storeResumeData(resumeData, for: url)
                        }
                        group.leave()
                    })
                }
                group.notify(queue: .main) { continuation.resume() }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadCoordinator: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        let reference = BackgroundDownloadTaskReference(description: downloadTask.taskDescription)
        let fm = FileManager.default

        // CRITICAL: URLSession deletes `location` the moment this delegate
        // method returns. The move MUST happen synchronously here — not
        // dispatched to MainActor — otherwise the temp file vanishes first.
        let response = downloadTask.response as? HTTPURLResponse
        let statusCode = response?.statusCode ?? 0
        let urlPath = downloadTask.originalRequest?.url?.path ?? "<unknown>"

        // Only the tiny pending-map operation crosses to MainActor. The file
        // move/copy below stays on the dedicated delegate queue.
        let pending: Pending?
        let abandoned: Bool
        if Thread.isMainThread {
            (pending, abandoned) = MainActor.assumeIsolated {
                (self.pendingByTaskID.removeValue(forKey: taskID), self.abandonedTaskIDs.contains(taskID) || (reference.map { self.jobs[$0.jobID] == nil } ?? false))
            }
        } else {
            (pending, abandoned) = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    (self.pendingByTaskID.removeValue(forKey: taskID), self.abandonedTaskIDs.contains(taskID) || (reference.map { self.jobs[$0.jobID] == nil } ?? false))
                }
            }
        }
        let finish: (Result<URL, Error>) -> Void = { result in
            Task { @MainActor in self.completeTransfer(taskID: taskID, reference: reference, pending: pending, result: result) }
        }
        if abandoned {
            try? fm.removeItem(at: location)
            Self.clearResumeData(for: downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url)
            finish(.failure(CancellationError()))
            return
        }
        // After an app relaunch the in-memory Pending map is gone, but the
        // destination was stored on the task itself (taskDescription) at
        // enqueue time — recover it so the completed bytes are kept instead
        // of deleted. Only delete when even that is absent.
        let destination: URL
        if let p = pending {
            destination = p.destination
        } else if let reference,
                  let recovered = DispatchQueue.main.sync(execute: {
                      MainActor.assumeIsolated { self.jobs[reference.jobID].flatMap { job in
                          job.files.first(where: { $0.relativePath == reference.relativePath }).map { job.destination(for: $0, home: self.journal.home) }
                      } }
                  }) {
            destination = recovered
        } else if let path = downloadTask.taskDescription, path.hasPrefix(NSHomeDirectory() + "/") {
            destination = URL(fileURLWithPath: path)
        } else {
            try? fm.removeItem(at: location)
            return
        }

        // Validate HTTP status — URLSession "succeeds" even on 4xx/5xx,
        // writing the error body to the temp file as if it were the asset.
        if let response, !(200...299).contains(statusCode) {
            try? fm.removeItem(at: location)
            let reason: String
            switch statusCode {
            case 404: reason = "File not found (404): \(urlPath)"
            case 401: reason = "Login required (401): \(urlPath)"
            case 403: reason = "Access denied (403): \(urlPath)"
            case 429: reason = "Rate limited (429). Try again in a minute."
            default:  reason = "HTTP \(statusCode) for \(urlPath)"
            }
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: reason]
            // Thread the server's pacing hint through to the retry helper
            // so 429/503 backoff can honor it.
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
                userInfo["Retry-After"] = retryAfter
            }
            finish(.failure(NSError(domain: "HFDownload", code: statusCode, userInfo: userInfo)))
            return
        }

        // Perform the move SYNCHRONOUSLY. If we fail, copy as a fallback.
        do {
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            do {
                try fm.moveItem(at: location, to: destination)
            } catch {
                // Cross-volume or sandbox issue — fall back to copy. Copy
                // into a .tmp sidecar then rename so a mid-copy crash can't
                // leave a half-written file at the final path. If even the
                // rename is rejected, a plain direct copy is the last resort.
                Diagnostics.shared.breadcrumb(
                    "Finalizing downloaded file via copy fallback",
                    category: "hf-download"
                )
                let tmp = URL(fileURLWithPath: destination.path + ".tmp")
                try? fm.removeItem(at: tmp)
                do {
                    try fm.copyItem(at: location, to: tmp)
                    try fm.moveItem(at: tmp, to: destination)
                } catch {
                    try? fm.removeItem(at: tmp)
                    try fm.copyItem(at: location, to: destination)
                }
                try? fm.removeItem(at: location)
            }
            // Weights are re-downloadable — keep them out of iCloud backups.
            FileManager.excludeFromBackup(destination)
            // The transfer finished — any stale resume data for this URL is
            // now useless.
            Diagnostics.shared.breadcrumb("Downloaded file finalized", category: "hf-download")
            Self.clearResumeData(for: downloadTask.originalRequest?.url
                                       ?? downloadTask.currentRequest?.url)
            finish(.success(destination))
        } catch {
            // One repair attempt before giving up: an older install (or a
            // bundled-model copy) can leave the destination chain read-only
            // (Cocoa 513). Re-chmod the parent chain and retry the move
            // once — the completed temp file is still right there.
            var cursor = destination.deletingLastPathComponent()
            for _ in 0..<3 {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursor.path)
                cursor = cursor.deletingLastPathComponent()
            }
            do {
                try fm.moveItem(at: location, to: destination)
                FileManager.excludeFromBackup(destination)
                Self.clearResumeData(for: downloadTask.originalRequest?.url
                                           ?? downloadTask.currentRequest?.url)
                finish(.success(destination))
                return
            } catch {
                // Fall through to the wrapped failure below.
            }
            try? fm.removeItem(at: location)
            // Wrap the raw Cocoa error with the target folder and a remedy —
            // the bare "You don't have permission to save the file" gave the
            // user nothing to act on.
            let folder = destination.deletingLastPathComponent().lastPathComponent
            let wrapped = NSError(domain: "HFDownload", code: -7, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't save the downloaded file into \(folder) (\(error.localizedDescription)). Restart the app and retry; if it persists, check free device storage."
            ])
            finish(.failure(wrapped))
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let taskID = downloadTask.taskIdentifier
        let reference = BackgroundDownloadTaskReference(description: downloadTask.taskDescription)
        Task { @MainActor [weak self] in
            guard let self, !abandonedTaskIDs.contains(taskID) else { return }
            let pending = pendingByTaskID[taskID]
            pending?.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : pending?.expectedSize ?? 0)
            if let reference, let job = jobs[reference.jobID],
               let file = job.files.first(where: { $0.relativePath == reference.relativePath }) {
                let key = job.destination(for: file, home: journal.home).path
                receivedBytes[key] = totalBytesWritten
                responseSizes[key] = max(0, totalBytesExpectedToWrite)
                publishProgress(jobID: job.id, currentFile: file.relativePath)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        let reference = BackgroundDownloadTaskReference(description: task.taskDescription)
        let completion: (Pending?, Bool)
        if Thread.isMainThread {
            completion = MainActor.assumeIsolated {
                (self.pendingByTaskID.removeValue(forKey: taskID), self.abandonedTaskIDs.remove(taskID) != nil || (reference.map { self.jobs[$0.jobID] == nil } ?? false))
            }
        } else {
            completion = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    (self.pendingByTaskID.removeValue(forKey: taskID), self.abandonedTaskIDs.remove(taskID) != nil || (reference.map { self.jobs[$0.jobID] == nil } ?? false))
                }
            }
        }
        if completion.1 {
            Self.clearResumeData(for: task.originalRequest?.url ?? task.currentRequest?.url)
            Task { @MainActor in self.completeTransfer(taskID: taskID, reference: reference,
                pending: completion.0, result: .failure(CancellationError())) }
            return
        }
        guard let error else { return }   // success path handled in didFinishDownloadingTo
        // Persist URLSession's resume data so the next attempt for this URL
        // continues where the transfer broke instead of restarting at byte 0.
        if let resumeData = (error as NSError)
            .userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Self.storeResumeData(resumeData,
                                 for: task.originalRequest?.url ?? task.currentRequest?.url)
        }
        Task { @MainActor in self.completeTransfer(taskID: taskID, reference: reference,
            pending: completion.0, result: .failure(error)) }
    }

    // Called when all background events have been delivered after a re-launch.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.systemCompletionHandler?()
            self?.systemCompletionHandler = nil
        }
    }
}
