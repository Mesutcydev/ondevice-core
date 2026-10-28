import Foundation

/// Audited MiniCPM-V 4.7 artifacts. The dense model uses the existing mtmd
/// runtime; the MoE model needs a different expert-streaming artifact/runtime
/// contract and must not be treated as an Edge0 or ordinary iPhone GGUF load.
enum MiniCPMV47Catalog {
    struct Model: Equatable, Sendable {
        let repoID: String
        let revision: String
        let displayName: String
        let modelFilename: String
        let projectorFilename: String
        let modelBytes: Int64
        let projectorBytes: Int64
        let approxRAMBytes: Int64
        let description: String

        var downloadBytes: Int64 { modelBytes + projectorBytes }
        var fileAllowlist: [String] {
            [modelFilename, projectorFilename, "README.md"]
        }
    }

    static let oneB = Model(
        repoID: "openbmb/MiniCPM-V-4.7-1B-gguf",
        revision: "6c2f4cb8bde51a00247e11003bbf66ca7c4f9249",
        displayName: "MiniCPM-V 4.7 1B (Q4_K_M GGUF)",
        modelFilename: "MiniCPM-V-4_7-1B-Q4_K_M.gguf",
        projectorFilename: "mmproj-model-f16.gguf",
        modelBytes: 672_003_680,
        projectorBytes: 1_110_117_984,
        // Conservative admission estimate, including the vision encoder's
        // load spike and runtime headroom. Download size is a separate value.
        approxRAMBytes: 3_200_000_000,
        description: "OpenBMB's compact image-understanding model for OCR, documents, and scene descriptions. Runs locally through llama.cpp; includes the vision encoder."
    )

    /// Only variants with a wired, compatible runtime enter the library.
    static let thirtyFiveB = Model(
        repoID: thirtyFiveBRepoID,
        revision: thirtyFiveBRevision,
        displayName: "MiniCPM-V 4.7 35B A3B (experimental)",
        modelFilename: "MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf",
        projectorFilename: "mmproj-model-f16.gguf",
        modelBytes: 15_503_944_896,
        projectorBytes: 1_119_575_840,
        approxRAMBytes: 4_800_000_000,
        description: "Experimental image understanding with experts streamed from storage. Requires a device with at least 12 GB RAM, a 16.6 GB download, and about 35 GB free for download and preparation. Performance varies by device."
    )
    static let downloadableModels = [oneB, thirtyFiveB]

    static let thirtyFiveBRepoID = "openbmb/MiniCPM-V-4.7-35B-A3B-gguf"
    static let thirtyFiveBRevision = "1e04eae556a075a1e78808a50266ed0b11de9bf1"
    static let minimum35BPhysicalMemory: Int64 = 11_000_000_000
    static let streaming35BRequirement = "MiniCPM-V 4.7 35B requires its dedicated expert-streaming backend and a prepared pack. Use the MiniCPM 35B library download; an ordinary GGUF load cannot run this model safely."

    /// Refuse a build without the private streaming runtime before native
    /// construction or unloading a usable Lens model.
    static func unavailableReason(for identity: String) -> String? {
        guard is35B(identity) else { return nil }
        #if canImport(ODMiniCPM)
        return nil
        #else
        return "This build does not include the MiniCPM 35B streaming runtime. Rebuild with scripts/bootstrap_minicpm_v47_runtime.py, or choose the 1B model."
        #endif
    }

    static func is35B(_ identity: String) -> Bool { normalized(identity).contains("minicpmv4735ba3b") }

    /// Local imports may use a renamed folder/repository identity. Admission
    /// must follow the actual model family rather than that user-facing alias.
    static func runtimeIdentity(repoID: String, modelPath: String?, hasStreamingReceipt: Bool) -> String {
        if hasStreamingReceipt || is35B(repoID) || modelPath.map(is35B) == true { return thirtyFiveBRepoID }
        if usesInstructVisionPrompt(for: repoID) || modelPath.map(usesInstructVisionPrompt) == true { return oneB.repoID }
        if let modelPath, let embedded = embeddedRuntimeIdentity(modelPath: modelPath) { return embedded }
        return repoID
    }

    /// The official 35B GGUF embeds the conversion name
    /// `35a3_hf_v47_0923`, rather than its public repository name. Inspect only
    /// bounded leading metadata, so renaming the GGUF cannot bypass admission.
    static func embeddedRuntimeIdentity(modelPath: String) -> String? {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath)) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_536) else { return nil }
        var cursor = 0
        func number(_ count: Int) -> UInt64? {
            guard cursor <= data.count, count <= data.count - cursor else { return nil }
            defer { cursor += count }
            return data[cursor..<(cursor + count)].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func string() -> String? {
            guard let length = number(8), length <= 8_192, cursor <= data.count,
                  Int(length) <= data.count - cursor else { return nil }
            defer { cursor += Int(length) }
            return String(data: data[cursor..<(cursor + Int(length))], encoding: .utf8)
        }
        guard number(4) == 0x4655_4747, number(4) == 3,
              number(8) != nil, let count = number(8), count <= 10_000 else { return nil }
        var architecture: String?, name: String?
        let widths: [UInt64: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        for _ in 0..<min(count, 32) {
            guard let key = string(), let type = number(4) else { return nil }
            if type == 8 {
                guard let value = string() else { return nil }
                if key == "general.architecture" { architecture = value }
                if key == "general.name" { name = value }
            } else if let width = widths[type] {
                guard number(width) != nil else { return nil }
            } else { return nil } // Never walk tokenizer arrays or tensor data.
            if let architecture, let name {
                if is35B(name) || (architecture == "qwen35moe" && normalized(name).hasPrefix("35a3hfv47")) {
                    return thirtyFiveBRepoID
                }
                if usesInstructVisionPrompt(for: name) { return oneB.repoID }
                return nil
            }
        }
        return nil
    }

    static func usesInstructVisionPrompt(for identity: String) -> Bool {
        normalized(identity).contains("minicpmv471b")
    }

    /// The publisher's enable_thinking=false template. Short Lens requests
    /// should produce an answer within their token budget, without spending
    /// that budget on an unfinished reasoning trace.
    static func instructVisionPrompt(_ prompt: String, marker: String) -> String {
        let content: String
        if prompt.contains(marker) {
            content = prompt
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = marker
        } else {
            content = "\(marker)\n\(prompt)"
        }
        return "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    private static func normalized(_ identity: String) -> String {
        identity.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
