import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()
    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var updates: [String: Task<Void, Never>] = [:]
    private var lastUpdate: [String: Date] = [:]
    private var latestStates: [String: DownloadActivityAttributes.ContentState] = [:]

    private init() {
        // Activities belong to the OS and survive process termination.
        for activity in Activity<DownloadActivityAttributes>.activities
            where activity.activityState == .active || activity.activityState == .stale {
            activities[activity.attributes.repoID] = activity
            latestStates[activity.attributes.repoID] = activity.content.state
        }
    }

    @discardableResult
    func start(repoID: String, displayName: String? = nil) -> Bool {
        // Query again at the user action: ActivityKit can restore its list
        // after this singleton was initialized during app launch.
        if activities[repoID] == nil,
           let restored = Activity<DownloadActivityAttributes>.activities.first(where: {
               $0.attributes.repoID == repoID && ($0.activityState == .active || $0.activityState == .stale)
           }) {
            activities[repoID] = restored; latestStates[repoID] = restored.content.state
        }
        if let activity = activities[repoID], activity.activityState == .active || activity.activityState == .stale {
            return true
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let state = DownloadActivityAttributes.ContentState(progress: 0, downloadedBytes: 0, totalBytes: 0,
            currentFile: "", filesDone: 0, filesTotal: 0, phase: .downloading)
        do {
            let activity = try Activity<DownloadActivityAttributes>.request(
                attributes: .init(repoID: repoID, displayName: displayName ?? repoID),
                content: .init(state: state, staleDate: .now.addingTimeInterval(120)), pushType: nil)
            activities[repoID] = activity; latestStates[repoID] = state
            return true
        } catch {
            Diagnostics.shared.breadcrumb("Download Live Activity unavailable", category: "liveactivity")
            return false
        }
    }

    func update(repoID: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64,
                currentFile: String, filesDone: Int, filesTotal: Int,
                phase: DownloadActivityAttributes.Phase = .downloading) {
        guard let activity = activities[repoID] else { return }
        let previous = latestStates[repoID]
        let state = DownloadActivityAttributes.ContentState(
            progress: min(1, max(0, progress.isFinite ? progress : 0)),
            downloadedBytes: max(0, downloadedBytes), totalBytes: max(0, totalBytes),
            currentFile: String(currentFile.prefix(100)), filesDone: filesDone, filesTotal: filesTotal, phase: phase)
        latestStates[repoID] = state
        // Byte callbacks can arrive hundreds of times a second. Publish at
        // most once per second, plus phase changes. Serialize updates so an
        // older tick cannot land after pause, cancellation or completion.
        guard previous?.phase != phase || Date().timeIntervalSince(lastUpdate[repoID] ?? .distantPast) >= 1 else { return }
        lastUpdate[repoID] = .now
        let prior = updates[repoID]
        updates[repoID] = Task {
            await prior?.value
            guard activities[repoID]?.id == activity.id else { return }
            await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(120)))
        }
    }

    func finish(repoID: String) { end(repoID: repoID, phase: .completed) }
    func pause(repoID: String) { end(repoID: repoID, phase: .paused) }
    func cancel(repoID: String) { end(repoID: repoID, phase: .cancelled) }
    func fail(repoID: String, reason: String) { end(repoID: repoID, phase: .failed) }

    private func end(repoID: String, phase: DownloadActivityAttributes.Phase) {
        var matching = Activity<DownloadActivityAttributes>.activities.filter { $0.attributes.repoID == repoID }
        if let tracked = activities.removeValue(forKey: repoID), !matching.contains(where: { $0.id == tracked.id }) {
            matching.append(tracked)
        }
        guard !matching.isEmpty else { return }
        let latest = latestStates.removeValue(forKey: repoID)
        let prior = updates.removeValue(forKey: repoID)
        lastUpdate.removeValue(forKey: repoID)
        Task {
            await prior?.value
            for activity in matching {
                var state = latest ?? activity.content.state
                state.phase = phase
                if phase == .completed { state.progress = 1; state.filesDone = state.filesTotal }
                await activity.end(.init(state: state, staleDate: nil),
                    dismissalPolicy: phase == .cancelled ? .immediate : .after(.now.addingTimeInterval(6)))
            }
        }
    }
}
#else
@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()
    enum Phase { case downloading, verifying, preparing }
    @discardableResult func start(repoID: String, displayName: String? = nil) -> Bool { false }
    func update(repoID: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64,
                currentFile: String, filesDone: Int, filesTotal: Int, phase: Phase = .downloading) {}
    func finish(repoID: String) {}
    func pause(repoID: String) {}
    func cancel(repoID: String) {}
    func fail(repoID: String, reason: String) {}
}
#endif
