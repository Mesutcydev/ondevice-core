import Foundation

/// Backends report failure before completion, potentially off the main actor.
/// Keep that terminal result together so the UI never treats a failure as an
/// empty successful answer or starts a reasoning-recovery request after it.
final class ChatGenerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func record(_ detail: String) {
        lock.lock()
        defer { lock.unlock() }
        if message == nil { message = detail }
    }

    var detail: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

/// Keeps admission closed until the cancelled operation and its cleanup drain.
/// A stale completion can neither release a newer operation nor publish a result.
struct PresentationRequestLifetime: Equatable {
    private(set) var id: UUID?
    private(set) var isCancelled = false
    var isRunning: Bool { id != nil }

    mutating func begin() -> UUID? {
        guard id == nil else { return nil }
        let next = UUID()
        id = next
        isCancelled = false
        return next
    }

    func accepts(_ requestID: UUID) -> Bool { id == requestID && !isCancelled }

    mutating func cancel() {
        guard id != nil else { return }
        isCancelled = true
    }

    @discardableResult mutating func finish(_ requestID: UUID) -> Bool {
        guard id == requestID else { return false }
        id = nil
        isCancelled = false
        return true
    }
}

/// Captured before asynchronous chat preparation. The view remains the state owner.
struct ChatPresentationRequest: Equatable {
    let id: UUID
    let conversationID: UUID
    let draftRevision: UInt64
    let modelID: String
    let draft: ConversationPresentation
    let attachmentIDs: [String]

    func belongsTo(requestID: UUID, conversationID: UUID?, modelID: String) -> Bool {
        id == requestID && self.conversationID == conversationID && self.modelID == modelID
    }

    /// Acceptance never consumes text or files added after the captured draft.
    func matchesDraft(_ current: ConversationPresentation, revision: UInt64) -> Bool {
        draftRevision == revision && draft.text == current.text && draft.files == current.files
            && draft.images == current.images && draft.imageIDs == current.imageIDs
            && draft.legacyImage == current.legacyImage && draft.legacyImageID == current.legacyImageID
    }
}
