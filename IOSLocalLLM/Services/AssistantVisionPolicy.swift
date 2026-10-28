import Foundation

/// Assistant owns its input capabilities independently of the Lens selection.
/// The shared owner still enforces one runtime and the full vision memory budget.
enum AssistantVisionPolicy {
    static func shouldLoadSharedRuntime(
        isSupportedMultimodal: Bool,
        requiredVisionBytes: UInt64,
        availableBytes: UInt64
    ) -> Bool {
        isSupportedMultimodal && requiredVisionBytes > 0 && availableBytes >= requiredVisionBytes
    }
}
