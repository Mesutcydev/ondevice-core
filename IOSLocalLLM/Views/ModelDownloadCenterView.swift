import SwiftUI
import Combine
import OnDeviceUI

/// Transfer status only. Browsing and model management live in Models.
@MainActor
struct ModelDownloadCenterView: View {
    @StateObject private var center = ModelDownloadCenter.shared
    @Environment(\.dismiss) private var dismiss

    private var transfers: [DownloadableModel] {
        center.models.filter { model in
            switch model.state {
            case .enumerating, .downloading, .paused, .failed: return true
            case .idle: return model.downloader?.hasResumableDownloadReceipt == true
            case .ready: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if transfers.isEmpty {
                        ContentUnavailableView {
                            Label("No active downloads", systemImage: "arrow.down.circle")
                        } description: {
                            Text("Find a model in Models. Downloads will appear here while they transfer.")
                        } actions: {
                            Button("Browse models") { openModels() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 52)
                    } else {
                        Text("Transfers")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        LazyVStack(spacing: 10) {
                            ForEach(transfers) { model in
                                if let downloader = model.downloader {
                                    ModelTransferRow(model: model, downloader: downloader)
                                }
                            }
                        }
                        Button("Browse more models") { openModels() }
                            .font(.subheadline.weight(.medium))
                            .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { center.refreshAllStates() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                center.refreshAllStates()
            }
        }
    }

    private func openModels() {
        dismiss()
        ODBridge.shared.store.selectedTab = .models
    }
}

@MainActor
private struct ModelTransferRow: View {
    let model: DownloadableModel
    @ObservedObject var downloader: HFModelDownloadManager
    @State private var cancelConfirmationPresented = false

    private var status: String {
        switch downloader.state {
        case .enumerating: return "Preparing download"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .failed: return "Download failed"
        case .idle:
            return downloader.hasResumableDownloadReceipt ? "Interrupted" : "Waiting"
        case .ready: return "Complete"
        }
    }

    private var canRestart: Bool {
        switch downloader.state {
        case .paused, .failed: return true
        case .idle: return downloader.hasResumableDownloadReceipt
        default: return false
        }
    }

    private var safeProgress: Double? {
        downloader.progress.isFinite ? min(1, max(0, downloader.progress)) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(model.sizeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack {
                Text(status)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let safeProgress, safeProgress > 0 {
                    Text("\(Int((safeProgress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = downloader.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                ProgressView(value: safeProgress)
                    .tint(.primary)
                    .accessibilityLabel("Download progress")
            }
            HStack(spacing: 12) {
                Button(canRestart ? "Resume" : "Pause") {
                    if canRestart { model.start() } else { model.pause() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                Button("Cancel", role: .destructive) {
                    cancelConfirmationPresented = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .confirmationDialog("Cancel download of \(model.displayName)?",
                            isPresented: $cancelConfirmationPresented, titleVisibility: .visible) {
            Button("Cancel download", role: .destructive) { model.cancel() }
        } message: {
            Text("Downloaded files for this model will be removed.")
        }
    }
}
// MARK: - DownloadObserver
// A small ObservableObject that bridges the DownloadableModel's underlying
// downloader(s) to the card view, updating on every published change.

@MainActor
final class DownloadObserver: ObservableObject {
    @Published var state: HFModelDownloadManager.DownloadState = .idle
    @Published var progress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var currentFile: String = ""
    @Published var filesDone: Int = 0
    @Published var filesTotal: Int = 0
    /// Smoothed download throughput in bytes/sec. Drives the speed + ETA
    /// readout so a multi-GB download tells the user how long it'll take
    /// instead of just creeping a progress bar.
    @Published var bytesPerSec: Double = 0

    var isActive: Bool { state == .downloading || state == .enumerating }

    /// Estimated seconds remaining, or nil when we can't make a trustworthy
    /// estimate (not downloading, no rate yet, unknown total).
    var etaSeconds: Double? {
        guard state == .downloading, bytesPerSec > 1024, totalBytes > 0 else { return nil }
        let remaining = Double(totalBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSec
    }

    private var cancellables = Set<AnyCancellable>()
    private let model: DownloadableModel

    // Rolling-rate state. We sample at most ~2×/sec and smooth with an EMA so
    // the readout doesn't jitter on every chunk callback.
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: Date?

    init(model: DownloadableModel) {
        self.model = model
        sync()
        subscribe()
    }

    private func sync() {
        let previousState = state
        state          = model.state
        progress       = model.progress
        downloadedBytes = model.downloadedBytes
        totalBytes     = model.totalBytes
        currentFile    = model.currentFile
        filesDone      = model.downloader?.filesDone ?? 0
        filesTotal     = model.downloader?.filesTotal ?? 0
        updateRate(enteredDownloading: previousState != .downloading && state == .downloading)
    }

    private func updateRate(enteredDownloading: Bool) {
        guard state == .downloading else {
            bytesPerSec = 0
            lastSampleTime = nil
            return
        }
        if enteredDownloading || lastSampleTime == nil {
            lastSampleBytes = downloadedBytes
            lastSampleTime = Date()
            return
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime!)
        guard dt >= 0.4 else { return }   // throttle: don't sample on every chunk
        let delta = Double(downloadedBytes - lastSampleBytes)
        if delta >= 0 {                   // ignore the dip when a resume rewinds bytes
            let instantaneous = delta / dt
            bytesPerSec = bytesPerSec == 0 ? instantaneous
                                           : bytesPerSec * 0.7 + instantaneous * 0.3
        }
        lastSampleBytes = downloadedBytes
        lastSampleTime = now
    }

    private func subscribe() {
        // Observe HFModelDownloadManager if present
        if let d = model.downloader {
            d.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
                .store(in: &cancellables)
        }
    }
}
