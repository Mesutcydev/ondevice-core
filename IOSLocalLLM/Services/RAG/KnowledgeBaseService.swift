import Foundation
import Combine

// MARK: - KnowledgeBaseService
//
// On-device RAG over the user's own files / pasted text. Index a document and
// it's chunked, embedded with `OnDeviceEmbedder` (no download, no network),
// and persisted to Application Support. At ask-time the assistant retrieves the
// most relevant chunks by cosine similarity and injects them as grounding
// context — "chat with your documents/codebase, fully offline."
//
// Everything stays on device: vectors live in a local JSON index, never
// uploaded. Documents remain available for local retrieval without a remote index.

struct KBDocument: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var addedAt: Date
    var chunkCount: Int
    var byteCount: Int
}

struct KBChunk: Codable, Sendable {
    let id: UUID
    let docID: UUID
    let text: String
    let vector: [Float]
    var pageNumber: Int? = nil
}

/// A retrieved chunk with its similarity score and originating document name.
struct KBRetrieval: Identifiable, Sendable {
    let id: UUID
    let docID: UUID
    let docName: String
    let text: String
    let score: Float
    var pageNumber: Int? = nil
}

@MainActor
final class KnowledgeBaseService: ObservableObject {

    static let shared = KnowledgeBaseService()

    @Published private(set) var documents: [KBDocument] = []
    @Published private(set) var isIndexing = false
    /// When true the assistant augments answers with retrieved KB context.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var chunks: [KBChunk] = []
    private var importGate = StudioImportGate()
    private var importJobs: [UUID: Task<[KBChunk], Never>] = [:]
    private let diskQueue = DispatchQueue(label: "studio.knowledge-base.persistence", qos: .utility)

    func cancelImports() {
        importGate.reset()
        importJobs.values.forEach { $0.cancel() }
        importJobs.removeAll()
        isIndexing = false
    }
    private let embedder = OnDeviceEmbedder()

    private static let enabledKey = "knowledgeBase.enabled"

    /// Guardrails so a giant paste can't OOM the embedder or balloon the index.
    private let maxCharsPerDoc = 600_000          // ~150k tokens of source
    private let chunkChars = 1_600                // ~400 tokens
    private let overlapChars = 200                // ~50 tokens
    private let maxChunksPerDoc = 400
    private let maxTotalChunks = 5_000

    /// True when on-device embeddings are usable (language model present).
    var isAvailable: Bool { embedder.isAvailable }
    var totalChunks: Int { chunks.count }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        load()
    }

    // MARK: - Mutation

    /// Chunk + embed `text` and add it as a document named `name`. Embedding
    /// runs off the main actor; the index is updated and persisted on return.
    func addDocument(name: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, embedder.isAvailable else {
            if !embedder.isAvailable {
                ToastCenter.shared.error("Knowledge Base unavailable",
                                         detail: "On-device embeddings aren't supported for this language.")
            }
            return
        }
        if chunks.count >= maxTotalChunks {
            ToastCenter.shared.error("Knowledge Base full",
                                     detail: "Remove older documents before indexing more.")
            return
        }
        let clipped = String(trimmed.prefix(maxCharsPerDoc))
        let ticket = importGate.generation
        let jobID = UUID()
        isIndexing = true
        defer {
            importJobs.removeValue(forKey: jobID)
            isIndexing = !importJobs.isEmpty
        }

        let docID = UUID()

        let chunkChars = self.chunkChars
        let overlapChars = self.overlapChars
        let maxChunks = self.maxChunksPerDoc

        let job = Task.detached(priority: .userInitiated) {
            let embedder = OnDeviceEmbedder()
            let windows = Self.chunk(clipped, chunkChars: chunkChars,
                                     overlapChars: overlapChars, maxChunks: maxChunks)
            var out: [KBChunk] = []
            out.reserveCapacity(windows.count)
            for w in windows {
                guard !Task.isCancelled else { return [KBChunk]() }
                guard let v = embedder.embed(w) else { continue }
                out.append(KBChunk(id: UUID(), docID: docID, text: w, vector: v))
            }
            return out
        }
        importJobs[jobID] = job
        let newChunks = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        guard ticket == importGate.generation, !Task.isCancelled, !job.isCancelled else { return }

        guard !newChunks.isEmpty else {
            ToastCenter.shared.error("Couldn't index \(name)", detail: "No embeddable text found.")
            return
        }

        guard importGate.accepts(ticket, existing: chunks.count, incoming: newChunks.count, limit: maxTotalChunks) else {
            ToastCenter.shared.error("Knowledge Base full", detail: "This document exceeds the remaining capacity. Remove a document and try again.")
            return
        }
        chunks.append(contentsOf: newChunks)
        documents.append(KBDocument(id: docID, name: name, addedAt: Date(),
                                    chunkCount: newChunks.count, byteCount: clipped.utf8.count))
        persist()
        HapticManager.impact(.medium)
        ToastCenter.shared.success("Added to Knowledge Base",
                                   detail: "\(name) · \(newChunks.count) chunks")
    }

    /// A PDF is indexed by page instead of by its first 64 KB. Keeping one
    /// bounded record per page makes a late answer discoverable while the
    /// prompt still receives only pages relevant to the current question.
    func addPDFDocument(
        name: String, pages: [FileAttachmentService.PDFPageText]
    ) async {
        let readable = pages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !readable.isEmpty, embedder.isAvailable else {
            if !embedder.isAvailable {
                ToastCenter.shared.error("Knowledge Base unavailable",
                                         detail: "On-device embeddings aren't supported for this language.")
            }
            return
        }
        if chunks.count + readable.count > maxTotalChunks {
            ToastCenter.shared.error("Knowledge Base full",
                                     detail: "Remove older documents before indexing more.")
            return
        }
        let ticket = importGate.generation
        let jobID = UUID()
        let docID = UUID()
        isIndexing = true
        defer {
            importJobs.removeValue(forKey: jobID)
            isIndexing = !importJobs.isEmpty
        }
        let job = Task.detached(priority: .userInitiated) {
            let worker = OnDeviceEmbedder()
            var out: [KBChunk] = []
            out.reserveCapacity(readable.count)
            for page in readable {
                guard !Task.isCancelled else { return [KBChunk]() }
                guard let vector = worker.embed(page.text) else { continue }
                out.append(KBChunk(id: UUID(), docID: docID, text: page.text,
                                   vector: vector, pageNumber: page.number))
            }
            return out
        }
        importJobs[jobID] = job
        let newChunks = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard ticket == importGate.generation, !Task.isCancelled, !job.isCancelled else { return }
        guard !newChunks.isEmpty else {
            ToastCenter.shared.error("Couldn't index \(name)", detail: "No embeddable pages found.")
            return
        }
        guard importGate.accepts(ticket, existing: chunks.count,
                                 incoming: newChunks.count, limit: maxTotalChunks) else {
            ToastCenter.shared.error("Knowledge Base full",
                                     detail: "This document exceeds the remaining capacity.")
            return
        }
        chunks.append(contentsOf: newChunks)
        documents.append(KBDocument(id: docID, name: name, addedAt: Date(),
                                    chunkCount: newChunks.count,
                                    byteCount: readable.reduce(0) { $0 + $1.text.utf8.count }))
        persist()
        HapticManager.impact(.medium)
        ToastCenter.shared.success("Added to Knowledge Base",
                                   detail: "\(name) · \(newChunks.count) pages")
    }

    func removeDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        chunks.removeAll { $0.docID == id }
        persist()
    }

    func clear() {
        cancelImports()
        documents.removeAll()
        chunks.removeAll()
        persist()
    }

    /// Privacy wipe: drop the in-memory index and delete the on-disk folder.
    func wipeFromDisk() {
        cancelImports()
        documents.removeAll()
        chunks.removeAll()
        isEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
        diskQueue.sync { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Retrieval

    /// Top-`k` chunks most similar to `query` (cosine), above `minScore`.
    func retrieve(query: String, topK: Int = 5, minScore: Float = 0.15) -> [KBRetrieval] {
        guard !chunks.isEmpty, let q = embedder.embed(query) else { return [] }
        let terms = Self.queryTerms(query)
        let scored: [(KBChunk, Float)] = chunks.map { chunk in
            let semantic = OnDeviceEmbedder.cosine(q, chunk.vector)
            let lexical = chunk.pageNumber == nil ? 0 : Self.pageLexicalScore(terms, text: chunk.text)
            return (chunk, semantic + lexical)
        }
        let docNames = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.name) })
        return scored
            .filter { $0.1 >= minScore }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { KBRetrieval(id: $0.0.id, docID: $0.0.docID, docName: docNames[$0.0.docID] ?? "document", text: $0.0.text, score: $0.1, pageNumber: $0.0.pageNumber) }
    }

    /// Rendered grounding block for the assistant prompt, or nil when the KB
    /// is empty/disabled or nothing relevant is found. Honors an approximate
    /// token budget (chars/4).
    func contextBlock(for query: String, tokenBudget: Int = 1_200) async -> (block: String, sources: [ChatMessage.DocumentSource])? {
        guard isEnabled, !chunks.isEmpty else { return nil }
        let snapshot = chunks
        let names = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.name) })
        let terms = Self.queryTerms(query)
        let generation = importGate.generation
        let job = Task.detached(priority: .userInitiated) { () -> [KBRetrieval] in
            let worker = OnDeviceEmbedder()
            guard !Task.isCancelled, let queryVector = worker.embed(query) else { return [] }
            var ranked: [(KBChunk, Float)] = []
            for chunk in snapshot {
                guard !Task.isCancelled else { return [] }
                let semantic = OnDeviceEmbedder.cosine(queryVector, chunk.vector)
                let lexical = chunk.pageNumber == nil ? 0 : Self.pageLexicalScore(terms, text: chunk.text)
                let score = semantic + lexical
                if score >= 0.15 { ranked.append((chunk, score)) }
            }
            return ranked.sorted { $0.1 > $1.1 }.prefix(6).map {
                KBRetrieval(id: $0.0.id, docID: $0.0.docID, docName: names[$0.0.docID] ?? "document", text: $0.0.text, score: $0.1, pageNumber: $0.0.pageNumber)
            }
        }
        let retrieved = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard !Task.isCancelled, isEnabled, generation == importGate.generation else { return nil }
        let currentIDs = Set(documents.map(\.id))
        let hits = retrieved.filter { currentIDs.contains($0.docID) }
        guard !hits.isEmpty else { return nil }

        var lines: [String] = [
            "KNOWLEDGE BASE CONTEXT — excerpts from the user's own files. Use them to answer and cite the [source] when you do. If they don't contain the answer, say so.",
            ""
        ]
        var usedChars = lines.joined().count
        let budgetChars = tokenBudget * 4
        var sources: [ChatMessage.DocumentSource] = []
        for (index, h) in hits.enumerated() {
            let label = h.pageNumber.map { "\(h.docName), p. \($0)" } ?? h.docName
            let available = budgetChars - usedChars - label.count - 8
            guard available > 0 else { break }
            let pageAllowance = available / max(1, min(3, hits.count - index))
            let excerpt = h.pageNumber == nil ? h.text
                : Self.pageExcerpt(h.text, terms: terms, maxChars: pageAllowance)
            let entry = "[\(label)]\n\(excerpt)\n"
            if usedChars + entry.count > budgetChars { break }
            lines.append(entry)
            usedChars += entry.count
            sources.append(.init(id: h.id, documentID: h.docID, name: label, excerpt: excerpt))
        }
        lines.append("KNOWLEDGE BASE END")
        guard sources.count > 0 else { return nil }
        return (lines.joined(separator: "\n"), sources)
    }

    nonisolated static func pageLexicalScore(_ terms: Set<String>, text: String) -> Float {
        guard !terms.isEmpty else { return 0 }
        let lower = text.lowercased()
        return min(1.2, Float(terms.filter { lower.contains($0) }.count) * 0.3)
    }

    nonisolated private static func queryTerms(_ query: String) -> Set<String> {
        let ignored: Set<String> = ["about", "document", "from", "page", "please",
                                    "that", "this", "what", "when", "where", "which", "with"]
        return Set(query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !ignored.contains($0) })
    }

    nonisolated private static func pageExcerpt(
        _ text: String, terms: Set<String>, maxChars: Int
    ) -> String {
        guard text.count > maxChars else { return text }
        let lower = text.lowercased()
        let offsets = terms.compactMap { term -> Int? in
            guard let range = lower.range(of: term) else { return nil }
            return lower.distance(from: lower.startIndex, to: range.lowerBound)
        }
        let start = max(0, (offsets.min() ?? 0) - maxChars / 4)
        return "…" + String(text.dropFirst(start).prefix(max(0, maxChars - 2))) + "…"
    }

    // MARK: - Chunking

    nonisolated static func chunk(_ text: String, chunkChars: Int, overlapChars: Int, maxChunks: Int) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex && out.count < maxChunks {
            let end = text.index(cursor, offsetBy: chunkChars, limitedBy: text.endIndex) ?? text.endIndex
            let snapEnd = snapToBoundary(in: text, range: cursor..<end)
            let raw = String(text[cursor..<snapEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { out.append(raw) }
            if snapEnd >= text.endIndex { break }
            let advance = max(snapEnd.utf16Offset(in: text) - overlapChars,
                              cursor.utf16Offset(in: text) + 1)
            cursor = String.Index(utf16Offset: min(advance, text.utf16.count), in: text)
        }
        return out
    }

    nonisolated private static func snapToBoundary(in text: String, range: Range<String.Index>) -> String.Index {
        let candidates: Set<Character> = [".", "!", "?", "\n"]
        var idx = range.upperBound
        let lower = range.lowerBound
        while idx > lower {
            let prev = text.index(before: idx)
            if candidates.contains(text[prev]) { return idx }
            idx = prev
        }
        return range.upperBound
    }

    // MARK: - Persistence

    private struct Index: Codable, Sendable { var documents: [KBDocument]; var chunks: [KBChunk] }

    nonisolated private static var indexURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    private func persist() {
        let index = Index(documents: documents, chunks: chunks)
        diskQueue.async {
            do {
                let data = try JSONEncoder().encode(index)
                try data.write(to: Self.indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } catch {
                Task { @MainActor in
                    ToastCenter.shared.error("Couldn't save documents", detail: "Your index is available this session. Try importing again before closing the app.")
                }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        documents = index.documents
        chunks = index.chunks
    }
}
