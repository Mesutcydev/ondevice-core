import Foundation
import Combine
import UIKit

// MARK: - Persistent conversation storage
// Saves to ~/Documents/conversations.json via Codable.
// Each conversation is a named list of messages.

final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()
    static let unreadableCopyPrefix = "conversations-unreadable-"

    @Published private(set) var conversations: [StoredConversation] = []

    private let fileURL: URL

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saveTask: Task<Void, Never>?
    private var persistRetryCount = 0
    private var unlockObservers: [NSObjectProtocol] = []

    /// Saves run off-main. The lock orders them against a wipe and against
    /// a file that exists but can't be read yet; both outrank any save.
    private let writeLock = NSLock()
    /// Bumped by a wipe. Guarded by `writeLock`.
    private var writeGeneration = 0
    /// The file is still protected (a background launch before unlock).
    /// It isn't empty, so nothing may replace it. Guarded by `writeLock`.
    private var fileIsUnreadable = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversations.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - CRUD

    func create(title: String = "New Chat") -> StoredConversation {
        let conv = StoredConversation(title: title)
        conversations.insert(conv, at: 0)
        scheduleSave()
        return conv
    }

    func update(id: UUID, messages: [ChatMessage]) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages = messages.map(StoredMessage.init)
        conversations[idx].updatedAt = .now
        if conversations[idx].title == "New Chat", let first = messages.first(where: { $0.role == .user }) {
            conversations[idx].title = String(first.content.prefix(40))
        }
        scheduleSave()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Navigation metadata only. Pinning never rewrites a transcript or draft.
    func setPinned(_ pinned: Bool, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              (conversations[index].isPinned ?? false) != pinned else { return }
        conversations[index].isPinned = pinned
        conversations[index].updatedAt = .now
        scheduleSave()
    }

    func messages(for id: UUID) -> [ChatMessage] {
        conversations.first(where: { $0.id == id })?.messages.map(\.chatMessage) ?? []
    }

    // Creates a new conversation or updates an existing one by id.
    func saveConversation(
        id: UUID,
        messages: [ChatMessage],
        contextMemory: ConversationContextMemory? = nil,
        assistantModelID: String? = nil
    ) {
        if conversations.contains(where: { $0.id == id }) {
            update(id: id, messages: messages)
            if let idx = conversations.firstIndex(where: { $0.id == id }) {
                conversations[idx].contextMemory = contextMemory
                if let assistantModelID {
                    conversations[idx].assistantModelID = assistantModelID
                }
            }
        } else {
            var conv = StoredConversation()
            conv.id = id
            conv.messages = messages.map(StoredMessage.init)
            conv.contextMemory = contextMemory
            conv.assistantModelID = assistantModelID
            if let first = messages.first(where: { $0.role == .user }) {
                conv.title = String(first.content.prefix(40))
            }
            conversations.insert(conv, at: 0)
        }
        scheduleSave()
    }

    func deleteConversations(at offsets: IndexSet) {
        offsets.map { conversations[$0].id }.forEach { delete(id: $0) }
    }

    /// UI restoration belongs to the same protected, atomically saved conversation file.
    /// It never changes message history or the model's context.
    func savePresentation(id: UUID, presentation: ConversationPresentation) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard conversations[index].presentation != presentation else { return }
        conversations[index].presentation = presentation
        scheduleSave()
    }

    func preserveUnsentDraft(id: UUID, draft: ConversationPresentation) {
        guard draft.hasDraft, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var drafts = conversations[index].unsentDrafts ?? []
        guard !drafts.contains(draft) else { return }
        drafts.append(draft)
        conversations[index].unsentDrafts = drafts
        scheduleSave()
    }

    func takeUnsentDraft(id: UUID, at draftIndex: Int) -> ConversationPresentation? {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              var drafts = conversations[index].unsentDrafts, drafts.indices.contains(draftIndex) else { return nil }
        let draft = drafts.remove(at: draftIndex)
        conversations[index].unsentDrafts = drafts.isEmpty ? nil : drafts
        scheduleSave()
        return draft
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error where Self.isLockedFileError(error) {
            // `completeUnlessOpen` keeps the file closed until the device
            // unlocks, e.g. during a background download relaunch. Starting
            // empty here let the next save replace every saved chat.
            Diagnostics.shared.breadcrumb("conversation load deferred until unlock", category: "conversations")
            writeLock.withLock { fileIsUnreadable = true }
            let center = NotificationCenter.default
            unlockObservers = [UIApplication.protectedDataDidBecomeAvailableNotification,
                               UIApplication.didBecomeActiveNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.retryDeferredLoad()
                }
            }
            return
        } catch {
            setAsideUnreadableFile(error)
            return
        }
        apply(data)
    }

    private func retryDeferredLoad() {
        guard writeLock.withLock({ fileIsUnreadable }) else { return }
        let data: Data?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let readable = try? Data(contentsOf: fileURL) else { return }
            data = readable
        } else {
            data = nil
        }
        writeLock.withLock { fileIsUnreadable = false }
        unlockObservers.forEach(NotificationCenter.default.removeObserver)
        unlockObservers = []
        if let data { apply(data) } else if !conversations.isEmpty { scheduleSave() }
    }

    private func apply(_ data: Data) {
        let decoded: [LossyConversation]
        do {
            decoded = try decoder.decode([LossyConversation].self, from: data)
        } catch {
            setAsideUnreadableFile(error)
            return
        }
        let stored = decoded.compactMap(\.value)
        if stored.count < decoded.count {
            // One bad record no longer hides the rest; keep the original.
            Diagnostics.shared.error(
                "conversation load skipped \(decoded.count - stored.count) unreadable records",
                category: "conversations"
            )
            try? FileManager.default.copyItem(at: fileURL, to: unreadableCopyURL())
        }
        // One-time cleanup: older builds let a thinking model's raw "<think>…"
        // output become the conversation title (visible in History / Home).
        // Strip any reasoning so the list reads cleanly.
        var changed = stored.count < decoded.count
        let restored = stored.map { conv in
            if conv.gitHubWorkspace?.changes.contains(where: \.needsEncryptionMigration) == true { changed = true }
            guard conv.title.contains("<think>") else { return conv }
            var c = conv
            c.title = Self.stripReasoningFromTitle(conv.title)
            changed = true
            return c
        }
        // Chats started while the file was unreadable stay alongside it.
        let restoredIDs = Set(restored.map(\.id))
        let created = conversations.filter { !restoredIDs.contains($0.id) }
        conversations = created + restored
        if changed || !created.isEmpty { scheduleSave() }
    }

    /// An undecodable file is moved aside, never overwritten by the next save.
    private func setAsideUnreadableFile(_ error: Error) {
        Diagnostics.shared.error(
            "conversation load failed: \(error.localizedDescription)",
            category: "conversations"
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: unreadableCopyURL())
        } catch {
            // Can't move it either: keep it intact for this session.
            writeLock.withLock { fileIsUnreadable = true }
        }
        DispatchQueue.main.async {
            ToastCenter.shared.error(
                "Couldn't read saved conversations",
                detail: "The original file was kept, so nothing in it is overwritten."
            )
        }
    }

    /// Data protection surfaces as a permission error, never as missing data.
    static func isLockedFileError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        guard let posix = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    private func unreadableCopyURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.unreadableCopyPrefix)\(stamp).json")
    }

    private struct LossyConversation: Decodable {
        let value: StoredConversation?
        init(from decoder: Decoder) throws { value = try? StoredConversation(from: decoder) }
    }

    /// Removes a `<think>…</think>` (or unclosed `<think>…`) block from a
    /// title; falls back to "Chat" when nothing usable remains.
    private static func stripReasoningFromTitle(_ raw: String) -> String {
        var s = raw
        if let close = s.range(of: "</think>", options: [.backwards]) {
            s = String(s[close.upperBound...])
        } else if let open = s.range(of: "<think>") {
            s = String(s[..<open.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Chat" : String(s.prefix(60))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        // Snapshot NOW, on the caller (the main actor, where every create/
        // update/delete/setTitle mutation happens). The debounced write then
        // encodes this immutable copy off-main instead of reading the live
        // @Published `conversations` array — which previously raced concurrent
        // main-actor mutations (a non-Sendable Array read+write data race that
        // can corrupt the COW buffer / crash). Each new mutation re-snapshots
        // and cancels the prior task, so the latest state still wins.
        let snapshot = conversations
        let generation = writeLock.withLock { writeGeneration }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist(snapshot, generation: generation)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        writeLock.withLock { generation == writeGeneration }
    }

    private func persist(_ snapshot: [StoredConversation], generation: Int) {
        do {
            let data = try encoder.encode(snapshot)
            // At-rest encryption: `completeUnlessOpen` lets a locked device
            // create the file, but reopening it needs an unlocked device;
            // `load()` defers until then instead of starting empty.
            let written = try writeLock.withLock { () throws -> Bool in
                // A wipe, or a file not yet readable, outranks this snapshot.
                guard generation == writeGeneration, !fileIsUnreadable else { return false }
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                return true
            }
            guard written else { return }
            persistRetryCount = 0
            SpotlightIndexer.reindexAll(snapshot) { [weak self] in self?.isCurrent(generation) ?? false }
        } catch {
            Diagnostics.shared.error(
                "conversation persist failed: \(error.localizedDescription)",
                category: "conversations"
            )
            if persistRetryCount < 2 {
                persistRetryCount += 1
                saveTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled else { return }
                    self?.persist(snapshot, generation: generation)
                }
            } else {
                persistRetryCount = 0
                DispatchQueue.main.async {
                    ToastCenter.shared.error(
                        "Couldn't save conversations",
                        detail: "Your latest changes may be lost if the app closes. Try again."
                    )
                }
            }
        }
    }

    /// Cancel the debounce and persist immediately. Call on scene-phase
    /// background so the user's most recent turn isn't lost if the app is
    /// suspended/terminated within the 500 ms save window.
    func flush() {
        saveTask?.cancel()
        persist(conversations, generation: writeLock.withLock { writeGeneration })
    }

    /// Clear all in-memory conversations for a privacy wipe. Call before
    /// deleting the file: it waits for a write already in progress and
    /// retires every earlier snapshot, so no save or Spotlight reindex can
    /// restore wiped chats afterwards.
    func clearAllForWipe() {
        saveTask?.cancel()
        saveTask = nil
        writeLock.withLock {
            writeGeneration += 1
            fileIsUnreadable = false
        }
        unlockObservers.forEach(NotificationCenter.default.removeObserver)
        unlockObservers = []
        conversations = []
    }

    /// Public title update — used by ConversationTitler.
    func setTitle(_ title: String, for id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        conversations[idx].updatedAt = .now
        scheduleSave()
    }

    /// Persists model-facing long-conversation memory without rewriting the
    /// visible transcript (which may currently contain a streaming message).
    func setContextMemory(_ memory: ConversationContextMemory?, for id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].contextMemory = memory
        conversations[idx].updatedAt = .now
        scheduleSave()
    }

    /// Repository scope and staged file snapshots contain no authentication material.
    func setGitHubWorkspace(_ workspace: GitHubWorkspaceDraft?, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].gitHubWorkspace != workspace else { return }
        conversations[index].gitHubWorkspace = workspace
        conversations[index].updatedAt = .now
        scheduleSave()
    }

    // MARK: - Pagination

    /// Returns the most recent `pageSize` messages for a conversation, plus
    /// a flag indicating whether older messages exist. Use to lazy-load long
    /// chat histories instead of loading 500+ messages on conversation open.
    func recentMessages(for id: UUID, pageSize: Int = 200) -> (messages: [ChatMessage], hasMore: Bool) {
        guard let conv = conversations.first(where: { $0.id == id }) else {
            return ([], false)
        }
        let all = conv.messages.map(\.chatMessage)
        if all.count <= pageSize { return (all, false) }
        return (Array(all.suffix(pageSize)), true)
    }

    /// Returns the next-older window of messages for incremental scroll-back.
    /// `before` is the index from the end of the conversation (so callers
    /// can paginate without keeping cursors).
    func olderMessages(for id: UUID, before: Int, pageSize: Int = 200) -> [ChatMessage] {
        guard let conv = conversations.first(where: { $0.id == id }) else { return [] }
        let all = conv.messages.map(\.chatMessage)
        let endIdx = Swift.max(0, all.count - before)
        let startIdx = Swift.max(0, endIdx - pageSize)
        return Array(all[startIdx..<endIdx])
    }
}

// MARK: - Codable models

struct StoredConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [StoredMessage]
    /// Model selected for this thread. Optional keeps older conversation files
    /// decodable; nil means use the user's default assistant model.
    var assistantModelID: String?
    /// Optional for legacy records. Scope and draft belong to this chat, not a global selection.
    var gitHubWorkspace: GitHubWorkspaceDraft?
    /// Bounded model-facing memory made from turns older than the live context
    /// window. The full transcript remains in `messages` for display/export.
    var contextMemory: ConversationContextMemory?
    var presentation: ConversationPresentation?
    var unsentDrafts: [ConversationPresentation]?
    /// Optional so conversation files from older builds continue to decode.
    var isPinned: Bool?
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.assistantModelID = nil
        self.contextMemory = nil
        self.createdAt = .now
        self.updatedAt = .now
    }

    // MARK: - Export

    /// Plain markdown export — pastes nicely into Notes, Obsidian, GitHub, etc.
    var markdownExport: String {
        var out = "# \(title)\n\n"
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        out += "_Created \(df.string(from: createdAt)) · "
        out += "Last updated \(df.string(from: updatedAt))_\n\n---\n\n"
        for m in messages where m.role != "system" {
            let heading = m.role == "user" ? "### You" : "### Assistant"
            out += "\(heading)\n\n\(m.content)\n\n"
        }
        return out
    }

    /// Structured JSON export for round-tripping back into the app.
    var jsonExport: Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    /// True when any message body matches `query` (case-insensitive),
    /// or when the title matches. Empty query returns true.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        if title.lowercased().contains(q) { return true }
        return messages.contains { $0.content.lowercased().contains(q) }
    }
}

/// Optional on old records. Attachments store already-extracted, bounded content;
/// restoring a draft does not reopen a security-scoped URL or perform network work.
struct ConversationPresentation: Codable, Equatable {
    var text: String = ""
    var files: [FileAttachmentService.Attachment] = []
    var images: [ChatMessage.ImageAttachment] = []
    var imageIDs: [UUID] = []
    var legacyImage: Data?
    var legacyImageID: UUID = UUID()
    var readingMessageID: UUID?
    var followsLatest: Bool = true
    /// Local disclosure choices, keyed by the first durable message in each group.
    /// Optional keeps presentation records written by earlier builds decodable.
    var expandedToolGroupIDs: Set<UUID>?

    var hasDraft: Bool { !text.isEmpty || !files.isEmpty || !images.isEmpty || legacyImage != nil }
}

struct StoredMessage: Codable {
    var id: UUID
    var role: String        // "user" | "assistant" | "system"
    var content: String
    /// Hidden grounding used by the model for later turns. Optional keeps
    /// conversations written by older builds fully decodable.
    var modelContent: String?
    var timestamp: Date
    var generationTokensPerSecond: Double?
    var generationDuration: TimeInterval?
    var reasoningStartedAt: Date?
    var reasoningDuration: TimeInterval?
    var generationModelID: String?
    var generationExecutionLocation: ModelExecutionLocation?
    var hitTokenLimit: Bool?
    var documentSources: [ChatMessage.DocumentSource]?

    init(_ msg: ChatMessage) {
        self.id = msg.id
        self.role = msg.role.rawValue
        self.content = msg.content
        self.modelContent = msg.modelContent
        self.timestamp = msg.timestamp
        self.generationTokensPerSecond = msg.generationTokensPerSecond
        self.generationDuration = msg.generationDuration
        self.reasoningStartedAt = msg.reasoningStartedAt
        self.reasoningDuration = msg.reasoningDuration
        self.generationModelID = msg.generationModelID
        self.generationExecutionLocation = msg.generationExecutionLocation
        self.hitTokenLimit = msg.hitTokenLimit
        self.documentSources = msg.documentSources
    }

    var chatMessage: ChatMessage {
        var message = ChatMessage(
            id: id,
            role: ChatMessage.Role(rawValue: role) ?? .user,
            content: content,
            modelContent: modelContent,
            timestamp: timestamp,
            generationTokensPerSecond: generationTokensPerSecond,
            generationDuration: generationDuration,
            generationModelID: generationModelID,
            generationExecutionLocation: generationExecutionLocation,
            hitTokenLimit: hitTokenLimit
        )
        message.documentSources = documentSources
        message.reasoningStartedAt = reasoningStartedAt
        message.reasoningDuration = reasoningDuration
        return message
    }
}

// MARK: - Conversation sharing

enum ConversationShareFormatter {
    /// A clean, portable transcript for the system share sheet.
    ///
    /// System prompts and tool plumbing are deliberately omitted because they
    /// are not part of the visible conversation. Streaming placeholders with
    /// no content are omitted as well.
    static func markdown(title: String, messages: [ChatMessage]) -> String {
        let turns = messages.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            let heading: String
            switch message.role {
            case .user:
                heading = String(localized: "You")
            case .assistant:
                heading = String(localized: "Assistant")
            case .system, .tool:
                return nil
            }
            return "### \(heading)\n\n\(content)"
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = cleanTitle.isEmpty ? String(localized: "Conversation") : cleanTitle
        return (["# \(displayTitle)"] + turns).joined(separator: "\n\n")
    }
}

// MARK: - Long-conversation context compaction

/// Persistent, model-facing memory for the part of a transcript that no
/// longer fits verbatim. `compactedThroughMessageID` makes compaction
/// incremental: later sends summarize only newly-expired turns.
struct ConversationContextMemory: Codable, Equatable {
    var summary: String
    var compactedThroughMessageID: UUID
    var updatedAt: Date
    var estimatedTokensBefore: Int? = nil
    var estimatedTokensAfter: Int? = nil
    var modelDisplayName: String? = nil

    var compactionNotice: String {
        if let before = estimatedTokensBefore, let after = estimatedTokensAfter {
            let model = modelDisplayName.map { " with \($0)" } ?? ""
            return "Earlier context was compacted from approximately \(before.formatted()) to \(after.formatted()) tokens to continue safely\(model)."
        }
        return "Earlier context was compacted to keep this conversation within the model’s context window."
    }
}

struct ConversationContextPreparation {
    var messages: [ChatMessage]
    var memory: ConversationContextMemory?
    var didCompact: Bool
}

enum ConversationContextCompactor {
    /// Start before the runtime's hard trim point, leaving room for attachment,
    /// web, tool, and chat-template overhead that is added after this pass.
    static let triggerFraction = 0.72
    static let recentDialogFraction = 0.46
    static let memoryFraction = 0.20

    static func prepare(
        messages: [ChatMessage],
        existingMemory: ConversationContextMemory?,
        maxTokens: Int,
        modelDisplayName: String? = nil,
        retainingRecentSource: Bool = false
    ) -> ConversationContextPreparation {
        guard maxTokens > 0 else {
            return .init(messages: messages, memory: existingMemory, didCompact: false)
        }

        let systemMessages = messages.filter { $0.role == .system }
        let fullDialog = messages.filter { $0.role != .system }

        // The caller supplies the complete stored transcript. A source-aware
        // runtime can recover it after moving to a larger input budget, rather
        // than continuing to hide code behind an old compaction cursor.
        if retainingRecentSource, estimateTokens(messages) <= maxTokens {
            return .init(messages: messages, memory: nil, didCompact: false)
        }

        // If the stored boundary disappeared (for example after importing or
        // editing a transcript), discard the stale memory instead of hiding
        // unrelated messages behind an invalid cursor.
        let validMemory: ConversationContextMemory?
        let activeDialog: [ChatMessage]
        if let existingMemory,
           let boundary = fullDialog.firstIndex(where: {
               $0.id == existingMemory.compactedThroughMessageID
           }) {
            validMemory = existingMemory
            activeDialog = Array(fullDialog.suffix(from: boundary + 1))
        } else {
            validMemory = nil
            activeDialog = fullDialog
        }

        let current = assemble(
            systemMessages: systemMessages,
            memory: validMemory,
            dialog: activeDialog
        )
        let threshold = retainingRecentSource ? 1.0 : triggerFraction
        let triggerTokens = max(1, Int(Double(maxTokens) * threshold))
        guard estimateTokens(current) > triggerTokens else {
            return .init(messages: current, memory: validMemory, didCompact: false)
        }

        // Keep a generous recent suffix verbatim. Only compact a prefix ending
        // in a completed assistant/tool response so a user/assistant turn is
        // never split across memory and live context.
        let recentBudget = max(128, Int(Double(maxTokens) * recentDialogFraction))
        var recentCost = 0
        var provisionalCut = activeDialog.count
        for index in activeDialog.indices.reversed() {
            let cost = estimateTokens(activeDialog[index])
            if recentCost + cost > recentBudget, index < activeDialog.count - 2 {
                provisionalCut = index + 1
                break
            }
            recentCost += cost
            provisionalCut = index
        }

        guard provisionalCut > 0 else {
            return .init(messages: current, memory: validMemory, didCompact: false)
        }
        let completedCut = stride(from: provisionalCut, through: 1, by: -1)
            .first { cut in
                let role = activeDialog[cut - 1].role
                return role == .assistant || role == .tool
            }
        guard let cut = completedCut, activeDialog.count - cut >= 2 else {
            return .init(messages: current, memory: validMemory, didCompact: false)
        }

        let expired = Array(activeDialog[..<cut])
        let recent = Array(activeDialog[cut...])
        guard let boundaryID = expired.last?.id else {
            return .init(messages: current, memory: validMemory, didCompact: false)
        }

        let summary = mergedSummary(
            previous: validMemory?.summary,
            expired: expired,
            maxCharacters: max(600, Int(Double(maxTokens * 4) * memoryFraction))
        )
        var memory = ConversationContextMemory(
            summary: summary,
            compactedThroughMessageID: boundaryID,
            updatedAt: .now,
            estimatedTokensBefore: estimateTokens(current),
            modelDisplayName: modelDisplayName
        )
        let compacted = assemble(systemMessages: systemMessages, memory: memory, dialog: recent)
        memory.estimatedTokensAfter = estimateTokens(compacted)
        return .init(
            messages: compacted,
            memory: memory,
            didCompact: true
        )
    }

    static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    private static func estimateTokens(_ message: ChatMessage) -> Int {
        message.contentForModel.count / 4 + 4
    }

    private static func assemble(
        systemMessages: [ChatMessage],
        memory: ConversationContextMemory?,
        dialog: [ChatMessage]
    ) -> [ChatMessage] {
        guard let memory else { return systemMessages + dialog }
        let memoryMessage = ChatMessage(
            id: memory.compactedThroughMessageID,
            role: .system,
            content: """
            [CONVERSATION MEMORY]
            This is a compact record of earlier turns. Use it as background \
            context, preserve stated goals and decisions, and defer to newer \
            verbatim messages if anything conflicts.

            \(memory.summary)
            """
        )
        return systemMessages + [memoryMessage] + dialog
    }

    private static func mergedSummary(
        previous: String?,
        expired: [ChatMessage],
        maxCharacters: Int
    ) -> String {
        var sections: [String] = []
        if let previous, !previous.isEmpty {
            sections.append("Earlier memory:\n\(previous)")
        }
        sections.append("Newly compacted turns:\n" + expired.map(summaryLine).joined(separator: "\n"))
        return bounded(sections.joined(separator: "\n\n"), maxCharacters: maxCharacters)
    }

    private static func summaryLine(_ message: ChatMessage) -> String {
        let label: String
        switch message.role {
        case .user: label = "User"
        case .assistant: label = "Assistant"
        case .tool: label = "Tool"
        case .system: label = "System"
        }
        var content = message.contentForModel
            .replacingOccurrences(of: "\\s+", with: " ",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if content.count > 700 {
            content = bounded(content, maxCharacters: 700)
        }
        if !message.imageThumbnails.isEmpty || message.imageThumbnailData != nil {
            content += " [image attached]"
        }
        return "- \(label): \(content)"
    }

    /// Preserve both the original goal at the beginning and the most recent
    /// compacted decisions at the end when memory itself reaches its cap.
    private static func bounded(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let marker = "\n[…older detail compacted…]\n"
        let available = max(0, maxCharacters - marker.count)
        let headCount = Int(Double(available) * 0.45)
        let tailCount = available - headCount
        return String(text.prefix(headCount)) + marker + String(text.suffix(tailCount))
    }
}
