import Foundation
import OnDeviceUI

enum ClassifierModelLibrary {
    static func entry(for model: ClassifierCatalogModel, installed: Bool = false,
                      transfer: CoreAIModelLibrary.Transfer? = nil) -> ODModel {
        var commands: [ODModelCommand] = installed ? [.details, .delete] : [.details]
        var status: String?
        var progress: Double?
        var paused = false
        if !installed {
            switch transfer {
            case .preparing: status = "Preparing download"
            case .downloading(let value): status = "Downloading"; progress = value
            case .paused(let value): status = "Paused"; progress = value; paused = true
            case .installing: status = "Installing"
            case .failed: status = "Download failed"
            case nil: break
            }
            if transfer == nil || paused || transfer == .failed { commands.append(.download) }
            if transfer == .preparing || status == "Downloading" { commands.append(.pauseDownload) }
            if transfer != nil && transfer != .installing { commands.append(.cancelDownload) }
        }
        let runtime = model.runtime == .gguf ? "GGUF" : "Core ML"
        return ODModel(id: model.selectionID, name: model.name,
            metadata: "\(runtime) · \(model.repo) · \(model.license)", byteCount: model.bytes,
            kind: .classifier, supportedKinds: installed ? [.classifier] : [], declaredKinds: [.classifier],
            isInstalled: installed, isSelectable: installed, availableCommands: commands,
            downloadStatus: status, downloadProgress: progress, estimatedMemoryBytes: model.estimatedPeak,
            isDownloadPaused: paused, summary: model.summary, vendor: runtime,
            badges: [runtime, model.isImage ? "Images" : "Decisions"])
    }
}
