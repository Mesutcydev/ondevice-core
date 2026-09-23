import SwiftUI
import OnDeviceUI

/// New-chat guidance only. Conversation history and navigation live on the main page.
struct ChatThreadEmptyState: View {
    let isFiltering: Bool
    var attachedFilename: String? = nil
    var attachedFileCount: Int = 0
    let modelName: String
    let modelStatus: String
    let loadFailure: String?
    let failureCanRetry: Bool
    let canGenerate: Bool
    let onRetry: () -> Void
    let onSwitchModel: () -> Void
    let onTryAnyway: (() -> Void)?

    private var emptyHelper: String {
        if attachedFileCount > 1 { return "Ask about the attached files." }
        if let attachedFilename, !attachedFilename.isEmpty { return "Ask about \(attachedFilename)." }
        return "Write a message, or attach a file."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isFiltering {
                ContentUnavailableView.search
            } else {
                Text("New chat").font(.title2.weight(.medium)).foregroundStyle(ODPalette.text)
                Text(emptyHelper).font(.body).foregroundStyle(.secondary)
                if let loadFailure {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loadFailure).font(.body).foregroundStyle(.secondary)
                        if failureCanRetry { Button("Try again", action: onRetry).buttonStyle(.glass) }
                        Button("Choose a model", action: onSwitchModel).buttonStyle(.glass)
                        if let onTryAnyway { Button("Review capacity override", action: onTryAnyway).buttonStyle(.glass) }
                    }
                }
                // No "not ready / choose a model" block here: model selection
                // lives in the composer (status strip above + notice in the
                // composer), and a third affordance in the thread read as
                // duplicated chrome (2026-09-21 device report).
            }
        }
        .padding(.horizontal, ODLayout.pageInset)
        .padding(.vertical, ODLayout.groupGap)
        .frame(maxWidth: ODLayout.readableMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct ChatReplyFailureNotice: View {
    let detail: String
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't finish the reply").font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("chat.reply.failure")
            Text(detail).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry response", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!canRetry)
                .accessibilityIdentifier("chat.reply.retry")
        }
        .foregroundStyle(ODPalette.text)
    }
}
