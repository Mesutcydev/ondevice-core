import Foundation
import Combine

@MainActor
final class CodingWorkspaceController: ObservableObject {
    let workspace: GitHubWorkspaceService
    private let vault: CodingWorkspaceVault
    @Published private(set) var state = CodingWorkspaceState()
    @Published private(set) var entries: [CodingWorkspaceEntry] = []
    @Published private(set) var visibleEntries: [CodingWorkspaceEntry] = []
    @Published private(set) var symbols: [CodingWorkspaceText.Symbol] = []
    @Published private(set) var readingEntries: [CodingWorkspaceEntry] = []
    @Published private(set) var commit = ""
    @Published private(set) var isBusy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var conflicts: [String] = []
    @Published var conflictChoices: [String: Bool] = [:]
    @Published var folder = "" { didSet { filterEntries() } }
    @Published var search = "" { didSet { filterEntries() } }
    @Published var question = ""
    private var scope: String?
    private var operation = UUID()
    private var saveTask: Task<Void, Never>?
    private var outlineTask: Task<Void, Never>?
    private var restoredBlocked = false
    private var appliedReceipt: String?
    private var cancelRequest: (() -> Void)?
    private var networkRequestID: UUID?

    init(workspace: GitHubWorkspaceService, vault: CodingWorkspaceVault = CodingWorkspaceVault()) {
        self.workspace = workspace; self.vault = vault
    }
    var activeFile: CodingWorkspaceFile? { state.files.first { $0.path == state.activePath } }
    var hasUnsavedEdits: Bool { state.files.contains(where: \.hasUnstagedChanges) }
    var readingProgress: String { "\(state.readPaths.count) / \(readingEntries.count)" }

    /// Pull proposals made in chat into the editor without replacing independent edits.
    func synchronizeDraft() async {
        guard !isBusy, !workspace.isRunning, let draft = workspace.draft,
              scope == CodingWorkspaceText.scopeKey(draft) else { return }
        if let receipt = workspace.lastReceipt, receipt != appliedReceipt {
            appliedReceipt = receipt
            await resolveConflicts()
            return
        }
        var next = state
        for change in draft.changes {
            guard let text = change.updatedText, let commit = draft.baseSHA else { continue }
            if let index = next.files.firstIndex(where: { $0.path == change.path }) {
                let edited = next.files[index].hasUnstagedChanges
                if !edited { next.files[index].text = text }
                next.files[index].base = change.originalText
                next.files[index].stagedText = text
                next.files[index].commit = commit
                next.files[index].mode = change.mode
            } else if next.files.count < CodingWorkspaceLimits.files {
                next.files.append(.init(path: change.path, base: change.originalText, text: text,
                                        commit: commit, mode: change.mode, stagedText: text))
            }
        }
        do { _ = try next.validated(); state = next; filterEntries(); updateOutline(); scheduleSave() }
        catch { self.error = "Some proposed files exceed the editor's document limit. They remain available in GitHub review." }
    }

    func activate() async {
        guard let draft = workspace.draft else {
            cancel(); scope = nil; commit = ""; state = .init(); entries = []; filterEntries(); return
        }
        let next = CodingWorkspaceText.scopeKey(draft)
        if scope != next {
            await flush()
            cancel(); scope = next; state = .init(); entries = []; folder = ""; search = ""
            error = nil; notice = nil; restoredBlocked = false; appliedReceipt = nil
            conflicts = []; conflictChoices = [:]
            do {
                let restored = try await vault.load(scope: next)
                guard current(next) else { return }
                state = restored ?? .init()
                // A newer conversation draft wins only when there are no independent editor changes.
                for change in workspace.draft?.changes ?? [] {
                    guard let text = change.updatedText else { continue }
                    if !state.files.contains(where: { $0.path == change.path }), let sha = workspace.draft?.baseSHA {
                        state.files.append(.init(path: change.path, base: change.originalText, text: text,
                                                 commit: sha, mode: change.mode, stagedText: text))
                    }
                }
                if state.activePath == nil { state.activePath = state.files.first?.path }
                commit = state.files.first?.commit ?? ""
                entries = state.files.map { .init(path: $0.path, isDirectory: false) }
                filterEntries(); updateOutline()
            } catch {
                restoredBlocked = true
                self.error = "Saved code could not be unlocked. Your encrypted files have been retained. Unlock the device and reopen the workspace."
                return
            }
        }
        if (entries.isEmpty || !state.offlineEnabled) && current(next) { await refresh() }
    }

    func refresh() async {
        guard !isBusy, let scope, !restoredBlocked else { return }
        let request = operation
        isBusy = true; error = nil
        defer { if request == operation { isBusy = false } }
        do {
            let listing = try await performRequest { [workspace] in try await workspace.workspaceListing() }
            try Task.checkCancellation()
            guard current(scope), request == operation else { return }
            entries = listing.entries; commit = listing.commit
            notice = listing.truncated ? "Showing the first 2,000 repository entries. Use a narrower repository for omitted files." : nil
            filterEntries()
        } catch {
            if !(error is CancellationError), current(scope), request == operation {
                self.error = GitHubError.safeMessage(error)
                if !state.files.isEmpty { notice = "Saved files remain available offline." }
            }
        }
    }

    func open(_ path: String) async {
        if state.files.contains(where: { $0.path == path }) { select(path); return }
        guard !isBusy, !commit.isEmpty, let scope, !restoredBlocked else { return }
        let request = operation
        isBusy = true; error = nil
        defer { if request == operation { isBusy = false } }
        do {
            let pinnedCommit = commit
            let file = try await performRequest { [workspace] in try await workspace.workspaceFile(path: path, commit: pinnedCommit) }
            try Task.checkCancellation()
            guard current(scope), request == operation else { return }
            var candidate = state; candidate.files.append(file); candidate.activePath = path
            _ = try candidate.validated(); state = candidate
            updateOutline(); scheduleSave()
        } catch { if current(scope), request == operation { self.error = GitHubError.safeMessage(error) } }
    }

    func select(_ path: String) {
        state.activePath = path; updateOutline(); scheduleSave()
    }

    func edit(_ text: String) {
        guard let index = state.files.firstIndex(where: { $0.path == state.activePath }) else { return }
        guard text.utf8.count <= CodingWorkspaceLimits.fileBytes else { error = "A code file can contain at most 256 KB."; return }
        var candidate = state; candidate.files[index].text = text
        do { _ = try candidate.validated(); state = candidate; updateOutline(); scheduleSave() }
        catch { self.error = "This workspace has reached its 2 MB document limit. Close an unchanged file before adding more code." }
    }

    func updateSelection(_ range: NSRange, firstVisibleLine: Int) {
        guard let index = state.files.firstIndex(where: { $0.path == state.activePath }) else { return }
        state.files[index].selectedLocation = range.location
        state.files[index].selectedLength = range.length
        state.files[index].firstVisibleLine = max(1, firstVisibleLine)
        scheduleSave()
    }

    func goToLine(_ line: Int) {
        guard let file = activeFile else { return }
        let lines = file.text.components(separatedBy: "\n")
        let bounded = min(max(1, line), lines.count)
        let location = lines.prefix(bounded - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        updateSelection(NSRange(location: location, length: 0), firstVisibleLine: bounded)
    }

    func createFile(_ path: String) {
        do {
            let path = try GitHubValidation.path(path.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !commit.isEmpty, !entries.contains(where: { $0.path == path }), !state.files.contains(where: { $0.path == path }) else { throw GitHubError.invalidPath }
            var next = state
            next.files.append(.init(path: path, base: nil, text: "", commit: commit))
            next.activePath = path; _ = try next.validated(); state = next
            entries.append(.init(path: path, isDirectory: false)); filterEntries(); updateOutline(); scheduleSave()
        } catch { self.error = "Use a new relative file path in this repository, such as Sources/Example.swift." }
    }

    func close(_ path: String, discardEdits: Bool = false) {
        guard let file = state.files.first(where: { $0.path == path }), !file.hasUnstagedChanges || discardEdits else {
            error = "Stage this file or restore its previous content before closing it."; return
        }
        state.files.removeAll { $0.path == path }
        if file.base == nil && file.stagedText == nil { entries.removeAll { $0.path == path }; filterEntries() }
        state.pinnedPaths.removeAll { $0 == path }
        if state.activePath == path { state.activePath = state.files.last?.path }
        updateOutline(); scheduleSave()
    }

    func restoreActiveFile() {
        guard let index = state.files.firstIndex(where: { $0.path == state.activePath }) else { return }
        state.files[index].text = state.files[index].stagedText ?? state.files[index].base ?? ""
        updateOutline(); scheduleSave()
    }

    func stage() async {
        guard !isBusy, let file = activeFile, let scope else { return }
        isBusy = true; error = nil
        let request = operation
        defer { if request == operation { isBusy = false } }
        do {
            try await performRequest { [workspace] in try await workspace.stageWorkspaceFile(file) }
            guard current(scope), request == operation,
                  let index = state.files.firstIndex(where: { $0.path == file.path }) else { return }
            state.files[index].stagedText = file.text
            notice = "File staged. Review changes before committing to GitHub."
            scheduleSave()
        } catch { if current(scope), request == operation { self.error = GitHubError.safeMessage(error) } }
    }

    func resolveConflicts() async {
        guard !isBusy, let scope else { return }
        guard await checkpoint() else { return }
        isBusy = true; error = nil
        let request = operation
        defer { if request == operation { isBusy = false } }
        do {
            let choices = conflictChoices
            let editorFiles = state.files
            let pending = try await performRequest { [workspace] in
                try await workspace.refreshWorkspaceDraft(
                    keepLocal: Set(choices.filter { $0.value }.keys),
                    useRemote: Set(choices.filter { !$0.value }.keys), editorFiles: editorFiles)
            }
            guard current(scope), request == operation else { return }
            conflicts = pending
            if pending.isEmpty {
                conflictChoices = [:]
                let listing = try await performRequest { [workspace] in try await workspace.workspaceListing() }
                guard current(scope), request == operation else { return }
                entries = listing.entries; commit = listing.commit
                var refreshed: [CodingWorkspaceFile] = []
                for old in state.files {
                    let fresh: CodingWorkspaceFile?
                    let pinnedCommit = commit
                    do { fresh = try await performRequest { [workspace] in try await workspace.workspaceFile(path: old.path, commit: pinnedCommit) } }
                    catch GitHubError.notFound { fresh = nil }
                    guard current(scope), request == operation else { return }
                    if choices[old.path] == false || !old.hasUnstagedChanges {
                        if var fresh {
                            fresh.selectedLocation = old.selectedLocation; fresh.firstVisibleLine = old.firstVisibleLine
                            refreshed.append(fresh)
                        }
                    } else {
                        var kept = old
                        kept.base = fresh?.base; kept.stagedText = fresh?.stagedText; kept.commit = commit
                        refreshed.append(kept)
                    }
                }
                state.files = refreshed
                if !refreshed.contains(where: { $0.path == state.activePath }) { state.activePath = refreshed.first?.path }
                notice = "Updated to the current branch. Review the refreshed changes before publishing."
                filterEntries(); updateOutline(); scheduleSave()
            }
        } catch { if current(scope), request == operation { self.error = GitHubError.safeMessage(error) } }
    }

    func setOffline(_ enabled: Bool) {
        state.offlineEnabled = enabled; scheduleSave()
        notice = enabled ? "Open files will be encrypted and saved on this device for offline use." : "Clean files will no longer be cached. Edited drafts and explicit checkpoints remain protected."
    }

    @discardableResult func checkpoint() async -> Bool {
        guard let scope, !restoredBlocked else { return false }
        do {
            let checkpoint = CodingWorkspaceCheckpoint(id: UUID(), date: Date(), title: activeFile?.path ?? "Workspace")
            try await vault.save(state, scope: scope, checkpoint: checkpoint.id)
            guard current(scope) else { return false }
            state.checkpoints.insert(checkpoint, at: 0)
            let removed = state.checkpoints.dropFirst(CodingWorkspaceLimits.checkpoints)
            state.checkpoints = Array(state.checkpoints.prefix(CodingWorkspaceLimits.checkpoints))
            for item in removed { try await vault.remove(scope: scope, checkpoint: item.id) }
            notice = "Checkpoint saved on this device."; scheduleSave(); return true
        } catch { self.error = "The checkpoint could not be saved securely. Your current edits are still open."; return false }
    }

    func restoreCheckpoint(_ checkpoint: CodingWorkspaceCheckpoint) async {
        guard let scope else { return }
        do {
            // Read before creating the recovery point: that point may evict the
            // oldest checkpoint, including the one being restored.
            guard let restored = try await vault.load(scope: scope, checkpoint: checkpoint.id), current(scope) else { return }
            // Preserve the current editor state before replacing it.
            guard await self.checkpoint() else { return }
            guard current(scope) else { return }
            let checkpoints = state.checkpoints
            state = restored; state.checkpoints = checkpoints
            for index in state.files.indices {
                let change = workspace.draft?.changes.first { $0.path == state.files[index].path }
                state.files[index].stagedText = change?.updatedText
                if let change, let commit = workspace.draft?.baseSHA {
                    state.files[index].base = change.originalText; state.files[index].commit = commit
                }
            }
            updateOutline(); scheduleSave()
            notice = "Checkpoint restored to the editor. Staged GitHub changes have not been published or replaced."
            filterEntries()
        } catch { self.error = "The encrypted checkpoint could not be restored." }
    }

    func togglePin(_ path: String) {
        if state.pinnedPaths.contains(path) { state.pinnedPaths.removeAll { $0 == path } }
        else if state.pinnedPaths.count < 10 { state.pinnedPaths.append(path) }
        scheduleSave()
    }
    func bookmark() {
        guard let file = activeFile else { return }
        let item = CodingWorkspaceBookmark(path: file.path, line: file.selectedLines.lowerBound)
        if state.bookmarks.contains(item) { state.bookmarks.removeAll { $0.id == item.id } }
        else if state.bookmarks.count < 100 { state.bookmarks.append(item) }
        scheduleSave()
    }
    func removeBookmark(_ bookmark: CodingWorkspaceBookmark) {
        state.bookmarks.removeAll { $0.id == bookmark.id }; scheduleSave()
    }
    func markRead(_ selectedPath: String? = nil) {
        guard let path = selectedPath ?? state.activePath else { return }
        if state.readPaths.contains(path) { state.readPaths.removeAll { $0 == path } }
        else if state.readPaths.count < 2_000 { state.readPaths.append(path) }
        scheduleSave()
    }

    func makeQuestion(action: CodingWorkspaceText.Action, maximumCharacters: Int) async -> String? {
        let originalScope = scope
        let request = operation
        let originalPath = state.activePath
        defer { if scope == originalScope, let originalPath { select(originalPath) } }
        var paths = state.pinnedPaths
        if let active = state.activePath, !paths.contains(active) { paths.insert(active, at: 0) }
        // Mentions resolve only inside the currently selected repository and bounded tree.
        let mentions = CodingWorkspaceText.mentions(in: question)
        for clean in mentions {
            for entry in entries where !entry.isDirectory && (entry.path == clean || entry.path.hasPrefix(clean + "/")) {
                guard paths.count < 10 else { break }
                if !state.files.contains(where: { $0.path == entry.path }) { await open(entry.path) }
                guard scope == originalScope, request == operation else { return nil }
                if !paths.contains(entry.path) { paths.append(entry.path) }
            }
        }
        guard !paths.isEmpty, paths.contains(where: { path in state.files.contains { $0.path == path } }) else {
            error = "Open a file or attach a file with @path before asking about code."; return nil
        }
        let prompt = CodingWorkspaceText.context(files: state.files, paths: paths, action: action, question: question,
                                                selectionOnly: state.pinnedPaths.isEmpty && mentions.isEmpty,
                                                maximumCharacters: maximumCharacters)
        guard prompt.contains("SOURCE ") else { error = "Select a smaller code range or use a model with more context space."; return nil }
        return prompt
    }

    func cancel() {
        operation = UUID(); isBusy = false; outlineTask?.cancel(); cancelRequest?(); cancelRequest = nil; networkRequestID = nil
        workspace.cancel()
    }
    private func performRequest<Value: Sendable>(_ body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let task = Task { try await body() }
        let id = UUID(); networkRequestID = id
        cancelRequest = { task.cancel() }
        defer { if networkRequestID == id { cancelRequest = nil; networkRequestID = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func flush() async {
        saveTask?.cancel(); saveTask = nil
        guard let scope, !restoredBlocked else { return }
        do { try await vault.save(state, scope: scope) }
        catch { self.error = "Code could not be saved securely. Keep this workspace open and retry after unlocking the device." }
    }
    func wipe() async {
        saveTask?.cancel(); outlineTask?.cancel(); cancel()
        scope = nil; state = .init(); entries = []; symbols = []; filterEntries()
        question = ""; folder = ""; search = ""; conflicts = []; conflictChoices = [:]; error = nil; notice = nil
        try? await vault.clearAll()
    }
    private func current(_ key: String) -> Bool {
        guard let draft = workspace.draft else { return false }
        return scope == key && CodingWorkspaceText.scopeKey(draft) == key && !Task.isCancelled
    }
    private func scheduleSave() {
        saveTask?.cancel()
        guard let scope, !restoredBlocked else { return }
        let snapshot = state, vault = vault
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                try await vault.save(snapshot, scope: scope)
            } catch is CancellationError { }
            catch { self?.error = "Code could not be saved securely. Unlock the device and retry." }
        }
    }
    private func updateOutline() {
        outlineTask?.cancel()
        let text = activeFile?.text ?? "", path = state.activePath
        outlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let symbols = await Task.detached(priority: .utility) { CodingWorkspaceText.outline(text) }.value
            guard !Task.isCancelled, self?.state.activePath == path else { return }
            self?.symbols = symbols
        }
    }
    private func filterEntries() {
        var paths = Set(entries.map(\.path))
        for file in state.files where paths.insert(file.path).inserted {
            entries.append(.init(path: file.path, isDirectory: false))
        }
        var folders = Set(entries.filter(\.isDirectory).map(\.path))
        for file in state.files {
            let components = file.path.split(separator: "/")
            for count in 1..<components.count {
                let path = components.prefix(count).joined(separator: "/")
                if folders.insert(path).inserted { entries.append(.init(path: path, isDirectory: true)) }
            }
        }
        visibleEntries = entries.filter { entry in
            if !search.isEmpty { return entry.path.localizedCaseInsensitiveContains(search) }
            let prefix = folder.isEmpty ? "" : folder + "/"
            guard entry.path.hasPrefix(prefix) else { return false }
            return !entry.path.dropFirst(prefix.count).contains("/")
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        readingEntries = entries.filter { !$0.isDirectory }.sorted {
            let a = $0.path.lowercased().contains("readme"), b = $1.path.lowercased().contains("readme")
            if a != b { return a }
            return $0.path < $1.path
        }
    }
}
