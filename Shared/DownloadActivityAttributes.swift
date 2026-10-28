import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

struct DownloadActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case downloading, verifying, preparing, completed, paused, cancelled, failed
    }
    struct ContentState: Codable, Hashable {
        var progress: Double
        var downloadedBytes: Int64
        var totalBytes: Int64
        var currentFile: String
        var filesDone: Int
        var filesTotal: Int
        var phase: Phase
    }
    /// An opaque job identifier keeps different variants independent.
    var repoID: String
    var displayName: String
    static let downloadsURL = URL(string: "tokenai://downloads")!
}
#endif
