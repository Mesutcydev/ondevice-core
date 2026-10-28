import Foundation
import CryptoKit

/// Only transfers explicitly started by the user enter this journal. It
/// contains pinned public source URLs and sandbox-relative paths, never tokens.
struct BackgroundDownloadOwner: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case hub, coreAI, classifier, image }
    var kind: Kind
    var id: String
    var repoID: String
    var revision: String
    var displayName: String
    var pathPrefix: String? = nil
    var fileAllowlist: [String]? = nil
    var repackEdge035B = false
}

struct BackgroundDownloadFile: Codable, Equatable, Sendable {
    var relativePath: String
    var source: URL
    var expectedBytes: Int64
    var completed = false
}

struct BackgroundDownloadJob: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case transferring, paused, failed, verifying }
    var id: String
    var owner: BackgroundDownloadOwner
    var rootPath: String
    var files: [BackgroundDownloadFile]
    var state: State = .transferring

    static func identifier(root: URL, ownerID: String, fileAllowlist: [String]? = nil,
                           home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        let relative = (try? relativePath(of: root, in: home)) ?? root.standardizedFileURL.path
        let value = relative + "\n" + ownerID + "\n" + (fileAllowlist?.sorted().joined(separator: "\n") ?? "*")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(owner: BackgroundDownloadOwner, root: URL, files: [BackgroundDownloadFile],
         home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        self.id = Self.identifier(root: root, ownerID: owner.id, fileAllowlist: owner.fileAllowlist, home: home)
        self.owner = owner
        self.rootPath = try Self.relativePath(of: root, in: home)
        self.files = files
        try validate(home: home)
    }

    func root(in home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(rootPath, isDirectory: true)
    }

    func destination(for file: BackgroundDownloadFile, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        root(in: home).appendingPathComponent(file.relativePath)
    }

    func validate(home: URL) throws {
        guard Self.safeRelativePath(rootPath),
              rootPath.hasPrefix("Documents/") || rootPath.hasPrefix("Library/"),
              !files.isEmpty, files.count <= 10_000,
              Set(files.map(\.relativePath)).count == files.count,
              owner.repoID.split(separator: "/").count == 2,
              !owner.revision.isEmpty,
              id == Self.identifier(root: root(in: home), ownerID: owner.id,
                                    fileAllowlist: owner.fileAllowlist, home: home)
        else { throw CocoaError(.fileReadCorruptFile) }
        let scope = HFDownloadScope(destination: root(in: home), fileAllowlist: owner.fileAllowlist)
        for file in files {
            guard Self.safeRelativePath(file.relativePath), file.expectedBytes >= 0,
                  file.source.scheme == "https", file.source.host == "huggingface.co",
                  file.source.user == nil, file.source.password == nil, file.source.query == nil,
                  file.source.fragment == nil,
                  file.source.path.hasPrefix("/\(owner.repoID)/resolve/\(owner.revision)/"),
                  scope.contains(path: destination(for: file, home: home).path)
            else { throw CocoaError(.fileReadCorruptFile) }
            // A user-created symlink must not send downloaded bytes outside
            // this model's tree or outside the current sandbox.
            let resolved = destination(for: file, home: home).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root(in: home).resolvingSymlinksInPath().path + "/"),
                  resolved.hasPrefix(home.resolvingSymlinksInPath().path + "/")
            else { throw CocoaError(.fileReadCorruptFile) }
            var cursor = destination(for: file, home: home)
            while cursor.path.hasPrefix(home.standardizedFileURL.path + "/") {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) == nil
                else { throw CocoaError(.fileReadCorruptFile) }
                cursor.deleteLastPathComponent()
            }
        }
    }

    static func fileIsComplete(_ file: BackgroundDownloadFile, at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return false }
        return file.expectedBytes == 0 || size.int64Value == file.expectedBytes
    }

    private static func relativePath(of url: URL, in home: URL) throws -> String {
        let prefix = home.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadCorruptFile) }
        return String(path.dropFirst(prefix.count))
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.contains("\\")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("~") }
    }
}

struct BackgroundDownloadTaskReference: Codable, Sendable {
    let jobID: String
    let relativePath: String

    var description: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init(jobID: String, relativePath: String) { self.jobID = jobID; self.relativePath = relativePath }
    init?(description: String?) {
        guard let description, let data = description.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

struct BackgroundDownloadJournal {
    let url: URL
    let home: URL

    func load() -> [String: BackgroundDownloadJob] {
        guard let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder().decode([BackgroundDownloadJob].self, from: data) else { return [:] }
        var result: [String: BackgroundDownloadJob] = [:]
        for job in jobs where (try? job.validate(home: home)) != nil { result[job.id] = job }
        return result
    }

    func save(_ jobs: [String: BackgroundDownloadJob]) throws {
        if jobs.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs.values.sorted { $0.id < $1.id }).write(to: url, options: .atomic)
    }
}
