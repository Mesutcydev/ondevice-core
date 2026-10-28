import XCTest
import CryptoKit
@testable import NativeUIReview

@MainActor
final class CodingWorkspaceTests: XCTestCase {
    private let head = GitHubReviewHTTP.head

    private func file(_ path: String = "README.md", text: String = "# Project\nBefore.\n", base: String? = "# Project\nBefore.\n") -> CodingWorkspaceFile {
        .init(path: path, base: base, text: text, commit: head)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coding-test-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func service() throws -> GitHubWorkspaceService {
        let name = "coding-contract-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let account = GitHubAccount(id: UUID(), login: "preview", userID: 123)
        let credentials = GitHubReviewCredentials()
        try credentials.setToken("test-github-token-only", for: account.id)
        defaults.set(try JSONEncoder().encode(account), forKey: GitHubConnectionStore.metadataKey)
        let connection = GitHubConnectionStore(defaults: defaults, credentials: credentials)
        connection.setEnabled(true)
        let service = GitHubWorkspaceService(connection: connection, client: GitHubReviewHTTP.client())
        try service.select(.init(accountID: account.id, owner: "preview", name: "project", branch: "main"))
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return service
    }
    private func response(_ text: String) -> GitHubReviewHTTPState.Response {
        let json: [String: Any] = ["type": "file", "size": text.utf8.count, "sha": GitHubReviewHTTP.blob,
                                   "encoding": "base64", "content": Data(text.utf8).base64EncodedString()]
        return .init(body: String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    func testSelectionContextRedactsSecretsAndRespectsCompleteBudget() throws {
        var selected = file(text: "outside\nlet value = 2\nlet answer = value + 1\noutside", base: "")
        selected.selectedLocation = 8; selected.selectedLength = 35
        let prompt = CodingWorkspaceText.context(files: [selected], paths: [selected.path], action: .explain,
                                                question: "Why?", selectionOnly: true, maximumCharacters: 512)
        XCTAssertTrue(prompt.contains("README.md:L2-L3"))
        XCTAssertFalse(prompt.contains("outside"))
        XCTAssertLessThanOrEqual(prompt.count, 512)
        let secret = "https://panel.invalid/get.php?username=fixture-user-823&password=fixture-pass-916"
        let safe = CodingWorkspaceText.context(files: [file(text: secret)], paths: ["README.md"], action: .ask,
                                              question: String(repeating: "x", count: 5_000), selectionOnly: false, maximumCharacters: 1_000)
        XCTAssertFalse(safe.contains("fixture-pass-916"))
        XCTAssertFalse(safe.contains("fixture-user-823"))
        XCTAssertLessThanOrEqual(safe.count, 1_000)
    }

    func testDiffHasCorrectLineReferencesAndCanReconstructBothVersions() {
        let before = "one\ntwo\nthree\n", after = "zero\none\nTWO\nthree\n"
        let lines = CodingDiffLine.compare(before: before, after: after)
        XCTAssertEqual(lines.filter { $0.kind != .added }.map(\.text).joined(separator: "\n"), before)
        XCTAssertEqual(lines.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n"), after)
        XCTAssertEqual(lines.first { $0.text == "TWO" }?.newLine, 3)
        XCTAssertEqual(lines.first { $0.text == "two" }?.oldLine, 2)
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
        XCTAssertTrue(CodingDiffLine.compare(before: String(repeating: "a\n", count: 6_001), after: "b").isEmpty)
    }

    func testStateRejectsTraversalDuplicatesOversizeAndRetainsDirtyDraftsWithoutOfflineOptIn() throws {
        var state = CodingWorkspaceState()
        state.files = [file(), file("Sources/A.swift", text: "changed", base: "original")]
        XCTAssertEqual(state.persisted.files.map(\.path), ["Sources/A.swift"])
        state.offlineEnabled = true
        XCTAssertEqual(state.persisted.files.count, 2)
        state.files.append(file("../escape"))
        XCTAssertThrowsError(try state.validated())
        state.files = [file(), file()]
        XCTAssertThrowsError(try state.validated())
        state.files = [file(text: String(repeating: "x", count: CodingWorkspaceLimits.fileBytes + 1))]
        XCTAssertThrowsError(try state.validated())
    }

    func testVaultEncryptsAndAuthenticatesFilesWithScopeAndNoPlaintextFallback() async throws {
        let directory = try root(), key = SymmetricKey(size: .bits256)
        let vault = CodingWorkspaceVault(root: directory, testKey: key)
        var state = CodingWorkspaceState(); state.files = [file(text: "private document marker")]
        try await vault.save(state, scope: "account/repo/main")
        let restored = try await vault.load(scope: "account/repo/main")
        XCTAssertEqual(restored?.files.first?.text, "private document marker")
        let unknown = try await vault.load(scope: "another/repo/main")
        XCTAssertNil(unknown)
        let stored = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let encrypted = try Data(contentsOf: stored)
        XCTAssertNil(encrypted.range(of: Data("private document marker".utf8)))
        let wrong = CodingWorkspaceVault(root: directory, testKey: SymmetricKey(size: .bits256))
        do { _ = try await wrong.load(scope: "account/repo/main"); XCTFail("Wrong key must fail") } catch { }
        var tampered = encrypted; tampered[tampered.startIndex + 10] ^= 1
        try tampered.write(to: stored)
        do { _ = try await vault.load(scope: "account/repo/main"); XCTFail("Tampering must fail") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    func testCheckpointsRestoreOldestWhileKeepingCurrentEditsRecoverable() async throws {
        let service = try service()
        let vault = CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256))
        let controller = CodingWorkspaceController(workspace: service, vault: vault)
        await controller.activate(); await controller.open("README.md")
        for i in 0..<5 { controller.edit("revision \(i)"); let saved = await controller.checkpoint(); XCTAssertTrue(saved) }
        let oldest = try XCTUnwrap(controller.state.checkpoints.last)
        controller.edit("unsaved latest")
        await controller.restoreCheckpoint(oldest)
        XCTAssertEqual(controller.activeFile?.text, "revision 0")
        let currentRecovery = try XCTUnwrap(controller.state.checkpoints.first)
        let recovered = try await vault.load(scope: CodingWorkspaceText.scopeKey(service.draft!), checkpoint: currentRecovery.id)
        XCTAssertEqual(recovered?.files.first?.text, "unsaved latest")
        XCTAssertEqual(controller.state.checkpoints.count, 5)
        controller.cancel()
    }

    func testMentionsAndBookmarksPreserveActiveFileAndUseOnlySelectedRepository() async throws {
        XCTAssertEqual(CodingWorkspaceText.mentions(in: "Read @\"Docs/Getting started.md\" and @`Sources/Example file.swift` and @../outside"),
                       ["Docs/Getting started.md", "Sources/Example file.swift"])
        let outline = CodingWorkspaceText.outline(CodingReviewFixture.files["Sources/Counter.swift"]!)
        XCTAssertTrue(outline.contains { $0.line == 6 && $0.title.contains("increment") })
        let service = try service()
        GitHubReviewHTTP.state.reset { CodingReviewFixture.response($0) }
        let controller = CodingWorkspaceController(workspace: service, vault: CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256)))
        await controller.activate(); await controller.open("README.md")
        controller.question = "Explain @Sources/"
        let prompt = await controller.makeQuestion(action: .ask, maximumCharacters: 12_000)
        XCTAssertTrue(prompt?.contains("SOURCE Sources/Counter.swift:L1") == true)
        XCTAssertEqual(controller.state.activePath, "README.md")
        controller.goToLine(3); controller.bookmark(); controller.markRead()
        XCTAssertEqual(controller.state.bookmarks.first?.line, 3)
        XCTAssertEqual(controller.state.readPaths, ["README.md"])
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.url!.path.hasPrefix("/repos/preview/project/") })
        controller.cancel()
    }

    func testManualStagingUsesExactBaselineAndNeverPublishes() async throws {
        let service = try service()
        var file = try await service.workspaceFile(path: "README.md", commit: head)
        file.text = "Reviewed edit"
        try await service.stageWorkspaceFile(file)
        XCTAssertEqual(service.draft?.changes.first?.updatedText, "Reviewed edit")
        file.text = "Stale editor edit"
        do { try await service.stageWorkspaceFile(file); XCTFail("A stale editor must not replace a newer proposal") } catch { }
        XCTAssertEqual(service.draft?.changes.first?.updatedText, "Reviewed edit")
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testChatProposalsAppearInBrowserAndKeepIndependentEditorChanges() async throws {
        let service = try service()
        let controller = CodingWorkspaceController(workspace: service, vault: CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256)))
        await controller.activate(); await controller.open("README.md"); controller.edit("Independent editor change")
        _ = await service.run(name: "write_file", args: ["path": "README.md", "content": "Chat proposal"])
        _ = await service.run(name: "write_file", args: ["path": "New.swift", "content": "struct New {}"])
        await controller.synchronizeDraft()
        XCTAssertEqual(controller.activeFile?.text, "Independent editor change")
        XCTAssertEqual(controller.activeFile?.stagedText, "Chat proposal")
        XCTAssertTrue(controller.visibleEntries.contains { $0.path == "New.swift" })
        await controller.flush(); controller.cancel()
    }

    func testEditorDraftsAreIsolatedBetweenChatsAndIdentitySurvivesStaging() async throws {
        let service = try service()
        let vault = CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256))
        let controller = CodingWorkspaceController(workspace: service, vault: vault)
        let first = try XCTUnwrap(service.draft)
        await controller.activate(); await controller.open("README.md"); controller.edit("First chat's independent edit")
        controller.conflicts = ["README.md"]; controller.conflictChoices["README.md"] = true
        let second = GitHubWorkspaceDraft(selection: first.selection)
        XCTAssertNotEqual(CodingWorkspaceText.scopeKey(first), CodingWorkspaceText.scopeKey(second))
        service.restore(second); await controller.activate()
        XCTAssertNil(controller.activeFile)
        XCTAssertTrue(controller.conflicts.isEmpty); XCTAssertTrue(controller.conflictChoices.isEmpty)
        service.restore(first); await controller.activate()
        XCTAssertEqual(controller.activeFile?.text, "First chat's independent edit")
        await controller.stage()
        XCTAssertEqual(service.draft?.editorID, first.editorID)
        service.discardChanges()
        XCTAssertEqual(service.draft?.editorID, first.editorID)
        controller.cancel()
    }

    func testOfflineRestorationKeepsNestedFilesPositionAndReadingWithoutNetwork() async throws {
        let service = try service()
        GitHubReviewHTTP.state.reset { CodingReviewFixture.response($0) }
        let vault = CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256))
        let first = CodingWorkspaceController(workspace: service, vault: vault)
        await first.activate()
        for path in ["styles.css", "script.js", "index.html"] {
            first.search = path
            XCTAssertEqual(first.visibleEntries.map(\.path), [path])
        }
        first.search = ""
        await first.open("Sources/Counter.swift"); first.goToLine(7); first.markRead(); first.setOffline(true)
        await first.flush(); first.cancel()
        GitHubReviewHTTP.state.reset { _ in .init(status: 503, body: "{}") }
        let restored = CodingWorkspaceController(workspace: service, vault: vault)
        await restored.activate()
        XCTAssertEqual(restored.state.activePath, "Sources/Counter.swift")
        XCTAssertEqual(restored.activeFile?.firstVisibleLine, 7)
        XCTAssertEqual(restored.state.readPaths, ["Sources/Counter.swift"])
        XCTAssertTrue(restored.visibleEntries.contains { $0.path == "Sources" && $0.isDirectory })
        XCTAssertTrue(GitHubReviewHTTP.state.requests.isEmpty)
        restored.cancel()
    }

    func testStopCancelsTheActualManualNetworkRequestAndKeepsOpenDocuments() async throws {
        let service = try service()
        let controller = CodingWorkspaceController(workspace: service, vault: CodingWorkspaceVault(root: try root(), testKey: SymmetricKey(size: .bits256)))
        await controller.activate(); await controller.open("README.md"); controller.edit("Keep my edit")
        GitHubReviewHTTP.state.reset { _ in .init(body: "", wait: true) }
        let loading = Task { await controller.refresh() }
        for _ in 0..<100 {
            if !GitHubReviewHTTP.state.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(GitHubReviewHTTP.state.requests.isEmpty)
        controller.cancel(); await loading.value
        XCTAssertGreaterThan(GitHubReviewHTTP.state.stopCount, 0)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.activeFile?.text, "Keep my edit")
    }

    func testPartialCommitPublishesOnlyIncludedPathsAndKeepsExcludedDraft() async throws {
        let service = try service()
        _ = await service.run(name: "write_file", args: ["path": "README.md", "content": "Reviewed edit"])
        _ = await service.run(name: "write_file", args: ["path": "Notes.md", "content": "Unselected edit"])
        guard case .review(var plan) = await service.run(name: "request_user_approval", args: ["message": "Update README"]) else { return XCTFail("Review missing") }
        plan.includedPaths = ["README.md"]
        let result = await service.approve(plan)
        XCTAssertTrue(result.hasPrefix("Committed 1 reviewed file"), result)
        XCTAssertEqual(service.draft?.changes.map(\.path), ["Notes.md"])
        XCTAssertEqual(service.draft?.baseSHA, GitHubReviewHTTP.newSHA)
        let request = try XCTUnwrap(GitHubReviewHTTP.state.requests.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/git/trees") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let tree = try XCTUnwrap(body["tree"] as? [[String: Any]])
        XCTAssertEqual(tree.compactMap { $0["path"] as? String }, ["README.md"])
        let patch = try XCTUnwrap(GitHubReviewHTTP.state.requests.first { $0.httpMethod == "PATCH" })
        let update = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(update["force"] as? Bool, false)
    }

    func testEmptyOrUnknownCommitSelectionIsRejectedWithoutWrites() async throws {
        let service = try service()
        _ = await service.run(name: "write_file", args: ["path": "README.md", "content": "Reviewed edit"])
        guard case .review(var plan) = await service.run(name: "request_user_approval", args: [:]) else { return XCTFail("Review missing") }
        plan.includedPaths = []
        let empty = await service.approve(plan); XCTAssertTrue(empty.hasPrefix("Error:"))
        plan.includedPaths = ["README.md", "Unknown.md"]
        let unknown = await service.approve(plan); XCTAssertTrue(unknown.hasPrefix("Error:"))
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testBranchRefreshRequiresExplicitChoiceForUnstagedEditAndCreatesNoWrites() async throws {
        let service = try service(), directory = try root()
        let vault = CodingWorkspaceVault(root: directory, testKey: SymmetricKey(size: .bits256))
        let controller = CodingWorkspaceController(workspace: service, vault: vault)
        await controller.activate(); await controller.open("README.md"); controller.edit("My independent edit")
        let remote = response("Changed on GitHub")
        GitHubReviewHTTP.state.reset { request in
            if request.url!.path.contains("/git/ref/") { return .init(body: "{\"object\":{\"sha\":\"\(GitHubReviewHTTP.newSHA)\"}}") }
            if request.url!.path.hasSuffix("/contents/README.md") { return remote }
            return GitHubReviewHTTP.preview(request)
        }
        await controller.resolveConflicts()
        XCTAssertEqual(controller.conflicts, ["README.md"])
        XCTAssertEqual(controller.activeFile?.text, "My independent edit")
        controller.conflictChoices["README.md"] = false
        await controller.resolveConflicts()
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertEqual(controller.activeFile?.text, "Changed on GitHub")
        XCTAssertEqual(controller.activeFile?.commit, GitHubReviewHTTP.newSHA)
        XCTAssertTrue(GitHubReviewHTTP.state.requests.allSatisfy { $0.httpMethod == "GET" })
        controller.cancel()
    }

    func testZIPHasStandardCRCAndPreservesRelativeUTF8Paths() throws {
        XCTAssertEqual(CodingWorkspaceArchive.crc32(Data("123456789".utf8)), 0xcbf43926)
        let files = [file("Sources/Hello.swift", text: "print(\"Hello\")\n"), file("Notes/你好.md", text: "# Hello 🌍\n")]
        let archive = try CodingWorkspaceArchive.make(files: files)
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(archive.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertNotNil(archive.range(of: Data("Notes/你好.md".utf8)))
        XCTAssertNotNil(archive.range(of: Data("# Hello 🌍\n".utf8)))
        try archive.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("CodingWorkspaceFixture.zip"))
        XCTAssertThrowsError(try CodingWorkspaceArchive.make(files: [file("../escape", text: "x")]))
    }

    func testPreviewPolicyAlwaysPrecedesUserScriptsAndDisallowsNetworkAndFrames() {
        let html = CodingPreviewScheme.protectedHTML("<script>fetch('https://example.invalid')</script><head></head>")
        XCTAssertLessThan(html.range(of: "Content-Security-Policy")!.lowerBound, html.range(of: "<script>")!.lowerBound)
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("frame-src 'none'"))
        XCTAssertTrue(html.contains("form-action 'none'"))
        XCTAssertFalse(html.contains("script-src https:"))
    }
}
