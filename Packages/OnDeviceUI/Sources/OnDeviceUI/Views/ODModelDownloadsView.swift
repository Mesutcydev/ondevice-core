import SwiftUI

/// Transfer state comes from the same snapshot as the model library, including
/// downloaders owned by image generation and Core AI as well as the Hub center.
@MainActor
public struct ODModelDownloadsView: View {
    @ObservedObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    private let onBrowseModels: () -> Void

    public init(store: ODStore, onBrowseModels: @escaping () -> Void) {
        self.store = store
        self.onBrowseModels = onBrowseModels
    }

    private var transfers: [ODModel] {
        var seen = Set<String>()
        return store.models.filter { $0.downloadStatus != nil && seen.insert($0.id).inserted }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if transfers.isEmpty {
                        ContentUnavailableView {
                            Label(ODLocalizedString("No active downloads"), systemImage: "arrow.down.circle")
                        } description: {
                            Text("Start a download from Catalog or Discover.", bundle: .module)
                        } actions: {
                            Button(ODLocalizedString("Find a model"), action: onBrowseModels)
                                .buttonStyle(.borderedProminent)
                                .odInkProminent()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 52)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(transfers) { model in
                                ODModelTransferRow(model: model, canPerformActions: store.canPerformActions) { command in
                                    store.send(.modelAction(modelID: model.id, command: command))
                                }
                            }
                        }
                        Button(ODLocalizedString("Find a model"), action: onBrowseModels)
                            .font(.subheadline.weight(.medium))
                            .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            .navigationTitle(ODLocalizedString("Downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ODLocalizedString("Done")) { dismiss() }
                }
            }
        }
    }
}

private struct ODModelTransferRow: View {
    let model: ODModel
    let canPerformActions: Bool
    let onCommand: (ODModelCommand) -> Void
    @State private var cancelConfirmationPresented = false

    private var commands: [ODModelCommand] { model.availableCommands ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.name).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                if let size = model.sizeLabel {
                    Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
            }
            HStack {
                if let status = model.downloadStatus {
                    Text(odKey: status).font(.subheadline.weight(.medium))
                }
                Spacer()
                if let progress = model.downloadProgress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.downloadStatus != "Download failed" {
                ProgressView(value: model.downloadProgress)
                    .tint(.primary)
                    .accessibilityLabel(Text("Model download progress", bundle: .module))
                    .accessibilityIdentifier("downloads.progress.\(model.id)")
            }
            if let detail = model.downloadDetail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let transfer = model.downloadTransferLabel {
                Text(verbatim: transfer).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if commands.contains(.download) || commands.contains(.pauseDownload) || commands.contains(.cancelDownload) {
                HStack(spacing: 12) {
                    if commands.contains(.pauseDownload) && !model.isDownloadPaused && model.downloadStatus != "Download failed" {
                        Button(ODLocalizedString("Pause")) { onCommand(.pauseDownload) }
                            .buttonStyle(.borderedProminent).tint(.primary)
                            .accessibilityIdentifier("downloads.pause.\(model.id)")
                    } else if commands.contains(.download) {
                        Button(ODLocalizedString("Resume")) { onCommand(.download) }
                            .buttonStyle(.borderedProminent).tint(.primary)
                            .accessibilityIdentifier("downloads.resume.\(model.id)")
                    }
                    if commands.contains(.cancelDownload) {
                        Button(ODLocalizedString("Cancel"), role: .destructive) { cancelConfirmationPresented = true }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("downloads.cancel.\(model.id)")
                    }
                }
                .disabled(!canPerformActions)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .confirmationDialog(ODLocalizedString("Cancel download of \(model.name)?"),
                            isPresented: $cancelConfirmationPresented, titleVisibility: .visible) {
            Button(ODLocalizedString("Cancel download"), role: .destructive) { onCommand(.cancelDownload) }
        } message: {
            Text("Downloaded files for this model will be removed. You can download it again later.", bundle: .module)
        }
    }
}
