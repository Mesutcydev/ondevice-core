// Review-only services. These never ship with the app and never perform inference or networking.
import SwiftUI
import Combine
import OnDeviceUI

final class Diagnostics { static let shared = Diagnostics(); func error(_ message: String, category: String) {} }
enum CloudSyncTombstones { static func mark(_ id: UUID) {} }
enum SpotlightIndexer { static func reindexAll(_ records: [StoredConversation]) {} }
final class ToastCenter { static let shared = ToastCenter(); func error(_ title: String, detail: String) {}
    func success(_ title: String, detail: String? = nil) {}
    func info(_ title: String, detail: String? = nil) {} }

final class ImageGenerationService: ObservableObject {
    struct Model: Identifiable { let id: String; let displayName: String; let subtitle: String; let sizeLabel: String
        var supportsNegativePrompt: Bool { !ProcessInfo.processInfo.arguments.contains("-image-turbo") }
    }
    enum State { case idle, failed(String), generating }
    static let shared = ImageGenerationService()
    static let catalog = [Model(id: "fixture", displayName: "Local image model", subtitle: "Review fixture", sizeLabel: "Sample data")]
    @Published var image: UIImage? = UIImage(named: "studio-example")
    @Published var resultPrompt: String? = "A quiet house beside a mountain lake."
    let resultURL = Bundle.main.url(forResource: "studio-example", withExtension: "png")
    let isCancelling = false
    @Published var state: State = .idle
    @Published var selectedModelID = "fixture"
    var selectedModel: Model { Self.catalog[0] }
    var isWorking: Bool { if case .generating = state { return true }; return false }
    var statusMessage = "Review fixture"
    var directDownloadErrors: [String: String] = [:]
    func select(_ id: String) { selectedModelID = id }
    func isInstalled(_ model: Model) -> Bool { !ProcessInfo.processInfo.arguments.contains("-image-no-model") }
    func isDownloading(_ model: Model) -> Bool { false }
    func downloadProgress(for model: Model) -> Double { 0 }
    func startDownload(_ model: Model) {}
    func deleteModel(_ model: Model) {}
    func generate(prompt: String, negativePrompt: String, steps: Int?) {
        state = ProcessInfo.processInfo.arguments.contains("-image-failure") ? .failed("Review fixture: image model could not load.") : .generating
    }
    func cancel() { state = .idle }
}


// Runtime snapshots for the real Device view. No production work is performed.
final class ODBridge: ObservableObject {
    static let shared = ODBridge()
    var store = ODStore.demo()
    func refresh() {}
}
final class ModelDownloadCenter: ObservableObject {
    static let shared = ModelDownloadCenter()
    var totalStorageUsed: Int64 = 7_350_000_000
}
final class CodingAssistantService: ObservableObject {
    enum State { case unloaded, loading(String), ready, generating, failed(String) }
    static let shared = CodingAssistantService()
    @Published var state: State = .ready
    @Published var tokenRate: Double = 0
    func load() async { state = .ready }
    func unload() { state = .unloaded }
    var activeDisplayName = "local_Ornith-1.5-9B-Q5_K_M"
    var activeSelectionID = "local/local_Ornith-1.5-9B-Q5_K_M"
}
struct SystemStatusView: View { var body: some View { Text("Review destination: SystemStatusView") } }
struct DiagnosticsView: View { var body: some View { Text("Review destination: DiagnosticsView") } }
struct ModelsManagerView: View { var body: some View { Text("Review destination: ModelsManagerView") } }
struct ModelStorageCleanupView: View { var body: some View { Text("Review destination: ModelStorageCleanupView") } }
struct ModelDownloadCenterView: View { var body: some View { Text("Review destination: ModelDownloadCenterView") } }
struct BenchmarkView: View { var body: some View { Text("Review destination: BenchmarkView") } }
struct QualityEvalView: View { var body: some View { Text("Review destination: QualityEvalView") } }
struct CompareView: View { var body: some View { Text("Review destination: CompareView") } }
struct KnowledgeBaseView: View { var body: some View { Text("Review destination: KnowledgeBaseView") } }
struct BridgePairingView: View { var body: some View { Text("Review destination: BridgePairingView") } }

// Explicit review fixtures for the production API-server view. No sockets or real keys.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var localAPIEnabled = false
    @Published var localAPIPort = 11434
    @Published var localAPIKeepScreenAwake = false
    @Published var localAPIIncludePeerToPeer = true
}
final class LocalAPIManager: ObservableObject {
    enum State { case stopped, starting, running(UInt16), failed(String) }
    static let shared = LocalAPIManager()
    @Published var state: State = .stopped
    @Published var addresses = ["192.0.2.1"]
    @Published var apiKey = "review-fixture-key"
    func start() async { state = .running(UInt16(AppSettings.shared.localAPIPort)) }
    func stop() async { state = .stopped }
    func restart() async { await start() }
    func autoLoadModelIfEnabled() async {}
    func refreshAddresses() {}
    func refreshIdleTimerPolicy() {}
    func rotateKey() { apiKey = "review-fixture-rotated-key" }
}
enum LocalAPIValidation {
    static func validPort(_ value: Int) -> UInt16? { (1024...65535).contains(value) ? UInt16(value) : nil }
}
struct AssistantModelPickerView: View {
    var downloadedOnly = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        // Mirror the production picker's dismissal affordance: a navigation
        // bar Done button plus the platform's interactive drag.
        NavigationStack {
            Text("Review fixture: downloaded model picker")
                .navigationTitle("Models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("picker.done")
                    }
                }
        }
    }
}
