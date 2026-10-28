import SwiftUI
import Combine
import OnDeviceUI

/// The shared model snapshot includes Hub, Core AI, classifier, and image transfers.
@MainActor
struct ModelDownloadCenterView: View {
    @StateObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var store = ODBridge.shared.store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ODModelDownloadsView(store: store) {
            dismiss()
            store.selectedTab = .models
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        center.refreshAllStates()
        ODBridge.shared.refresh()
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
