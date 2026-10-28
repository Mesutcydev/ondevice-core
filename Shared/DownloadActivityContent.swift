import SwiftUI

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
struct DownloadActivityContent: View {
    let name: String
    let state: DownloadActivityAttributes.ContentState
    var isStale = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !compact {
                    DownloadActivityProgressGlyph(progress: state.progress, phase: state.phase, size: 26)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                }
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !compact {
                    Text(state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit()).foregroundStyle(.cyan)
                }
            }
            ProgressView(value: state.progress).tint(.cyan)
                .accessibilityLabel("Download progress")
            DownloadActivityStatus(state: state, isStale: isStale)
        }
        .foregroundStyle(.white)
        .padding(compact ? 0 : 16)
    }
}

struct DownloadActivityProgressGlyph: View {
    let progress: Double
    let phase: DownloadActivityAttributes.Phase
    var size: CGFloat = 20

    private var symbol: String {
        switch phase {
        case .completed: return "checkmark"
        case .paused: return "pause.fill"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .verifying, .preparing: return "ellipsis"
        case .downloading: return "arrow.down"
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(phase == .failed ? Color.orange : Color.cyan,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(phase == .failed ? Color.orange : Color.cyan)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DownloadActivityStatus: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch state.phase {
                case .downloading:
                    if isStale { Text("Downloading · waiting for update") }
                    else { Text("Downloading") }
                case .verifying: Text("Open app to finish")
                case .preparing: Text("Preparing model")
                case .completed: Text("Download complete")
                case .paused: Text("Paused")
                case .cancelled: Text("Canceled")
                case .failed: Text("Interrupted · tap to retry")
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if state.totalBytes > 0 {
                Text("\(state.downloadedBytes, format: .byteCount(style: .file)) / \(state.totalBytes, format: .byteCount(style: .file))")
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            } else if state.filesTotal > 0 {
                Text("\(state.filesDone) / \(state.filesTotal) files").monospacedDigit()
            }
        }
        .font(.caption).foregroundStyle(.white.opacity(0.8))
    }
}
#endif
