import Foundation
import OnDeviceUI

/// Shared production/QA projection. Catalog packs are visible before installation;
/// availability and Assistant selection are separate from download capability.
enum CoreAIModelLibrary {
    enum Transfer: Equatable {
        case preparing, downloading(Double), paused(Double), installing, failed
    }

    static var catalog: [CoreAIZooModel] {
        CoreAIZooCatalog.iphoneLanguageModels + CoreAIZooCatalog.macOnlyClassifierModels
    }

    static func entry(for pack: CoreAIZooModel, isInstalled: Bool = false,
                      isDefault: Bool = false, transfer: Transfer? = nil) -> ODModel {
        let macOnly = CoreAIZooCatalog.macOnlyClassifierModels.contains { $0.id == pack.id }
        let isChat = pack.category == .officialRecipe || pack.category == .chat
        let kind: ODModelKind
        switch pack.category {
        case .officialRecipe, .chat: kind = .language
        case .classifier: kind = .classifier
        case .vision: kind = .vision
        case .utility: kind = .utility
        }
        var commands: [ODModelCommand] = isInstalled ? [.details, .delete] : [.details]
        var status: String?
        var progress: Double?
        var paused = false
        if !isInstalled && !macOnly {
            switch transfer {
            case .preparing: status = "Preparing download"
            case .downloading(let value): status = "Downloading"; progress = value
            case .paused(let value): status = "Paused"; progress = value; paused = true
            case .installing: status = "Installing"
            case .failed: status = "Download failed"
            case nil: break
            }
            if transfer == nil || paused || transfer == .failed { commands.append(.download) }
            if case .downloading = transfer { commands.append(.pauseDownload) }
            if case .preparing = transfer { commands.append(.pauseDownload) }
            if transfer != nil && transfer != .installing { commands.append(.cancelDownload) }
        }
        return ODModel(
            id: pack.assistantSelectionID, name: pack.displayName,
            metadata: "Core AI · \(pack.hfRepo) · \(pack.category.rawValue)",
            byteCount: pack.approxDownloadBytes, kind: kind,
            supportedKinds: isChat && !macOnly ? [.language] : (kind == .classifier && isInstalled && !macOnly ? [.classifier] : []), declaredKinds: [kind],
            isInstalled: isInstalled, isDefault: isChat && isDefault,
            isSelectable: (isChat || (kind == .classifier && isInstalled)) && !macOnly,
            unavailableReason: macOnly ? "This published Core AI pack is for Mac. iPhone download is unavailable; the publisher has only validated this export on Mac." : nil,
            availableCommands: commands, downloadStatus: status, downloadProgress: progress,
            estimatedMemoryBytes: isChat ? pack.assistantModel.approxRAMBytes : nil,
            isDownloadPaused: paused,
            summary: macOnly ? "Typed decisions · Mac Core AI pack" : pack.subtitle,
            vendor: "Core AI", badges: macOnly ? ["Core AI", "Mac only"] : ["Core AI", kind.title]
        )
    }
}
