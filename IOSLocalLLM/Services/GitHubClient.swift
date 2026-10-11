import Foundation

nonisolated struct GitHubDeviceCode: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int?
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case expiresIn = "expires_in", interval
    }
}
nonisolated enum GitHubDevicePoll: Sendable { case pending, slowDown, authorized(String) }
nonisolated struct GitHubUser: Decodable, Sendable { let id: Int; let login: String }
nonisolated struct GitHubBranch: Decodable, Identifiable, Sendable {
    let name: String
    var id: String { name }
}
nonisolated struct GitHubFile: Sendable { let data: Data; let sha: String; let mode: String }
nonisolated struct GitHubTreeEntry: Decodable, Sendable {
    let path: String
    let type: String
    let mode: String
    let sha: String
    let size: Int?
}
nonisolated struct GitHubTree: Decodable, Sendable {
    let sha: String
    let tree: [GitHubTreeEntry]
    let truncated: Bool?
}
nonisolated struct GitHubCommit: Decodable, Sendable {
    struct Object: Decodable, Sendable { let sha: String }
    let sha: String
    let tree: Object
    let parents: [Object]
    let message: String
}

/// GitHub is the only permitted origin. Never forward tokens on redirects.
nonisolated private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Original Foundation implementation of GitHub's public REST and OAuth device APIs.
/// No cache, cookies, raw error bodies, automatic retries of writes, or credential logging.
nonisolated final class GitHubClient: @unchecked Sendable {
    static let shared = GitHubClient()
    static let maximumFileBytes = 262_144
    static let maximumAttachmentBytes = 1_048_576
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func user(token: String) async throws -> GitHubUser {
        try await decode(GitHubUser.self, segments: ["user"], token: token)
    }

    func repositories(token: String, page: Int) async throws -> [GitHubRepository] {
        try await decode([GitHubRepository].self, segments: ["user", "repos"], token: token,
                         query: ["per_page": "100", "page": String(max(1, page)), "sort": "updated", "affiliation": "owner,collaborator,organization_member"])
    }

    func repository(owner: String, name: String, token: String) async throws -> GitHubRepository {
        guard GitHubValidation.component(owner), GitHubValidation.component(name) else { throw GitHubError.invalidRepository }
        return try await decode(GitHubRepository.self, segments: ["repos", owner, name], token: token)
    }

    func branches(_ selection: GitHubRepositorySelection, token: String, page: Int) async throws -> [GitHubBranch] {
        try await decode([GitHubBranch].self, segments: repo(selection) + ["branches"], token: token,
                         query: ["per_page": "100", "page": String(max(1, page))])
    }

    func head(_ selection: GitHubRepositorySelection, token: String) async throws -> String {
        let object = try await json(segments: repo(selection) + ["git", "ref", "heads"] + selection.branch.components(separatedBy: "/"), token: token)
        guard let ref = object as? [String: Any], let value = ref["object"] as? [String: Any],
              let sha = value["sha"] as? String, GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        return sha
    }

    func commit(_ selection: GitHubRepositorySelection, sha: String, token: String) async throws -> GitHubCommit {
        guard GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        return try await decode(GitHubCommit.self, segments: repo(selection) + ["git", "commits", sha], token: token)
    }

    func tree(_ selection: GitHubRepositorySelection, sha: String, recursive: Bool, token: String) async throws -> GitHubTree {
        guard GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        return try await decode(GitHubTree.self, segments: repo(selection) + ["git", "trees", sha], token: token,
                                query: recursive ? ["recursive": "1"] : [:])
    }

    func contents(_ selection: GitHubRepositorySelection, path: String, ref: String, token: String) async throws -> Any {
        let clean = try GitHubValidation.path(path, allowRoot: true)
        return try await json(segments: repo(selection) + ["contents"] + (clean.isEmpty ? [] : clean.components(separatedBy: "/")),
                              token: token, query: ["ref": ref])
    }

    func file(_ selection: GitHubRepositorySelection, path: String, ref: String, token: String) async throws -> GitHubFile {
        _ = try GitHubValidation.path(path)
        let object = try await contents(selection, path: path, ref: ref, token: token)
        guard let file = object as? [String: Any], file["type"] as? String == "file",
              file["submodule_git_url"] == nil, file["target"] == nil else { throw GitHubError.unsupportedFile }
        guard let size = file["size"] as? Int, size <= Self.maximumFileBytes else { throw GitHubError.tooLarge }
        guard file["encoding"] as? String == "base64", let content = file["content"] as? String,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters), data.count <= Self.maximumFileBytes,
              let sha = file["sha"] as? String, GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        // Contents doesn't expose the executable/symlink mode. Resolve the exact tree
        // entry before staging, in fileMode(), rather than changing it to 100644.
        return GitHubFile(data: data, sha: sha, mode: "100644")
    }

    func fileMode(_ selection: GitHubRepositorySelection, path: String, commitSHA: String, token: String) async throws -> String? {
        let clean = try GitHubValidation.path(path)
        let base = try await commit(selection, sha: commitSHA, token: token)
        var treeSHA = base.tree.sha
        let parts = clean.components(separatedBy: "/")
        for (index, name) in parts.enumerated() {
            let level = try await tree(selection, sha: treeSHA, recursive: false, token: token)
            guard level.truncated != true else { throw GitHubError.tooLarge }
            guard let entry = level.tree.first(where: { $0.path == name }) else { return nil }
            if index == parts.count - 1 {
                guard entry.type == "blob", ["100644", "100755"].contains(entry.mode) else { throw GitHubError.unsupportedFile }
                return entry.mode
            }
            guard entry.type == "tree" else { throw GitHubError.unsupportedFile }
            treeSHA = entry.sha
        }
        return nil
    }

    func log(_ selection: GitHubRepositorySelection, limit: Int, token: String) async throws -> String {
        let object = try await json(segments: repo(selection) + ["commits"], token: token,
                                    query: ["sha": selection.branch, "per_page": String(min(30, max(1, limit)))])
        guard let commits = object as? [[String: Any]] else { throw GitHubError.invalidResponse }
        return commits.map { item in
            let commit = item["commit"] as? [String: Any]
            return "\(String((item["sha"] as? String ?? "").prefix(12))) \(String((commit?["message"] as? String ?? "").prefix(500)))"
        }.joined(separator: "\n")
    }

    func fileHistory(_ selection: GitHubRepositorySelection, path: String, limit: Int, token: String) async throws -> [String] {
        _ = try GitHubValidation.path(path)
        guard (1...10).contains(limit) else { throw GitHubError.tooLarge }
        let object = try await json(segments: repo(selection) + ["commits"], token: token,
            query: ["sha": selection.branch, "path": path, "per_page": String(limit)])
        guard let items = object as? [[String: Any]] else { throw GitHubError.invalidResponse }
        return try items.prefix(limit).map { item in
            guard let sha = item["sha"] as? String, GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
            return sha
        }
    }

    func workflowStatus(_ selection: GitHubRepositorySelection, token: String) async throws -> String {
        let object = try await json(segments: repo(selection) + ["actions", "runs"], token: token,
            query: ["branch": selection.branch, "per_page": "10"])
        guard let data = object as? [String: Any], let runs = data["workflow_runs"] as? [[String: Any]] else { throw GitHubError.invalidResponse }
        return runs.isEmpty ? "No workflow runs on the selected branch." : runs.prefix(10).map { run in
            "\(run["name"] as? String ?? "Workflow"): \(run["status"] as? String ?? "unknown") · \(run["conclusion"] as? String ?? "pending") · \(String((run["head_sha"] as? String ?? "").prefix(12)))"
        }.joined(separator: "\n")
    }

    func diff(_ selection: GitHubRepositorySelection, base: String, head: String, token: String) async throws -> String {
        guard GitHubValidation.branch(base) || GitHubValidation.sha(base), GitHubValidation.branch(head) || GitHubValidation.sha(head) else {
            throw GitHubError.invalidBranch
        }
        let object = try await json(segments: repo(selection) + ["compare", "\(base)...\(head)"], token: token,
                                    query: ["per_page": "30"])
        guard let compare = object as? [String: Any], let files = compare["files"] as? [[String: Any]] else { throw GitHubError.invalidResponse }
        return files.prefix(30).map {
            "\($0["status"] as? String ?? "changed") \($0["filename"] as? String ?? "")\n\(String(($0["patch"] as? String ?? "[binary or patch unavailable]").prefix(4_000)))"
        }.joined(separator: "\n\n") + "\nShowing up to 30 files; patches may be truncated."
    }

    func checks(_ selection: GitHubRepositorySelection, sha: String, token: String) async throws -> String {
        guard GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        let object = try await json(segments: repo(selection) + ["commits", sha, "check-runs"], token: token, query: ["per_page": "30"])
        guard let result = object as? [String: Any], let checks = result["check_runs"] as? [[String: Any]] else { throw GitHubError.invalidResponse }
        return checks.isEmpty ? "No check runs for this commit." : checks.prefix(30).map {
            "\($0["name"] as? String ?? "Check"): \($0["status"] as? String ?? "unknown") · \($0["conclusion"] as? String ?? "pending")"
        }.joined(separator: "\n")
    }

    /// The server's search index may lag and searches its default branch.
    /// Scope qualifiers supplied by a model are rejected to prevent escaping the selection.
    func search(_ selection: GitHubRepositorySelection, query: String, token: String) async throws -> String {
        guard !query.isEmpty, query.count <= 300,
              !query.contains(":"), !query.contains("\n") else { throw GitHubError.invalidPath }
        let object = try await json(segments: ["search", "code"], token: token,
                                    query: ["q": "\(query) repo:\(selection.fullName)", "per_page": "30"])
        guard let result = object as? [String: Any], let items = result["items"] as? [[String: Any]] else { throw GitHubError.invalidResponse }
        let paths = items.compactMap { item -> String? in
            guard let repo = item["repository"] as? [String: Any],
                  (repo["full_name"] as? String)?.lowercased() == selection.fullName.lowercased() else { return nil }
            return item["path"] as? String
        }
        return "Search index uses the repository's default branch. Read matching files on the selected branch to verify.\n"
            + (paths.isEmpty ? "No matches." : paths.joined(separator: "\n"))
    }

    /// One commit for the entire reviewed draft. No force-push and no file-by-file commits.
    func commitChanges(_ plan: GitHubReviewPlan, message: String, token: String,
                       validate: @escaping @Sendable () async throws -> Void) async throws -> String {
        let selection = plan.draft.selection
        try await validate()
        guard try await head(selection, token: token) == plan.expectedSHA else { throw GitHubError.conflict }
        let base = try await commit(selection, sha: plan.expectedSHA, token: token)
        var entries: [[String: Any]] = []
        for change in plan.draft.changes {
            try await validate()
            _ = try GitHubValidation.path(change.path)
            var entry: [String: Any] = ["path": change.path, "type": "blob", "mode": change.mode]
            if let data = change.updated {
                let blob = try await objectSHA(segments: repo(selection) + ["git", "blobs"], token: token,
                                               body: ["content": data.base64EncodedString(), "encoding": "base64"])
                entry["sha"] = blob
            } else { entry["sha"] = NSNull() }
            entries.append(entry)
        }
        try await validate()
        let treeSHA = try await objectSHA(segments: repo(selection) + ["git", "trees"], token: token,
                                          body: ["base_tree": base.tree.sha, "tree": entries])
        return try await advance(selection, treeSHA: treeSHA, expectedSHA: plan.expectedSHA, message: message,
                                 token: token, validate: validate)
    }

    func advance(_ selection: GitHubRepositorySelection, treeSHA: String, expectedSHA: String, message: String,
                 token: String, validate: @escaping @Sendable () async throws -> Void) async throws -> String {
        try await validate()
        guard try await head(selection, token: token) == expectedSHA else { throw GitHubError.conflict }
        let sha = try await objectSHA(segments: repo(selection) + ["git", "commits"], token: token,
                                      body: ["message": message, "tree": treeSHA, "parents": [expectedSHA]])
        try await validate()
        // A concurrent branch advance becomes a non-fast-forward rejection.
        _ = try await json(method: "PATCH", segments: repo(selection) + ["git", "refs", "heads"] + selection.branch.components(separatedBy: "/"),
                           token: token, body: ["sha": sha, "force": false])
        return sha
    }

    func createBranch(_ selection: GitHubRepositorySelection, name: String, expectedSHA: String, token: String) async throws {
        guard GitHubValidation.branch(name) else { throw GitHubError.invalidBranch }
        guard try await head(selection, token: token) == expectedSHA else { throw GitHubError.conflict }
        try Task.checkCancellation()
        _ = try await json(method: "POST", segments: repo(selection) + ["git", "refs"], token: token,
                           body: ["ref": "refs/heads/\(name)", "sha": expectedSHA])
    }

    func pullRequest(_ selection: GitHubRepositorySelection, title: String, base: String, body: String,
                     expectedSHA: String, token: String) async throws -> URL {
        guard GitHubValidation.branch(base), base != selection.branch else { throw GitHubError.invalidBranch }
        guard try await head(selection, token: token) == expectedSHA else { throw GitHubError.conflict }
        try Task.checkCancellation()
        let result = try await json(method: "POST", segments: repo(selection) + ["pulls"], token: token,
                                    body: ["title": title, "head": selection.branch, "base": base, "body": body])
        guard let object = result as? [String: Any], let value = object["html_url"] as? String,
              let url = URL(string: value), url.scheme == "https", url.host == "github.com" else { throw GitHubError.invalidResponse }
        return url
    }

    func startDeviceSignIn(clientID: String) async throws -> GitHubDeviceCode {
        let data = try await request(host: "github.com", method: "POST", segments: ["login", "device", "code"], token: nil,
                                     body: ["client_id": clientID, "scope": "repo"])
        guard let code = try? JSONDecoder().decode(GitHubDeviceCode.self, from: data),
              code.verificationURI.scheme == "https", code.verificationURI.host == "github.com",
              code.verificationURI.path == "/login/device", !code.deviceCode.isEmpty, !code.userCode.isEmpty,
              (1...1_800).contains(code.expiresIn) else { throw GitHubError.invalidClient }
        return code
    }

    func pollDeviceSignIn(clientID: String, deviceCode: String) async throws -> GitHubDevicePoll {
        let data = try await request(host: "github.com", method: "POST", segments: ["login", "oauth", "access_token"], token: nil,
                                     body: ["client_id": clientID, "device_code": deviceCode,
                                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.invalidResponse }
        if let token = object["access_token"] as? String, GitHubValidation.token(token) { return .authorized(token) }
        switch object["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": throw GitHubError.deviceExpired
        case "access_denied": throw GitHubError.deviceDenied
        default: throw GitHubError.invalidClient
        }
    }

    private func repo(_ selection: GitHubRepositorySelection) throws -> [String] {
        _ = try selection.validated()
        return ["repos", selection.owner, selection.name]
    }
    private func decode<T: Decodable>(_ type: T.Type, segments: [String], token: String, query: [String: String] = [:]) async throws -> T {
        let data = try await request(segments: segments, token: token, query: query)
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw GitHubError.invalidResponse }
        return value
    }
    private func json(method: String = "GET", segments: [String], token: String,
                      query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Any {
        let data = try await request(method: method, segments: segments, token: token, query: query, body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw GitHubError.invalidResponse }
        return object
    }
    private func objectSHA(segments: [String], token: String, body: [String: Any]) async throws -> String {
        let object = try await json(method: "POST", segments: segments, token: token, body: body)
        guard let value = object as? [String: Any], let sha = value["sha"] as? String, GitHubValidation.sha(sha) else { throw GitHubError.invalidResponse }
        return sha
    }
    private func request(host: String = "api.github.com", method: String = "GET", segments: [String], token: String?,
                         query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard ["api.github.com", "github.com"].contains(host), token == nil || host == "api.github.com" else { throw GitHubError.invalidRepository }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        var components = URLComponents()
        components.scheme = "https"; components.host = host
        components.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw GitHubError.invalidRepository }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OnDeviceMax", forHTTPHeaderField: "User-Agent")
        if host == "api.github.com" { request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version") }
        else { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        if let token {
            guard GitHubValidation.token(token) else { throw GitHubError.invalidCredential }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let activity = host == "github.com" ? "GitHub sign-in" : "GitHub tools"
        await NetworkActivityMonitor.shared.begin(label: activity)
        defer { Task { @MainActor in NetworkActivityMonitor.shared.end(label: activity) } }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 401: throw GitHubError.invalidCredential
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0": throw GitHubError.rateLimited
        case 403: throw GitHubError.permission
        case 404: throw GitHubError.notFound
        case 409, 422: throw GitHubError.conflict
        case 429: throw GitHubError.rateLimited
        default: throw GitHubError.connection
        }
        var data = Data()
        let limit = 8 * 1_024 * 1_024
        if response.expectedContentLength > Int64(limit) { throw GitHubError.tooLarge }
        for try await byte in bytes {
            if data.count >= limit { throw GitHubError.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }
}
