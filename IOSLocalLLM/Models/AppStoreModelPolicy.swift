import Foundation

/// Confirmed rights conflicts are blocked at download and runtime boundaries,
/// including selections persisted by a previous research build. This is not a
/// blanket license approval for other Hub repositories or user imports.
enum AppStoreModelPolicy {
    nonisolated static var isPublicDistribution: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }
    nonisolated static let publicVisionSelectionID = "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
    nonisolated static let auditedRevisions: [String: String] = {
        guard let url = Bundle.main.url(forResource: "AuditedModelRevisions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    /// Public downloads use a frozen source revision. Provenance is separate
    /// from license eligibility and validation of a previously installed cache.
    nonisolated static func downloadRevision(for repoID: String, fallback: String = "main",
                                             publicDistribution: Bool = isPublicDistribution,
                                             revisions: [String: String] = auditedRevisions) -> String? {
        guard publicDistribution else { return fallback }
        guard restriction(for: repoID, publicDistribution: true) == nil,
              let revision = revisions[repoID], revision.count == 40,
              revision.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return revision
    }
    nonisolated static let missingRevisionMessage = "This model has no verified source revision for the public app. Choose a catalog model whose source has been reviewed."

    nonisolated static func restriction(for identity: String, publicDistribution: Bool = isPublicDistribution) -> String? {
        guard publicDistribution else { return nil }
        let normalized = identity.lowercased()
        if normalized.contains("fastvlm") || normalized.contains("fastvithd") {
            return String(localized: "FastVLM is unavailable in the public app because its model license limits use to research. Choose SmolVLM2 in Models for Lens.")
        }
        if normalized.contains("youtu") {
            return String(localized: "This Youtu model is unavailable in the public app while its territory restrictions remain unresolved. Choose another model in Models.")
        }
        return nil
    }

    nonisolated static func visionSelection(_ stored: String, publicDistribution: Bool = isPublicDistribution) -> String {
        guard publicDistribution else { return stored }
        return stored.isEmpty || restriction(for: stored, publicDistribution: true) != nil
            ? publicVisionSelectionID : stored
    }
}
