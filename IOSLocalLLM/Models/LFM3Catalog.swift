import Foundation

/// Liquid's published GGUF artifacts. These are optional user downloads;
/// neither the weights nor the vision projector are bundled with the app.
enum LFM3Catalog {
    /// The production app keeps its validated shared runtime. An experimental
    /// build must explicitly select the separately bootstrapped LFM3 runtime.
    static var isEnabled: Bool {
        #if LFM3_EXPERIMENTAL
        true
        #else
        false
        #endif
    }

    struct Model: Equatable, Sendable {
        let repoID: String
        let revision: String
        let modelFilename: String
        let modelBytes: Int64
        let projectorFilename: String?
        let projectorBytes: Int64

        var downloadBytes: Int64 { modelBytes + projectorBytes }
        var fileAllowlist: [String] {
            [modelFilename] + (projectorFilename.map { [$0] } ?? []) + ["README.md", "LICENSE"]
        }
    }

    static let text = Model(
        repoID: "LiquidAI/LFM3-1.7B-GGUF",
        revision: "b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf",
        modelFilename: "LFM3-1.7B-QAD-Q4_0.gguf",
        modelBytes: 1_049_615_680,
        projectorFilename: nil,
        projectorBytes: 0
    )

    static let vision = Model(
        repoID: "LiquidAI/LFM3-VL-2B-GGUF",
        revision: "7c3b4a43c9023e80bf234fec5e826a3365c8dda8",
        modelFilename: "LFM3-VL-2B-QAD-Q4_0.gguf",
        modelBytes: 1_049_615_648,
        projectorFilename: "mmproj-LFM3-VL-2B-Q8_0.gguf",
        projectorBytes: 203_031_872
    )

    static func isFamily(_ identity: String) -> Bool {
        identity.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.contains("lfm3")
    }

    static func unavailableReason(for identity: String) -> String? {
        guard !isEnabled, isFamily(identity) else { return nil }
        return "LFM3 needs the experimental LFM3 runtime; this build uses the existing llama.cpp runtime."
    }

    static func isVision(_ identity: String) -> Bool {
        identity.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .contains("lfm3vl2b")
    }

    /// mtmd expands the marker to Liquid's vision-start/image/vision-end
    /// tokens. Lens uses the publisher's non-thinking assistant prefix so a
    /// short image request does not spend its answer budget on reasoning.
    static func visionPrompt(_ prompt: String, marker: String) -> String {
        let content: String
        if prompt.contains(marker) {
            content = prompt
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = marker
        } else {
            content = "\(marker)\n\(prompt)"
        }
        return "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }
}
