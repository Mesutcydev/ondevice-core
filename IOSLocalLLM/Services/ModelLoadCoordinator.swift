import Foundation

/// Owns a cold load before its first suspension point. Repeated requests join
/// the same job, including while a cancelled native loader is still retiring.
/// Published UI state is not a synchronization boundary for model ownership.
@MainActor
final class ModelLoadCoordinator {
    private var pending: Task<Void, Never>?
    private var identity: UUID?

    var isLoading: Bool { pending != nil }

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let pending {
            await pending.value
            return
        }
        let id = UUID()
        identity = id
        let job = Task { @MainActor in
            defer {
                if self.identity == id {
                    self.pending = nil
                    self.identity = nil
                }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        pending = job
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Capture this task before starting teardown. Cancellation is cooperative;
    /// awaiting its value also retires the loader's local runtime references.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        pending?.cancel()
        return pending
    }
}
