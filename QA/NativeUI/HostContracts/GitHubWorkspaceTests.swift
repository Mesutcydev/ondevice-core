import XCTest
import CryptoKit
@testable import NativeUIReview

@MainActor
final class GitHubWorkspaceTests: XCTestCase {
    private func assertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    private let token = "test-github-only-not-model"
    private let secretFixture = "https://panel.invalid/get.php?username=fixture-user-823&password=fixture-pass-916\nUsername fixture-user-823\nPassword fixture-pass-916\n"
    private func fixtureFile(_ text: String) -> GitHubReviewHTTPState.Response {
        let body: [String: Any] = ["type":"file", "size":text.utf8.count, "sha":GitHubReviewHTTP.blob,
                                 "encoding":"base64", "content":Data(text.utf8).base64EncodedString()]
        return .init(body: String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
    }
    private func context(enabled: Bool = true) throws -> (GitHubWorkspaceService, GitHubReviewCredentials, UserDefaults) {
        let name = "github-contract-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let account = GitHubAccount(id: UUID(), login: "preview", userID: 123)
        let keys = GitHubReviewCredentials()
        try keys.setToken(token, for: account.id)
        defaults.set(try JSONEncoder().encode(account), forKey: GitHubConnectionStore.metadataKey)
        let connection = GitHubConnectionStore(defaults: defaults, credentials: keys)
        if enabled { connection.setEnabled(true) }
        let service = GitHubWorkspaceService(connection: connection, client: GitHubReviewHTTP.client())
        try service.select(.init(accountID: account.id, owner: "preview", name: "project", branch: "main"))
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (service, keys, defaults)
    }
    private func text(_ outcome: GitHubToolOutcome) -> String {
        if case .result(let text) = outcome { return text }
        XCTFail("Expected a tool result"); return ""
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func stage(_ service: GitHubWorkspaceService, path: String = "README.md", content: String = "# Project\nAfter.\n") async -> String {
        text(await service.run(name: "write_file", args: ["path": path, "content": content]))
    }

    func testDefaultOffMakesNoToolRequestsAndNeverPutsTokensInMetadataOrPrompt() async throws {
        let (service, _, defaults) = try context(enabled: false)
        XCTAssertFalse(service.connection.isEnabled)
        XCTAssertTrue(service.promptAddendum(compact: false).isEmpty)
        let result = text(await service.run(name: "read_file", args: ["path": "README.md"]))
        XCTAssertTrue(result.contains("GitHub tools are off"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        service.connection.setEnabled(true)
        XCTAssertTrue(service.promptAddendum(compact: false).contains("preview/project"))
        XCTAssertFalse(service.promptAddendum(compact: false).contains(token))
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: GitHubConnectionStore.metadataKey)), as: UTF8.self).contains(token))
        let exported = try JSONEncoder().encode(service.draft)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(token))
    }

    func testRepositoryScopePathsHeadersAndErrorBodiesAreSafe() async throws {
        let (service, _, _) = try context()
        for path in ["../README.md", "/etc/passwd", "folder/../file", "a\\b", ".git/config", "folder//file"] {
            assertTrue(text(await service.run(name: "read_file", args: ["path": path])).hasPrefix("Error:"))
        }
        assertTrue(text(await service.run(name: "search_code", args: ["query": "hello repo:other/repo"])).hasPrefix("Error:"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        let result = text(await service.run(name: "read_file", args: ["path": "README.md", "owner": "other", "repo": "other", "ref": "other"]))
        XCTAssertTrue(result.contains("Before."))
        let request = try XCTUnwrap(GitHubReviewHTTP.state.requests.last)
        XCTAssertEqual(request.url?.path, "/repos/preview/project/contents/README.md")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "main")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertFalse(request.url!.absoluteString.contains(token))
        GitHubReviewHTTP.state.reset { _ in .init(status: 403, body: "secret token or private server body") }
        let error = text(await service.run(name: "read_file", args: ["path": "README.md"]))
        XCTAssertTrue(error.contains("GitHub denied access"))
        XCTAssertFalse(error.contains("private server body"))
        XCTAssertFalse(error.contains(token))
    }

    func testStagingExactReplacementReadOverlayAndDeletionDoNotPublish() async throws {
        let (service, _, _) = try context()
        assertTrue(await stage(service).hasPrefix("Staged README.md"))
        XCTAssertEqual(service.draft?.changes.first?.mode, "100755")
        let count = GitHubReviewHTTP.state.requests.count
        let read = text(await service.run(name: "read_file", args: ["path": "README.md"]))
        XCTAssertTrue(read.contains("After."))
        XCTAssertEqual(GitHubReviewHTTP.state.requests.count, count, "Draft reads must use the overlay")
        let mismatch = text(await service.run(name: "replace_text", args: ["path": "README.md", "oldText": "After.", "newText": "Replacement.", "expectedOccurrences": 2]))
        XCTAssertTrue(mismatch.hasPrefix("Error:"))
        XCTAssertEqual(service.draft?.changes.first?.updatedText, "# Project\nAfter.\n")
        let replaced = text(await service.run(name: "replace_text", args: ["path": "README.md", "oldText": "After.", "newText": "Replacement.", "expectedOccurrences": 1]))
        XCTAssertTrue(replaced.hasPrefix("Staged"))
        XCTAssertEqual(service.draft?.changes.first?.updatedText, "# Project\nReplacement.\n")
        assertTrue(text(await service.run(name: "delete_file", args: ["path": "README.md"])).hasPrefix("Staged"))
        XCTAssertNil(service.draft?.changes.first?.updated)
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        let listing = text(await service.run(name: "list_files", args: [:]))
        XCTAssertFalse(listing.contains("README.md"))
    }

    func testSecretReadScanAndRedactionKeepValuesOutOfResultsAndRequireTheExactHash() async throws {
        let (service, _, _) = try context()
        let text = secretFixture
        let response = fixtureFile(text)
        GitHubReviewHTTP.state.reset { request in
            request.url!.path.hasSuffix("/contents/README.md") ? response : GitHubReviewHTTP.preview(request)
        }
        let read = self.text(await service.run(name: "read_file", args: ["path":"README.md"]))
        XCTAssertFalse(read.contains("fixture-user-823"))
        XCTAssertFalse(read.contains("fixture-pass-916"))
        XCTAssertTrue(read.contains("YOUR_USER") && read.contains("YOUR_PASS"))
        let scan = self.text(await service.run(name: "scan_secrets", args: ["paths":["README.md"]]))
        XCTAssertTrue(scan.contains("Line 1:"))
        XCTAssertFalse(scan.contains("fixture-pass-916"))
        let wrong = self.text(await service.run(name: "redact_secrets", args: ["path":"README.md", "expectedFileHash":"wrong"]))
        XCTAssertTrue(wrong.hasPrefix("Error:"))
        XCTAssertEqual(service.draft?.changes.count, 0)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
        let staged = self.text(await service.run(name: "redact_secrets", args: ["path":"README.md", "expectedFileHash":hash]))
        XCTAssertTrue(staged.hasPrefix("Staged"))
        let change = try XCTUnwrap(service.draft?.changes.first)
        XCTAssertEqual(change.originalText, text)
        XCTAssertFalse(try XCTUnwrap(change.updatedText).contains("fixture-pass-916"))
        XCTAssertEqual(change.mode, "100755")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        let plan = try await service.review()
        assertTrue(await service.approve(plan).hasPrefix("Committed"))
    }

    func testWritesCannotReintroduceRecognizedSecretsAndPathScanIsBounded() async throws {
        let (service, _, _) = try context()
        assertTrue(await stage(service, content: secretFixture).contains("Potential credentials"))
        XCTAssertTrue(service.draft?.changes.isEmpty == true)
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        for paths in [["../outside"], ["README.md", "README.md"], Array(repeating:"README.md",count:21)] {
            assertTrue(text(await service.run(name:"scan_secrets",args:["paths":paths])).hasPrefix("Error:"))
        }
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
    }

    func testHistoryAuditIsPinnedToTheSelectedBranchAndNeverWritesOrRevealsValues() async throws {
        let (service, _, _) = try context()
        let response = fixtureFile(secretFixture)
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path.hasSuffix("/contents/README.md") { return response }
            if request.url!.path.hasSuffix("/commits") { return .init(body:"[{\"sha\":\"\(GitHubReviewHTTP.head)\"}]") }
            return GitHubReviewHTTP.preview(request)
        }
        let audit = text(await service.run(name:"audit_secret_history",args:["paths":["README.md"],"limit":2,"repo":"other","branch":"other"]))
        XCTAssertTrue(audit.contains(GitHubReviewHTTP.head))
        XCTAssertTrue(audit.contains("No history was changed"))
        XCTAssertFalse(audit.contains("fixture-pass-916"))
        for request in GitHubReviewHTTP.state.requests {
            XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertTrue(request.url!.path.hasPrefix("/repos/preview/project/"))
        }
        let request = try XCTUnwrap(GitHubReviewHTTP.state.requests.first)
        let items = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(items.first(where:{$0.name=="sha"})?.value,"main")
        XCTAssertEqual(items.first(where:{$0.name=="per_page"})?.value,"2")
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        assertTrue(text(await service.run(name:"audit_secret_history",args:["paths":["README.md"],"limit":11])).hasPrefix("Error:"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
    }

    func testEncryptedSnapshotsRoundTripUseFreshNoncesAndRejectTampering() throws {
        let key = SymmetricKey(size: .bits256)
        let encoder = JSONEncoder(); encoder.userInfo[GitHubDraftProtection.keyInfo] = key
        let decoder = JSONDecoder(); decoder.userInfo[GitHubDraftProtection.keyInfo] = key
        let change = GitHubFileChange(path:"README.md",original:Data(secretFixture.utf8),updated:Data("Sanitized".utf8),mode:"100644")
        let first = try encoder.encode(change)
        let second = try encoder.encode(change)
        XCTAssertNotEqual(first,second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:first) as? [String:Any])
        XCTAssertNil(object["original"])
        XCTAssertNil(object["updated"])
        XCTAssertNotNil(object["encryptedSnapshot"])
        XCTAssertFalse(String(decoding:first,as:UTF8.self).contains("fixture-pass-916"))
        XCTAssertFalse(String(decoding:first,as:UTF8.self).contains(Data(secretFixture.utf8).base64EncodedString()))
        XCTAssertEqual(try decoder.decode(GitHubFileChange.self,from:first),change)
        var changed = object; changed["path"] = "other.md"
        let tampered = try decoder.decode(GitHubFileChange.self,from:JSONSerialization.data(withJSONObject:changed))
        XCTAssertTrue(tampered.isLocked)
        XCTAssertThrowsError(try tampered.unlocked(using:key))
        let legacy: [String:Any] = ["path":"README.md","mode":"100644","original":Data(secretFixture.utf8).base64EncodedString()]
        let migrated = try decoder.decode(GitHubFileChange.self,from:JSONSerialization.data(withJSONObject:legacy))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with:encoder.encode(migrated)) as? [String:Any])
        XCTAssertNil(saved["original"])
        XCTAssertNotNil(saved["encryptedSnapshot"])
        let wrongKey = SymmetricKey(size:.bits256)
        decoder.userInfo[GitHubDraftProtection.keyInfo] = wrongKey
        let locked = try decoder.decode(GitHubFileChange.self,from:first)
        XCTAssertTrue(locked.isLocked)
        XCTAssertNil(locked.original)
        XCTAssertThrowsError(try locked.unlocked(using:wrongKey))
        XCTAssertEqual(try locked.unlocked(using:key),change)
        let preserved = try XCTUnwrap(JSONSerialization.jsonObject(with:encoder.encode(locked)) as? [String:Any])
        XCTAssertEqual(preserved["encryptedSnapshot"] as? String,object["encryptedSnapshot"] as? String)
    }

    func testMoveStagesOneAtomicPairPreservesExecutableModeAndRejectsOverwrite() async throws {
        let (service, _, _) = try context()
        let result = text(await service.run(name:"move_file",args:["path":"README.md","destination":"notes.md"]))
        XCTAssertTrue(result.hasPrefix("Staged move"),result)
        XCTAssertEqual(service.draft?.changes.count,2)
        XCTAssertNil(service.draft?.changes.first(where:{$0.path=="README.md"})?.updated)
        XCTAssertEqual(service.draft?.changes.first(where:{$0.path=="notes.md"})?.mode,"100755")
        assertTrue(text(await service.run(name:"read_file",args:["path":"notes.md"])).contains("Before."))
        assertTrue(text(await service.run(name:"move_file",args:["path":"notes.md","destination":"README.md"])).hasPrefix("Staged move"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy{$0.httpMethod=="GET"})
    }

    func testAnotherDevicesEncryptedDraftKeepsChatReadableAndCannotRunTools() async throws {
        let (service, _, _) = try context()
        var conversation = StoredConversation(title:"Preserved conversation")
        conversation.messages = [StoredMessage(ChatMessage(role:.user,content:"Keep this history"))]
        var workspace = try XCTUnwrap(service.draft)
        workspace.baseSHA = GitHubReviewHTTP.head
        workspace.changes = [.init(path:"README.md",original:Data(secretFixture.utf8),updated:Data("Safe text".utf8),mode:"100644")]
        conversation.gitHubWorkspace = workspace
        let encoder = JSONEncoder(); encoder.userInfo[GitHubDraftProtection.keyInfo] = SymmetricKey(size:.bits256)
        let decoder = JSONDecoder(); decoder.userInfo[GitHubDraftProtection.keyInfo] = SymmetricKey(size:.bits256)
        let saved = try encoder.encode(conversation)
        let restored = try decoder.decode(StoredConversation.self,from:saved)
        XCTAssertEqual(restored.messages.first?.content,"Keep this history")
        XCTAssertTrue(restored.gitHubWorkspace?.changes.first?.isLocked == true)
        service.restore(restored.gitHubWorkspace)
        XCTAssertFalse(service.isAvailable)
        assertTrue(text(await service.run(name:"read_file",args:["path":"README.md"])).contains("encrypted"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        let resaved = try encoder.encode(restored)
        XCTAssertFalse(String(decoding:resaved,as:UTF8.self).contains("fixture-pass-916"))
    }

    func testNewReadToolsAndCatalogUseScopedRequestsAndLineBounds() async throws {
        let (service, _, _) = try context()
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path.hasSuffix("/actions/runs") { return .init(body:"{\"workflow_runs\":[{\"name\":\"Build\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_sha\":\"\(GitHubReviewHTTP.head)\"}]}") }
            return GitHubReviewHTTP.preview(request)
        }
        assertTrue(text(await service.run(name:"repository_info",args:[:])).contains("Write access: yes"))
        assertTrue(text(await service.run(name:"list_branches",args:[:])).contains("Selected: main"))
        let range = text(await service.run(name:"read_file_range",args:["path":"README.md","start_line":2,"line_count":1]))
        XCTAssertTrue(range.contains("2: Before."))
        XCTAssertFalse(range.contains("# Project"))
        assertTrue(text(await service.run(name:"read_file_range",args:["path":"README.md","start_line":0,"line_count":1])).hasPrefix("Error:"))
        assertTrue(text(await service.run(name:"workflow_status",args:[:])).contains("Build: completed · success"))
        for name in ["repository_info","list_branches","read_file_range","move_file","scan_secrets","redact_secrets","audit_secret_history","workflow_status"] {
            XCTAssertTrue(service.promptAddendum(compact:false).contains(name))
            XCTAssertNotNil(AssistantToolCallParser.extractCall(from:"{\"name\":\"\(name)\",\"args\":{}}"))
        }
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy{$0.httpMethod=="GET"})
    }

    func testApprovalPublishesOneAtomicCommitAndPreservesModeWithoutForce() async throws {
        let (service, _, _) = try context()
        _ = await stage(service)
        let plan = try await service.review(message: "Reviewed edit")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        let result = await service.approve(plan)
        XCTAssertTrue(result.hasPrefix("Committed 1 reviewed file"), result)
        let requests = GitHubReviewHTTP.state.requests
        let treeRequest = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/git/trees") })
        let tree = try body(treeRequest)
        XCTAssertEqual(tree["base_tree"] as? String, GitHubReviewHTTP.tree)
        let entries = try XCTUnwrap(tree["tree"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["path"] as? String, "README.md")
        XCTAssertEqual(entries.first?["mode"] as? String, "100755")
        let commits = requests.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/git/commits") }
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(try body(commits[0])["parents"] as? [String], [GitHubReviewHTTP.head])
        let refs = requests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(try body(refs[0])["force"] as? Bool, false)
        XCTAssertEqual(service.draft?.changes.count, 0)
        assertTrue(await service.approve(plan).hasPrefix("Error:"), "An approval cannot be replayed")
    }

    func testBranchAdvanceAndChangedDraftInvalidateReviewBeforeAnyWrites() async throws {
        let (service, _, _) = try context()
        _ = await stage(service)
        let plan = try await service.review()
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path.contains("/git/ref/") { return .init(body: "{\"object\":{\"sha\":\"\(GitHubReviewHTTP.newSHA)\"}}") }
            return GitHubReviewHTTP.preview(request)
        }
        assertTrue(await service.approve(plan).contains("branch changed on GitHub"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(service.draft?.changes.count, 1)
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        _ = await stage(service, content: "Another draft")
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        assertTrue(await service.approve(plan).contains("draft changed"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
    }

    func testNewBinaryUploadRequiresAnActualUserAttachmentAndDraftCanBeDiscarded() async throws {
        let (service, _, _) = try context()
        let data = Data([0, 1, 2, 255])
        let outcome = await service.run(name: "upload_attachment", args: ["path": "image.png", "attachment_name": "user-image.png"],
                                       attachments: [.init(name: "user-image.png", data: data)])
        XCTAssertTrue(text(outcome).hasPrefix("Staged"))
        XCTAssertEqual(service.draft?.changes.first?.updated, data)
        XCTAssertNil(service.draft?.changes.first?.original)
        let absent = text(await service.run(name: "upload_attachment", args: ["path": "other.png", "attachment_name": "/etc/passwd"]))
        XCTAssertTrue(absent.hasPrefix("Error:"))
        service.discardChanges()
        XCTAssertEqual(service.draft?.changes.count, 0)
        XCTAssertNil(service.draft?.baseSHA)
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testDisableCancelsPendingHTTPAndKeepsDraftAndDisconnectDeletesOnlySecureCredential() async throws {
        let (service, keys, defaults) = try context()
        _ = await stage(service)
        GitHubReviewHTTP.state.reset { _ in .init(body: "", wait: true) }
        let task = Task { await service.run(name: "read_file", args: ["path": "other.md"]) }
        for _ in 0..<100 {
            if !GitHubReviewHTTP.state.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        service.connection.setEnabled(false)
        assertTrue(text(await task.value).contains("cancelled"))
        XCTAssertEqual(service.draft?.changes.count, 1)
        XCTAssertFalse(service.isRunning)
        try service.connection.disconnect()
        XCTAssertEqual(keys.count, 0)
        XCTAssertNil(defaults.data(forKey: GitHubConnectionStore.metadataKey))
        XCTAssertFalse(service.connection.isEnabled)
    }

    func testKeychainFailureDoesNotFallBackToPlaintextOrClaimSuccessfulDisconnect() async throws {
        let (service, keys, defaults) = try context()
        keys.fails = true
        XCTAssertThrowsError(try service.connection.disconnect())
        XCTAssertNotNil(service.connection.account)
        XCTAssertNotNil(defaults.data(forKey: GitHubConnectionStore.metadataKey))
        XCTAssertFalse(service.connection.isEnabled, "A failed token deletion must still revoke tool access")
        service.connection.setEnabled(true)
        let read = text(await service.run(name: "read_file", args: ["path": "README.md"]))
        XCTAssertTrue(read.contains("securely"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains(token) })
    }

    func testConversationRestorationIsOfflineAndOldRecordsDecodeWithoutGitHub() throws {
        let (service, _, _) = try context()
        var conversation = StoredConversation(title: "Project")
        conversation.gitHubWorkspace = service.draft
        let encoded = try JSONEncoder().encode(conversation)
        let restored = try JSONDecoder().decode(StoredConversation.self, from: encoded)
        service.restore(restored.gitHubWorkspace)
        XCTAssertEqual(service.draft?.selection.fullName, "preview/project")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(token))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "gitHubWorkspace")
        XCTAssertNil(try JSONDecoder().decode(StoredConversation.self, from: JSONSerialization.data(withJSONObject: object)).gitHubWorkspace)
    }

    func testBranchAndPullRequestCallsPrepareReviewWithoutPublishing() async throws {
        let (service, _, _) = try context()
        let outcome = await service.run(name: "create_branch", args: ["name": "feature/agent"])
        guard case .review(let plan) = outcome else { return XCTFail("Branch must require review") }
        XCTAssertEqual(plan.action, .createBranch(name: "feature/agent"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        let result = await service.approve(plan)
        XCTAssertTrue(result.hasPrefix("Created and selected"))
        XCTAssertEqual(service.draft?.selection.branch, "feature/agent")
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        let pr = await service.run(name: "open_pull_request", args: ["title": "Agent changes", "base": "main", "body": "Reviewed changes"])
        guard case .review(let prPlan) = pr else { return XCTFail("PR must require review") }
        XCTAssertEqual(prPlan.draft.selection.branch, "feature/agent")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testDeviceFlowUsesJSONAndHandlesPendingSlowdownDenialWithoutLeakingResponses() async throws {
        let client = GitHubReviewHTTP.client()
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path == "/login/device/code" {
                return .init(body: "{\"device_code\":\"temporary-device-code\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":900,\"interval\":5}")
            }
            return .init(body: "{\"error\":\"authorization_pending\"}")
        }
        let code = try await client.startDeviceSignIn(clientID: "public-client-id")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        if case .pending = try await client.pollDeviceSignIn(clientID: "public-client-id", deviceCode: code.deviceCode) {} else { XCTFail("Expected pending") }
        let request = try XCTUnwrap(GitHubReviewHTTP.state.requests.last)
        XCTAssertEqual(try body(request)["grant_type"] as? String, "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        GitHubReviewHTTP.state.reset { _ in .init(body: "{\"error\":\"slow_down\"}") }
        if case .slowDown = try await client.pollDeviceSignIn(clientID: "id", deviceCode: "code") {} else { XCTFail("Expected slowdown") }
        GitHubReviewHTTP.state.reset { _ in .init(body: "{\"error\":\"access_denied\",\"error_description\":\"secret raw body\"}") }
        do { _ = try await client.pollDeviceSignIn(clientID: "id", deviceCode: "code"); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? GitHubError, .deviceDenied) }
    }

    func testReconnectingRequiresExplicitRepoAuthorizationAndKeepsItsDraft() async throws {
        let (service, _, _) = try context()
        _ = await stage(service)
        let oldID = try XCTUnwrap(service.draft?.selection.accountID)
        try service.connection.disconnect()
        try await service.connection.connect(token: token, client: service.client)
        service.connection.setEnabled(true)
        XCTAssertNotEqual(service.connection.account?.id, oldID)
        XCTAssertFalse(service.isAvailable)
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        let blocked = text(await service.run(name: "read_file", args: ["path": "README.md"]))
        XCTAssertTrue(blocked.contains("different GitHub connection"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        let reconnected = await service.reconnectRepository()
        XCTAssertTrue(reconnected.hasPrefix("Repository reconnected"), reconnected)
        XCTAssertTrue(service.isAvailable)
        XCTAssertEqual(service.draft?.changes.first?.updatedText, "# Project\nAfter.\n")
        XCTAssertEqual(service.draft?.baseSHA, GitHubReviewHTTP.head)
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testForwardRevertReviewsChangedPathsAndAddsACommitWithoutDeletingHistory() async throws {
        let (service, _, _) = try context()
        let parentTree = String(repeating: "e", count: 40)
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path.hasSuffix("/git/commits/" + GitHubReviewHTTP.newSHA) {
                return .init(body: "{\"sha\":\"\(GitHubReviewHTTP.newSHA)\",\"tree\":{\"sha\":\"\(parentTree)\"},\"parents\":[],\"message\":\"Parent\"}")
            }
            if request.url!.path.hasSuffix("/git/trees/" + parentTree) {
                return .init(body: "{\"sha\":\"\(parentTree)\",\"tree\":[{\"path\":\"README.md\",\"type\":\"blob\",\"mode\":\"100644\",\"sha\":\"\(GitHubReviewHTTP.newSHA)\"}],\"truncated\":false}")
            }
            return GitHubReviewHTTP.preview(request)
        }
        let outcome = await service.run(name: "revert_last_commit", args: ["reason": "Undo the latest change"])
        guard case .review(let plan) = outcome else { return XCTFail("Revert must require review") }
        XCTAssertEqual(plan.action, .revert(reason: "Undo the latest change", treeSHA: parentTree, changedFiles: ["README.md"]))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        let result = await service.approve(plan)
        XCTAssertTrue(result.hasPrefix("Created a forward revert"), result)
        let request = try XCTUnwrap(GitHubReviewHTTP.state.requests.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/git/commits") })
        XCTAssertEqual(try body(request)["tree"] as? String, parentTree)
        XCTAssertEqual(try body(request)["parents"] as? [String], [GitHubReviewHTTP.head])
        XCTAssertFalse(GitHubReviewHTTP.state.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testOversizedFilesAndInvalidDeviceVerificationOriginsAreRejected() async throws {
        let (service, _, _) = try context()
        GitHubReviewHTTP.state.reset { _ in .init(body: "{\"type\":\"file\",\"size\":999999999,\"content\":\"AA==\",\"encoding\":\"base64\"}") }
        assertTrue(text(await service.run(name: "read_file", args: ["path": "huge.txt"])).contains("size limit"))
        GitHubReviewHTTP.state.reset { _ in .init(body: "{\"device_code\":\"code\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://other.example.com/login/device\",\"expires_in\":900}") }
        do { _ = try await service.client.startDeviceSignIn(clientID: "public-id"); XCTFail("Unexpected origin") }
        catch { XCTAssertEqual(error as? GitHubError, .invalidClient) }
    }

    func testModelToolCallsReachScopedGitHubServiceAndOpenReviewOnlyAfterStaging() async throws {
        let (service, _, _) = try context()
        let read = try XCTUnwrap(AssistantToolCallParser.extractCall(from: "```tool\n{\"name\":\"read_file\",\"args\":{\"path\":\"README.md\"}}\n```"))
        assertTrue(text(await service.run(name: read.name, args: read.args)).contains("Before."))
        let write = try XCTUnwrap(AssistantToolCallParser.extractCall(from: "{\"tool_calls\":[{\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\",\\\"content\\\":\\\"Reviewed content\\\"}\"}}]}"))
        assertTrue(text(await service.run(name: write.name, args: write.args)).hasPrefix("Staged"))
        let approval = try XCTUnwrap(AssistantToolCallParser.extractCall(from: "<tool_call>{\"name\":\"request_user_approval\",\"args\":{\"message\":\"Reviewed update\"}}</tool_call>"))
        guard case .review(let plan) = await service.run(name: approval.name, args: approval.args) else { return XCTFail("Expected native review") }
        XCTAssertEqual(plan.draft.changes.first?.updatedText, "Reviewed content")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertNil(AssistantToolCallParser.extractCall(from: "<think>{\"name\":\"write_file\",\"args\":{}}</think>Still reasoning"))
        XCTAssertNil(AssistantToolCallParser.extractCall(from: "<think>{\"name\":\"write_file\",\"args\":{}}"))
        XCTAssertNil(AssistantToolCallParser.extractCall(from: "{\"name\":\"arbitrary_shell\",\"args\":{}}"))
        XCTAssertEqual(AssistantToolCallParser.extractCall(from: "{\"name\":\"calculator\",\"args\":{\"expression\":\"2+2\"}}")?.name, "calculator")
    }

    func testSharedParserPreservesExistingCallsAndKeepsReasoningFromActing() throws {
        let inline = #"```tool {"name":"calculator","args":{"expression":"(3+5)*2"}}```"#
        XCTAssertEqual(AssistantToolCallParser.extractCall(from: inline)?.args["expression"] as? String, "(3+5)*2")
        let thinking = #"<think>{"name":"write_file","args":{"path":"README.md","content":"Unreviewed"}}</think><tool_call>{"function":{"name":"datetime","arguments":"{\"timezone\":\"Europe/Istanbul\"}"}}</tool_call>"#
        let call = try XCTUnwrap(AssistantToolCallParser.extractCall(from: thinking))
        XCTAssertEqual(call.name, "datetime")
        XCTAssertEqual(call.args["timezone"] as? String, "Europe/Istanbul")
        let nested = #"Some context {"name":"replace_text","args":{"path":"README.md","oldText":"{\"key\":\"} brace\"}","newText":"{}","expectedOccurrences":1}}"#
        XCTAssertEqual(AssistantToolCallParser.extractCall(from: nested)?.args["oldText"] as? String, #"{"key":"} brace"}"#)
        let echoed = #"```tool_result {"value":42}``` ```tool {"name":"unit_convert","args":{"value":10,"from":"km","to":"mi"}}```"#
        XCTAssertEqual(AssistantToolCallParser.extractCall(from: echoed)?.name, "unit_convert")
    }
}
