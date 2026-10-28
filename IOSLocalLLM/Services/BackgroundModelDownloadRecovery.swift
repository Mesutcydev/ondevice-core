import Foundation
import UIKit

/// Reconnect only previously authorized transfers. Recovery never loads a
/// model or resumes image generation; installation keeps its existing checks.
@MainActor
enum BackgroundModelDownloadRecovery {
    private static var restoring = false

    static func restore() async {
        guard !restoring, UIApplication.shared.applicationState == .active else { return }
        restoring = true
        defer { restoring = false }
        let coordinator = BackgroundDownloadCoordinator.shared
        await coordinator.restoreSession()
        guard UIApplication.shared.applicationState == .active else { return }
        for job in Array(coordinator.jobs.values) {
            guard AppStoreModelPolicy.restriction(for: job.owner.repoID) == nil,
                  AppStoreModelPolicy.downloadRevision(for: job.owner.repoID, fallback: job.owner.revision) == job.owner.revision else { continue }
            switch job.owner.kind {
            case .hub:
                let center = ModelDownloadCenter.shared
                var manager = center.models.compactMap(\.downloader).first {
                    $0.backgroundDownloadID == job.id && $0.repoID == job.owner.repoID
                }
                if manager == nil {
                    let custom = HFModelDownloadManager(repoID: job.owner.repoID, destination: job.root(),
                        branch: job.owner.revision, fileAllowlist: job.owner.fileAllowlist)
                    custom.automaticallyRepackEdge035B = job.owner.repackEdge035B
                    center.registerCustom(repoID: job.owner.repoID, displayName: job.owner.displayName,
                        subtitle: job.owner.repoID, category: .assistant, sizeLabel: "", downloader: custom)
                    manager = center.models.compactMap(\.downloader).first { $0.backgroundDownloadID == job.id }
                }
                manager?.restoreBackgroundDownload(job)
            case .coreAI:
                guard let model = CoreAIZooCatalog.model(id: job.owner.id),
                      model.hfRepo == job.owner.repoID, model.revision == job.owner.revision else { continue }
                CoreAIDownloadCenter.shared.manager(for: model).restoreBackgroundDownload(job)
            case .classifier:
                guard let model = ClassifierCatalog.model(id: job.owner.id),
                      model.repo == job.owner.repoID, model.revision == job.owner.revision else { continue }
                CoreAIDownloadCenter.shared.restore(classifier: model, job: job)
            case .image:
                guard let model = ImageGenerationService.model(forID: job.owner.id),
                      model.id == job.owner.repoID else { continue }
                ImageGenerationService.shared.restoreBackgroundDownload(model, job: job)
            }
        }
    }
}
