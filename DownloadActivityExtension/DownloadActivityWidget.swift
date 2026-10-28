import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DownloadActivityWidgets: WidgetBundle {
    var body: some Widget { ModelDownloadActivity() }
}

struct ModelDownloadActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadActivityContent(name: context.attributes.displayName, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DownloadActivityAttributes.downloadsURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Token AI", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadActivityPercent(progress: context.state.progress)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadActivityContent(name: context.attributes.displayName, state: context.state,
                                            isStale: context.isStale, compact: true)
                }
            } compactLeading: {
                DownloadActivityProgressGlyph(progress: context.state.progress, phase: context.state.phase, size: 20)
            } compactTrailing: {
                DownloadActivityPercent(progress: context.state.progress)
            } minimal: {
                DownloadActivityProgressGlyph(progress: context.state.progress, phase: context.state.phase, size: 20)
            }
            .widgetURL(DownloadActivityAttributes.downloadsURL)
            .keylineTint(.cyan)
        }
    }
}

struct DownloadActivityPercent: View {
    let progress: Double
    var body: some View {
        Text(progress, format: .percent.precision(.fractionLength(0)))
            .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
    }
}
