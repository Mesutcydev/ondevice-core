import SwiftUI
import ActivityKit

/// Uses the shipping content and ActivityKit lifecycle without Core AI.
struct DownloadActivityReview: View {
    @State private var activityStatus = "Not started"
    @State private var activeCount = 0
    private let state = DownloadActivityAttributes.ContentState(progress: 0.42,
        downloadedBytes: 6_980_000_000, totalBytes: 16_623_520_736, currentFile: "model.gguf",
        filesDone: 1, filesTotal: 3, phase: .downloading)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button("Cancel sample Live Activity") {
                    DownloadLiveActivityManager.shared.cancel(repoID: "native-ui-download-review")
                    activityStatus = "Cancel requested"
                }
                .buttonStyle(.bordered).frame(minHeight: 44)
                .accessibilityIdentifier("download.activity.cancel")
                Text("Lock Screen").font(.title2.bold())
                DownloadActivityContent(name: "MiniCPM-V 4.7 35B A3B", state: state)
                    .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
                Text("Dynamic Island · expanded").font(.title2.bold())
                VStack(spacing: 14) {
                    HStack {
                        Label("Token AI", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(state.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                    }
                    DownloadActivityContent(name: "MiniCPM-V 4.7 35B A3B", state: state, compact: true)
                }
                .padding(16).background(.black, in: RoundedRectangle(cornerRadius: 32))
                Text("Dynamic Island · compact").font(.title2.bold())
                HStack(spacing: 10) {
                    DownloadActivityProgressGlyph(progress: state.progress, phase: state.phase)
                    Capsule().fill(.black).frame(width: 90, height: 28)
                    Text(state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).background(.black, in: Capsule())
                Button("Start sample Live Activity") {
                    let started = DownloadLiveActivityManager.shared.start(repoID: "native-ui-download-review", displayName: "MiniCPM-V 4.7 35B A3B")
                    activityStatus = started ? "Live Activity started" : "Live Activity unavailable"
                    DownloadLiveActivityManager.shared.update(repoID: "native-ui-download-review", progress: state.progress,
                        downloadedBytes: state.downloadedBytes, totalBytes: state.totalBytes, currentFile: state.currentFile,
                        filesDone: state.filesDone, filesTotal: state.filesTotal)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("download.activity.start")
                Text(activityStatus).accessibilityIdentifier("download.activity.status")
                Text("Active activities: \(activeCount)").accessibilityIdentifier("download.activity.count")
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            activeCount = Activity<DownloadActivityAttributes>.activities.filter {
                $0.activityState == .active || $0.activityState == .stale
            }.count
        }
    }
}
