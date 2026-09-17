import Foundation

// MARK: - Edge0ModelFamily
//
// Edge0 native runtimes are family implementations, not a single model. The
// family is decided by the curated identity of the selected checkpoint (exact
// repository id), never by the architecture string alone: an arbitrary
// Qwen3.5-MoE checkpoint must not be routed into the Edge0-35B release
// contract (true-router K=4 + Recover-LoRA + bounded per-token experts).
//
// The runtime surface stays `.edge0MLX`; this enum only chooses the engine
// and the family-specific admission/metadata.

enum Edge0ModelFamily: String, Sendable, CaseIterable {
    case bailing8B = "Edge0-8B"
    case qwen35MoE = "Edge0-35B"

    /// Curated repository ids (the release identity for each family).
    static let bailing8BRepoID = "Edge0/Edge0-8B-A1B-preview"
    static let qwen35MoERepoID = "Edge0/Edge0-35B-A3B-preview"

    /// Pinned Edge0 source revision for the 35B release contract.
    static let qwen35MoEPinnedRevision =
        "1ff9f4478890faec0368c5463b621d1036d5b518"

    /// Exact curated repo-id match. Returns nil for any other checkpoint, so
    /// the backend refuses instead of guessing a family.
    static func resolve(repoID: String) -> Edge0ModelFamily? {
        switch repoID {
        case bailing8BRepoID: return .bailing8B
        case qwen35MoERepoID: return .qwen35MoE
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .bailing8B: return "Edge0-8B (Bailing-Ling)"
        case .qwen35MoE: return "Edge0-35B (Qwen3.5-MoE)"
        }
    }

    /// True for families whose runtime is bring-up/experimental.
    var isExperimental: Bool { self == .qwen35MoE }

    var repoID: String {
        switch self {
        case .bailing8B: return Self.bailing8BRepoID
        case .qwen35MoE: return Self.qwen35MoERepoID
        }
    }
}
