import Foundation
import UIKit
import UniformTypeIdentifiers
import SwiftUI

// MARK: - LocalModelImportService
// Imports a model from the Files app (iCloud Drive, on-device, AirDrop
// staging, etc.) or from the app's own Documents folder. MLX and GGUF models
// land in HFModels and register with ModelDownloadCenter; Core AI packs are
// handed to CoreAIModelStore.
//
// Accepted inputs:
//   • An MLX folder (config.json + safetensors)
//   • A Core AI pack folder (metadata.json + .aimodel)
//   • A single GGUF file, or a folder holding a GGUF (or GGUF VLM pair)

@MainActor
final class LocalModelImportService: ObservableObject {

    static let shared = LocalModelImportService()

    private init() {}

    /// Documents subfolders the app manages itself. Never offered for import
    /// and never consumed after one.
    private static let managedDocumentsFolders: Set<String> = [
        "HFModels", "huggingface", "GGUFModels", "FastVLMModels", "LLMModels",
        "Edge0Models", "WhisperModels", "VoiceModels", "BundledVoiceModels"
    ]

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Model folders and GGUF files the user placed in On My iPhone ›
    /// OnDeviceMax (or that arrived in its Inbox). Importing these needs no
    /// document picker, so it keeps working on re-signed sideload installs
    /// where Files silently refuses open-in-place folder access.
    static func documentsCandidates() -> [URL] {
        let fm = FileManager.default
        let docs = documentsDirectory
        let roots = [docs, docs.appendingPathComponent("Inbox", isDirectory: true)]
        func entries(of dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
            )) ?? []
        }
        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var results: [URL] = []
        // List model roots themselves, one level into a wrapper folder, so each
        // model in a "Models" folder is its own choice.
        func consider(_ dir: URL, depth: Int) {
            if isModelRoot(dir) || (try? CoreAIModelStore.resolvePackRoot(from: dir)) != nil {
                results.append(dir)
            } else if depth > 0 {
                entries(of: dir).filter(isDirectory).forEach { consider($0, depth: depth - 1) }
            }
        }
        for root in roots {
            for entry in entries(of: root) where !managedDocumentsFolders.contains(entry.lastPathComponent)
                && entry.lastPathComponent != "Inbox" {
                if isDirectory(entry) {
                    consider(entry, depth: 1)
                } else if entry.pathExtension.lowercased() == "gguf" {
                    results.append(entry)
                }
            }
        }
        return results.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// True for sources that are already app-owned copies: the system
    /// picker's temporary copy, or an item in the app's Documents outside the
    /// managed model folders. When an import uses the whole source, it is
    /// removed afterwards so a multi-GB model isn't kept twice (the in-sandbox
    /// copy is an APFS clone).
    private static func ownsSource(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(tmp + "/") { return true }
        let docs = documentsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(docs + "/") else { return false }
        let top = path.dropFirst(docs.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return !managedDocumentsFolders.contains(top)
    }

    /// Imports a folder or file chosen from Files or `documentsCandidates()`.
    func importModel(from url: URL) async throws -> String {
        try await importModel(from: [url])
    }

    /// Copy-mode multi-selection supplies one temporary URL per file. Flat
    /// MLX/Edge0 folders can be rebuilt without an open-in-place folder grant.
    /// Returns a local id, a curated Edge0 preset id, or a Core AI selection id.
    func importModel(from urls: [URL]) async throws -> String {
        guard let first = urls.first else {
            throw Self.importError("Choose at least one model file.", code: -5)
        }
        // The document picker hands us a security-scoped URL — must call
        // startAccessingSecurityScopedResource before reading.
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (url, didStart) in zip(urls, scoped) where didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let multipleFiles = urls.count > 1
        let ownsSource = !multipleFiles && Self.ownsSource(first)
        if multipleFiles {
            var names = Set<String>()
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw Self.importError("Select files from inside one model folder, then tap Open.", code: -5)
                }
                let name = url.lastPathComponent
                guard !name.hasPrefix("."), names.insert(name.lowercased()).inserted else {
                    throw Self.importError("The selection contains duplicate or hidden file names. Select files from one model folder.", code: -5)
                }
            }
        }

        // Destination under Documents/HFModels/local_<name>
        var sourceIsDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &sourceIsDirectory)
        let importName = multipleFiles
            ? (Self.metadataName(forFiles: urls) ?? "Imported-model")
            : sourceIsDirectory.boolValue
            ? first.lastPathComponent
            : first.deletingPathExtension().lastPathComponent
        let cleaned = importName
            .replacingOccurrences(of: " ", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let hfModelsRoot = docs.appendingPathComponent("HFModels", isDirectory: true)

        // Don't silently clobber an existing import that happens to share
        // the folder name — append a numeric suffix instead
        // (local_foo, local_foo-2, local_foo-3, …).
        var folderName = "local_\(cleaned)"
        var dest = hfModelsRoot.appendingPathComponent(folderName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            folderName = "local_\(cleaned)-\(suffix)"
            dest = hfModelsRoot.appendingPathComponent(folderName)
            suffix += 1
        }

        // Free-space gate before copying: importing a multi-GB folder with
        // no room used to fail halfway with an opaque copy error. App-owned
        // sources are cloned on the same volume and need no extra room.
        let importBytes: Int64 = urls.reduce(0) { total, url in
            var srcIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &srcIsDir)
            let bytes = srcIsDir.boolValue
                ? (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0
                : ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            return total + (Self.ownsSource(url) ? 0 : bytes)
        }
        if importBytes > 0, let free = HFModelDownloadManager.freeDiskBytes(),
           free < importBytes + 200_000_000 {
            throw Self.importError(
                "Not enough disk space to import “\(cleaned)”. Need ~\((importBytes + 200_000_000).formattedBytes) free, only \(free.formattedBytes) available.",
                code: -3
            )
        }

        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // Branch on input type
        if !multipleFiles && first.pathExtension.lowercased() == "zip" {
            // Unzip into dest
            try await unzip(first, to: dest)
        } else if multipleFiles {
            try await copySelectedFiles(urls, to: dest)
        } else {
            // A multi-GB GGUF copy can take minutes. FileManager.copyItem is
            // synchronous; running it on this @MainActor service froze the UI
            // and made the app appear dead throughout the import.
            let source = first
            let destination = dest
            do { try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                    do {
                        var isDirectory: ObjCBool = false
                        guard fm.fileExists(atPath: readableURL.path, isDirectory: &isDirectory) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        if isDirectory.boolValue {
                            try fm.copyItem(at: readableURL, to: destination)
                        } else {
                            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                            try fm.copyItem(
                                at: readableURL,
                                to: destination.appendingPathComponent(source.lastPathComponent)
                            )
                        }
                    } catch {
                        copyError = error
                    }
                }
                if let error = copyError ?? coordinationError {
                    try? fm.removeItem(at: destination)
                    throw error
                }
            }.value } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw NSError(domain: "LocalImport", code: -4, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Files didn't give OnDevice Max access to “\(cleaned)”, which is common on sideloaded installs. Copy it to On My iPhone › OnDevice Max in Files, then pick it from the Import model list."
                ])
            }
        }

        // Core AI packs install through their own store, not HFModels.
        if let packRoot = try? CoreAIModelStore.resolvePackRoot(from: dest) {
            defer { try? FileManager.default.removeItem(at: dest) }
            let manifest = try CoreAIModelStore.shared.importModel(from: dest)
            if ownsSource, packRoot.standardizedFileURL == dest.standardizedFileURL {
                try? FileManager.default.removeItem(at: first)
            }
            ToastCenter.shared.success("Imported \(manifest.displayName)",
                                        detail: "Available in Models.")
            return CoreAIInstalledModel.assistantSelectionID(for: manifest.id)
        }

        // Only a source that is itself the model root is fully consumed;
        // a wrapper may hold other models the user still wants.
        let consumesSource = ownsSource && Self.isModelRoot(dest)

        // Imported weights are user-restorable from their original source —
        // keep them out of iCloud backups like every downloaded model.
        FileManager.excludeFromBackup(dest)

        // Users often share a model as a folder that contains the actual
        // model directory one level down (e.g. AirDrop / zip re-wrapping adds
        // an enclosing folder). Hoist the real model root up so config.json /
        // the GGUF pair sit where the loader and the readiness check expect.
        normalizeModelLayout(at: dest)

        // Edge0 checkpoints have a native runtime only under their curated
        // identities. The artifact validators prove the exact release before
        // anything is moved into a preset destination.
        if let family = Self.validatedEdge0Family(in: dest) {
            do {
                let presetID = try await adoptValidatedEdge0(
                    at: dest, family: family, previousRepoID: nil
                )
                if consumesSource { try? FileManager.default.removeItem(at: first) }
                ToastCenter.shared.success("Imported \(family.displayName)",
                                            detail: "Available in Assistant.")
                return presetID
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
        }
        if Self.isEdge0ImportCandidate(in: dest) {
            let missing = Self.missingEdge0Files(in: dest)
            try? FileManager.default.removeItem(at: dest)
            let list = missing.prefix(4).joined(separator: ", ")
                + (missing.count > 4 ? " and \(missing.count - 4) more" : "")
            throw Self.importError(
                missing.isEmpty
                    ? "This Edge0 checkpoint does not match a supported release."
                    : "This Edge0 checkpoint is missing \(list). Open the model folder in Files, tap Select All, then Open.",
                code: -9
            )
        }

        let repoID = "local/\(folderName)"

        // Persist the repoID so ModelDownloadCenter.scanCustomDownloads
        // recovers the SAME id on the next launch instead of deriving a
        // different one from the folder name (the folder→repoID split is
        // lossy). Without this the imported model came back under a mismatched
        // id after a restart.
        let sidecar = dest.appendingPathComponent(".repoID")
        try? repoID.data(using: .utf8)?.write(to: sidecar, options: [.atomic])

        let downloader = HFModelDownloadManager(
            repoID: repoID, destination: dest
        )
        downloader.checkIfReady()

        // Fail loudly when the folder doesn't actually contain a usable model.
        // Previously import always reported success and registered the entry
        // even when no weights were recognized — so the user saw "Imported"
        // but the model never appeared in Installed (which filters on
        // `isReady`). Roll back the copied bytes so a half-recognized folder
        // doesn't linger as dead weight.
        guard downloader.state == .ready else {
            try? FileManager.default.removeItem(at: dest)
            throw NSError(domain: "LocalImport", code: -2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't find a usable model in “\(cleaned)”. Import an MLX folder containing config.json plus .safetensors weights, a Core AI pack with metadata.json and .aimodel, a standalone text .gguf, or a vision GGUF paired with its mmproj-*.gguf file."
            ])
        }

        // Detect the real category from the files on disk (config.json's
        // architecture / file layout) instead of assuming .assistant — that
        // assumption hid imported VLMs from the vision picker.
        let category = LocalModelRegistry.category(in: dest)

        let runtime: ModelRuntime? = LocalModelFileValidator.hasValidGGUFTextModel(in: dest)
            ? .llamaCpp
            : nil

        ModelDownloadCenter.shared.registerCustom(
            repoID: repoID,
            displayName: cleaned,
            subtitle: "local · imported from Files",
            category: category,
            sizeLabel: dirSize(at: dest).formattedBytes,
            docURL: nil,
            downloader: downloader,
            runtime: runtime
        )
        if consumesSource { try? FileManager.default.removeItem(at: first) }

        ToastCenter.shared.success("Imported \(cleaned)",
                                    detail: "Available in the model picker.")
        return repoID
    }

    // MARK: - Helpers

    private static func importError(_ message: String, code: Int) -> NSError {
        NSError(domain: "LocalImport", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The picker has already copied selected files into its temporary area.
    /// Move those copies into one model directory; coordinate only URLs that
    /// are still owned by an external provider.
    private func copySelectedFiles(_ sources: [URL], to destination: URL) async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let temporaryCopies = sources.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(temporaryRoot + "/")
        }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for (source, temporaryCopy) in zip(sources, temporaryCopies) {
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    if temporaryCopy {
                        try fm.moveItem(at: source, to: target)
                    } else {
                        let coordinator = NSFileCoordinator()
                        var coordinationError: NSError?
                        var copyError: Error?
                        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) {
                            readableURL in
                            do { try fm.copyItem(at: readableURL, to: target) }
                            catch { copyError = error }
                        }
                        if let error = copyError ?? coordinationError { throw error }
                    }
                }
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }.value
    }

    /// Only validated, exact Edge0 release artifacts may adopt a native
    /// preset. A Qwen architecture string by itself is insufficient.
    static func validatedEdge0Family(in directory: URL) -> Edge0ModelFamily? {
        if (try? Edge0_35BModelArtifacts.validateInstall(directory: directory)) != nil {
            return .qwen35MoE
        }
        if (try? Edge0ModelArtifacts.validate(directory: directory)) != nil {
            return .bailing8B
        }
        return nil
    }

    /// Recognize an incomplete/duplicate local Edge0 import so the startup
    /// scan cannot expose it as a generic MLX or Lens model.
    static func isEdge0ImportCandidate(in directory: URL) -> Bool {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: directory.path),
           names.contains(where: {
               $0.hasPrefix("lora_edge0_") || $0.hasPrefix("prerouter_edge0_")
           }) { return true }
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // Same identity the installed registry uses, so an incomplete 35B
        // selection is refused here instead of importing as a generic model.
        return Edge0_35BModelConfiguration.isEdge0Architecture(json)
    }

    /// Release files an Edge0 selection still lacks, for an actionable error.
    static func missingEdge0Files(in directory: URL) -> [String] {
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let architectures = json["architectures"] as? [String]
        else { return present.contains("config.json") ? [] : ["config.json"] }
        let required = architectures.contains("Qwen3_5MoeForConditionalGeneration")
            ? Edge0_35BModelArtifacts.downloadAllowlist
            : Edge0ModelArtifacts.requiredFiles
        return required.filter { !present.contains($0) }
    }

    /// Copy-mode picks arrive as loose temporary files with no folder name, so
    /// name the import from the model itself: the model card's "# owner/name"
    /// title, else a GGUF file name, else config.json's type and weight size.
    static func metadataName(forFiles files: [URL]) -> String? {
        func named(_ name: String) -> URL? {
            files.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let readme = named("README.md"),
           let text = try? String(contentsOf: readme, encoding: .utf8) {
            for line in text.split(separator: "\n").prefix(80) where line.hasPrefix("# ") {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let name = title.split(separator: "/").last.map(String.init),
                   !name.isEmpty, !name.contains(" ") {
                    return name
                }
            }
        }
        if let gguf = files.first(where: {
            $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.lowercased().hasPrefix("mmproj")
        }) {
            return gguf.deletingPathExtension().lastPathComponent
        }
        if let config = named("config.json"),
           let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let modelType = json["model_type"] as? String {
            let weightBytes = files.filter { $0.pathExtension == "safetensors" }.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let size = weightBytes > 0 ? "-\(max(1, Int((Double(weightBytes) / 1e9).rounded())))GB" : ""
            return modelType.replacingOccurrences(of: "_", with: ".") + size
        }
        return nil
    }

    /// Used by both a fresh Files import and the startup migration of an
    /// earlier HFModels/local_* import. The preset downloader is stopped and
    /// its partial destination cleared before the validated directory moves.
    func adoptValidatedEdge0(
        at source: URL, family: Edge0ModelFamily, previousRepoID: String?
    ) async throws -> String {
        guard let preset = AssistantModelCatalog.presets.first(where: { $0.repoID == family.repoID }),
              let model = ModelDownloadCenter.shared.models.first(where: {
                  $0.id == preset.id && $0.sourceRepoID == family.repoID
              }), let downloader = model.downloader else {
            throw Self.importError("The \(family.displayName) preset is unavailable in this build.", code: -6)
        }
        downloader.checkIfReady()
        guard !model.isReady else {
            throw Self.importError("\(family.displayName) is already installed. Remove the existing preset before importing another copy.", code: -7)
        }

        try await downloader.prepareForLocalImport()
        let destination = downloader.destination
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: destination)
            try family.repoID.data(using: .utf8)?.write(
                to: destination.appendingPathComponent(".repoID"), options: [.atomic]
            )
            FileManager.excludeFromBackup(destination)
            downloader.checkIfReady()
            guard model.isReady else {
                throw Self.importError("The imported \(family.displayName) files did not pass the preset readiness check.", code: -8)
            }
        } catch {
            if fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: destination, to: source)
            }
            downloader.checkIfReady()
            throw error
        }

        if let previousRepoID {
            InstalledModelRegistry.shared.remove(repoID: previousRepoID)
            let settings = AppSettings.shared
            if LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID) == previousRepoID {
                settings.cameraVisualModelID = ""
                settings.hasPickedCameraVisualModel = false
            }
            if LocalModelRegistry.unwrapAssistantSelectionID(settings.assistantModelID) == previousRepoID {
                settings.assistantModelID = preset.id
            }
            if LocalModelRegistry.unwrapAssistantSelectionID(settings.voiceConversationModelID) == previousRepoID {
                settings.voiceConversationModelID = preset.id
            }
        }
        if let record = InstalledModelRegistry.validateDirectory(destination, repoID: family.repoID),
           record.validationState.isActivatable {
            InstalledModelRegistry.shared.register(record)
        }
        return preset.id
    }

    private func dirSize(at url: URL) -> Int64 {
        (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0
    }

    /// If `dest` isn't itself a model root but contains one nested up to two
    /// levels down, replaces `dest`'s contents with that nested root so the
    /// model files sit at the top level.
    private func normalizeModelLayout(at dest: URL) {
        let fm = FileManager.default
        if Self.isModelRoot(dest) { return }
        guard let found = Self.findModelRoot(under: dest, maxDepth: 2), found != dest else { return }

        // Move the discovered root aside, then swap it in for `dest`.
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("__import_tmp_\(dest.lastPathComponent)")
        try? fm.removeItem(at: tmp)
        do {
            try fm.moveItem(at: found, to: tmp)
            try fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            Diagnostics.shared.error("normalizeModelLayout failed: \(error)", category: "localimport")
        }
    }

    /// A directory is a model root if it holds an MLX `config.json`, a
    /// standalone text GGUF, or a complete GGUF VLM pair. Mirrors
    /// HFModelDownloadManager's readiness check.
    private static func isModelRoot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) { return true }
        return Self.hasGGUFPair(in: dir)
            || LocalModelFileValidator.hasValidGGUFTextModel(in: dir)
    }

    private static func findModelRoot(under root: URL, maxDepth: Int) -> URL? {
        if isModelRoot(root) { return root }
        guard maxDepth > 0 else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        for entry in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                if let found = findModelRoot(under: entry, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func hasGGUFPair(in dir: URL) -> Bool {
        LocalModelFileValidator.hasCompleteGGUFVLMPair(in: dir)
    }

    /// Unzip via Foundation's Process bridge isn't available on iOS, so we use
    /// NSFileCoordinator + the system "Archive Utility" style approach via the
    /// `Compression` framework. For .zip with a simple flat structure this
    /// works; complex zips should be pre-extracted on macOS.
    private func unzip(_ archive: URL, to dest: URL) async throws {
        // iOS doesn't expose a simple zip API without a third-party lib.
        // Throw WITHOUT creating the destination — the old code mkdir'd `dest`
        // first and then threw, orphaning an empty folder. (Also unreachable
        // now that .zip is no longer an accepted type.)
        throw NSError(domain: "LocalImport", code: -1, userInfo: [
            NSLocalizedDescriptionKey:
                "Zip imports aren't supported on iOS yet. Please extract on macOS first, then re-import the folder."
        ])
    }
}

// MARK: - LocalModelExportPicker
// Hands an installed model directory to the system document picker. The picker
// performs the copy directly to the user's chosen Files location, so the app
// does not create a second multi-gigabyte staging copy inside its sandbox.

struct LocalModelExportPicker: UIViewControllerRepresentable {

    let modelDirectory: URL
    let onComplete: () -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forExporting: [modelDirectory],
            asCopy: true
        )
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: () -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onComplete()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
