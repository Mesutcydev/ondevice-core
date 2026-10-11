import Foundation

// Unrelated Assistant types only. The classifier catalog and its library
// projection are compiled from production sources; no inference is performed.
enum ModelCapability: Hashable, Sendable { case thinking, tools, vision }
enum ModelRuntime: Sendable { case mlx, llamaCpp, coreAI }
struct AssistantModel: Sendable {
    let id: String
    let repoID: String
    let displayName: String
    let subtitle: String
    let approxRAMBytes: Int64
    let tags: [String]
    let contextWindowTokens: Int
    var downloadSizeBytes: Int64? = nil
    var capabilities: Set<ModelCapability> = []
    var supportsTools: Bool = false
    var runtime: ModelRuntime = .mlx
}
