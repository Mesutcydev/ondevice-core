import Combine
import Foundation

@MainActor
final class ClassifierModelStore: ObservableObject {
    static let shared = ClassifierModelStore()
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var removingIDs: Set<String> = []
    @Published private(set) var installedSizes: [String: Int64] = [:]
    var storageBytes: Int64 { installedSizes.values.reduce(0, +) }
    let directory: URL

    private struct Receipt: Codable { let id: String; let revision: String }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassifierModels", isDirectory: true)
        refresh()
    }
    func root(for entry: ClassifierCatalogModel) -> URL { directory.appendingPathComponent(entry.id, isDirectory: true) }
    func refresh() {
        installedIDs = Set(ClassifierCatalog.models.filter { entry in
            let root = root(for: entry)
            guard let data = try? Data(contentsOf: root.appendingPathComponent("installation.json")),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.id == entry.id, receipt.revision == entry.revision,
                  let asset = try? entry.assetURL(in: root), FileManager.default.fileExists(atPath: asset.path) else { return false }
            if entry.asset.hasSuffix(".mlpackage") {
                guard let compiled = try? ClassifierCatalogModel.containedURL("model.mlmodelc", in: root),
                      FileManager.default.fileExists(atPath: compiled.path) else { return false }
            }
            return true
        }.map(\.selectionID))
        installedSizes = Dictionary(uniqueKeysWithValues: ClassifierCatalog.models.filter {
            installedIDs.contains($0.selectionID)
        }.map { ($0.selectionID, (try? FileManager.default.allocatedSizeOfDirectory(at: root(for: $0))) ?? 0) })
    }

    func install(_ entry: ClassifierCatalogModel, from staging: URL) async throws {
        guard !removingIDs.contains(entry.selectionID) else { throw CoreAIClassifierError.busy }
        let fm = FileManager.default
        let asset = try entry.assetURL(in: staging)
        guard fm.fileExists(atPath: asset.path) else { throw CoreAIInferenceError.unavailable("Missing classifier asset: \(entry.asset)") }
        for sidecar in entry.sidecars {
            guard fm.fileExists(atPath: try ClassifierCatalogModel.containedURL(sidecar, in: staging).path) else { throw CoreAIInferenceError.unavailable("Missing classifier file: \(sidecar)") }
        }
        if let files = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in files {
                guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CoreAIClassifierError.unsafeAssetPath }
            }
        }
        if entry.runtime == .gguf {
            let handle = try FileHandle(forReadingFrom: asset)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else { throw CoreAIClassifierError.unsupportedContract }
            try await GGUFDecisionClassifierRuntime.validateDownload(entry, root: staging)
            for name in ["Apache-2.0", "mmBERT-MIT"] where name != "mmBERT-MIT" || entry.layout == .julia {
                guard let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "LICENSES")
                    ?? Bundle.main.url(forResource: name, withExtension: "txt") else { throw CoreAIInferenceError.unavailable("Missing \(name) license notice.") }
                try Data(contentsOf: url).write(to: staging.appendingPathComponent("\(name).txt"), options: .atomic)
            }
        } else { try await PortableClassifierRuntime.prepareDownload(entry, in: staging) }
        try Task.checkCancellation()
        // Never replace files that an in-flight native specialization still owns.
        if CoreAIInferenceService.shared.isUsingPack(entry.selectionID) { await CoreAIClassifierHost.workbench.unloadAndWaitForCleanup() }
        try Task.checkCancellation()
        let notice = "\(entry.name)\nSource: https://huggingface.co/\(entry.repo)/tree/\(entry.revision)\nLicense: \(entry.license). Model weights retain the publisher's terms.\n"
        try Data(notice.utf8).write(to: staging.appendingPathComponent("MODEL-NOTICE.txt"), options: .atomic)
        try JSONEncoder().encode(Receipt(id: entry.id, revision: entry.revision)).write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = root(for: entry)
        let backup = directory.appendingPathComponent(".replaced-\(UUID().uuidString)")
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch { if exists { try? fm.moveItem(at: backup, to: destination) }; throw error }
        if exists { try? fm.removeItem(at: backup) }
        refresh()
        MemoryAdvisor.invalidateFootprintCache()
    }

    func remove(_ entry: ClassifierCatalogModel) {
        guard removingIDs.insert(entry.selectionID).inserted else { return }
        Task {
            defer { removingIDs.remove(entry.selectionID) }
            await CoreAIDownloadCenter.shared.existing(id: entry.selectionID)?.cancelAndWaitForCleanup()
            let workbench = CoreAIClassifierHost.workbench
            if CoreAIInferenceService.shared.isUsingPack(entry.selectionID)
                || (workbench.selectedModelID == entry.selectionID && workbench.phase.busy) {
                await workbench.unloadAndWaitForCleanup()
            }
            if workbench.selectedModelID == entry.selectionID { workbench.selectedModelID = "" }
            do {
                try FileManager.default.removeItem(at: root(for: entry))
                refresh(); MemoryAdvisor.invalidateFootprintCache()
                ToastCenter.shared.success("Classifier removed", detail: entry.name)
            } catch { ToastCenter.shared.error("Couldn’t remove classifier", detail: error.localizedDescription) }
        }
    }
}
